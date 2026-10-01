[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$FlutterSdkRoot,

  [ValidateSet('official', 'local')]
  [string]$Engine = 'local',

  [ValidateSet('stock', 'patched')]
  [string]$LocalVariant = 'stock',

  [string]$WorkspaceRoot,

  [string]$WindowsSdkPath = 'C:\Program Files (x86)\Windows Kits\10',

  [ValidateSet('debug', 'profile', 'release')]
  [string[]]$Mode = @('debug', 'profile', 'release')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
Import-Module (Join-Path $PSScriptRoot 'show_host_input.psm1') `
  -DisableNameChecking
$showHost = Resolve-KirakaraShowHostInput

$lock = Get-EngineLock
$flutterRoot = Resolve-UnresolvedPath $FlutterSdkRoot
if (-not (Test-PathWithin $flutterRoot (Join-Path (Get-AppRepositoryRoot) '.kfe/sdk'))) {
  throw 'App 构建只能执行当前仓库 .kfe/sdk 中的官方工具；不会写入系统 Flutter cache。'
}
$flutter = Join-Path $flutterRoot 'bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutter -PathType Leaf)) {
  throw "Flutter SDK is missing flutter.bat: $flutterRoot"
}

$frameworkHead = Get-GitHead $flutterRoot
if ($frameworkHead -ne $lock.flutter.frameworkRevision) {
  throw "Flutter Framework revision mismatch. Expected $($lock.flutter.frameworkRevision), got $frameworkHead."
}
$sdkEngineRevision = (
  Get-Content -Raw -LiteralPath (Join-Path $flutterRoot 'bin\internal\engine.version')
).Trim()
if ($sdkEngineRevision -ne $lock.flutter.engineRevision) {
  throw "Flutter SDK Engine revision mismatch. Expected $($lock.flutter.engineRevision), got $sdkEngineRevision."
}

$layout = $null
if ($Engine -eq 'local') {
  if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    throw '-WorkspaceRoot is required for -Engine local.'
  }
  $layout = Get-EngineWorkspaceLayout $WorkspaceRoot
  Assert-ExternalEngineWorkspace $layout
  if ($LocalVariant -eq 'stock') {
    Assert-PinnedFlutterSource -Lock $lock -Layout $layout -RequireStockTree
  } else {
    Assert-AppliedPatchset -Lock $lock -Layout $layout
    Assert-MatchingTextFile `
      -ExpectedPath (Join-Path $layout.EngineSource `
        'flutter\shell\platform\windows\kirakara_flutter_compositor_api.h') `
      -ActualPath (Join-Path (Get-AppRepositoryRoot) `
        'engine\include\kirakara_flutter_compositor_api.h') `
      -Label 'Kirakara compositor ABI header'
  }
} elseif ($LocalVariant -ne 'stock') {
  throw '-LocalVariant patched applies only to -Engine local.'
}

function Get-OfficialEngineDirectory {
  param([Parameter(Mandatory = $true)][string]$BuildMode)

  $directoryName = switch ($BuildMode) {
    'debug' { 'windows-x64' }
    'profile' { 'windows-x64-profile' }
    'release' { 'windows-x64-release' }
  }
  return Join-Path $flutterRoot "bin\cache\artifacts\engine\$directoryName"
}

function Get-AppBundleDirectory {
  param([Parameter(Mandatory = $true)][string]$BuildMode)

  $configuration = switch ($BuildMode) {
    'debug' { 'Debug' }
    'profile' { 'Profile' }
    'release' { 'Release' }
  }
  return Join-Path (Get-AppRepositoryRoot) `
    "build\windows\x64\runner\$configuration"
}

$environmentBefore = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in Get-ChildItem Env:) { $environmentBefore[$entry.Name]=$entry.Value }
Push-Location (Get-AppRepositoryRoot)
try {
  $env:KIRAKARA_SHOW_HOST_DLL = $showHost.path
  # The retained official/local A/B build entry must use the same isolated
  # caches as flutterw; running a separate official Engine is not permission
  # to write into the user's pub cache or global Flutter user state.
  $appLayout = Get-EngineWorkspaceLayout (Join-Path (Get-AppRepositoryRoot) '.kfe')
  Assert-RepositoryEngineWriteWorkspace $appLayout
  [Kirakara.Artifacts.Security]::NoReparse($flutterRoot)
  Set-EngineProcessEnvironment -Layout $appLayout
  Import-Module (Join-Path (Get-AppRepositoryRoot) 'native/scripts/native_runtime_package.psm1') -DisableNameChecking
  $nativeRuntime = Ensure-NativeRuntimePackage
  $env:KIRAKARA_NATIVE_RUNTIME_ROOT = $nativeRuntime.runtime
  Import-Module (Join-Path (Get-AppRepositoryRoot) 'third_party/scripts/handwriting_package.psm1') -DisableNameChecking
  $handwriting = Ensure-HandwritingPackage
  $env:KIRAKARA_HANDWRITING_PACKAGE_ROOT = $handwriting.root
  Import-Module (Join-Path (Get-AppRepositoryRoot) 'third_party/scripts/rime_package.psm1') -DisableNameChecking
  $rimeData = Ensure-RimeDataPackage
  $env:KIRAKARA_RIME_DATA_PACKAGE_ROOT = $rimeData.root
  Invalidate-StaleFlutterWindowsBuildForSdk `
    -FlutterSdkRoot $flutterRoot `
    -AppRoot (Get-AppRepositoryRoot) | Out-Null
  foreach ($buildMode in $Mode) {
    $buildVariant = if ($Engine -eq 'local') { $LocalVariant } else { 'stock' }
    $build = Get-BuildLock `
      -Lock $lock `
      -Mode $buildMode `
      -Variant $buildVariant
    $engineDirectory = if ($Engine -eq 'local') {
      Get-EngineOutputDirectory -Layout $layout -LocalEngine $build.localEngine
    } else {
      Get-OfficialEngineDirectory -BuildMode $buildMode
    }
    if ($Engine -eq 'local') {
      Assert-UsableEngineArtifacts `
        -Layout $layout `
        -Lock $lock `
        -Build $build `
        -Mode $buildMode `
        -Variant $LocalVariant `
        -OutputDirectory $engineDirectory
    }

    $arguments = @('build', 'windows', "--$buildMode")
    if ($Engine -eq 'local') {
      Invalidate-StaleFlutterEphemeralEngine `
        -EngineOutputDirectory $engineDirectory `
        -AppRoot (Get-AppRepositoryRoot)
      $arguments += @(
        "--local-engine=$($build.localEngine)",
        "--local-engine-host=$($build.localEngineHost)",
        "--local-engine-src-path=$($layout.OutputRoot)"
      )
    }
    $engineLabel = if ($Engine -eq 'local') {
      "$Engine/$LocalVariant"
    } else {
      $Engine
    }
    Write-Host "Building Kirakara App mode '$buildMode' with '$engineLabel' Engine..."
    Invoke-CheckedNative $flutter $arguments `
      "Kirakara App build failed for mode '$buildMode' with '$engineLabel' Engine."

    $bundle = Get-AppBundleDirectory -BuildMode $buildMode
    Assert-MatchingFile `
      -ExpectedPath (Join-Path $engineDirectory 'flutter_windows.dll') `
      -ActualPath (Join-Path $bundle 'flutter_windows.dll') `
      -Label 'flutter_windows.dll'
    $icuDirectory = if ($Engine -eq 'local') {
      $engineDirectory
    } else {
      Join-Path $flutterRoot 'bin\cache\artifacts\engine\windows-x64'
    }
    Assert-MatchingFile `
      -ExpectedPath (Join-Path $icuDirectory 'icudtl.dat') `
      -ActualPath (Join-Path $bundle 'data\icudtl.dat') `
      -Label 'icudtl.dat'
    Assert-WindowsAppDpiAwarenessDisabled `
      -Lock $lock `
      -Executable (Join-Path $bundle 'kirakara_app.exe') `
      -WindowsSdkPath $WindowsSdkPath
    Write-Host "Verified App bundle uses the selected '$engineLabel' Engine for '$buildMode'."
  }
} finally {
  Pop-Location
  foreach ($name in @(Get-ChildItem Env: | ForEach-Object Name)) {
    if (-not $environmentBefore.ContainsKey($name)) { Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue }
  }
  foreach ($entry in $environmentBefore.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key,$entry.Value,'Process')
  }
}
