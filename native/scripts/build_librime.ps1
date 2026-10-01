#Requires -Version 7.2
[CmdletBinding()]
param([ValidateRange(1,64)][int]$Jobs=8,[string]$CMake,[switch]$Offline)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$environmentBefore=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in Get-ChildItem Env:) {$environmentBefore[$entry.Name]=$entry.Value}
try {
. (Join-Path $repo 'engine/scripts/common.ps1')
$layout=Get-EngineWorkspaceLayout (Join-Path $repo '.kfe')
Assert-RepositoryEngineWriteWorkspace $layout
Set-EngineProcessEnvironment -Layout $layout
& (Join-Path $PSScriptRoot 'prepare_librime_sources.ps1') -Offline:$Offline
$lock=Get-Content -Raw -LiteralPath (Join-Path $repo 'native/native.lock.json')|ConvertFrom-Json
$source=Join-Path $repo '.kfe/source/librime'
$boost=Join-Path $repo '.kfe/source/boost'
$output=Join-Path $repo '.kfe/out/librime'
$prefix=Join-Path $repo '.kfe/native/librime-deps'
$runtime=Join-Path $repo '.kfe/native/runtime'
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if ([string]::IsNullOrWhiteSpace($CMake)) {
  $vs=(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)|Select-Object -First 1
  if (-not $vs) {throw '需要 Visual Studio C++ 桌面工具；不会自动安装系统组件。'}
  $CMake=Join-Path $vs 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
}
if (-not (Test-Path -LiteralPath $CMake -PathType Leaf)) {throw '未找到支持 MSVC 的 CMake。'}
$generators=@((& $CMake --help)|Where-Object {$_ -match '^\s*\*?\s*Visual Studio (\d+) (\d{4})\s*='}|
  ForEach-Object {$_ -replace '^\s*\*?\s*(Visual Studio \d+ \d{4}).*','$1'})
if (-not $generators) {throw 'CMake 缺少 Visual Studio generator。'}
$cached=@(Get-ChildItem -LiteralPath $output -Recurse -Filter CMakeCache.txt -File -ErrorAction SilentlyContinue |
  ForEach-Object {Get-Content -LiteralPath $_.FullName|Where-Object {$_ -like 'CMAKE_GENERATOR:INTERNAL=*'}|
    ForEach-Object {$_ -replace '^CMAKE_GENERATOR:INTERNAL=',''}}|Sort-Object -Unique)
if ($cached.Count -gt 1) {throw '现有 librime 构建缓存使用不同 generator；保留缓存，请人工检查。'}
$generator=if ($cached.Count) {$cached[0]} else {$generators[0]}
if ($generator -notin $generators) {throw '现有构建缓存的 generator 当前不可用；不会清理缓存。'}
if ((& git -C $source rev-parse HEAD) -cne $lock.librime.revision) {throw 'librime 源码 revision 不匹配。请先获取锁定的官方源码。'}
if (@(& git -C $source status --porcelain --untracked-files=no).Count) {throw '不使用被修改的 librime 源码。'}
foreach ($property in $lock.librime.submodules.PSObject.Properties) {
  if ((& git -C (Join-Path $source $property.Name) rev-parse HEAD) -cne [string]$property.Value) {throw 'librime 子模块 revision 不匹配。'}
  if (@(& git -C (Join-Path $source $property.Name) status --porcelain --untracked-files=no).Count) {throw '不使用被修改的 librime 构建依赖。'}
}
if (-not (Test-Path -LiteralPath (Join-Path $boost 'boost/version.hpp'))) {throw 'Boost 尚未准备。必须使用 native.lock.json 记录的官方数据包。'}
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
foreach ($path in @($output,$prefix,$runtime,$source,$boost)) { [Kirakara.Artifacts.Security]::NoReparse($path) }
$prefixArgument=$prefix.Replace('\','/')
$common=@('-G',$generator,'-A','x64','-DCMAKE_POLICY_VERSION_MINIMUM=3.10','-DCMAKE_POLICY_DEFAULT_CMP0167=OLD',
  '-DBUILD_SHARED_LIBS=OFF',"-DCMAKE_INSTALL_PREFIX=$prefixArgument",
  '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded$<$<CONFIG:Debug>:Debug>',
  '-DCMAKE_CXX_FLAGS=/utf-8 /EHsc /DNOMINMAX',
  "-DCMAKE_USER_MAKE_RULES_OVERRIDE=$($source.Replace('\','/'))/cmake/c_flag_overrides.cmake",
  "-DCMAKE_USER_MAKE_RULES_OVERRIDE_CXX=$($source.Replace('\','/'))/cmake/cxx_flag_overrides.cmake")
function Build-Dependency {
  param([string]$Name,[string[]]$Options)
  $directory=Join-Path $output $Name
  & $CMake -S (Join-Path $source "deps/$Name") -B $directory @common @Options | Out-Host
  if ($LASTEXITCODE) {throw "$Name 配置失败。"}
  & $CMake --build $directory --config Release --parallel $Jobs | Out-Host
  if ($LASTEXITCODE) {throw "$Name 构建失败。"}
  if ($Name -eq 'opencc') {
    # The upstream CLI accepts narrow paths. Use relative arguments for its
    # dictionary conversion, without modifying upstream code or drive aliases.
    $data=Join-Path $directory 'data'
    $tool=Join-Path $directory 'src/tools/Release/opencc_dict.exe'
    $raw=@('STCharacters','STPhrases','TSCharacters','TSPhrases','TWVariants','TWVariantsRevPhrases','HKVariants','HKVariantsRevPhrases','JPVariants','JPShinjitaiCharacters','JPShinjitaiPhrases')
    $generated=@('TWPhrases','TWPhrasesRev','TWVariantsRev','HKVariantsRev','JPVariantsRev')
    Push-Location $data
    try {
      foreach ($name in $raw+$generated) {
        $input=if ($name -in $raw) {[IO.Path]::GetRelativePath($data,(Join-Path $source "deps/opencc/data/dictionary/$name.txt"))} else {"$name.txt"}
        & $tool -i $input -o "$name.ocd2" -f text -t ocd2 | Out-Host
        if ($LASTEXITCODE -or -not (Test-Path -LiteralPath "$name.ocd2")) {throw 'OpenCC 数据转换未产生输出。'}
      }
    } finally {Pop-Location}
  }
  & $CMake --install $directory --config Release | Out-Host
  if ($LASTEXITCODE) {throw "$Name 安装失败。"}
}
Build-Dependency 'leveldb' @('-DLEVELDB_BUILD_BENCHMARKS=OFF','-DLEVELDB_BUILD_TESTS=OFF')
Build-Dependency 'yaml-cpp' @('-DMSVC_SHARED_RT=OFF','-DYAML_MSVC_SHARED_RT=OFF','-DYAML_CPP_BUILD_CONTRIB=OFF','-DYAML_CPP_BUILD_TESTS=OFF','-DYAML_CPP_BUILD_TOOLS=OFF')
Build-Dependency 'marisa-trie' @()
$marisaLibrary=Join-Path $prefix 'lib/marisa.lib'
$marisaHash=Get-ArtifactHash $marisaLibrary
$marisaCmake=Join-Path $repo 'native/cmake/opencc_repository_marisa.cmake'
[Kirakara.Artifacts.Security]::NoReparse($marisaCmake)
# 两个上游项目原本都会安装 marisa.lib，导致固定仓库头文件配上另一份库。
# 为 OpenCC 提供一个明确的仓库内目标，避免同名库覆盖和混合 ABI；不改上游代码。
Build-Dependency 'opencc' @('-DBUILD_TESTING=OFF','-DENABLE_GTEST=OFF','-DENABLE_BENCHMARK=OFF','-DBUILD_PYTHON=OFF',
  '-DUSE_SYSTEM_MARISA=ON',"-DCMAKE_PROJECT_INCLUDE=$($marisaCmake.Replace('\','/'))",
  "-DKIRAKARA_REPOSITORY_MARISA_PREFIX=$prefixArgument")
if ((Get-ArtifactHash $marisaLibrary) -cne $marisaHash) { throw 'OpenCC 安装覆盖了固定 marisa；不继续生成 DLL。' }
$openccDataLock=Get-Content -Raw -LiteralPath (Join-Path $repo 'third_party/rime-opencc.lock.json')|ConvertFrom-Json
if ($openccDataLock.revision -cne $lock.librime.submodules.'deps/opencc') { throw 'OpenCC 数据来源 revision 不匹配。' }
foreach ($record in $openccDataLock.runtimeFiles) {
  Assert-ArtifactFile ([Kirakara.Artifacts.Security]::Child((Join-Path $prefix 'share/opencc'),[string]$record.path)) $record
}
$directory=Join-Path $output 'rime'
& $CMake -S $source -B $directory @common '-DBUILD_SHARED_LIBS=ON' '-DBUILD_STATIC=ON' '-DBUILD_TEST=OFF' '-DBUILD_DATA=OFF' '-DENABLE_LOGGING=OFF' '-DENABLE_EXTERNAL_PLUGINS=OFF' '-DRIME_PLUGINS=' "-DCMAKE_PREFIX_PATH=$prefixArgument" "-DBOOST_ROOT=$($boost.Replace('\','/'))" "-DCMAKE_INSTALL_PREFIX=$($runtime.Replace('\','/'))/rime-build" | Out-Host
if ($LASTEXITCODE) {throw 'librime 配置失败。'}
& $CMake --build $directory --config Release --parallel $Jobs | Out-Host
if ($LASTEXITCODE) {throw 'librime 构建失败。'}
& $CMake --install $directory --config Release | Out-Host
if ($LASTEXITCODE) {throw 'librime 安装失败。'}
$dll=Join-Path $runtime 'rime-build/lib/rime.dll'
if (-not (Test-Path -LiteralPath $dll)) { $dll=Join-Path $runtime 'rime-build/bin/rime.dll' }
if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {throw 'librime 构建没有生成 DLL。'}
$target=Join-Path $runtime 'ime/rime/windows'
$null=New-Item -ItemType Directory -Path $target -Force
Copy-Item -LiteralPath $dll -Destination (Join-Path $target 'rime.dll')
$record=[ordered]@{schemaVersion=1;revision=$lock.librime.revision;submodules=$lock.librime.submodules
  compiler='本机 MSVC；完整编译器信息保留于 CMakeCache';cmake=$CMake;generator=$generator
  marisaProvider='repository-pinned'
  marisaRevision=$lock.librime.submodules.'deps/marisa-trie';marisaLibrarySha256=$marisaHash
  marisaCmakeSha256=Get-ArtifactHash $marisaCmake;openccRuntimeFilesVerified=$openccDataLock.runtimeFiles.Count
  logging=$false;externalPlugins=$false;sha256=Get-ArtifactHash (Join-Path $target 'rime.dll')}
$record|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $target 'provenance.json') -Encoding utf8
Write-Host 'librime 已从固定官方 revision 重建；未读取旧 rime.dll。'
} finally {
  foreach ($name in @(Get-ChildItem Env:|ForEach-Object Name)) {
    if (-not $environmentBefore.ContainsKey($name)) {Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue}
  }
  foreach ($entry in $environmentBefore.GetEnumerator()) {[Environment]::SetEnvironmentVariable($entry.Key,$entry.Value,'Process')}
}
