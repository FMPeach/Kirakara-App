#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Package,[Parameter(Mandatory)][string]$CandidateLock,[string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'rime_package.psm1') -DisableNameChecking
$selection=Get-RimeDataEntry $CandidateLock
$expected=$selection.expected
$zip=[IO.Path]::GetFullPath($Package)
$candidate=[IO.Path]::GetFullPath($CandidateLock)
Assert-ArtifactFile $zip $selection.entry
$head=(& git -C $repo rev-parse HEAD).Trim()
if ($head -cnotmatch '^[0-9a-f]{40}$') { throw '独立克隆必须来自已确认提交。' }
$scratch=Join-Path $repo ('.kfe/tmp/rime-clone-test-'+[guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null=New-Item -ItemType Directory -Path $scratch
$checkout=Join-Path $scratch 'checkout'
$workspace=Join-Path $checkout '.kfe'
$child=$null
function Invoke-ClonePrepare {
  $start=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -ErrorAction Stop).Source)
  $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.WorkingDirectory=$checkout
  $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
  foreach ($argument in @('-NoProfile','-NonInteractive','-File',(Join-Path $checkout 'flutterw.ps1'),
      'data','prepare','rime','--package',$zip,'--lock',$candidate)) { $start.ArgumentList.Add($argument) }
  foreach ($name in @('TEMP','TMP')) { $start.Environment[$name]=Join-Path $scratch 'tmp' }
  $child=[Diagnostics.Process]::Start($start)
  try {
    $stdout=$child.StandardOutput.ReadToEndAsync(); $stderr=$child.StandardError.ReadToEndAsync()
    if (-not $child.WaitForExit(60000)) { $child.Kill($true); $child.WaitForExit(); throw '独立克隆数据准备超时。' }
    if ($child.ExitCode -ne 0) { throw '独立克隆 flutterw 数据准备失败；未判为通过。' }
  } finally {
    if (-not $child.HasExited) { $child.Kill($true); $child.WaitForExit() }
    $child.Dispose()
  }
  $destination=Join-Path $workspace ('prebuilt/rime-data/'+$expected.value)
  $manifest=Assert-ArtifactManifest -Root $destination -Kind rime-data -IdentityHash $expected.value -Entry $selection.entry -Installed
  Assert-RimeDataContents $destination $manifest $expected
  $ready=Get-Content -Raw -LiteralPath (Join-Path $destination 'ready.json') | ConvertFrom-Json
  if ($ready.identityHash -cne $expected.value -or $ready.archiveSha256 -cne $selection.entry.sha256) { throw '独立克隆 ready 未对应正确数据包。' }
  foreach ($path in @('source','sdk','out','native')) {
    if (Test-Path -LiteralPath (Join-Path $workspace $path)) { throw '数据准备意外触发 SDK/Engine/原生源码构建。' }
  }
}
try {
  $null=New-Item -ItemType Directory -Path (Join-Path $scratch 'tmp')
  & git clone --no-local --no-hardlinks --no-checkout --quiet $repo $checkout
  if ($LASTEXITCODE) { throw '独立本地克隆失败。' }
  & git -C $checkout checkout --detach --quiet $head
  if ($LASTEXITCODE -or (Test-Path -LiteralPath $workspace)) { throw '独立克隆未处于指定提交或携带旧缓存。' }
  $statusBefore=@(& git -C $checkout status --short) -join "`n"
  Invoke-ClonePrepare
  # This directory was created only by this test. Validate its complete target
  # before simulating the user's cache deletion; never touch the maintained .kfe.
  [Kirakara.Artifacts.Security]::NoReparse($workspace)
  if ([IO.Path]::GetFullPath($workspace) -cne (Join-Path $checkout '.kfe') -or
      -not $checkout.StartsWith($repo+'\.kfe\tmp\rime-clone-test-',[StringComparison]::OrdinalIgnoreCase)) { throw '测试缓存清理目标越界。' }
  Remove-Item -LiteralPath $workspace -Recurse -Force
  Invoke-ClonePrepare
  if ((@(& git -C $checkout status --short) -join "`n") -cne $statusBefore) { throw '数据安装改动了独立克隆源码。' }
  if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath=Join-Path $repo 'build/diagnostics/rime-data-clean-clone.json' }
  $report=[IO.Path]::GetFullPath($ReportPath)
  if (-not $report.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '报告必须位于当前仓库。' }
  [Kirakara.Artifacts.Security]::NoReparse($report)
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
  [ordered]@{passed=$true;commit=$head;identityHash=$expected.value;freshCloneWithoutCache=$true
    wrapperPrepareVerified=$true;cacheDeletionAndRestoreVerified=$true;trackedSourceUnchanged=$true
    engineSdkOrNativeSourcePrepared=$false;appRunVerified=$false;formalReleasePublished=$false} | ConvertTo-Json |
    Set-Content -LiteralPath $report -Encoding utf8
  Write-Host "独立克隆的 Rime 数据准备、删除测试缓存后恢复及源码不变通过。报告：$report"
} finally {
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  if (-not $scratch.StartsWith($repo+'\.kfe\tmp\rime-clone-test-',[StringComparison]::OrdinalIgnoreCase)) { throw '独立克隆清理目标越界。' }
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
