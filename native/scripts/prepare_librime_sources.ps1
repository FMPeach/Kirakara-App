#Requires -Version 7.2
[CmdletBinding()]
param([switch]$Offline)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
$lock=Get-Content -Raw -LiteralPath (Join-Path $repo 'native/native.lock.json')|ConvertFrom-Json
$source=Join-Path $repo '.kfe/source/librime'
$boost=Join-Path $repo '.kfe/source/boost'
$archive=Join-Path $repo ('.kfe/downloads/boost_'+$lock.librime.boost.version.Replace('.','_')+'.tar.bz2')
foreach ($path in @($source,$boost,$archive)) { [Kirakara.Artifacts.Security]::NoReparse($path) }
if (-not (Test-Path -LiteralPath (Join-Path $source '.git'))) {
  if ((Test-Path -LiteralPath $source) -or $Offline) { throw 'librime 源码缺失或目录不受管理；不会覆盖。' }
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force
  & git -c core.autocrlf=false clone --no-checkout $lock.librime.repository $source | Out-Host
  if ($LASTEXITCODE) {throw 'librime 官方源码获取失败。'}
  & git -C $source fetch --depth 1 origin $lock.librime.revision | Out-Host
  if ($LASTEXITCODE) {throw 'librime 固定 revision 获取失败。'}
  & git -C $source -c core.autocrlf=false checkout --detach $lock.librime.revision | Out-Host
  if ($LASTEXITCODE) {throw 'librime 固定 revision 签出失败。'}
}
if ((& git -C $source rev-parse HEAD) -cne $lock.librime.revision -or
    @(& git -C $source status --porcelain --untracked-files=no).Count) { throw 'librime 源码不是锁定的干净 revision；不会重置用户改动。' }
foreach ($property in $lock.librime.submodules.PSObject.Properties) {
  $child=Join-Path $source $property.Name
  [Kirakara.Artifacts.Security]::NoReparse($child)
  if (-not (Test-Path -LiteralPath (Join-Path $child '.git'))) {
    if ($Offline) {throw '离线准备缺少锁定的 librime 构建依赖。'}
    & git -C $source -c core.autocrlf=false submodule update --init -- $property.Name | Out-Host
    if ($LASTEXITCODE) {throw 'librime 构建依赖获取失败。'}
  }
  if ((& git -C $child rev-parse HEAD) -cne [string]$property.Value -or
      @(& git -C $child status --porcelain --untracked-files=no).Count) {throw 'librime 依赖 revision 或内容不匹配；不会覆盖。'}
}
# Only the four locked submodules are obtained. GPL/unknown external plugins,
# glog and googletest are not initialized as implicit build dependencies.
$scratch=Join-Path $repo ('.kfe/tmp/rime-source-'+[guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null=New-Item -ItemType Directory -Path $scratch
try {
  if (-not (Test-Path -LiteralPath $archive)) {
    if ($Offline) {throw '离线准备缺少固定 Boost 官方源包。'}
    $partial=Join-Path $scratch 'boost.partial'
    Save-ArtifactDownload -Uri $lock.librime.boost.url -Path $partial -ExpectedBytes $lock.librime.boost.size
    Assert-ArtifactFile $partial $lock.librime.boost
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $archive) -Force
    [IO.File]::Move($partial,$archive)
  }
  Assert-ArtifactFile $archive $lock.librime.boost
  $root='boost_'+$lock.librime.boost.version.Replace('.','_')
  $types=@(& tar -tvf $archive ($root+'/boost/') ($root+'/LICENSE_1_0.txt'))
  if ($LASTEXITCODE -or $types.Count -gt 30000 -or @($types|Where-Object {$_ -notmatch '^[-d]'}).Count) {
    throw 'Boost 使用范围含链接/异常类型，或条目超限。'
  }
  $extracted=Join-Path $scratch 'extracted'
  $null=New-Item -ItemType Directory -Path $extracted
  & tar -xf $archive -C $extracted ($root+'/boost/') ($root+'/LICENSE_1_0.txt')
  if ($LASTEXITCODE) {throw 'Boost 头文件解压失败；未获取含非法 Windows 文件名的上游测试。'}
  $expectedRoot=Join-Path $extracted $root
  $files=@(Get-ChildItem -LiteralPath $expectedRoot -Recurse -File -Force)
  $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($file in $files) {
    $relative=[IO.Path]::GetRelativePath($expectedRoot,$file.FullName).Replace('\','/')
    $null=$paths.Add([Kirakara.Artifacts.Security]::RelativePath($relative))
    [Kirakara.Artifacts.Security]::NoReparse($file.FullName)
  }
  if (Test-Path -LiteralPath $boost) {
    foreach ($file in $files) {
      $relative=[IO.Path]::GetRelativePath($expectedRoot,$file.FullName).Replace('\','/')
      $actual=[Kirakara.Artifacts.Security]::Child($boost,$relative)
      if (-not (Test-Path -LiteralPath $actual -PathType Leaf) -or (Get-ArtifactHash $actual) -cne (Get-ArtifactHash $file.FullName)) {
        throw '现有 Boost 头文件或许可与官方源包不同；不会覆盖现有源码。'
      }
    }
    foreach ($file in Get-ChildItem -LiteralPath $boost -Recurse -File -Force) {
      [Kirakara.Artifacts.Security]::NoReparse($file.FullName)
      if (-not $paths.Contains([IO.Path]::GetRelativePath($boost,$file.FullName).Replace('\','/'))) { throw 'Boost 源码包含官方选定范围以外的文件。' }
    }
  } else {
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $boost) -Force
    [IO.Directory]::Move($expectedRoot,$boost)
  }
  Write-Host "librime 固定源码及四个依赖通过；Boost 官方头文件/许可 $($files.Count) 项逐内容验证通过。"
} finally {
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
