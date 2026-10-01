#Requires -Version 7.2
[CmdletBinding()]
param([string]$CandidateLock,[string]$Package,[ValidateRange(10,300)][int]$TimeoutSeconds=120,[string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
Import-Module (Join-Path $repo 'third_party/scripts/rime_package.psm1') -DisableNameChecking
$data=Ensure-RimeDataPackage -Package $Package -LockPath $CandidateLock
$runtime=Join-Path $repo '.kfe/native/runtime/ime/rime/windows'
$dll=Join-Path $runtime 'rime.dll'
$provenance=Get-Content -Raw -LiteralPath (Join-Path $runtime 'provenance.json') | ConvertFrom-Json
$native=Get-Content -Raw -LiteralPath (Join-Path $repo 'native/native.lock.json') | ConvertFrom-Json
if ($provenance.schemaVersion -ne 1 -or $provenance.revision -cne $native.librime.revision -or
    $provenance.logging -or $provenance.externalPlugins) { throw '只测试当前固定源码且不带外部插件/日志的 librime 构建。' }
foreach ($property in $native.librime.submodules.PSObject.Properties) {
  if ($provenance.submodules.($property.Name) -cne $property.Value) { throw 'librime 对应构建依赖不匹配。' }
}
if ((Get-ArtifactHash $dll) -cne $provenance.sha256) { throw '本地重建 librime 与构建来源记录不匹配。' }
foreach ($name in @('marisaProvider','marisaRevision','marisaLibrarySha256','marisaCmakeSha256','openccRuntimeFilesVerified')) {
  if ($provenance.PSObject.Properties.Name -notcontains $name) { throw 'librime 缺少明确的 marisa 构建来源记录；请重新执行固定源码构建。' }
}
if ($provenance.marisaProvider -cne 'repository-pinned' -or
    $provenance.marisaRevision -cne $native.librime.submodules.'deps/marisa-trie' -or
    $provenance.openccRuntimeFilesVerified -ne 30 -or
    $provenance.marisaLibrarySha256 -cne (Get-ArtifactHash (Join-Path $repo '.kfe/native/librime-deps/lib/marisa.lib')) -or
    $provenance.marisaCmakeSha256 -cne (Get-ArtifactHash (Join-Path $repo 'native/cmake/opencc_repository_marisa.cmake'))) {
  throw 'librime marisa 库/构建接线与固定来源记录不匹配。'
}
$pe=[Kirakara.Artifacts.PeReader]::Read($dll)
if ($pe.Machine -ne 0x8664 -or -not $pe.IsDll) { throw 'librime 不是 x64 DLL。' }
$scratch=Join-Path $repo ('.kfe/tmp/rime-runtime-test-'+[guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null=New-Item -ItemType Directory -Path $scratch
$process=$null
try {
  $requestPath=Join-Path $scratch 'request.json'
  $resultPath=Join-Path $scratch 'result.json'
  [ordered]@{dll=$dll;shared=$data.data;state=$scratch;result=$resultPath} | ConvertTo-Json |
    Set-Content -LiteralPath $requestPath -Encoding utf8
  $start=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -ErrorAction Stop).Source)
  $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.WorkingDirectory=$repo
  $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
  $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
  $start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
  foreach ($pair in @(@{name='TEMP';folder='tmp'},@{name='TMP';folder='tmp'},
      @{name='APPDATA';folder='roaming'},@{name='LOCALAPPDATA';folder='local'})) {
    $directory=Join-Path $scratch $pair.folder
    $null=New-Item -ItemType Directory -Path $directory -Force
    $start.Environment[$pair.name]=$directory
  }
  foreach ($arg in @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'rime_runtime_probe_worker.ps1'),'-RequestPath',$requestPath)) {
    $start.ArgumentList.Add($arg)
  }
  $watch=[Diagnostics.Stopwatch]::StartNew()
  $process=[Diagnostics.Process]::Start($start)
  $outputTask=$process.StandardOutput.ReadToEndAsync()
  $errorTask=$process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit($TimeoutSeconds*1000)) {
    $process.Kill($true); $process.WaitForExit()
    throw 'librime 隔离测试超时；没有将编译或超时判为运行通过。'
  }
  $watch.Stop()
  # Child output contains only test/tool diagnostics, not user input. Preserve
  # it inside the scratch tree if this probe fails; report text stays content-free.
  if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $resultPath)) {
    [IO.File]::WriteAllText((Join-Path $scratch 'worker.stderr.txt'),$errorTask.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
    throw "librime 隔离运行失败（退出码 $($process.ExitCode)）；诊断：$scratch"
  }
  $result=Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
  if (@($result.Schemas).Count -ne 7 -or $result.CandidateChecks -ne 2 -or
      -not $result.SimplificationVerified -or -not $result.NormalFinalization) { throw '隔离运行返回的验证结果不完整。' }
  # Verify the installed source/data tree is still immutable after deployment.
  $null=Ensure-RimeDataPackage -LockPath $CandidateLock
  if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath=Join-Path $repo 'build/diagnostics/rime-runtime-probe.json' }
  $report=[IO.Path]::GetFullPath($ReportPath)
  if (-not $report.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '报告必须位于当前仓库。' }
  [Kirakara.Artifacts.Security]::NoReparse($report)
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
  [ordered]@{passed=$true;librimeRevision=$native.librime.revision;dllSha256=$provenance.sha256
    marisaProvider=$provenance.marisaProvider;marisaRevision=$provenance.marisaRevision
    marisaLibrarySha256=$provenance.marisaLibrarySha256;openccRuntimeFilesVerified=$provenance.openccRuntimeFilesVerified
    dataIdentityHash=$data.identityHash;elapsedMilliseconds=$watch.ElapsedMilliseconds;schemas=$result.Schemas
    candidateChecks=2;openccSimplificationVerified=$true;normalFinalization=$true
    userStateRoot=$scratch;realUserDataAccessed=$false;appImeUiVerified=$false;formalReleasePublished=$false} | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $report -Encoding utf8
  Write-Host "librime 实际部署、七方案选择及两项固定候选/简化检查通过；未代替 App UI。报告：$report"
} finally {
  if ($null -ne $process) {
    if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
    $process.Dispose()
  }
  # Keep generated deploy data and failure diagnostics for inspection. They
  # remain ignored in this bounded .kfe/tmp tree, not in AppData or Git.
}
