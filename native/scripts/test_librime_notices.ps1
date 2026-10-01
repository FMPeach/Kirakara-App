#Requires -Version 7.2
[CmdletBinding()]
param([string]$RapidJsonSourceRoot,[string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
Import-Module (Join-Path $repo 'third_party/scripts/rime_package.psm1') -DisableNameChecking
$lock=Get-Content -Raw -LiteralPath (Join-Path $repo 'native/librime-components.lock.json')|ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($RapidJsonSourceRoot)) { $RapidJsonSourceRoot=Join-Path $repo '.kfe/source/rapidjson-1.1.0' }
$rapidjson=[IO.Path]::GetFullPath($RapidJsonSourceRoot)
if (-not $rapidjson.StartsWith($repo+'\.kfe\source\',[StringComparison]::OrdinalIgnoreCase)) { throw '上游验证来源必须在当前 .kfe/source 内。' }
[Kirakara.Artifacts.Security]::NoReparse($rapidjson)
if ((& git -C $rapidjson rev-parse HEAD) -cne $lock.rapidjsonSource.revision -or $LASTEXITCODE -or
    (& git -C $rapidjson remote get-url origin) -cne $lock.rapidjsonSource.repository -or $LASTEXITCODE) {
  throw '未准备固定官方 RapidJSON 来源；此显式维护测试不自动获取上游或切换 HEAD。'
}
$prepare=Join-Path $PSScriptRoot 'prepare_librime_notices.ps1'
$dll=Join-Path $repo '.kfe/native/runtime/ime/rime/windows/rime.dll'
$dllHash=Get-ArtifactHash $dll
$source=Join-Path $repo '.kfe/source/librime'
$sourceRoots=@($source)+@('leveldb','marisa-trie','opencc','yaml-cpp'|ForEach-Object { Join-Path $source ('deps/'+$_) })
function Read-SourceState {
  $state=[Collections.Generic.List[string]]::new()
  foreach ($root in $sourceRoots) {
    $head=& git -C $root rev-parse HEAD
    if ($LASTEXITCODE) { throw '测试来源 HEAD 不可读。' }
    $status=@(& git -C $root status --porcelain --untracked-files=all)
    if ($LASTEXITCODE) { throw '测试来源状态不可读。' }
    $state.Add($head+':'+($status -join '|'))
  }
  return $state.ToArray() -join "`n"
}
$sourceBefore=Read-SourceState
$scratch=Join-Path $repo ('.kfe/tmp/librime-notices-test-'+[guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null=New-Item -ItemType Directory -Path $scratch
$cases=[Collections.Generic.List[string]]::new()
$junction=$null
function Invoke-Case {
  param([string]$Directory,[string]$ExpectedFailure)
  $result=Join-Path $scratch ([guid]::NewGuid().ToString('N')+'.json')
  $failure=$null
  try { & $prepare -Offline -OutputDirectory $Directory -ReportPath $result }
  catch { $failure=$_.Exception.Message }
  if ($ExpectedFailure) {
    if (-not $failure -or $failure -notlike $ExpectedFailure -or (Test-Path -LiteralPath $result)) {
      throw '声明拒绝场景没有按预期失败，或留下了成功报告。'
    }
  } else {
    if ($failure) { throw '有效声明场景失败，不能计通过。' }
    $record=Get-Content -Raw -LiteralPath $result|ConvertFrom-Json
    if (-not $record.passed -or $record.noticeFiles -ne 19 -or $record.components -ne 11 -or
        -not $record.actualBuildExclusionsVerified -or $record.compilerInvoked -or
        $record.completeNativeAuditVerified -or $record.formalReleasePublished) {
      throw '声明成功报告越过测试/发布边界。'
    }
  }
}
function Snapshot-Files {
  param([string]$Root)
  return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force|Sort-Object FullName|
    ForEach-Object { [IO.Path]::GetRelativePath($Root,$_.FullName)+':'+(Get-ArtifactHash $_.FullName) }) -join "`n"
}
function Copy-Fixture {
  param([string]$Name)
  $target=Join-Path $scratch $Name
  [Kirakara.Artifacts.Security]::NoReparse($target)
  Copy-Item -LiteralPath (Join-Path $scratch 'valid') -Destination $target -Recurse
  return $target
}
try {
  $opencc=Join-Path $source 'deps/opencc'
  $native=Get-Content -Raw -LiteralPath (Join-Path $repo 'native/native.lock.json')|ConvertFrom-Json
  $revision=$native.librime.submodules.'deps/opencc'
  $headers=@(& git -C $opencc ls-tree -r --name-only $revision -- $lock.rapidjsonSource.vendoredPrefix)
  if ($LASTEXITCODE) { throw '内置 RapidJSON 来源清单不可读。' }
  $exact=0; $modified=0
  foreach ($path in $headers) {
    $suffix=$path.Substring('deps/rapidjson-1.1.0/'.Length)
    $vendor=Read-RimeSourceBlob $opencc $revision $path
    $original=Read-RimeSourceBlob $rapidjson $lock.rapidjsonSource.revision ('include/'+$suffix)
    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($vendor)) -ceq
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($original))) { $exact++ }
    elseif ($suffix -ceq 'rapidjson/rapidjson.h' -and
        [Text.Encoding]::UTF8.GetString($original).Replace('#  elif defined(_MSC_VER) && defined(_M_ARM)',
          '#  elif defined(_MSC_VER) && (defined(_M_ARM) || defined(_M_ARM64))') -ceq [Text.Encoding]::UTF8.GetString($vendor)) { $modified++ }
    else { throw '内置 RapidJSON 有未记录的来源差异。' }
  }
  if ($headers.Count -ne 35 -or $exact -ne 34 -or $modified -ne 1) { throw 'RapidJSON 来源验证不完整。' }
  $cases.Add('三十五份内置 RapidJSON 头文件匹配固定官方来源及一项已记录上游修改')
  $valid=Join-Path $scratch 'valid'
  Invoke-Case $valid
  $cases.Add('实际固定来源生成十九份声明，不编译或放开发布门控')
  $snapshot=Snapshot-Files $valid
  Invoke-Case $valid
  if ((Snapshot-Files $valid) -cne $snapshot) { throw '声明复用改动了已有文件。' }
  $cases.Add('离线完整复用，所有文件字节不变')

  $missing=Copy-Fixture 'missing'
  Remove-Item -LiteralPath (Join-Path $missing 'opencc/LICENSE')
  $before=Snapshot-Files $missing
  Invoke-Case $missing '*已有声明目录有缺失/额外文件*'
  if ((Snapshot-Files $missing) -cne $before) { throw '缺失场景覆盖了用户文件。' }
  $cases.Add('缺许可明确拒绝，不补写或覆盖现有目录')

  $altered=Copy-Fixture 'altered'
  $file=Join-Path $altered 'librime/LICENSE'
  $bytes=[IO.File]::ReadAllBytes($file); $bytes[0]=$bytes[0] -bxor 1; [IO.File]::WriteAllBytes($file,$bytes)
  $inventoryPath=Join-Path $altered 'notice-inventory.json'
  $inventory=Get-Content -Raw -LiteralPath $inventoryPath|ConvertFrom-Json
  ($inventory.files|Where-Object path -CEQ 'librime/LICENSE').sha256=Get-ArtifactHash $file
  [IO.File]::WriteAllText($inventoryPath,($inventory|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  $before=Snapshot-Files $altered
  Invoke-Case $altered '*包文件缺失、大小或 SHA-256 不匹配*'
  if ((Snapshot-Files $altered) -cne $before) { throw '篡改场景覆盖了用户文件。' }
  $cases.Add('许可及自报清单同时篡改仍拒绝，不信包内清单自证')

  $extra=Copy-Fixture 'extra'
  [IO.File]::WriteAllText((Join-Path $extra 'user-file.txt'),'用户文件必须保留',[Text.UTF8Encoding]::new($false))
  $before=Snapshot-Files $extra
  Invoke-Case $extra '*已有声明目录有缺失/额外文件*'
  if ((Snapshot-Files $extra) -cne $before) { throw '额外文件场景没有保留用户内容。' }
  $cases.Add('额外用户文件拒绝并保留')

  $target=Join-Path $scratch 'junction-target'
  $null=New-Item -ItemType Directory -Path $target
  [IO.File]::WriteAllText((Join-Path $target 'keep.txt'),'链接目标必须保留',[Text.UTF8Encoding]::new($false))
  $before=Snapshot-Files $target
  $junction=Join-Path $scratch 'linked-output'
  $null=New-Item -ItemType Junction -Path $junction -Target $target
  Invoke-Case $junction '*reparse*'
  if ((Snapshot-Files $target) -cne $before) { throw '链接拒绝修改了目标。' }
  $cases.Add('输出目录联接拒绝且目标不变')
  Remove-Item -LiteralPath $junction; $junction=$null

  $outside=$repo+'-notices-test-'+[guid]::NewGuid().ToString('N')
  Invoke-Case $outside '*声明输出必须在当前仓库 .kfe 内*'
  if (Test-Path -LiteralPath $outside) { throw '错误输出在仓库外创建了目录。' }
  $cases.Add('仓库外输出拒绝且未创建目录')
  Invoke-Case (Join-Path $repo '.kfe') '*声明输出必须在当前仓库 .kfe 内*'
  $cases.Add('缓存根目录不能作为覆盖目标')
  if ((Get-ArtifactHash $dll) -cne $dllHash -or (Read-SourceState) -cne $sourceBefore) { throw '声明测试改动了 DLL 或上游来源。' }
  if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath=Join-Path $repo 'build/diagnostics/librime-notices-contract.json' }
  $report=[IO.Path]::GetFullPath($ReportPath)
  if (-not $report.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '报告必须在当前仓库。' }
  [Kirakara.Artifacts.Security]::NoReparse($report)
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
  [ordered]@{passed=$true;cases=$cases.ToArray();dllAndSourcesUnchanged=$true;rapidjsonHeadersVerified=$headers.Count;compilerInvoked=$false
    appImeUiVerified=$false;completeNativeAuditVerified=$false;formalReleasePublished=$false}|ConvertTo-Json -Depth 4|
    Set-Content -LiteralPath $report -Encoding utf8
  Write-Host "librime 声明 $($cases.Count) 项检查通过。报告：$report"
} finally {
  if ($junction -and (Test-Path -LiteralPath $junction)) { Remove-Item -LiteralPath $junction }
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  if (-not $scratch.StartsWith($repo+'\.kfe\tmp\librime-notices-test-',[StringComparison]::OrdinalIgnoreCase)) { throw '声明测试清理越界。' }
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
$global:LASTEXITCODE=0
