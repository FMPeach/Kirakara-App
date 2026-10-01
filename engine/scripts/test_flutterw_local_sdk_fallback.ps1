[CmdletBinding()]
param(
  [string[]]$WrapperArguments = @('pub', 'get'),
  [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$wrapper = Join-Path $repository 'flutterw.ps1'
$lock = Get-Content -Raw -LiteralPath (
  Join-Path $repository 'engine\engine.lock.json') | ConvertFrom-Json
$localSdk = Join-Path $repository '.kfe\sdk'

function Get-EnvironmentSnapshot {
  param(
    [Parameter(Mandatory = $true)]
    [EnvironmentVariableTarget]$Target
  )

  $result = [Collections.Generic.Dictionary[string, string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in [Environment]::GetEnvironmentVariables(
      $Target).GetEnumerator()) {
    $result[[string]$entry.Key] = [string]$entry.Value
  }
  return $result
}

function Get-ChangedEnvironmentNames {
  param(
    [Parameter(Mandatory = $true)]$Before,
    [Parameter(Mandatory = $true)]$After
  )

  $names = @($Before.Keys) + @($After.Keys) | Sort-Object -Unique
  return @($names | Where-Object {
      -not $Before.ContainsKey($_) -or
      -not $After.ContainsKey($_) -or
      $Before[$_] -cne $After[$_]
    })
}

function Get-TextSha256 {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString(
        $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
      )).Replace('-', '')
  } finally {
    $sha.Dispose()
  }
}

$visibleFlutterCommands = @(Get-Command flutter.bat, flutter `
    -All -ErrorAction SilentlyContinue)
$externalFlutterRoots = @($visibleFlutterCommands | ForEach-Object {
    Split-Path -Parent (Split-Path -Parent $_.Source)
  } | Sort-Object -Unique)
$flutterCommandDirectories = [Collections.Generic.HashSet[string]]::new(
  [StringComparer]::OrdinalIgnoreCase)
foreach ($command in $visibleFlutterCommands) {
  $null = $flutterCommandDirectories.Add(
    [IO.Path]::GetFullPath((Split-Path -Parent $command.Source)).TrimEnd('\'))
}

$originalPath = $env:Path
$explicitSdk = [Environment]::GetEnvironmentVariable(
  'KIRAKARA_FLUTTER_SDK_ROOT', 'Process')
$sdkExistedBefore = Test-Path -LiteralPath $localSdk -PathType Container
$durationMilliseconds = 0
$outputText = ''
$wrapperExitCode = -1
$processChanges = @()
$userChanges = @()
$machineChanges = @()
$gitBefore = ''
$gitAfter = ''
$externalStatusesBefore = @{}
$externalStatusesAfter = @{}

try {
  $env:Path = @($originalPath -split ';' | Where-Object {
      if ([string]::IsNullOrWhiteSpace($_)) {
        return $false
      }
      $candidate = [IO.Path]::GetFullPath($_).TrimEnd('\')
      return -not $flutterCommandDirectories.Contains($candidate)
    }) -join ';'
  Remove-Item Env:\KIRAKARA_FLUTTER_SDK_ROOT -ErrorAction SilentlyContinue
  if (Get-Command flutter.bat, flutter -ErrorAction SilentlyContinue) {
    throw 'A system Flutter command remains visible after PATH isolation.'
  }

  $processBefore = Get-EnvironmentSnapshot -Target Process
  $userBefore = Get-EnvironmentSnapshot -Target User
  $machineBefore = Get-EnvironmentSnapshot -Target Machine
  $gitBefore = @(& git config --global --null --list 2>&1) -join "`n"
  foreach ($root in $externalFlutterRoots) {
    $externalStatusesBefore[$root] = @(
      & git -C $root status --short 2>&1) -join "`n"
  }

  $watch = [Diagnostics.Stopwatch]::StartNew()
  $output = @(& $wrapper @WrapperArguments *>&1)
  $wrapperExitCode = $LASTEXITCODE
  $watch.Stop()
  $durationMilliseconds = $watch.ElapsedMilliseconds
  $output | Out-Host
  $outputText = @($output | ForEach-Object { $_.ToString() }) -join "`n"

  $processAfter = Get-EnvironmentSnapshot -Target Process
  $userAfter = Get-EnvironmentSnapshot -Target User
  $machineAfter = Get-EnvironmentSnapshot -Target Machine
  $gitAfter = @(& git config --global --null --list 2>&1) -join "`n"
  foreach ($root in $externalFlutterRoots) {
    $externalStatusesAfter[$root] = @(
      & git -C $root status --short 2>&1) -join "`n"
  }
  $processChanges = @(
    Get-ChangedEnvironmentNames $processBefore $processAfter)
  $userChanges = @(Get-ChangedEnvironmentNames $userBefore $userAfter)
  $machineChanges = @(
    Get-ChangedEnvironmentNames $machineBefore $machineAfter)
} finally {
  $env:Path = $originalPath
  [Environment]::SetEnvironmentVariable(
    'KIRAKARA_FLUTTER_SDK_ROOT', $explicitSdk, 'Process')
}

if ($wrapperExitCode -ne 0) {
  throw "Repository-local Flutter SDK invocation failed: $wrapperExitCode"
}
if ($outputText -notmatch [regex]::Escape("$localSdk (.kfe/sdk")) {
  throw 'flutterw did not report the repository-local Flutter SDK.'
}
if ($processChanges.Count -ne 0) {
  throw "flutterw leaked process environment: $($processChanges -join ', ')"
}
if ($userChanges.Count -ne 0 -or $machineChanges.Count -ne 0) {
  throw 'flutterw changed persistent user or machine environment variables.'
}
if ($gitBefore -cne $gitAfter) {
  throw 'flutterw changed global Git configuration.'
}
foreach ($root in $externalFlutterRoots) {
  if ($externalStatusesBefore[$root] -cne $externalStatusesAfter[$root]) {
    throw "flutterw changed the external Flutter SDK: $root"
  }
}

$head = @(& git -C $localSdk rev-parse HEAD 2>&1)
if ($LASTEXITCODE -ne 0 -or $head.Count -ne 1) {
  throw "Repository-local Flutter SDK has no valid HEAD: $localSdk"
}
$head = ([string]$head[0]).Trim()
$engineVersion = (Get-Content -Raw -LiteralPath (
    Join-Path $localSdk 'bin\internal\engine.version')).Trim()
$trackedChanges = @(& git -C $localSdk status --short 2>&1)
if ($head -ne [string]$lock.flutter.frameworkRevision) {
  throw "Framework revision mismatch. Expected $($lock.flutter.frameworkRevision), got $head."
}
if ($engineVersion -ne [string]$lock.flutter.engineRevision) {
  throw "Engine revision mismatch. Expected $($lock.flutter.engineRevision), got $engineVersion."
}
if ($trackedChanges.Count -ne 0) {
  throw "Repository-local Flutter SDK has tracked changes:`n$($trackedChanges -join "`n")"
}

$artifacts = [ordered]@{}
foreach ($mode in 'debug', 'profile', 'release') {
  $directory = switch ($mode) {
    'debug' { 'windows-x64' }
    'profile' { 'windows-x64-profile' }
    'release' { 'windows-x64-release' }
  }
  $dll = Join-Path $localSdk (
    "bin\cache\artifacts\engine\$directory\flutter_windows.dll")
  if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
    throw "Repository-local Flutter SDK is missing $mode Windows Engine: $dll"
  }
  $artifacts[$mode] = [ordered]@{
    path = [IO.Path]::GetRelativePath($localSdk, $dll).Replace('\', '/')
    size = (Get-Item -LiteralPath $dll).Length
    sha256 = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
  }
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $ReportPath = Join-Path $repository (
    "build\diagnostics\engine\flutterw-local-sdk-fallback-$stamp.json")
}
$absoluteReport = $ExecutionContext.SessionState.Path.
  GetUnresolvedProviderPathFromPSPath($ReportPath)
if (Test-Path -LiteralPath $absoluteReport) {
  throw "ReportPath already exists: $absoluteReport"
}
New-Item -ItemType Directory -Path (Split-Path -Parent $absoluteReport) `
  -Force | Out-Null
[ordered]@{
  schemaVersion = 1
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  localSdk = $localSdk
  localSdkExistedBefore = $sdkExistedBefore
  wrapperArguments = @($WrapperArguments)
  bootstrapWorkObserved = $outputText -match (
    'Cloning the locked official Flutter SDK|Precaching the official Windows')
  durationMilliseconds = $durationMilliseconds
  wrapperExitCode = $wrapperExitCode
  frameworkRevision = $head
  engineRevision = $engineVersion
  trackedChanges = @($trackedChanges)
  artifacts = $artifacts
  externalFlutterRoots = @($externalFlutterRoots)
  processEnvironmentChangedNames = @($processChanges)
  userEnvironmentChangedNames = @($userChanges)
  machineEnvironmentChangedNames = @($machineChanges)
  globalGitConfigBeforeSha256 = Get-TextSha256 $gitBefore
  globalGitConfigAfterSha256 = Get-TextSha256 $gitAfter
  proxyConfigured = -not [string]::IsNullOrWhiteSpace(
    [Environment]::GetEnvironmentVariable('KIRAKARA_ENGINE_PROXY', 'Process'))
  passed = $true
} | ConvertTo-Json -Depth 8 | Set-Content `
  -LiteralPath $absoluteReport `
  -Encoding utf8
Write-Host "Repository-local Flutter SDK fallback passed. Report: $absoluteReport"
