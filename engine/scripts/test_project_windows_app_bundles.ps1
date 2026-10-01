[CmdletBinding()]
param([string]$ReportPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'common.ps1')
Import-Module (Join-Path $PSScriptRoot 'project_engine_bootstrap.psm1') -Force

$lock = Get-EngineLock
$layout = Get-EngineWorkspaceLayout (Join-Path $repository '.kfe')
$results = @()
foreach ($mode in 'debug', 'profile', 'release') {
  $ready = Assert-KirakaraProjectEngineReady -Mode $mode
  $build = Get-BuildLock -Lock $lock -Mode $mode -Variant patched
  $configuration = switch ($mode) {
    'debug' { 'Debug' }
    'profile' { 'Profile' }
    'release' { 'Release' }
  }
  $bundle = Join-Path $repository "build\windows\x64\runner\$configuration"
  $executable = Join-Path $bundle 'kirakara_app.exe'
  $bundleDll = Join-Path $bundle 'flutter_windows.dll'
  $engineDll = Join-Path $ready.output 'flutter_windows.dll'
  foreach ($path in $executable, $bundleDll, $engineDll) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "$mode App bundle input is missing: $path"
    }
  }
  Assert-MatchingFile `
    -ExpectedPath $engineDll `
    -ActualPath $bundleDll `
    -Label "$mode repository-local Engine DLL"
  $hash = (Get-FileHash -LiteralPath $bundleDll -Algorithm SHA256).Hash
  $results += [ordered]@{
    mode = $mode
    localEngine = [string]$build.localEngine
    readyFingerprint = [string]$ready.fingerprint
    executable = [IO.Path]::GetRelativePath($repository, $executable).Replace('\', '/')
    flutterWindowsDllSha256 = $hash
    flutterWindowsDllSize = (Get-Item -LiteralPath $bundleDll).Length
    bundleMatchesReadyEngine = $true
  }
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $ReportPath = Join-Path $repository `
    "build\diagnostics\engine\project-app-bundles-$stamp.json"
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
Write-Host "Project App bundle tests passed. Report: $absoluteReport"
