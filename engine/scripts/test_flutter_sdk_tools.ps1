#Requires -Version 7.2
[CmdletBinding()]
param([string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')
Import-Module (Join-Path $PSScriptRoot 'flutter_sdk_tools.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'artifact_package.psm1') -DisableNameChecking
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$layout=Get-EngineWorkspaceLayout (Join-Path $repo '.kfe')
$lock=Get-EngineLock
$environmentBefore=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in Get-ChildItem Env:) {$environmentBefore[$entry.Name]=$entry.Value}
try {
  Set-EngineProcessEnvironment -Layout $layout
  $sdkFiles=@($lock.sdkToolBootstrap.upstreamFiles | ForEach-Object {
    $path=Join-Path $layout.FlutterSdk $_.path
    [ordered]@{path=$path;sha256=Get-ArtifactHash $path}
  })
  $tools=Ensure-KirakaraSdkTools -Layout $layout -Lock $lock
  $config=Get-Content -Raw -LiteralPath $tools.packageConfig -Encoding utf8|ConvertFrom-Json
  $configUri=[uri]::new($tools.packageConfig)
  foreach ($package in $config.packages) {
    $uri=[uri]::new($configUri,[string]$package.rootUri)
    if (-not $uri.IsFile -or -not $uri.LocalPath.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) {
      throw '派生工具 package_config 引用了当前仓库之外的缓存。'
    }
  }
  $test=@($config.packages|Where-Object name -EQ 'test')
  if ($test.Count -ne 1) {throw '找不到工具补丁测试入口。'}
  $testRoot=[uri]::new($configUri,[string]$test[0].rootUri).LocalPath
  Push-Location (Join-Path $tools.source 'packages/flutter_tools')
  try {
    Invoke-CheckedNative (Join-Path $layout.FlutterSdk 'bin/cache/dart-sdk/bin/dart.exe') @(
      "--packages=$($tools.packageConfig)",(Join-Path $testRoot 'bin/test.dart'),
      '--reporter=expanded','--concurrency=1',(Join-Path $repo 'engine/tests/windows_optional_symbols_test.dart')
    ) 'Flutter tools 的 PDB 严格性回归失败。' | Out-Host
  } finally {Pop-Location}
  $sdkSnapshot=Join-Path $layout.FlutterSdk 'bin/cache/flutter_tools.snapshot'
  $snapshotTime=(Get-Item -LiteralPath $sdkSnapshot).LastWriteTimeUtc
  $second=Ensure-KirakaraSdkTools -Layout $layout -Lock $lock
  if (-not $second.reused -or (Get-Item -LiteralPath $sdkSnapshot).LastWriteTimeUtc -ne $snapshotTime) {
    throw '工具复用错误地重写了 snapshot。'
  }
  $badLock=$lock|ConvertTo-Json -Depth 40|ConvertFrom-Json
  $badLock.sdkToolBootstrap.patches[0].sha256='0'*64
  $rejected=$false
  try {$null=Ensure-KirakaraSdkTools -Layout $layout -Lock $badLock} catch {$rejected=$true}
  if (-not $rejected) {throw '工具补丁哈希错误未被拒绝。'}
  foreach ($file in $sdkFiles) {
    if ((Get-ArtifactHash $file.path) -cne $file.sha256) {throw '官方 SDK 源码被工具补丁改写。'}
  }
  if (@(Get-TrackedGitChanges $layout.FlutterSdk).Count) {throw '官方 SDK 产生了已跟踪修改。'}
  if ([string]::IsNullOrWhiteSpace($ReportPath)) {$ReportPath=Join-Path $repo 'build/diagnostics/flutter-sdk-tools.json'}
  $report=[IO.Path]::GetFullPath($ReportPath)
  if (-not $report.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) {throw '测试报告必须位于当前仓库。'}
  [Kirakara.Artifacts.Security]::NoReparse($report)
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
  [ordered]@{passed=$true;unitChecks=10;identityHash=$tools.identityHash
    sourceSnapshotSha256=$tools.snapshotSha256;reuseWithoutRewrite=$true;badPatchRejected=$true
    dependencyPathsRepositoryLocal=$true;officialSdkTrackedSourceUnchanged=$true
    scope='Flutter tools 可选 local-engine PDB；不是 Kirakara App 或图形实机验收'} |
    ConvertTo-Json -Depth 6|Set-Content -LiteralPath $report -Encoding utf8
  Write-Host "Flutter tools 源码补丁回归通过：$report"
} finally {
  foreach ($name in @(Get-ChildItem Env:|ForEach-Object Name)) {
    if (-not $environmentBefore.ContainsKey($name)) {Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue}
  }
  foreach ($entry in $environmentBefore.GetEnumerator()) {[Environment]::SetEnvironmentVariable($entry.Key,$entry.Value,'Process')}
}
