$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$stateDir = Join-Path $root "work\job-monitor"
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$seenPath = Join-Path $stateDir "oracle-cloud-seen-jobs.json"
$ntfyTopic = if ($env:ROLEPILOT_NTFY_TOPIC) { [string]$env:ROLEPILOT_NTFY_TOPIC } else { "https://ntfy.sh/oracle_integrations" }
$minYears = if ($env:ROLEPILOT_MIN_YEARS) { [int]$env:ROLEPILOT_MIN_YEARS } else { 2 }
$maxAlertsPerRun = 25

$oracleSkills = @(
  @{ name = "Oracle Integration Cloud (OIC)"; pattern = 'oracle integration cloud|\boic\b|oracle integrations?' },
  @{ name = "Oracle Cloud Infrastructure (OCI)"; pattern = 'oracle cloud infrastructure|\boci\b' },
  @{ name = "Visual Builder Cloud Service (VBCS)"; pattern = 'visual builder cloud service|\bvbcs\b|oracle visual builder' },
  @{ name = "Oracle HCM"; pattern = 'oracle hcm|hcm cloud|oracle fusion hcm|fusion hcm' }
)

$searches = @(
  [ordered]@{ name = "Oracle OIC India"; query = '("Oracle Integration Cloud" OR OIC OR "Oracle Integration") (India OR Bengaluru OR Hyderabad OR Pune OR Chennai OR Mumbai OR Gurugram) (jobs OR careers OR hiring)'; maxResults = 30 },
  [ordered]@{ name = "Oracle OCI India"; query = '("Oracle Cloud Infrastructure" OR OCI) (India OR Bengaluru OR Hyderabad OR Pune OR Chennai OR Mumbai OR Gurugram) (jobs OR careers OR hiring)'; maxResults = 30 },
  [ordered]@{ name = "Oracle VBCS India"; query = '("Visual Builder Cloud Service" OR VBCS OR "Oracle Visual Builder") (India OR Bengaluru OR Hyderabad OR Pune OR Chennai OR Mumbai OR Gurugram) (jobs OR careers OR hiring)'; maxResults = 25 },
  [ordered]@{ name = "Oracle HCM India"; query = '("Oracle HCM" OR "HCM Cloud" OR "Oracle Fusion HCM") (India OR Bengaluru OR Hyderabad OR Pune OR Chennai OR Mumbai OR Gurugram) (jobs OR careers OR hiring)'; maxResults = 30 },
  [ordered]@{ name = "Oracle Cloud ATS India"; query = '(OIC OR OCI OR VBCS OR "Oracle HCM") (India OR Bengaluru OR Hyderabad OR Pune OR Chennai) (greenhouse OR lever OR workdayjobs OR smartrecruiters OR taleo OR successfactors)'; maxResults = 30 },
  [ordered]@{ name = "LinkedIn Oracle Cloud India"; query = 'site:linkedin.com/jobs/view (OIC OR OCI OR VBCS OR "Oracle HCM") (India OR Bengaluru OR Hyderabad OR Pune OR Chennai OR Remote)'; maxResults = 30 }
)

function Normalize-Text($value) {
  if ($null -eq $value) { return "" }
  return ([string]$value) -replace '<[^>]+>', ' ' -replace '&nbsp;', ' ' -replace '\s+', ' '
}

function Canonical-Url($url) {
  if ([string]::IsNullOrWhiteSpace([string]$url)) { return "" }
  return (([string]$url -replace '([?&])utm_[^&]+', '$1' -replace '[?&]$', '').Trim().ToLowerInvariant())
}

function Get-SkillMatches($text) {
  $matches = New-Object System.Collections.Generic.List[string]
  foreach ($skill in $oracleSkills) {
    if ($text -match $skill.pattern) { $matches.Add($skill.name) }
  }
  return @($matches | Select-Object -Unique)
}

function Test-OracleCandidate($title, $link, $description) {
  $hay = "$title $link $description".ToLowerInvariant()
  if ($hay -match 'internship|\bintern\b|principal|director|manager|architect|training course|certification|question paper|walkin|walk-in|bpo|customer support|sales|account executive') { return $false }
  if ($hay -notmatch 'india|bengaluru|bangalore|hyderabad|pune|chennai|mumbai|gurugram|noida|remote') { return $false }
  if ((Get-SkillMatches $hay).Count -lt 1) { return $false }
  return $link -match 'linkedin\.com/jobs|greenhouse|lever\.co|myworkdayjobs|smartrecruiters|careers|jobs|job|naukri|indeed|foundit|instahyre|hirist|taleo|successfactors'
}

function Get-SearchJobs($search) {
  $jobs = New-Object System.Collections.Generic.List[object]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  try {
    $rssUrl = "https://www.bing.com/search?q=" + [Uri]::EscapeDataString([string]$search.query) + "&format=rss&count=50"
    $rssContent = (Invoke-WebRequest -UseBasicParsing -Uri $rssUrl -TimeoutSec 25).Content
    $rss = [xml]$rssContent
    foreach ($item in @($rss.rss.channel.item)) {
      $title = Normalize-Text $item.title
      $link = Normalize-Text $item.link
      $description = Normalize-Text $item.description
      if (-not (Test-OracleCandidate $title $link $description)) { continue }
      $key = Canonical-Url $link
      if (-not $seen.Add($key)) { continue }
      $jobs.Add([pscustomobject]@{ title = $title; link = $link; content = $description; source = $search.name })
      if ($jobs.Count -ge [int]$search.maxResults) { break }
    }
  } catch {
    Write-Warning "Search failed for $($search.name): $($_.Exception.Message)"
  }
  return $jobs
}

function Get-GoogleJobs($search) {
  $jobs = New-Object System.Collections.Generic.List[object]
  if ([string]::IsNullOrWhiteSpace($env:GOOGLE_API_KEY) -or [string]::IsNullOrWhiteSpace($env:GOOGLE_CSE_ID)) { return $jobs }
  try {
    $uri = "https://www.googleapis.com/customsearch/v1?key=$([Uri]::EscapeDataString($env:GOOGLE_API_KEY))&cx=$([Uri]::EscapeDataString($env:GOOGLE_CSE_ID))&q=$([Uri]::EscapeDataString([string]$search.query))&num=10&sort=date"
    $payload = (Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 25).Content | ConvertFrom-Json
    foreach ($item in @($payload.items)) {
      $title = Normalize-Text $item.title
      $link = Normalize-Text $item.link
      $description = Normalize-Text $item.snippet
      if (-not (Test-OracleCandidate $title $link $description)) { continue }
      $jobs.Add([pscustomobject]@{ title = $title; link = $link; content = $description; source = $search.name })
    }
  } catch {
    Write-Warning "Google search failed for $($search.name): $($_.Exception.Message)"
  }
  return $jobs
}

function Get-ExperienceNote($text) {
  $hay = $text.ToLowerInvariant()
  if ($hay -match '(\d+)\s*\+?\s*years?') {
    $years = [int]$Matches[1]
    if ($years -ge $minYears) { return "$years+ years mentioned" }
    return "$years years mentioned; review experience requirement"
  }
  return "$minYears+ years target; verify experience requirement"
}

function Send-NtfyJobAlert($job) {
  $body = @(
    $job.title
    "Skills: $($job.skills -join ', ')"
    "Experience: $($job.experience)"
    "Source: $($job.source)"
  ) -join "`n"
  $headers = @{ Title = "Oracle Cloud Job: $($job.company)"; Priority = "high"; Tags = "briefcase"; Click = $job.link }
  try {
    Invoke-WebRequest -UseBasicParsing -Method Post -Uri $ntfyTopic -Headers $headers -Body $body -TimeoutSec 20 | Out-Null
    return $true
  } catch {
    Write-Warning "ntfy alert failed for $($job.link): $($_.Exception.Message)"
    return $false
  }
}

$seenKeys = New-Object 'System.Collections.Generic.HashSet[string]'
if (Test-Path $seenPath) {
  try {
    $previous = Get-Content -Raw $seenPath | ConvertFrom-Json
    foreach ($item in @($previous.jobs)) { if ($item.canonicalUrl) { [void]$seenKeys.Add([string]$item.canonicalUrl) } }
  } catch { Write-Warning "Could not read seen-job state: $($_.Exception.Message)" }
}

$jobMap = @{}
foreach ($search in $searches) {
  foreach ($raw in @(Get-SearchJobs $search) + @(Get-GoogleJobs $search)) {
    $key = Canonical-Url $raw.link
    if (-not $key) { continue }
    $hay = "$($raw.title) $($raw.content)".ToLowerInvariant()
    $skills = Get-SkillMatches $hay
    if ($skills.Count -lt 1) { continue }
    if (-not $jobMap.ContainsKey($key)) {
      $company = try { ([Uri]$raw.link).Host -replace '^www\.', '' } catch { "Job board" }
      $jobMap[$key] = [pscustomobject]@{
        title = $raw.title; link = $raw.link; company = $company; source = $raw.source; skills = $skills
        experience = Get-ExperienceNote $hay; canonicalUrl = $key
      }
    }
  }
}

$jobs = @($jobMap.Values | Sort-Object title)
$newJobs = @($jobs | Where-Object { -not $seenKeys.Contains($_.canonicalUrl) } | Select-Object -First $maxAlertsPerRun)
$posted = 0
foreach ($job in $newJobs) {
  if (Send-NtfyJobAlert $job) { $posted += 1; [void]$seenKeys.Add($job.canonicalUrl) }
}

$state = [ordered]@{
  updatedAt = [DateTimeOffset]::Now.ToString("yyyy-MM-ddTHH:mm:sszzz")
  jobs = @($seenKeys | ForEach-Object { [ordered]@{ canonicalUrl = $_ } })
}
$state | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -Path $seenPath

[pscustomobject]@{
  generatedAt = [DateTimeOffset]::Now.ToString("yyyy-MM-ddTHH:mm:sszzz")
  relevantJobs = $jobs.Count
  newJobs = $newJobs.Count
  ntfyPosted = $posted
  ntfyTopic = $ntfyTopic
  skills = @($oracleSkills.name)
} | ConvertTo-Json -Depth 4
