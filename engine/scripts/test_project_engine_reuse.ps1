[CmdletBinding()]
param([string]$ReportPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$wrapper = Join-Path $repository 'flutterw.ps1'
$results = @()

foreach ($mode in 'debug', 'profile', 'release') {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $output = @(& $wrapper engine prepare $mode *>&1)
  $exitCode = $LASTEXITCODE
  $watch.Stop()
  $text = @($output | ForEach-Object { $_.ToString() }) -join "`n"
  $output | Out-Host
  if ($exitCode -ne 0) {
    throw "Second $mode prepare failed with exit code $exitCode."
  }
  $reportedSourceReuse = $text -match "Reusing verified $mode Engine"
  $reportedPrebuiltReuse =
    $text -match '复用已完整校验的 flutter-engine 包' -and
    $text -match "$mode 预编译 Engine 已准备"
  if (-not ($reportedSourceReuse -or $reportedPrebuiltReuse)) {
    throw "Second $mode prepare did not report verified reuse."
  }
  $forbidden = @(
    'Fetching and synchronizing',
    'Building only the requested',
    'Generating patched Windows Engine',
    'gclient sync',
    'ninja:'
  )
  $matches = @($forbidden | Where-Object { $text -match [regex]::Escape($_) })
  if ($matches.Count -ne 0) {
    throw "Second $mode prepare repeated build work: $($matches -join ', ')"
  }
  $results += [ordered]@{
    mode = $mode
    exitCode = $exitCode
    durationMilliseconds = $watch.ElapsedMilliseconds
    reportedVerifiedReuse = $true
    reuseKind = if ($reportedPrebuiltReuse) { 'prebuilt' } else { 'source' }
    repeatedFetchSyncGnOrNinja = $false
  }
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $ReportPath = Join-Path $repository `
    "build\diagnostics\engine\project-engine-reuse-$stamp.json"
}
$absoluteReport = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
  $ReportPath)
if (Test-Path -LiteralPath $absoluteReport) {
  throw "ReportPath already exists: $absoluteReport"
}
New-Item -ItemType Directory -Path (Split-Path -Parent $absoluteReport) `
  -Force | Out-Null
[ordered]@{
  schemaVersion = 1
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  results = @($results)
  passed = $true
} | ConvertTo-Json -Depth 6 | Set-Content `
  -LiteralPath $absoluteReport `
  -Encoding utf8
Write-Host "Project Engine reuse tests passed. Report: $absoluteReport"
