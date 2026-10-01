[CmdletBinding()]
param([string]$ReportPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$workspace = Join-Path $repository '.kfe'
$wrapper = Join-Path $repository 'flutterw.ps1'
. (Join-Path $PSScriptRoot 'common.ps1')

$lock = Get-EngineLock
$layout = Get-EngineWorkspaceLayout $workspace
$before = @()
foreach ($mode in 'debug', 'profile', 'release') {
  $build = Get-BuildLock -Lock $lock -Mode $mode -Variant patched
  $output = Get-EngineOutputDirectory -Layout $layout -LocalEngine $build.localEngine
  $stamp = Join-Path $layout.State "$mode-ready.json"
  $dll = Join-Path $output 'flutter_windows.dll'
  foreach ($path in $stamp, $dll) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Clean-boundary input is missing: $path"
    }
  }
  $before += [ordered]@{
    mode = $mode
    readyStampSha256 = (Get-FileHash -LiteralPath $stamp -Algorithm SHA256).Hash
    engineDllSha256 = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
  }
}

$output = @(& $wrapper clean *>&1)
$exitCode = $LASTEXITCODE
$output | Out-Host
if ($exitCode -ne 0) {
  throw "flutterw clean failed with exit code $exitCode."
}
if (-not (Test-Path -LiteralPath $workspace -PathType Container)) {
  throw 'flutterw clean removed the repository-local Engine workspace.'
}
$appBuildRemoved = -not (Test-Path -LiteralPath (
    Join-Path $repository 'build\windows') -PathType Container)
if (-not $appBuildRemoved) {
  throw 'flutterw clean did not remove the generated Windows App build.'
}

$after = @()
foreach ($entry in $before) {
  $build = Get-BuildLock -Lock $lock -Mode $entry.mode -Variant patched
  $outputDirectory = Get-EngineOutputDirectory `
    -Layout $layout -LocalEngine $build.localEngine
  $stamp = Join-Path $layout.State "$($entry.mode)-ready.json"
  $dll = Join-Path $outputDirectory 'flutter_windows.dll'
  $stampHash = (Get-FileHash -LiteralPath $stamp -Algorithm SHA256).Hash
  $dllHash = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
  if ($stampHash -ne $entry.readyStampSha256 -or
      $dllHash -ne $entry.engineDllSha256) {
    throw "flutterw clean changed repository-local $($entry.mode) Engine state."
  }
  $after += [ordered]@{
    mode = $entry.mode
    readyStampSha256 = $stampHash
    engineDllSha256 = $dllHash
    unchanged = $true
  }
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $ReportPath = Join-Path $repository `
    "build\diagnostics\engine\flutterw-clean-boundary-$stamp.json"
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
  flutterCleanExitCode = $exitCode
  appWindowsBuildRemoved = $appBuildRemoved
  repositoryEngineWorkspacePreserved = $true
  modes = @($after)
  passed = $true
} | ConvertTo-Json -Depth 6 | Set-Content `
  -LiteralPath $absoluteReport `
  -Encoding utf8
Write-Host "flutterw clean boundary passed. Report: $absoluteReport"
