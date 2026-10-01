#Requires -Version 7.2
[CmdletBinding()]
param([switch]$Offline,[string]$OutputDirectory,[string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
Import-Module (Join-Path $repo 'third_party/scripts/rime_package.psm1') -DisableNameChecking
$lockPath=Join-Path $repo 'native/librime-components.lock.json'
$lock=Get-Content -Raw -LiteralPath $lockPath|ConvertFrom-Json
$nativePath=Join-Path $repo 'native/native.lock.json'
$native=Get-Content -Raw -LiteralPath $nativePath|ConvertFrom-Json
if ($lock.schemaVersion -ne 1 -or $lock.noticeFormatVersion -ne 1 -or $lock.target -cne 'windows-x64' -or $lock.formalReleaseAllowed -or
    $lock.librimeRevision -cne $native.librime.revision -or $lock.marisaProvider -cne 'repository-pinned') {
  throw 'librime 组件清单不是当前固定构建的非发布清单。'
}
$runtime=Join-Path $repo '.kfe/native/runtime/ime/rime/windows'
$dll=Join-Path $runtime 'rime.dll'
$provenance=Get-Content -Raw -LiteralPath (Join-Path $runtime 'provenance.json')|ConvertFrom-Json
foreach ($name in @('revision','sha256','logging','externalPlugins','submodules','marisaProvider','marisaRevision',
    'marisaLibrarySha256','marisaCmakeSha256','openccRuntimeFilesVerified')) {
  if ($provenance.PSObject.Properties.Name -notcontains $name) { throw 'DLL 缺少完整固定依赖来源记录；请重新构建。' }
}
$dllHash=Get-ArtifactHash $dll
if ($provenance.revision -cne $native.librime.revision -or $provenance.sha256 -cne $dllHash -or
    $provenance.logging -or $provenance.externalPlugins -or $provenance.marisaProvider -cne $lock.marisaProvider -or
    $provenance.marisaRevision -cne $native.librime.submodules.'deps/marisa-trie' -or
    $provenance.marisaLibrarySha256 -cne (Get-ArtifactHash (Join-Path $repo '.kfe/native/librime-deps/lib/marisa.lib')) -or
    $provenance.marisaCmakeSha256 -cne (Get-ArtifactHash (Join-Path $repo 'native/cmake/opencc_repository_marisa.cmake')) -or
    $provenance.openccRuntimeFilesVerified -ne 30) {
  throw '只为来源匹配且共用固定 marisa 的本地 DLL 准备声明；不接受旧 DLL。'
}
foreach ($property in $native.librime.submodules.PSObject.Properties) {
  if ($provenance.submodules.($property.Name) -cne $property.Value) { throw 'DLL 的固定依赖来源记录不匹配。' }
}
$contracts=[ordered]@{
  rime=[ordered]@{BUILD_TEST='OFF';ENABLE_LOGGING='OFF';ENABLE_EXTERNAL_PLUGINS='OFF';RIME_PLUGINS=''}
  opencc=[ordered]@{BUILD_TESTING='OFF';ENABLE_GTEST='OFF';ENABLE_BENCHMARK='OFF';BUILD_PYTHON='OFF'
    USE_SYSTEM_MARISA='ON';USE_SYSTEM_DARTS='OFF';ENABLE_DARTS='ON';USE_SYSTEM_RAPIDJSON='OFF';USE_SYSTEM_TCLAP='OFF'}
  leveldb=[ordered]@{HAVE_SNAPPY='';HAVE_CRC32C='';HAVE_TCMALLOC=''}
}
foreach ($project in $contracts.Keys) {
  $cache=Join-Path $repo ('.kfe/out/librime/'+$project+'/CMakeCache.txt')
  [Kirakara.Artifacts.Security]::NoReparse($cache)
  $lines=@(Get-Content -LiteralPath $cache)
  foreach ($name in $contracts[$project].Keys) {
    $cacheMatches=@($lines|Where-Object { $_ -match ('^'+[regex]::Escape($name)+':[^=]+=') })
    if ($cacheMatches.Count -ne 1 -or $cacheMatches[0].Substring($cacheMatches[0].IndexOf('=')+1) -cne $contracts[$project][$name]) {
      throw '实际构建选项不属于组件声明范围；不将可选/系统组件隐藏在清单外。'
    }
  }
}
$lockHash=Get-ArtifactHash $lockPath
$nativeHash=Get-ArtifactHash $nativePath
$identity=Get-ArtifactTextHash ($dllHash+':'+$lockHash+':'+$nativeHash)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory=Join-Path $repo ('.kfe/native/notices/librime/'+$identity) }
$output=[IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith($repo+'\.kfe\',[StringComparison]::OrdinalIgnoreCase)) { throw '声明输出必须在当前仓库 .kfe 内。' }
[Kirakara.Artifacts.Security]::NoReparse($output)
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath=Join-Path $repo 'build/diagnostics/librime-notices.json' }
$report=[IO.Path]::GetFullPath($ReportPath)
if (-not $report.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '报告必须在当前仓库。' }
[Kirakara.Artifacts.Security]::NoReparse($report)
$scratch=Join-Path $repo ('.kfe/tmp/librime-notices-'+[guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null=New-Item -ItemType Directory -Path $scratch
$stage=Join-Path $scratch 'stage'
$null=New-Item -ItemType Directory -Path $stage
$files=[Collections.Generic.List[object]]::new()
$paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
function Assert-NoticeBytes {
  param([byte[]]$Bytes,$Record)
  if ($Bytes.Length -ne $Record.size -or [string]$Record.sha256 -cnotmatch '^[0-9A-F]{64}$' -or
      [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)) -cne $Record.sha256) {
    throw '声明或来源证明的原始字节与固定清单不匹配。'
  }
}
function Add-Notice {
  param([byte[]]$Bytes,$Record)
  Assert-NoticeBytes $Bytes $Record
  if (-not $paths.Add([string]$Record.outputPath)) { throw '声明输出路径重复。' }
  $target=[Kirakara.Artifacts.Security]::Child($stage,[string]$Record.outputPath)
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
  [IO.File]::WriteAllBytes($target,$Bytes)
  $files.Add([ordered]@{path=$Record.outputPath;size=$Record.size;sha256=$Record.sha256})
}
function Get-NoticeDownload {
  param($Record,[string]$Filename)
  $cache=[Kirakara.Artifacts.Security]::Child((Join-Path $repo '.kfe/downloads'),$Filename)
  if (-not (Test-Path -LiteralPath $cache)) {
    if ($Offline) { throw '离线缺少固定原始声明/源包；不生成半成品。' }
    $partial=Join-Path $scratch ([guid]::NewGuid().ToString('N')+'.partial')
    Save-ArtifactDownload -Uri $Record.url -Path $partial -ExpectedBytes $Record.size
    Assert-ArtifactFile $partial $Record
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $cache) -Force
    [IO.File]::Move($partial,$cache)
  }
  Assert-ArtifactFile $cache $Record
  return $cache
}
function Read-NoticeTarEntry {
  param([string]$Archive,[string]$Path)
  [Kirakara.Artifacts.Security]::RelativePath($Path)|Out-Null
  $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/tar.exe'))
  $start.UseShellExecute=$false; $start.CreateNoWindow=$true
  $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
  foreach ($arg in @('-xOf',$Archive,$Path)) { $start.ArgumentList.Add($arg) }
  $child=[Diagnostics.Process]::Start($start)
  $memory=[IO.MemoryStream]::new()
  try {
    $copy=$child.StandardOutput.BaseStream.CopyToAsync($memory)
    $errorOutput=$child.StandardError.ReadToEndAsync()
    if (-not $child.WaitForExit(30000)) { $child.Kill($true); $child.WaitForExit(); throw '固定小源包读取超时。' }
    $null=$copy.GetAwaiter().GetResult()
    $null=$errorOutput.GetAwaiter().GetResult()
    if ($child.ExitCode -ne 0 -or $memory.Length -gt 1048576) { throw '固定小源包条目缺失或异常。' }
    return ,$memory.ToArray()
  } finally {
    if (-not $child.HasExited) { $child.Kill($true); $child.WaitForExit() }
    $child.Dispose(); $memory.Dispose()
  }
}
try {
  $sourceGroups=@($lock.sourceNotices|Group-Object sourceRoot)
  foreach ($group in $sourceGroups) {
    $root=[Kirakara.Artifacts.Security]::Child($repo,$group.Name)
    if (-not $root.StartsWith($repo+'\.kfe\source\',[StringComparison]::OrdinalIgnoreCase)) { throw '声明来源不在当前仓库源码缓存。' }
    $revisions=@($group.Group.revision|Sort-Object -Unique)
    if ($revisions.Count -ne 1 -or (& git -C $root rev-parse HEAD) -cne $revisions[0] -or $LASTEXITCODE) {
      throw '声明来源 HEAD 不匹配；不 checkout 或重置。'
    }
    $status=@(& git -C $root status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -or $status.Count) { throw '声明来源有用户修改；保留内容并停止。' }
  }
  foreach ($record in $lock.sourceNotices) {
    $root=[Kirakara.Artifacts.Security]::Child($repo,[string]$record.sourceRoot)
    Add-Notice (Read-RimeSourceBlob $root $record.revision $record.path) $record
  }
  foreach ($record in $lock.fileNotices) {
    $source=[Kirakara.Artifacts.Security]::Child($repo,[string]$record.sourcePath)
    if (-not $source.StartsWith($repo+'\.kfe\source\',[StringComparison]::OrdinalIgnoreCase)) { throw '原始声明来源越界。' }
    Assert-ArtifactFile $source $record
    Add-Notice ([IO.File]::ReadAllBytes($source)) $record
  }
  foreach ($record in $lock.httpNotices) {
    $cache=Get-NoticeDownload $record ('librime-notice-'+$record.sha256+'.txt')
    Add-Notice ([IO.File]::ReadAllBytes($cache)) $record
  }
  $archive=Get-NoticeDownload $lock.dartsSourceArchive $lock.dartsSourceArchive.filename
  $original=Read-NoticeTarEntry $archive $lock.dartsSourceArchive.originalHeader.path
  Assert-NoticeBytes $original $lock.dartsSourceArchive.originalHeader
  $opencc=Join-Path $repo '.kfe/source/librime/deps/opencc'
  $vendor=Read-RimeSourceBlob $opencc $native.librime.submodules.'deps/opencc' $lock.dartsSourceArchive.vendoredHeader.path
  Assert-NoticeBytes $vendor $lock.dartsSourceArchive.vendoredHeader
  $derived=[Text.Encoding]::UTF8.GetString($original).Replace('typedef unsigned int id_type;','typedef size_t id_type;').
    Replace('const value_type values(std::size_t id) const','value_type values(std::size_t id) const')
  if ($derived -cne [Text.Encoding]::UTF8.GetString($vendor)) { throw 'OpenCC darts 副本与记录的原始源码/两项上游修改不匹配。' }
  foreach ($record in $lock.dartsSourceArchive.notices) { Add-Notice (Read-NoticeTarEntry $archive $record.path) $record }
  if ($files.Count -ne 19 -or $lock.components.Count -ne 11) { throw '运行库声明清单不完整。' }
  $lockBytes=[IO.File]::ReadAllBytes($lockPath)
  Add-Notice $lockBytes ([pscustomobject]@{outputPath='components.lock.json';size=$lockBytes.Length;sha256=$lockHash})
  # 声明格式变化必须升版锁中的 noticeFormatVersion；不覆盖旧格式目录。
  $inventory=[ordered]@{schemaVersion=1;noticeFormatVersion=$lock.noticeFormatVersion;kind='librime-notices';identityHash=$identity;librimeRevision=$native.librime.revision
    dllSha256=$dllHash;componentsLockSha256=$lockHash;nativeLockSha256=$nativeHash;noticeFiles=19;components=11
    dartsExactSourceDerivationVerified=$true;actualBuildExclusionsVerified=$true;formalReleaseAllowed=$false;files=$files.ToArray()}
  $inventoryBytes=[Text.Encoding]::UTF8.GetBytes(($inventory|ConvertTo-Json -Depth 8))
  Add-Notice $inventoryBytes ([pscustomobject]@{outputPath='notice-inventory.json';size=$inventoryBytes.Length
    sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($inventoryBytes))})
  $reused=Test-Path -LiteralPath $output
  if ($reused) {
    foreach ($item in Get-ChildItem -LiteralPath $output -Recurse -Force) { [Kirakara.Artifacts.Security]::NoReparse($item.FullName) }
    $actual=@(Get-ChildItem -LiteralPath $output -Recurse -File -Force)
    if ($actual.Count -ne $files.Count) { throw '已有声明目录有缺失/额外文件；不会覆盖。' }
    foreach ($file in $files) { Assert-ArtifactFile ([Kirakara.Artifacts.Security]::Child($output,$file.path)) $file }
  } else {
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force
    [IO.Directory]::Move($stage,$output)
  }
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
  [ordered]@{passed=$true;root=$output;identityHash=$identity;dllSha256=$dllHash;noticeFiles=19;components=11;reused=$reused
    exactDartsDerivationVerified=$true;actualBuildExclusionsVerified=$true;upstreamSourcesModified=$false;compilerInvoked=$false;appImeUiVerified=$false
    completeNativeAuditVerified=$false;formalReleasePublished=$false}|ConvertTo-Json|
    Set-Content -LiteralPath $report -Encoding utf8
  Write-Host "librime 11 个组件的 19 份原始声明已校验；未发布或清除整包审计门控。报告：$report"
} finally {
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  if (-not $scratch.StartsWith($repo+'\.kfe\tmp\librime-notices-',[StringComparison]::OrdinalIgnoreCase)) { throw '声明临时目录清理越界。' }
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
$global:LASTEXITCODE=0
