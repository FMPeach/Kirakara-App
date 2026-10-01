#Requires -Version 7.2
[CmdletBinding()]
param(
  [string[]]$WrapperArguments = @('--version'),
  [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$wrapper = Join-Path $repository 'flutterw.ps1'

function Get-EnvironmentSnapshot {
  param(
    [Parameter(Mandatory = $true)]
    [EnvironmentVariableTarget]$Target
  )

  $result = [Collections.Generic.Dictionary[string, string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in [Environment]::GetEnvironmentVariables($Target).GetEnumerator()) {
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

function Get-CacheTreeSnapshot {
  param([Parameter(Mandatory)][string]$Root, [switch]$HashContents)
  $records = [Collections.Generic.List[string]]::new()
  if (Test-Path -LiteralPath $Root) {
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Sort-Object FullName) {
      if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw '隔离测试缓存包含文件链接，不能把未覆盖内容宣告为已验证。'
      }
      $relative = [IO.Path]::GetRelativePath($Root,$file.FullName).Replace('\','/')
      $fingerprint = if ($HashContents) { (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
        else { $file.LastWriteTimeUtc.Ticks.ToString() }
      $records.Add("$relative|$($file.Length)|$fingerprint")
    }
  }
  return [ordered]@{ exists = Test-Path -LiteralPath $Root; files = $records.Count
    contentHashes = [bool]$HashContents; sha256 = Get-TextSha256 ($records -join "`n") }
}

function Get-GlobalCacheSnapshot {
  param([string]$FlutterRoot)
  # SDK cache is compared byte-for-byte. Potentially large unrelated pub caches
  # are compared by file names, lengths and modification timestamps instead.
  $snapshot = [ordered]@{
    officialFlutterCache = Get-CacheTreeSnapshot (Join-Path $FlutterRoot 'bin/cache') -HashContents
    defaultPubCache = Get-CacheTreeSnapshot (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Pub/Cache')
    flutterUserState = Get-CacheTreeSnapshot (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'flutter') -HashContents
  }
  $override = [Environment]::GetEnvironmentVariable('PUB_CACHE','Process')
  if (-not [string]::IsNullOrWhiteSpace($override)) {
    $localPrefix = (Join-Path $repository '.kfe').TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not [IO.Path]::GetFullPath($override).StartsWith($localPrefix,[StringComparison]::OrdinalIgnoreCase)) {
      $snapshot.externalPubCache = Get-CacheTreeSnapshot $override
    }
  }
  return $snapshot
}

$flutterCommand = Get-Command flutter.bat, flutter -ErrorAction Stop |
  Select-Object -First 1
$flutterRoot = Split-Path -Parent (Split-Path -Parent $flutterCommand.Source)
$processBefore = Get-EnvironmentSnapshot -Target Process
$userBefore = Get-EnvironmentSnapshot -Target User
$machineBefore = Get-EnvironmentSnapshot -Target Machine
$gitBefore = @(& git config --global --null --list 2>&1) -join "`n"
$sdkStatusBefore = @(& git -C $flutterRoot status --short 2>&1) -join "`n"
$cacheBefore = Get-GlobalCacheSnapshot $flutterRoot

& $wrapper @WrapperArguments | Out-Host
$wrapperExitCode = $LASTEXITCODE

$processAfter = Get-EnvironmentSnapshot -Target Process
$userAfter = Get-EnvironmentSnapshot -Target User
$machineAfter = Get-EnvironmentSnapshot -Target Machine
$gitAfter = @(& git config --global --null --list 2>&1) -join "`n"
$sdkStatusAfter = @(& git -C $flutterRoot status --short 2>&1) -join "`n"
$cacheAfter = Get-GlobalCacheSnapshot $flutterRoot

$processChanges = @(Get-ChangedEnvironmentNames $processBefore $processAfter)
$userChanges = @(Get-ChangedEnvironmentNames $userBefore $userAfter)
$machineChanges = @(Get-ChangedEnvironmentNames $machineBefore $machineAfter)
if ($wrapperExitCode -ne 0) {
  throw "flutterw failed with exit code $wrapperExitCode."
}
if ($processChanges.Count -ne 0) {
  throw "flutterw leaked process environment variables: $($processChanges -join ', ')"
}
if ($userChanges.Count -ne 0) {
  throw "flutterw changed user environment variables: $($userChanges -join ', ')"
}
if ($machineChanges.Count -ne 0) {
  throw "flutterw changed machine environment variables: $($machineChanges -join ', ')"
}
if ($gitBefore -cne $gitAfter) {
  throw 'flutterw changed global Git configuration.'
}
if ($sdkStatusBefore -cne $sdkStatusAfter) {
  throw 'flutterw changed tracked files in the selected official Flutter SDK.'
}
if (($cacheBefore | ConvertTo-Json -Depth 5 -Compress) -cne ($cacheAfter | ConvertTo-Json -Depth 5 -Compress)) {
  throw 'flutterw 改变了系统 Flutter 缓存、外部 pub 缓存或全局 Flutter 用户状态。'
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $ReportPath = Join-Path $repository `
    "build\diagnostics\engine\flutterw-isolation-$stamp.json"
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
  wrapperArguments = @($WrapperArguments)
  wrapperExitCode = $wrapperExitCode
  selectedFlutterSdk = $flutterRoot
  processEnvironmentChangedNames = @($processChanges)
  userEnvironmentChangedNames = @($userChanges)
  machineEnvironmentChangedNames = @($machineChanges)
  globalGitConfigBeforeSha256 = Get-TextSha256 $gitBefore
  globalGitConfigAfterSha256 = Get-TextSha256 $gitAfter
  flutterSdkTrackedStatusBeforeSha256 = Get-TextSha256 $sdkStatusBefore
  flutterSdkTrackedStatusAfterSha256 = Get-TextSha256 $sdkStatusAfter
  globalCachesBefore = $cacheBefore
  globalCachesAfter = $cacheAfter
  passed = $true
} | ConvertTo-Json -Depth 6 | Set-Content `
  -LiteralPath $absoluteReport `
  -Encoding utf8
Write-Host "flutterw environment isolation passed. Report: $absoluteReport"
