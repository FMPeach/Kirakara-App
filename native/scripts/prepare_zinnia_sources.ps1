#Requires -Version 7.2
[CmdletBinding()]
param([switch]$Offline,[string]$SourceRoot,[string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
# 复用现有的原始 Git blob 读取器；不调用 Rime 安装、编译或运行功能。
Import-Module (Join-Path $repo 'third_party/scripts/rime_package.psm1') -DisableNameChecking
$lock=(Get-Content -Raw -LiteralPath (Join-Path $repo 'native/native.lock.json')|ConvertFrom-Json).zinnia
$data=(Get-Content -Raw -LiteralPath (Join-Path $repo 'third_party/data.lock.json')|ConvertFrom-Json).zinniaTomoe
if ($lock.revision -cnotmatch '^[0-9a-f]{40}$' -or $lock.revision -cne $data.converterRevision -or
    $lock.license -cne 'BSD-3-Clause' -or $lock.sourceSubdirectory -cne 'zinnia') {
  throw 'Zinnia 固定库/转换器来源或许可边界不匹配。'
}
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot=Join-Path $repo '.kfe/source/zinnia' }
$source=[IO.Path]::GetFullPath($SourceRoot)
if (-not $source.StartsWith($repo+'\.kfe\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Zinnia 来源缓存必须在当前仓库 .kfe 内。' }
[Kirakara.Artifacts.Security]::NoReparse($source)
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath=Join-Path $repo 'build/diagnostics/zinnia-source.json' }
$report=[IO.Path]::GetFullPath($ReportPath)
if (-not $report.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '报告必须在当前仓库。' }
[Kirakara.Artifacts.Security]::NoReparse($report)
# 只读核验不允许部分克隆按需获取对象；显式 clone/fetch/checkout 仍只在非离线准备时执行。
$null=& git --no-lazy-fetch --no-optional-locks --version
if ($LASTEXITCODE) { throw 'Zinnia 来源核验需要支持 --no-lazy-fetch 的 Git；不会自动替换系统工具。' }
$scratch=Join-Path $repo ('.kfe/tmp/zinnia-source-'+[guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null=New-Item -ItemType Directory -Path $scratch
function Assert-ZinniaSource {
  param([string]$Root)
  [Kirakara.Artifacts.Security]::NoReparse($Root)
  $metadata=Join-Path $Root '.git'
  if (-not (Test-Path -LiteralPath $metadata -PathType Container)) { throw 'Zinnia 来源不是独立 Git 仓库；不覆盖用户内容。' }
  $pending=[Collections.Generic.Stack[string]]::new(); $pending.Push($metadata)
  while ($pending.Count) {
    $directory=$pending.Pop()
    [Kirakara.Artifacts.Security]::NoReparse($directory)
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
      $attributes=[IO.File]::GetAttributes($entry)
      if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Zinnia Git 元数据含链接；不读取或写入目标。' }
      if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Push($entry) }
    }
  }
  $top=@(& git --no-lazy-fetch --no-optional-locks -C $Root rev-parse --show-toplevel)
  if ($LASTEXITCODE -or $top.Count -ne 1 -or [IO.Path]::GetFullPath($top[0]) -ine $Root) { throw 'Zinnia 来源属于其他 Git 工作区。' }
  $remote=@(& git --no-lazy-fetch --no-optional-locks -C $Root remote get-url origin)
  if ($LASTEXITCODE -or $remote.Count -ne 1 -or $remote[0] -cne $lock.repository) { throw 'Zinnia remote 与固定官方来源不同；不修改现有 remote。' }
  $head=@(& git --no-lazy-fetch --no-optional-locks -C $Root rev-parse HEAD)
  if ($LASTEXITCODE -or $head.Count -ne 1 -or $head[0] -cne $lock.revision) { throw 'Zinnia HEAD 不属于固定 revision；不 checkout/reset。' }
  $status=@(& git --no-lazy-fetch --no-optional-locks -C $Root status --porcelain --untracked-files=all)
  if ($LASTEXITCODE) { throw 'Zinnia 本地 Git 对象缺失或无法读取；不隐式下载或修改已有缓存。' }
  if ($status.Count) { throw 'Zinnia 来源有用户修改/未跟踪文件；不重置或清理。' }
  $license=Read-RimeSourceBlob $Root $lock.revision $lock.licenseFile.path -NoLazyFetch
  if ($license.Length -ne $lock.licenseFile.size -or
      [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($license)) -cne $lock.licenseFile.sha256) {
    throw 'Zinnia 原始 BSD 许可与固定来源不匹配。'
  }
  # Runner / 转换器的构建所需目录必须实际签出；只保留 Git 对象不足以编译。
  foreach ($name in @('character.cpp','feature.cpp','libzinnia.cpp','param.cpp','recognizer.cpp','sexp.cpp','svm.cpp','trainer.cpp','zinnia.h','COPYING')) {
    $path=[Kirakara.Artifacts.Security]::Child($Root,($lock.sourceSubdirectory+'/'+$name))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw '固定 Zinnia 构建所需源码文件未签出。' }
  }
  $inputs=@(& git --no-lazy-fetch --no-optional-locks -C $Root ls-tree -r --name-only $lock.revision -- $lock.sourceSubdirectory|
    Where-Object { $_ -match '^zinnia/[^/]+\.(cpp|h)$' })+@($lock.licenseFile.path)
  if ($LASTEXITCODE -or $inputs.Count -ne 23) { throw '固定 Zinnia 源码使用范围不完整。' }
  $utf8=[Text.UTF8Encoding]::new($false,$true)
  foreach ($inputPath in $inputs) {
    $raw=Read-RimeSourceBlob $Root $lock.revision $inputPath -NoLazyFetch
    $file=[Kirakara.Artifacts.Security]::Child($Root,$inputPath)
    # 同时防止 assume-unchanged 隐藏修改；正常 Git CRLF/LF 转换不算改源码。
    if ($utf8.GetString($raw).Replace("`r`n","`n") -cne
        $utf8.GetString([IO.File]::ReadAllBytes($file)).Replace("`r`n","`n")) {
      throw 'Zinnia 实际源码内容与固定 Git 来源不同；保留修改，不宣告通过。'
    }
  }
}
try {
  $created=$false
  if (Test-Path -LiteralPath $source) { Assert-ZinniaSource $source }
  else {
    if ($Offline) { throw '离线缺少固定 Zinnia 来源；不初始化或下载。' }
    $staged=Join-Path $scratch 'source'
    & git -c core.autocrlf=false clone --no-checkout --filter=blob:none --no-tags $lock.repository $staged|Out-Host
    if ($LASTEXITCODE) { throw 'Zinnia 官方源码获取失败；未发布半成品来源目录。' }
    & git -C $staged -c core.autocrlf=false fetch --quiet --no-tags --depth=1 origin $lock.revision|Out-Host
    if ($LASTEXITCODE) { throw '固定 Zinnia revision 获取失败；未改变已有来源。' }
    & git -C $staged -c core.autocrlf=false checkout --quiet --detach $lock.revision|Out-Host
    if ($LASTEXITCODE) { throw '固定 Zinnia revision 签出失败。' }
    Assert-ZinniaSource $staged
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force
    [IO.Directory]::Move($staged,$source)
    $created=$true
  }
  Assert-ZinniaSource $source
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
  [ordered]@{passed=$true;root=$source;revision=$lock.revision;licenseSha256=$lock.licenseFile.sha256
    createdSource=$created;sourceInputsVerified=23;gitTextLineEndingsAccepted=$true;implicitGitFetchDisabled=$true;existingWorktreePreserved=$true;compilerInvoked=$false;engineSourcePrepared=$false
    appImeUiVerified=$false;formalReleasePublished=$false}|ConvertTo-Json|Set-Content -LiteralPath $report -Encoding utf8
  Write-Host "Zinnia 固定源码及原始 BSD 许可验证通过；没有编译或复现模型。报告：$report"
} finally {
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  if (-not $scratch.StartsWith($repo+'\.kfe\tmp\zinnia-source-',[StringComparison]::OrdinalIgnoreCase)) { throw 'Zinnia 获取临时目录清理越界。' }
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
$global:LASTEXITCODE=0
