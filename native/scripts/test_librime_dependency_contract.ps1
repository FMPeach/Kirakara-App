#Requires -Version 7.2
[CmdletBinding()]
param([string]$CMake,[string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
if ([string]::IsNullOrWhiteSpace($CMake)) {
  $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
  $vs=(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)|Select-Object -First 1
  if ($LASTEXITCODE -or -not $vs) { throw '需要支持 Visual Studio 的 CMake；不自动安装系统工具。' }
  $CMake=Join-Path $vs 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
}
if (-not (Test-Path -LiteralPath $CMake -PathType Leaf)) { throw 'CMake 不存在。' }
$prefix=Join-Path $repo '.kfe/native/librime-deps'
$helper=Join-Path $repo 'native/cmake/opencc_repository_marisa.cmake'
$openccCache=Join-Path $repo '.kfe/out/librime/opencc/CMakeCache.txt'
$rimeCache=Join-Path $repo '.kfe/out/librime/rime/CMakeCache.txt'
foreach ($path in @($prefix,$helper,$openccCache,$rimeCache)) { [Kirakara.Artifacts.Security]::NoReparse($path) }
function Read-CacheValue {
  param([string]$Path,[string]$Name)
  $lines=@(Get-Content -LiteralPath $Path|Where-Object { $_ -match ('^'+[regex]::Escape($Name)+':[^=]+=') })
  if ($lines.Count -ne 1) { throw '构建缓存缺少唯一的依赖字段。' }
  return $lines[0].Substring($lines[0].IndexOf('=')+1)
}
$generator=Read-CacheValue $openccCache 'CMAKE_GENERATOR'
$library=Join-Path $prefix 'lib/marisa.lib'
$fixedLibrary=Join-Path $repo '.kfe/out/librime/marisa-trie/Release/marisa.lib'
if ((Read-CacheValue $openccCache 'USE_SYSTEM_MARISA') -cne 'ON' -or
    [IO.Path]::GetFullPath((Read-CacheValue $openccCache 'LIBMARISA')) -ine $library -or
    [IO.Path]::GetFullPath((Read-CacheValue $rimeCache 'Marisa_LIBRARY')) -ine $library -or
    [IO.Path]::GetFullPath((Read-CacheValue $rimeCache 'Marisa_INCLUDE_PATH')) -ine (Join-Path $prefix 'include') -or
    (Get-ArtifactHash $library) -cne (Get-ArtifactHash $fixedLibrary)) {
  throw '实际 OpenCC/librime 没有使用同一份固定 marisa；先重建，不能只验证夹具。'
}
$marisaSource=Join-Path $repo '.kfe/source/librime/deps/marisa-trie/include'
$headers=@(Get-ChildItem -LiteralPath $marisaSource -Recurse -File -Filter '*.h')
foreach ($header in $headers) {
  $relative=[IO.Path]::GetRelativePath($marisaSource,$header.FullName).Replace('\','/')
  $installed=[Kirakara.Artifacts.Security]::Child((Join-Path $prefix 'include'),$relative)
  if ((Get-ArtifactHash $installed) -cne (Get-ArtifactHash $header.FullName)) { throw '已安装 marisa 头文件不属于固定库来源。' }
}
$scratch=Join-Path $repo ('.kfe/tmp/rime-dependency-contract-'+[guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null=New-Item -ItemType Directory -Path $scratch
$cases=[Collections.Generic.List[string]]::new()
$cases.Add('实际 OpenCC/librime 共用固定库，安装未覆盖且头文件完整匹配')
function Invoke-Fixture {
  param([string]$Name,[string]$Project='opencc',[string]$Prefix=$prefix,[string]$CachedLibrary,[switch]$Duplicate,[string]$ExpectedFailure)
  $source=Join-Path $scratch ($Name+'/source')
  $output=Join-Path $scratch ($Name+'/out')
  $null=New-Item -ItemType Directory -Path $source -Force
  $content="cmake_minimum_required(VERSION 3.10)`n"
  if ($Duplicate) { $content+="add_library(marisa STATIC IMPORTED)`n" }
  $content+="project($Project LANGUAGES NONE)`n"
  $content+=@'
get_target_property(_imported marisa IMPORTED)
get_target_property(_library marisa IMPORTED_LOCATION)
get_target_property(_includes marisa INTERFACE_INCLUDE_DIRECTORIES)
if(NOT _imported OR NOT _library STREQUAL LIBMARISA OR
   NOT _includes STREQUAL "${KIRAKARA_REPOSITORY_MARISA_PREFIX}/include")
  message(FATAL_ERROR "固定目标和库/头文件不一致")
endif()
'@
  [IO.File]::WriteAllText((Join-Path $source 'CMakeLists.txt'),$content,[Text.UTF8Encoding]::new($false))
  $start=[Diagnostics.ProcessStartInfo]::new($CMake)
  $start.UseShellExecute=$false; $start.CreateNoWindow=$true
  $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
  $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
  $start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
  $arguments=@('-S',$source,'-B',$output,'-G',$generator,'-A','x64',
    "-DCMAKE_PROJECT_INCLUDE=$($helper.Replace('\','/'))","-DKIRAKARA_REPOSITORY_MARISA_PREFIX=$($Prefix.Replace('\','/'))")
  if ($CachedLibrary) { $arguments+="-DLIBMARISA=$($CachedLibrary.Replace('\','/'))" }
  foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
  $child=[Diagnostics.Process]::Start($start)
  try {
    $stdout=$child.StandardOutput.ReadToEndAsync(); $stderr=$child.StandardError.ReadToEndAsync()
    if (-not $child.WaitForExit(30000)) { $child.Kill($true); $child.WaitForExit(); throw '依赖配置夹具超时；不计通过。' }
    $messages=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
    if ($ExpectedFailure) {
      if ($child.ExitCode -eq 0 -or $messages -notlike $ExpectedFailure) { throw "拒绝配置没有按预期失败：$Name" }
    } elseif ($child.ExitCode -ne 0) { throw '有效的固定 marisa 配置失败；不计通过。' }
  } finally {
    if (-not $child.HasExited) { $child.Kill($true); $child.WaitForExit() }
    $child.Dispose()
  }
}
try {
  Invoke-Fixture 'valid'
  $cases.Add('实际 CMake 配置创建固定的导入目标及配套头文件')
  Invoke-Fixture 'wrong-project' -Project 'other' -ExpectedFailure '*只适用于 OpenCC 项目*'
  $cases.Add('用于其他项目时明确拒绝')
  Invoke-Fixture 'wrong-prefix' -Prefix (Join-Path $scratch 'unknown') -ExpectedFailure '*必须来自当前仓库的固定构建目录*'
  $cases.Add('其他来源目录明确拒绝，不探测系统库')
  Invoke-Fixture 'wrong-cache' -CachedLibrary (Join-Path $scratch 'unknown/marisa.lib') -ExpectedFailure '*已有 OpenCC marisa 缓存不匹配*'
  $cases.Add('已有未知库缓存拒绝，不静默替换')
  Invoke-Fixture 'duplicate' -Duplicate -ExpectedFailure '*已存在其他 marisa 目标*'
  $cases.Add('重复 marisa 目标拒绝，防止混用')
  if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath=Join-Path $repo 'build/diagnostics/librime-dependency-contract.json' }
  $report=[IO.Path]::GetFullPath($ReportPath)
  if (-not $report.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '报告必须位于当前仓库。' }
  [Kirakara.Artifacts.Security]::NoReparse($report)
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
  [ordered]@{passed=$true;cases=$cases.ToArray();installedHeadersVerified=$headers.Count;marisaLibrarySha256=Get-ArtifactHash $library
    fixtureCompilerInvoked=$false;appImeUiVerified=$false;formalReleasePublished=$false}|ConvertTo-Json -Depth 4|
    Set-Content -LiteralPath $report -Encoding utf8
  Write-Host "librime 依赖 $($cases.Count) 项实际缓存/配置检查通过。报告：$report"
} finally {
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  if (-not $scratch.StartsWith($repo+'\.kfe\tmp\rime-dependency-contract-',[StringComparison]::OrdinalIgnoreCase)) { throw '依赖测试清理目标越界。' }
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
$global:LASTEXITCODE=0
