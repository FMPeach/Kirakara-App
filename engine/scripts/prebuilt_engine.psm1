Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'artifact_package.psm1') -DisableNameChecking
$script:AppRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))

function Get-PrebuiltEngineIdentity {
  param([Parameter(Mandatory)]$Lock,[Parameter(Mandatory)][ValidateSet('debug','profile','release')][string]$Mode)
  $builds = @($Lock.patchset.builds | Where-Object mode -EQ $Mode)
  if ($builds.Count -ne 1) { throw 'Engine 模式锁定配置不唯一。' }
  $build = $builds[0]
  $dart = @($Lock.projectBootstrap.engineDependencyPatches | Where-Object name -EQ 'dart')
  if ($dart.Count -ne 1) { throw 'Engine 锁缺少唯一 Dart revision。' }
  foreach ($patch in @($Lock.patchset.patches)+@($Lock.projectBootstrap.engineSourcePatches)+@($dart[0].patches)+@($Lock.sdkToolBootstrap.patches)) {
    $patchPath = [Kirakara.Artifacts.Security]::Child($script:AppRoot,[string]$patch.path)
    if ((Get-ArtifactHash $patchPath) -ine [string]$patch.sha256) {
      throw '补丁文件与 Engine 锁不一致；不能静默使用不匹配的预编译包。'
    }
  }
  $identity = [ordered]@{
    packageFormatVersion=2; os='windows'; architecture='x64'; mode=$Mode
    frameworkRevision=[string]$Lock.flutter.frameworkRevision
    engineRevision=[string]$Lock.flutter.engineRevision
    dartRevision=[string]$dart[0].revision
    patchsetRevision=[string]$Lock.patchset.revision
    patchsetVersion=[int]$Lock.patchset.version; abiVersion=[int]$Lock.patchset.abiVersion
    engineSourceTree=[string]$Lock.projectBootstrap.engineSourceTree
    localEngine=[string]$build.localEngine; localEngineHost=[string]$build.localEngineHost
    argsGnSha256=[string]$build.argsGnSha256
    patches=@($Lock.patchset.patches | ForEach-Object { [ordered]@{path=$_.path;sha256=$_.sha256} })
    sourcePatches=@($Lock.projectBootstrap.engineSourcePatches | ForEach-Object { [ordered]@{path=$_.path;sha256=$_.sha256} })
    dartPatches=@($dart[0].patches | ForEach-Object { [ordered]@{path=$_.path;sha256=$_.sha256} })
    sdkTools=@($Lock.prebuiltSdkTools | ForEach-Object { [ordered]@{path=$_.outputPath;sha256=$_.sha256} })
    sdkToolBootstrap=$Lock.sdkToolBootstrap
  }
  return [pscustomobject]@{
    value=Get-ArtifactTextHash ($identity | ConvertTo-Json -Depth 15 -Compress)
    identity=$identity; build=$build
  }
}

function Get-PrebuiltEngineCacheKey {
  param([Parameter(Mandatory)][string]$IdentityHash)
  if ($IdentityHash -notmatch '^[0-9A-Fa-f]{64}$') {
    throw 'Engine 缓存键必须来自完整的 SHA-256 身份。'
  }
  return $IdentityHash.Substring(0,8).ToUpperInvariant()
}

function Get-PrebuiltEngineEntry {
  param([Parameter(Mandatory)]$Lock,[Parameter(Mandatory)][string]$Mode,[string]$LockPath)
  if ([string]::IsNullOrWhiteSpace($LockPath)) {
    $LockPath = [Environment]::GetEnvironmentVariable('KIRAKARA_PREBUILT_LOCK','Process')
  }
  if ([string]::IsNullOrWhiteSpace($LockPath)) { $LockPath = Join-Path $script:AppRoot 'engine/prebuilt.lock.json' }
  [Kirakara.Artifacts.Security]::NoReparse($LockPath)
  $prebuiltLock = Get-Content -Raw -LiteralPath $LockPath -Encoding utf8 |
    ConvertFrom-Json
  if ($prebuiltLock.schemaVersion -ne 1 -or $prebuiltLock.packageFormatVersion -ne 2 -or
      $prebuiltLock.target -cne 'windows-x64') { throw '预编译锁格式或架构不受支持。' }
  $identity = Get-PrebuiltEngineIdentity $Lock $Mode
  $entry = $prebuiltLock.modes.PSObject.Properties[$Mode].Value
  if ($null -eq $entry) {
    throw "维护者尚未配置 $Mode 预编译 Engine Release。可使用审核后的本地 ZIP/候选锁，或显式执行 '.\flutterw engine prepare $Mode --from-source'。不会自动进行几十 GB 源码构建。"
  }
  if ($entry.identityHash -cne $identity.value) { throw '预编译 Engine 锁与源码/补丁身份不匹配。' }
  return [pscustomobject]@{entry=$entry;identity=$identity;lockPath=[IO.Path]::GetFullPath($LockPath)}
}

function Get-PrebuiltEngineRequiredFiles {
  param([Parameter(Mandatory)]$Identity)
  $localEngine = [string]$Identity.localEngine
  [Kirakara.Artifacts.Security]::RelativePath($localEngine) | Out-Null
  $prefix = "out/$localEngine/"
  $required = @('args.gn','flutter_windows.dll','flutter_windows.dll.exp','flutter_windows.dll.lib','icudtl.dat',
    'flutter_export.h','flutter_macros.h','flutter_windows.h','flutter_messenger.h',
    'flutter_plugin_registrar.h','flutter_texture_registrar.h',
    'cpp_client_wrapper/core_implementations.cc','cpp_client_wrapper/standard_codec.cc',
    'cpp_client_wrapper/plugin_registrar.cc','cpp_client_wrapper/flutter_engine.cc',
    'cpp_client_wrapper/flutter_view_controller.cc','cpp_client_wrapper/include/flutter/flutter_engine.h',
    'dart-sdk/bin/dart.exe','dart-sdk/bin/dartaotruntime.exe',
    'dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot','dart-sdk/lib/_internal/vm_platform_strong.dill',
    'flutter_patched_sdk/platform_strong.dill','flutter_patched_sdk/vm_outline_strong.dill',
    'gen/dart-pkg/sky_engine/pubspec.yaml','impellerc.exe',
    'font-subset.exe','gen/const_finder.dart.snapshot')
  if ($Identity.mode -ne 'debug') { $required += 'gen_snapshot.exe' }
  return @($required | ForEach-Object { $prefix+$_ }) + @(
    'licenses/Flutter-BSD-3-Clause.txt','licenses/Dart-BSD-3-Clause.txt',
    'licenses/Skia-BSD-3-Clause.txt','licenses/ICU.txt','licenses/Engine-NOTICES.txt',
    'MODIFICATIONS.md','engine.lock.json')
}

function Invoke-PrebuiltAbiProbe {
  param([Parameter(Mandatory)][string]$DllPath)
  $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
  $start.UseShellExecute = $false; $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
  Set-KirakaraProcessArguments -StartInfo $start -Arguments @(
    '-NoLogo','-NoProfile','-NonInteractive','-File',
    (Join-Path $PSScriptRoot 'probe_prebuilt_abi.ps1'),'-DllPath',$DllPath,
    '-EngineLockPath',(Join-Path $script:AppRoot 'engine/engine.lock.json'))
  $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
  try {
    if (-not $process.Start()) { throw '无法启动有时限的 ABI 验证进程。' }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(15000)) {
      Stop-KirakaraProcessTree -Process $process
      $process.WaitForExit()
      throw 'Engine ABI 验证超时；没有回退或启动源码构建。'
    }
    if ($process.ExitCode -ne 0) { throw "Engine ABI 验证失败：$($stderr.GetAwaiter().GetResult())" }
    $result = $stdout.GetAwaiter().GetResult() | ConvertFrom-Json
    if (-not $result.passed) { throw 'Engine ABI 验证没有明确通过。' }
  } finally { $process.Dispose() }
}

function Assert-PrebuiltEngineContents {
  param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)]$Lock,[Parameter(Mandatory)]$ExpectedIdentity,[switch]$SkipAbiProbe)
  $actualHash = Get-ArtifactTextHash ($Manifest.identity | ConvertTo-Json -Depth 15 -Compress)
  if ($actualHash -cne $ExpectedIdentity.value) { throw 'Engine manifest revision/ABI/模式身份错误。' }
  $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($file in $Manifest.files) {
    $null = $paths.Add([string]$file.path)
    if ([string]$file.path -match '\.(pdb|obj|ninja)$' -or [string]$file.path -match '(^|/)(source|\.git|obj)/') {
      throw '普通预编译包不能携带 PDB、构建缓存或完整上游源码；符号必须独立。'
    }
  }
  foreach ($required in Get-PrebuiltEngineRequiredFiles $ExpectedIdentity.identity) {
    if (-not $paths.Contains($required)) { throw "Engine 开发包缺少必要文件：$required" }
  }
  $output = Join-Path $Root ('out/'+$ExpectedIdentity.build.localEngine)
  if ((Get-ArtifactHash (Join-Path $output 'args.gn')) -ine $ExpectedIdentity.build.argsGnSha256) {
    throw 'Engine GN 参数哈希不匹配。'
  }
  foreach ($record in $ExpectedIdentity.build.artifacts | Where-Object { $_.path -notlike '*.pdb' }) {
    Assert-ArtifactFile ([Kirakara.Artifacts.Security]::Child($output,[string]$record.path)) $record
  }
  foreach ($record in $Lock.prebuiltSdkTools) {
    Assert-ArtifactFile ([Kirakara.Artifacts.Security]::Child($output,[string]$record.outputPath)) $record
  }
  foreach ($file in $Manifest.files | Where-Object { $_.path -match '\.(dll|exe)$' }) {
    $pe = [Kirakara.Artifacts.PeReader]::Read([Kirakara.Artifacts.Security]::Child($Root,[string]$file.path))
    if ($pe.Machine -ne 0x8664) { throw 'Engine 包中存在非 x64 可执行文件。' }
  }
  $dllPath = Join-Path $output 'flutter_windows.dll'
  $engine = [Kirakara.Artifacts.PeReader]::Read($dllPath)
  if (-not $engine.IsDll) { throw 'Flutter Engine 不是 DLL。' }
  foreach ($export in @('FlutterDesktopEngineCreate','FlutterDesktopViewControllerCreate') + @($Lock.patchset.additionalExports)) {
    if ($engine.Exports -cnotcontains $export) { throw "Engine 缺少必要导出：$export" }
  }
  if (-not $SkipAbiProbe) { Invoke-PrebuiltAbiProbe $dllPath }
}

function Ensure-PrebuiltEngine {
  param([Parameter(Mandatory)]$Layout,[Parameter(Mandatory)]$Lock,
        [Parameter(Mandatory)][string]$Mode,[string]$Package,[string]$LockPath,
        $TrustedEntry)
  if ($null -eq $TrustedEntry) {
    $selection = Get-PrebuiltEngineEntry $Lock $Mode $LockPath
  } else {
    $identity = Get-PrebuiltEngineIdentity $Lock $Mode
    if ($TrustedEntry.identityHash -cne $identity.value) {
      throw '仓库内候选 Engine 选择与当前源码、补丁或 ABI 身份不匹配。'
    }
    $selection = [pscustomobject]@{
      entry = $TrustedEntry
      identity = $identity
      lockPath = $null
    }
  }
  $cacheKey = Get-PrebuiltEngineCacheKey $selection.identity.value
  $destination = Join-Path $Layout.Root ("prebuilt/$Mode/"+$cacheKey)
  $identity = $selection.identity
  $engineModule = $ExecutionContext.SessionState.Module
  $verify = {
    param($root,$manifest)
    & $engineModule {
      param($packageRoot,$packageManifest,$engineLock,$expected)
      Assert-PrebuiltEngineContents $packageRoot $packageManifest $engineLock $expected
    } $root $manifest $Lock $identity
  }.GetNewClosure()
  $root = Install-ArtifactPackage -Workspace $Layout.Root -Destination $destination -Kind flutter-engine `
    -IdentityHash $identity.value -Entry $selection.entry -Verify $verify -LocalArchive $Package
  return [pscustomobject]@{
    kind='prebuilt'; mode=$Mode; root=$root; outputRoot=$root
    output=Join-Path $root ('out/'+$identity.build.localEngine)
    localEngine=$identity.build.localEngine; localEngineHost=$identity.build.localEngineHost
    identityHash=$identity.value
  }
}

Export-ModuleMember -Function @('Get-PrebuiltEngineIdentity','Get-PrebuiltEngineCacheKey','Get-PrebuiltEngineEntry',
  'Get-PrebuiltEngineRequiredFiles','Invoke-PrebuiltAbiProbe','Assert-PrebuiltEngineContents','Ensure-PrebuiltEngine')
