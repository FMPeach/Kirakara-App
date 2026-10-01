#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackagesDirectory, [string]$ReportPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $PSScriptRoot 'artifact_package.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'prebuilt_engine.psm1') -DisableNameChecking
$lock = Get-Content -Raw -LiteralPath (Join-Path $repo 'engine/engine.lock.json') | ConvertFrom-Json
$packages = [IO.Path]::GetFullPath($PackagesDirectory)
[Kirakara.Artifacts.Security]::NoReparse($packages)
$scratch = Join-Path $repo ('.kfe/tmp/clean-clone-test-' + [guid]::NewGuid().ToString('N'))
$clone = Join-Path $scratch 'checkout'
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null = New-Item -ItemType Directory -Path $scratch
$children = [Collections.Generic.List[object]]::new()
function Invoke-CloneFlutterw {
  param([string[]]$Arguments, [string]$CandidateLock)
  $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
  $start.UseShellExecute = $false; $start.CreateNoWindow = $true; $start.WorkingDirectory = $clone
  $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
  $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  $argumentsFile = Join-Path $scratch ('arguments-' + [guid]::NewGuid().ToString('N') + '.json')
  [IO.File]::WriteAllText($argumentsFile,(ConvertTo-Json -InputObject @($Arguments)),[Text.UTF8Encoding]::new($false))
  foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'test_flutterw_worker.ps1'),
      '-Wrapper',(Join-Path $clone 'flutterw.ps1'),'-ArgumentsFile',$argumentsFile)) {
    $start.ArgumentList.Add($argument)
  }
  # The clone gets no pub/Engine cache from the old repository. An installed
  # official SDK may be read-only copied by the ordinary bootstrap design.
  $null = $start.Environment.Remove('PUB_CACHE')
  $null = $start.Environment.Remove('KIRAKARA_ENGINE_WORKSPACE')
  $null = $start.Environment.Remove('KIRAKARA_FLUTTER_SDK_ROOT')
  if ([string]::IsNullOrWhiteSpace($CandidateLock)) {
    $null = $start.Environment.Remove('KIRAKARA_PREBUILT_LOCK')
  } else {
    $start.Environment['KIRAKARA_PREBUILT_LOCK'] = $CandidateLock
  }
  $process = [Diagnostics.Process]::Start($start)
  $child = @{ process = $process; stdout = $process.StandardOutput.ReadToEndAsync()
    stderr = $process.StandardError.ReadToEndAsync() }
  $children.Add($child)
  if (-not $process.WaitForExit(600000)) { $process.Kill($true); $process.WaitForExit(); throw '干净克隆引导测试超时。' }
  $stdout = $child.stdout.GetAwaiter().GetResult(); $stderr = $child.stderr.GetAwaiter().GetResult()
  if ($process.ExitCode -ne 0) { throw "干净克隆命令失败：$stderr`n$stdout" }
  $stdout | Write-Host
}
function Assert-NoEngineSource {
  foreach ($relative in @('.kfe/source/flutter','.kfe/source/gn','.kfe/source/ninja','.kfe/source/depot_tools')) {
    if (Test-Path -LiteralPath (Join-Path $clone $relative)) { throw '预编译测试意外获取了 Engine 源码或构建工具。' }
  }
}
try {
  & git clone --no-local --no-hardlinks $repo $clone | Out-Host
  if ($LASTEXITCODE) { throw '新正式仓库的独立测试克隆失败。' }
  $revision = (& git -C $clone rev-parse HEAD)
  if (Test-Path -LiteralPath (Join-Path $clone '.kfe')) { throw '测试克隆意外带入缓存。' }
  $records = [Collections.Generic.List[object]]::new()
  foreach ($mode in @('debug','profile','release')) {
    $name = "kirakara-engine-windows-x64-$mode-v$($lock.patchset.version)"
    $candidate = Join-Path $packages ($name + '.candidate.lock.json')
    $archive = Join-Path $packages ($name + '.zip')
    Invoke-CloneFlutterw @('engine','prepare',$mode,'--package',$archive,'--lock',$candidate) $candidate
    Assert-NoEngineSource
    $ready = @(Get-ChildItem -LiteralPath (Join-Path $clone ".kfe/prebuilt/$mode") -Recurse -File -Filter ready.json)
    if ($ready.Count -ne 1) { throw '干净克隆对应模式没有唯一 ready stamp。' }
    $identity = Get-PrebuiltEngineIdentity $lock $mode
    $cacheKey = Get-PrebuiltEngineCacheKey $identity.value
    if ($ready[0].Directory.Name -cne $cacheKey -or $cacheKey.Length -ne 8) {
      throw '干净克隆没有使用 8 位 Engine 缓存目录别名。'
    }
    $records.Add(@{ mode = $mode; installed = $true; cacheKey = $cacheKey })
  }
  $debugCandidate = Join-Path $packages "kirakara-engine-windows-x64-debug-v$($lock.patchset.version).candidate.lock.json"
  # Explicit prepare is the trust boundary. A later ordinary command must use
  # the persisted, fully verified selection without a machine environment
  # variable or a formal download URL.
  Invoke-CloneFlutterw @('pub','get')
  Assert-NoEngineSource
  if (-not (Test-Path -LiteralPath (Join-Path $clone '.kfe/sdk/bin/flutter.bat')) -or
      -not (Test-Path -LiteralPath (Join-Path $clone '.kfe/pub-cache/hosted'))) { throw 'SDK/pub 缓存没有准备到测试仓库内。' }
  $cache = Join-Path $clone '.kfe'
  # Delete only the disposable clone's cache to verify the public recovery
  # command. Never purge the maintained repository or another project's cache.
  [Kirakara.Artifacts.Security]::NoReparse($cache)
  $expected = [IO.Path]::GetFullPath((Join-Path $scratch 'checkout/.kfe'))
  if ($cache -cne $expected -or -not $expected.StartsWith($scratch + '\',[StringComparison]::OrdinalIgnoreCase)) {
    throw '缓存清理目标未通过测试克隆边界校验。'
  }
  Remove-Item -LiteralPath $cache -Recurse -Force
  $debugArchive = Join-Path $packages "kirakara-engine-windows-x64-debug-v$($lock.patchset.version).zip"
  Invoke-CloneFlutterw @('engine','prepare','debug','--package',$debugArchive,'--lock',$debugCandidate) $debugCandidate
  Assert-NoEngineSource
  $ready = @(Get-ChildItem -LiteralPath (Join-Path $clone '.kfe/prebuilt/debug') -Recurse -File -Filter ready.json)
  if ($ready.Count -ne 1) { throw '删除测试缓存后的 Engine 恢复失败。' }
  if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $repo 'build/diagnostics/prebuilt-clean-clone.json' }
  $report = [IO.Path]::GetFullPath($ReportPath)
  if (-not $report.StartsWith($repo.TrimEnd('\','/') + '\',[StringComparison]::OrdinalIgnoreCase)) { throw '报告必须位于当前仓库。' }
  [Kirakara.Artifacts.Security]::NoReparse($report)
  $null = New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
  [IO.File]::WriteAllText($report,([ordered]@{ passed = $true; scope = 'Engine/SDK/pub 引导；不含 App 启动或构建'
    clonedRevision = $revision; independentLocalClone = $true; engineSourceDownloaded = $false
    oldRepositoryCacheCopied = $false; modes = $records.ToArray(); pubGet = $true
    cacheDeletedAndEngineRestored = $true; appRunVerified = $false; appReleaseBuildVerified = $false
    formalReleasePublished = $false } | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
  Write-Host "干净克隆 Engine/SDK 引导通过；不等于 App 全链路通过。报告：$report"
} finally {
  foreach ($child in $children) {
    if (-not $child.process.HasExited) { $child.process.Kill($true); $child.process.WaitForExit() }
    $child.process.Dispose()
  }
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
