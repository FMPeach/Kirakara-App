Set-StrictMode -Version Latest

$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'common.ps1')
Import-Module (Join-Path $PSScriptRoot 'prebuilt_engine.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'flutter_sdk_tools.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'show_host_input.psm1') -Force -DisableNameChecking

function Get-KirakaraProjectLayout {
  $layout = Get-EngineWorkspaceLayout (Join-Path $script:RepositoryRoot '.kfe')
  Assert-ExternalEngineWorkspace $layout
  if ($layout.Kind -ne 'repository-local') {
    throw 'The Kirakara project Engine layout was not recognized as repository-local.'
  }
  return $layout
}

function Get-KirakaraEngineToolchainEnvironmentSnapshot {
  $snapshot = [ordered]@{}
  foreach ($name in @(
      'GYP_MSVS_OVERRIDE_PATH',
      'VCToolsVersion',
      'WINDOWSSDKDIR'
    )) {
    $snapshot[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
  }
  return $snapshot
}

function Restore-KirakaraEngineToolchainEnvironment {
  param([Parameter(Mandatory = $true)]$Snapshot)

  foreach ($name in $Snapshot.Keys) {
    [Environment]::SetEnvironmentVariable(
      [string]$name,
      $Snapshot[$name],
      'Process')
  }
}

function Resolve-KirakaraCanonicalDirectoryPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $currentPath = [IO.Path]::GetFullPath((Resolve-UnresolvedPath $Path))
  foreach ($pass in 0..15) {
    $pathRoot = [IO.Path]::GetPathRoot($currentPath)
    $relative = $currentPath.Substring($pathRoot.Length)
    $segments = @($relative.Split(
        @([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
        [StringSplitOptions]::RemoveEmptyEntries))
    $resolved = $pathRoot
    $changed = $false
    foreach ($segment in $segments) {
      $candidate = Join-Path $resolved $segment
      $item = Get-Item -LiteralPath $candidate -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        $resolved = $candidate
        continue
      }
      $targets = @($item.Target)
      if ($targets.Count -ne 1 -or
          [string]::IsNullOrWhiteSpace([string]$targets[0])) {
        throw "Cannot resolve repository reparse point: $candidate"
      }
      $target = [string]$targets[0]
      if ($target.StartsWith('\??\')) {
        $target = $target.Substring(4)
      }
      if (-not [IO.Path]::IsPathRooted($target)) {
        $target = Join-Path (Split-Path -Parent $candidate) $target
      }
      $resolved = [IO.Path]::GetFullPath($target)
      $changed = $true
    }
    $resolved = [IO.Path]::GetFullPath($resolved)
    if (-not $changed -or $resolved.Equals(
        $currentPath, [StringComparison]::OrdinalIgnoreCase)) {
      return $resolved
    }
    $currentPath = $resolved
  }
  throw "Repository reparse-point chain is too deep: $Path"
}

function Get-KirakaraModeFromArguments {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)]
    [ValidateSet('debug', 'release')]
    [string]$DefaultMode
  )

  $modes = [System.Collections.Generic.List[string]]::new()
  foreach ($argument in $Arguments) {
    switch ($argument) {
      '--debug' { $modes.Add('debug') }
      '--profile' { $modes.Add('profile') }
      '--release' { $modes.Add('release') }
    }
  }
  $selected = @($modes | Sort-Object -Unique)
  if ($selected.Count -gt 1) {
    throw "Conflicting Flutter build modes: $($selected -join ', ')."
  }
  if ($selected.Count -eq 1) {
    return $selected[0]
  }
  return $DefaultMode
}

function Get-KirakaraDeviceId {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  for ($index = 0; $index -lt $Arguments.Count; $index++) {
    $argument = $Arguments[$index]
    if ($argument -in @('-d', '--device-id')) {
      if ($index + 1 -ge $Arguments.Count) {
        throw "$argument requires a device id."
      }
      return $Arguments[$index + 1]
    }
    if ($argument -match '^(?:-d|--device-id)=(.+)$') {
      return $Matches[1]
    }
  }
  return $null
}

function Get-KirakaraFlutterInvocationPlan {
  param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments)

  $commandIndex = -1
  $command = $null
  for ($index = 0; $index -lt $Arguments.Count; $index++) {
    if ($Arguments[$index] -in @('pub', 'run', 'build')) {
      $commandIndex = $index
      $command = $Arguments[$index]
      break
    }
  }

  $needsEngine = $false
  $injectEngine = $false
  $mode = $null
  $reason = 'Flutter command does not require the custom Windows Engine.'
  if ($command -eq 'pub') {
    $subcommand = if ($commandIndex + 1 -lt $Arguments.Count) {
      $Arguments[$commandIndex + 1]
    } else { $null }
    if ($subcommand -eq 'get') {
      $needsEngine = $true
      $mode = 'debug'
      $reason = 'First pub get prepares the debug Engine for the next development run.'
    }
  } elseif ($command -eq 'run') {
    $deviceId = Get-KirakaraDeviceId -Arguments $Arguments
    if ($null -eq $deviceId -or $deviceId -eq 'windows') {
      $needsEngine = $true
      $injectEngine = $true
      $mode = Get-KirakaraModeFromArguments `
        -Arguments $Arguments `
        -DefaultMode debug
      $reason = 'Windows run requires the matching custom Engine mode.'
    } else {
      $reason = "Explicit non-Windows device '$deviceId' uses the official Flutter Engine."
    }
  } elseif ($command -eq 'build') {
    $subcommand = if ($commandIndex + 1 -lt $Arguments.Count) {
      $Arguments[$commandIndex + 1]
    } else { $null }
    if ($subcommand -eq 'windows') {
      $needsEngine = $true
      $injectEngine = $true
      $mode = Get-KirakaraModeFromArguments `
        -Arguments $Arguments `
        -DefaultMode release
      $reason = 'Windows build requires the matching custom Engine mode.'
    }
  }

  if ($needsEngine) {
    $conflicting = @($Arguments | Where-Object {
        $_ -match '^--local-(?:engine|engine-host|engine-src-path)(?:=|$)'
      })
    if ($conflicting.Count -ne 0) {
      throw (
        'flutterw owns local Engine selection; remove explicit flags: ' +
        ($conflicting -join ', ')
      )
    }
  }

  return [pscustomobject]@{
    command = $command
    needsEngine = $needsEngine
    injectEngine = $injectEngine
    mode = $mode
    reason = $reason
  }
}

function Set-KirakaraGitProcessConfiguration {
  $existingCount = 0
  $rawCount = [Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT', 'Process')
  if (-not [string]::IsNullOrWhiteSpace($rawCount)) {
    if (-not [int]::TryParse($rawCount, [ref]$existingCount)) {
      throw "Invalid process GIT_CONFIG_COUNT: $rawCount"
    }
  }
  for ($index = 0; $index -lt $existingCount; $index++) {
    $key = [Environment]::GetEnvironmentVariable(
      "GIT_CONFIG_KEY_$index", 'Process')
    if ($key -eq 'core.longpaths') {
      return
    }
  }
  [Environment]::SetEnvironmentVariable(
    "GIT_CONFIG_KEY_$existingCount", 'core.longpaths', 'Process')
  [Environment]::SetEnvironmentVariable(
    "GIT_CONFIG_VALUE_$existingCount", 'true', 'Process')
  [Environment]::SetEnvironmentVariable(
    'GIT_CONFIG_COUNT', ($existingCount + 1).ToString(), 'Process')
}

function Get-KirakaraOfficialEngineDirectoryName {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('debug', 'profile', 'release')]
    [string]$Mode
  )

  switch ($Mode) {
    'debug' { return 'windows-x64' }
    'profile' { return 'windows-x64-profile' }
    'release' { return 'windows-x64-release' }
  }
}

function Assert-KirakaraPinnedFlutterSdk {
  param(
    [Parameter(Mandatory = $true)][string]$SdkRoot,
    [Parameter(Mandatory = $true)]$Lock,
    [ValidateSet('debug', 'profile', 'release')]
    [string]$RequiredMode = 'debug'
  )

  $root = Resolve-UnresolvedPath $SdkRoot
  $flutter = Join-Path $root 'bin\flutter.bat'
  if (-not (Test-Path -LiteralPath $flutter -PathType Leaf)) {
    throw "Flutter SDK is missing flutter.bat: $root"
  }
  if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
    throw "Flutter SDK must retain its Git metadata for revision validation: $root"
  }
  $frameworkHead = Get-GitHead $root
  if ($frameworkHead -ne [string]$Lock.flutter.frameworkRevision) {
    throw "Flutter Framework revision mismatch at '$root'. Expected $($Lock.flutter.frameworkRevision), got $frameworkHead."
  }
  $engineVersionPath = Join-Path $root 'bin\internal\engine.version'
  if (-not (Test-Path -LiteralPath $engineVersionPath -PathType Leaf)) {
    throw "Flutter SDK is missing engine.version: $engineVersionPath"
  }
  $engineRevision = (Get-Content -Raw -LiteralPath $engineVersionPath -Encoding utf8).Trim()
  if ($engineRevision -ne [string]$Lock.flutter.engineRevision) {
    throw "Flutter SDK Engine revision mismatch at '$root'. Expected $($Lock.flutter.engineRevision), got $engineRevision."
  }
  $dart = Join-Path $root 'bin\cache\dart-sdk\bin\dart.exe'
  if (-not (Test-Path -LiteralPath $dart -PathType Leaf)) {
    throw "Flutter SDK has not bootstrapped its locked Dart SDK: $dart"
  }
  $officialDirectory = Join-Path $root (
    'bin\cache\artifacts\engine\' +
    (Get-KirakaraOfficialEngineDirectoryName -Mode $RequiredMode)
  )
  $officialDll = Join-Path $officialDirectory 'flutter_windows.dll'
  if (-not (Test-Path -LiteralPath $officialDll -PathType Leaf)) {
    throw "Flutter SDK has not precached the official $RequiredMode Windows Engine: $officialDll"
  }
  return $root
}

function Get-KirakaraPathFlutterSdk {
  $command = Get-Command flutter.bat, flutter -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($null -eq $command) {
    return $null
  }
  $bin = Split-Path -Parent $command.Source
  return Split-Path -Parent $bin
}

function Initialize-KirakaraLocalFlutterSdk {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)]
    [ValidateSet('debug', 'profile', 'release')]
    [string]$RequiredMode
  )

  $sdk = $Layout.FlutterSdk
  New-Item -ItemType Directory -Path $Layout.Root -Force | Out-Null
  $null = Repair-InterruptedManagedGitCheckout `
    -Path $sdk `
    -ManagedRoot $Layout.Root `
    -Repository ([string]$Lock.flutter.repository) `
    -Revision ([string]$Lock.flutter.frameworkRevision) `
    -Label 'project Flutter SDK'
  if (Test-Path -LiteralPath $sdk) {
    $changes = @(Get-TrackedGitChanges $sdk)
    if ($changes.Count -ne 0) {
      throw "Project Flutter SDK has tracked changes and will not be overwritten:`n$($changes -join [Environment]::NewLine)"
    }
  } else {
    Write-Host '[Kirakara Engine] Cloning the locked official Flutter SDK into .kfe/sdk...'
    Invoke-CheckedNative git @(
      'clone', '--filter=blob:none', '--no-checkout',
      [string]$Lock.flutter.repository, $sdk
    ) 'Could not clone the locked Flutter SDK.' | Out-Host
  }

  Invoke-CheckedNative git @(
    '-C', $sdk, 'fetch', '--depth=1', 'origin',
    [string]$Lock.flutter.frameworkRevision
  ) 'Could not fetch the locked Flutter Framework revision.' | Out-Host
  Invoke-CheckedNative git @(
    '-C', $sdk, 'checkout', '--detach',
    [string]$Lock.flutter.frameworkRevision
  ) 'Could not check out the locked Flutter Framework revision.' | Out-Host

  $flutter = Join-Path $sdk 'bin\flutter.bat'
  Write-Host '[Kirakara Engine] Precaching the official Windows Flutter artifacts inside .kfe/sdk...'
  Invoke-CheckedNative $flutter @('precache', '--windows') `
    'Could not precache the official Windows Flutter artifacts.' | Out-Host
  return Assert-KirakaraPinnedFlutterSdk `
    -SdkRoot $sdk `
    -Lock $Lock `
    -RequiredMode $RequiredMode
}

function Copy-KirakaraReadOnlySdkSeed {
  param([Parameter(Mandatory)]$Layout,[Parameter(Mandatory)]$Lock,
        [Parameter(Mandatory)][string]$Seed)
  $seedRoot = Assert-KirakaraPinnedFlutterSdk -SdkRoot $Seed -Lock $Lock -RequiredMode debug
  if (@(Get-TrackedGitChanges $seedRoot).Count -ne 0) {
    throw 'Flutter 种子 SDK 有已跟踪的修改；不会复制修改过的系统 SDK。'
  }
  if (Test-Path -LiteralPath (Join-Path $seedRoot '.git/objects/info/alternates')) {
    throw 'Flutter 种子 SDK 使用共享 Git object；不能当作独立仓库缓存复制。'
  }
  $reparse = @(Get-ChildItem -LiteralPath $seedRoot -Force -Recurse -Attributes ReparsePoint)
  if ($reparse.Count -ne 0) { throw 'Flutter 种子 SDK 包含链接；请使用官方干净 SDK。' }
  $temporary = Join-Path $Layout.Temp ('sdk-seed-'+[guid]::NewGuid().ToString('N'))
  [Kirakara.Artifacts.Security]::NoReparse($temporary)
  try {
    Write-Host '[Kirakara] 只读复制匹配的官方 Flutter SDK 到当前仓库 .kfe/sdk。'
    & robocopy $seedRoot $temporary /E /COPY:DAT /DCOPY:DAT /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Host
    if ($LASTEXITCODE -ge 8) { throw '仓库内 Flutter SDK 复制失败。' }
    $null = Assert-KirakaraPinnedFlutterSdk -SdkRoot $temporary -Lock $Lock -RequiredMode debug
    [IO.Directory]::Move($temporary,$Layout.FlutterSdk)
  } finally {
    if (Test-Path -LiteralPath $temporary) {
      [Kirakara.Artifacts.Security]::NoReparse($temporary)
      Remove-Item -LiteralPath $temporary -Recurse -Force
    }
  }
}

function Resolve-KirakaraFlutterSdk {
  param(
    [Parameter(Mandatory)][pscustomobject]$Layout,
    [Parameter(Mandatory)]$Lock,
    [Parameter(Mandatory)][ValidateSet('debug','profile','release')][string]$RequiredMode,
    [switch]$NoInstall
  )
  # Never execute Flutter in a user-installed SDK: even pub get updates SDK cache.
  if (Test-Path -LiteralPath $Layout.FlutterSdk -PathType Container) {
    try {
      $root = Assert-KirakaraPinnedFlutterSdk -SdkRoot $Layout.FlutterSdk -Lock $Lock -RequiredMode $RequiredMode
      return [pscustomobject]@{root=$root;source='.kfe/sdk';repositoryLocal=$true}
    } catch {
      if ($NoInstall) { throw }
    }
  } elseif ($NoInstall) { throw '当前仓库 .kfe/sdk 尚未准备；系统 Flutter 始终只读。' }

  $handle = Enter-KirakaraBootstrapLock -Layout $Layout
  try {
    if (-not (Test-Path -LiteralPath $Layout.FlutterSdk)) {
      $seed = [Environment]::GetEnvironmentVariable('KIRAKARA_FLUTTER_SDK_ROOT','Process')
      if ([string]::IsNullOrWhiteSpace($seed)) { $seed = Get-KirakaraPathFlutterSdk }
      if (-not [string]::IsNullOrWhiteSpace($seed)) {
        try { Copy-KirakaraReadOnlySdkSeed -Layout $Layout -Lock $Lock -Seed $seed }
        catch { Write-Warning "SDK 种子未使用：$($_.Exception.Message)" }
      }
    }
    if (Test-Path -LiteralPath $Layout.FlutterSdk) {
      # Validate the revision before any precache; do not alter a mismatched checkout.
      $null = Assert-KirakaraPinnedFlutterSdk -SdkRoot $Layout.FlutterSdk -Lock $Lock -RequiredMode debug
      $flutter = Join-Path $Layout.FlutterSdk 'bin/flutter.bat'
      try {
        $root = Assert-KirakaraPinnedFlutterSdk -SdkRoot $Layout.FlutterSdk -Lock $Lock -RequiredMode $RequiredMode
      } catch {
        Invoke-CheckedNative $flutter @('precache','--windows') '仓库内官方 SDK precache 失败。' | Out-Host
        $root = Assert-KirakaraPinnedFlutterSdk -SdkRoot $Layout.FlutterSdk -Lock $Lock -RequiredMode $RequiredMode
      }
    } else {
      # SDK preparation is small and independent of Engine source toolchains.
      $root = Initialize-KirakaraLocalFlutterSdk -Layout $Layout -Lock $Lock -RequiredMode $RequiredMode
    }
    return [pscustomobject]@{root=$root;source='.kfe/sdk (prepared)';repositoryLocal=$true}
  } finally { Exit-KirakaraBootstrapLock -Handle $handle }
}

function Get-KirakaraPinnedVisualStudioPath {
  param([Parameter(Mandatory = $true)]$Lock)

  $vswhere = Join-Path ${env:ProgramFiles(x86)} `
    'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "Visual Studio Installer is missing vswhere.exe: $vswhere"
  }
  $json = @(& $vswhere -format json -products '*') -join [Environment]::NewLine
  if ($LASTEXITCODE -ne 0) {
    throw 'Could not enumerate Visual Studio installations.'
  }
  $matches = @($json | ConvertFrom-Json | Where-Object {
      $_.displayName -eq [string]$Lock.hostBaseline.visualStudioProduct -and
      $_.installationVersion -eq [string]$Lock.hostBaseline.visualStudioVersion
    })
  if ($matches.Count -ne 1) {
    throw (
      'Expected exactly one pinned Visual Studio installation: ' +
      "$($Lock.hostBaseline.visualStudioProduct) " +
      "$($Lock.hostBaseline.visualStudioVersion). Found $($matches.Count)."
    )
  }
  $path = [string]$matches[0].installationPath
  Assert-VisualStudioVersion -Lock $Lock -VisualStudioPath $path
  Assert-MsvcToolsetVersion -Lock $Lock -VisualStudioPath $path
  return $path
}

function Assert-KirakaraBootstrapPreflight {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Lock,
    [string]$WindowsSdkPath = 'C:\Program Files (x86)\Windows Kits\10'
  )

  if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
    throw 'Kirakara flutterw requires Windows PowerShell 5.1 or newer.'
  }
  foreach ($command in @('git')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
      throw "Required command is missing from PATH: $command"
    }
  }
  $bootstrap = $Lock.PSObject.Properties['projectBootstrap']
  if ($null -eq $bootstrap -or $bootstrap.Value.schemaVersion -ne 1) {
    throw 'engine.lock.json has no supported projectBootstrap contract.'
  }
  if ([string]$bootstrap.Value.workspace -ne '.kfe') {
    throw "Unsupported project bootstrap workspace: $($bootstrap.Value.workspace)"
  }
  if ([string]$Lock.depotTools.vpythonTomlNormalizedSha256 -notmatch '^[0-9A-F]{64}$') {
    throw 'depotTools.vpythonTomlNormalizedSha256 must be an uppercase SHA-256 value.'
  }
  $gnProperty = $bootstrap.Value.PSObject.Properties['gn']
  if ($null -eq $gnProperty -or $gnProperty.Value.schemaVersion -ne 1) {
    throw 'engine.lock.json has no supported repository-local GN contract.'
  }
  $gn = $gnProperty.Value
  foreach ($property in @(
      'repository',
      'revision',
      'officialBinarySha256'
    )) {
    if ([string]::IsNullOrWhiteSpace([string]$gn.$property)) {
      throw "projectBootstrap.gn.$property must not be empty."
    }
  }
  foreach ($property in @(
      'officialBinarySha256'
    )) {
    if ([string]$gn.$property -notmatch '^[0-9A-F]{64}$') {
      throw "projectBootstrap.gn.$property is not an uppercase SHA-256 value."
    }
  }
  $sourceFiles = @($gn.sourceFiles)
  if ($sourceFiles.Count -eq 0) {
    throw 'projectBootstrap.gn.sourceFiles must not be empty.'
  }
  $sourcePaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal)
  foreach ($sourceFile in $sourceFiles) {
    if ([string]::IsNullOrWhiteSpace([string]$sourceFile.path) -or
        [string]$sourceFile.sourceSha256 -notmatch '^[0-9A-F]{64}$' -or
        [string]$sourceFile.patchedSha256 -notmatch '^[0-9A-F]{64}$') {
      throw 'projectBootstrap.gn.sourceFiles contains an incomplete entry.'
    }
    if (-not $sourcePaths.Add(([string]$sourceFile.path).Replace('\', '/'))) {
      throw "projectBootstrap.gn.sourceFiles contains a duplicate path: $($sourceFile.path)"
    }
  }
  if ($null -eq $gn.PSObject.Properties['patch'] -or
      [string]::IsNullOrWhiteSpace([string]$gn.patch.path) -or
      [string]$gn.patch.sha256 -notmatch '^[0-9A-F]{64}$') {
    throw 'projectBootstrap.gn.patch is incomplete.'
  }
  if (@($gn.compilerFlags).Count -eq 0 -or
      @($gn.ninjaTargets).Count -eq 0 -or
      [int]$gn.unitTestCount -lt 1) {
    throw 'projectBootstrap.gn build and unit-test contract is incomplete.'
  }
  $ninjaProperty = $bootstrap.Value.PSObject.Properties['ninja']
  if ($null -eq $ninjaProperty -or $ninjaProperty.Value.schemaVersion -ne 1) {
    throw 'engine.lock.json has no supported repository-local Ninja contract.'
  }
  $ninja = $ninjaProperty.Value
  foreach ($property in @(
      'repository',
      'revision',
      'sourceTree',
      'upstreamVersion',
      'cipdPackage',
      'cipdVersion',
      'cipdInstance',
      'officialBinarySha256'
    )) {
    if ([string]::IsNullOrWhiteSpace([string]$ninja.$property)) {
      throw "projectBootstrap.ninja.$property must not be empty."
    }
  }
  if ([string]$ninja.revision -notmatch '^[0-9a-f]{40}$' -or
      [string]$ninja.sourceTree -notmatch '^[0-9a-f]{40}$' -or
      [string]$ninja.officialBinarySha256 -notmatch '^[0-9A-F]{64}$') {
    throw 'projectBootstrap.ninja revision, source tree, or binary hash is malformed.'
  }
  $ninjaSourceFiles = @($ninja.sourceFiles)
  if ($ninjaSourceFiles.Count -eq 0) {
    throw 'projectBootstrap.ninja.sourceFiles must not be empty.'
  }
  $ninjaSourcePaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal)
  foreach ($sourceFile in $ninjaSourceFiles) {
    if ([string]::IsNullOrWhiteSpace([string]$sourceFile.path) -or
        [string]$sourceFile.sourceSha256 -notmatch '^[0-9A-F]{64}$' -or
        [string]$sourceFile.patchedSha256 -notmatch '^[0-9A-F]{64}$') {
      throw 'projectBootstrap.ninja.sourceFiles contains an incomplete entry.'
    }
    if (-not $ninjaSourcePaths.Add(
        ([string]$sourceFile.path).Replace('\', '/'))) {
      throw "projectBootstrap.ninja.sourceFiles contains a duplicate path: $($sourceFile.path)"
    }
  }
  if ($null -eq $ninja.PSObject.Properties['patch'] -or
      [string]::IsNullOrWhiteSpace([string]$ninja.patch.path) -or
      [string]$ninja.patch.sha256 -notmatch '^[0-9A-F]{64}$') {
    throw 'projectBootstrap.ninja.patch is incomplete.'
  }
  if (@($ninja.compilerFlags).Count -eq 0 -or
      @($ninja.configureArguments).Count -eq 0 -or
      @($ninja.ninjaTargets).Count -eq 0 -or
      [int]$ninja.unitTestCount -lt 1) {
    throw 'projectBootstrap.ninja build and unit-test contract is incomplete.'
  }
  $rootPath = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Layout.Root))
  $drive = [IO.DriveInfo]::new($rootPath)
  $minimum = [long]$bootstrap.Value.minimumFreeSpaceBytes
  if ($drive.AvailableFreeSpace -lt $minimum) {
    $requiredGiB = [math]::Round($minimum / 1GB, 1)
    $availableGiB = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    throw "Repository-local Engine bootstrap requires at least $requiredGiB GiB free on $rootPath; only $availableGiB GiB is available."
  }
  Assert-WindowsSdkVersion -Lock $Lock -WindowsSdkPath $WindowsSdkPath
  $visualStudio = Get-KirakaraPinnedVisualStudioPath -Lock $Lock
  return [pscustomobject]@{
    visualStudioPath = $visualStudio
    windowsSdkPath = Resolve-UnresolvedPath $WindowsSdkPath
    availableFreeBytes = [long]$drive.AvailableFreeSpace
    minimumFreeBytes = $minimum
  }
}

function Get-KirakaraSha256Text {
  param([Parameter(Mandatory = $true)][string]$Text)

  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    return ([BitConverter]::ToString($hash)).Replace('-', '')
  } finally {
    $sha.Dispose()
  }
}

function Get-KirakaraBootstrapFingerprint {
  param(
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)]
    [ValidateSet('debug', 'profile', 'release')]
    [string]$Mode
  )

  $relativeFiles = [System.Collections.Generic.List[string]]::new()
  foreach ($path in @(
      'engine/include/kirakara_flutter_compositor_api.h',
      'engine/scripts/common.ps1',
      'engine/scripts/powershell_compat.ps1',
      'engine/scripts/fetch_engine.ps1',
      'engine/scripts/apply_patches.ps1',
      'engine/scripts/build_windows_engine.ps1',
      'engine/scripts/verify_engine_bundle.ps1',
      'engine/scripts/test_engine_abi_gate.ps1',
      'engine/scripts/project_engine_bootstrap.psm1',
      'engine/scripts/flutter_sdk_tools.psm1',
      'flutterw.ps1',
      'flutterw.cmd'
    )) {
    $relativeFiles.Add($path)
  }
  foreach ($patch in @($Lock.patchset.patches)) {
    if (-not $relativeFiles.Contains([string]$patch.path)) {
      $relativeFiles.Add([string]$patch.path)
    }
  }
  foreach ($patch in @($Lock.sdkToolBootstrap.patches)) {
    $relativeFiles.Add([string]$patch.path)
  }
  foreach ($patch in @($Lock.projectBootstrap.engineSourcePatches)) {
    if (-not $relativeFiles.Contains([string]$patch.path)) {
      $relativeFiles.Add([string]$patch.path)
    }
  }
  foreach ($dependency in @($Lock.projectBootstrap.engineDependencyPatches)) {
    foreach ($patch in @($dependency.patches)) {
      if (-not $relativeFiles.Contains([string]$patch.path)) {
        $relativeFiles.Add([string]$patch.path)
      }
    }
  }
  foreach ($patch in @($Lock.projectBootstrap.vpythonVirtualenv.patches)) {
    $bootstrapPatch = [string]$patch.path
    if (-not $relativeFiles.Contains($bootstrapPatch)) {
      $relativeFiles.Add($bootstrapPatch)
    }
  }
  $gnPatch = [string]$Lock.projectBootstrap.gn.patch.path
  if (-not $relativeFiles.Contains($gnPatch)) {
    $relativeFiles.Add($gnPatch)
  }
  $ninjaPatch = [string]$Lock.projectBootstrap.ninja.patch.path
  if (-not $relativeFiles.Contains($ninjaPatch)) {
    $relativeFiles.Add($ninjaPatch)
  }
  $fileHashes = [ordered]@{}
  foreach ($relative in @($relativeFiles | Sort-Object)) {
    $path = Join-Path $script:RepositoryRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Bootstrap fingerprint input is missing: $path"
    }
    $fileHashes[$relative] = (
      Get-FileHash -LiteralPath $path -Algorithm SHA256
    ).Hash
  }
  $build = Get-BuildLock -Lock $Lock -Mode $Mode -Variant patched
  # Exact Release artifact hashes describe a reviewed distribution candidate,
  # not an Engine build input. Hash a canonical copy of the lock with those
  # output-only fields removed so relocking a candidate cannot invalidate all
  # three development ready stamps. Every current and future non-artifact lock
  # field remains covered without maintaining a second hand-written schema.
  $buildLock = $Lock | ConvertTo-Json -Depth 30 | ConvertFrom-Json
  $buildLock.projectBootstrap.PSObject.Properties.Remove('releaseCandidate')
  foreach ($collection in @($buildLock.builds, $buildLock.patchset.builds)) {
    foreach ($lockedBuild in @($collection)) {
      $lockedBuild.PSObject.Properties.Remove('artifacts')
    }
  }
  $buildLockJson = $buildLock | ConvertTo-Json -Depth 30 -Compress
  $inputs = [ordered]@{
    schemaVersion = 2
    mode = $Mode
    buildLockSha256 = Get-KirakaraSha256Text -Text $buildLockJson
    frameworkRevision = [string]$Lock.flutter.frameworkRevision
    engineRevision = [string]$Lock.flutter.engineRevision
    engineSourceTree = [string]$Lock.flutter.engineSourceTree
    patchsetSourceTree = [string]$Lock.patchset.sourceTree
    repositoryLocalEngineSourceTree = [string]$Lock.projectBootstrap.engineSourceTree
    patchsetVersion = [uint32]$Lock.patchset.version
    abiVersion = [uint32]$Lock.patchset.abiVersion
    localEngine = [string]$build.localEngine
    gnArguments = @($build.gnArguments)
    ninjaTargets = @($build.ninjaTargets)
    visualStudioVersion = [string]$Lock.hostBaseline.visualStudioVersion
    msvcToolsetVersion = [string]$Lock.hostBaseline.msvcToolsetVersion
    msvcCompilerVersion = [string]$Lock.hostBaseline.msvcCompilerVersion
    windowsSdkVersion = [string]$Lock.hostBaseline.engineBuildWindowsSdkVersion
    targetOs = [string]$Lock.target.os
    targetArchitecture = [string]$Lock.target.architecture
    files = $fileHashes
  }
  $canonical = $inputs | ConvertTo-Json -Depth 10 -Compress
  return [pscustomobject]@{
    value = Get-KirakaraSha256Text -Text $canonical
    inputs = $inputs
  }
}

function Repair-KirakaraVpythonVirtualenv {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Lock
  )

  $contract = $Lock.projectBootstrap.vpythonVirtualenv
  $store = Join-Path $Layout.Cache 'vpython\store'
  $candidates = @()
  if (Test-Path -LiteralPath $store -PathType Container) {
    foreach ($package in @(Get-ChildItem -LiteralPath $store -Directory `
        -Filter 'virtualenv+*')) {
      $candidate = Join-Path $package.FullName (
        "contents\virtualenv-$($contract.version)\virtualenv.py")
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $candidates += $candidate
      }
    }
  }
  if ($candidates.Count -eq 0) {
    # The pinned depot_tools revision uses its modern vpython.toml/uv backend.
    # A clean cache therefore never materializes the legacy virtualenv 16.x
    # package. Older repository caches may still contain it, in which case the
    # compatibility patches below remain necessary and are applied in place.
    $modernConfig = Join-Path $Layout.DepotTools 'vpython.toml'
    if (-not (Test-Path -LiteralPath $modernConfig -PathType Leaf)) {
      throw (
        "Pinned depot_tools has neither its modern vpython.toml nor the legacy " +
        "virtualenv $($contract.version) package: $($Layout.DepotTools)"
      )
    }
    $configText = [IO.File]::ReadAllText($modernConfig)
    $normalizedConfig = $configText.Replace("`r`n", "`n").Replace("`r", "`n")
    $configHash = Get-KirakaraSha256Text -Text $normalizedConfig
    if ($configHash -ne [string]$Lock.depotTools.vpythonTomlNormalizedSha256) {
      throw (
        'Pinned depot_tools vpython.toml hash mismatch. Expected ' +
        "$($Lock.depotTools.vpythonTomlNormalizedSha256), got $configHash."
      )
    }
    Write-Host (
      '[Kirakara Engine] Verified the locked depot_tools uv-based vpython ' +
      'environment; no legacy virtualenv patch is required.')
    return [pscustomobject]@{
      backend = 'uv'
      legacyPatched = $false
      configSha256 = $configHash
    }
  }
  if ($candidates.Count -ne 1) {
    throw "Expected at most one pinned vpython virtualenv $($contract.version) script, found $($candidates.Count) under $store."
  }

  $target = $candidates[0]
  $actualHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
  if ($actualHash -eq [string]$contract.patchedSha256) {
    return [pscustomobject]@{
      backend = 'legacy-virtualenv'
      legacyPatched = $true
      scriptSha256 = $actualHash
    }
  }
  $patches = @($contract.patches)
  if ($patches.Count -eq 0 -or
      [string]$patches[-1].resultSha256 -ne [string]$contract.patchedSha256) {
    throw 'Pinned vpython compatibility patch chain is incomplete.'
  }
  $startIndex = 0
  if ($actualHash -ne [string]$contract.sourceSha256) {
    $matchedIndex = -1
    for ($index = 0; $index -lt $patches.Count; $index++) {
      if ($actualHash -eq [string]$patches[$index].resultSha256) {
        $matchedIndex = $index
        break
      }
    }
    if ($matchedIndex -lt 0) {
      $accepted = @([string]$contract.sourceSha256) + @(
        $patches | ForEach-Object { [string]$_.resultSha256 })
      throw (
        'Pinned vpython virtualenv source hash mismatch. Expected one of ' +
        "$($accepted -join ', '), got ${actualHash}: $target"
      )
    }
    $startIndex = $matchedIndex + 1
  }

  $targetDirectory = Split-Path -Parent $target
  $relativeDirectory = (Get-KirakaraRelativePath `
    -BasePath $script:RepositoryRoot `
    -Path $targetDirectory).Replace('\', '/')
  if ($relativeDirectory.StartsWith('../') -or
      [IO.Path]::IsPathRooted($relativeDirectory)) {
    throw "Refusing to patch vpython outside the App repository: $target"
  }
  for ($index = $startIndex; $index -lt $patches.Count; $index++) {
    $patch = $patches[$index]
    $patchPath = Join-Path $script:RepositoryRoot ([string]$patch.path)
    if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
      throw "Pinned vpython compatibility patch is missing: $patchPath"
    }
    $patchHash = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash
    if ($patchHash -ne [string]$patch.sha256) {
      throw (
        'Pinned vpython compatibility patch hash mismatch. Expected ' +
        "$($patch.sha256), got $patchHash."
      )
    }
    Write-Host (
      '[Kirakara Engine] Applying locked vpython compatibility patch ' +
      "$($index + 1)/$($patches.Count)...")
    Invoke-CheckedNative git @(
      '-C', $script:RepositoryRoot,
      'apply', '--check', "--directory=$relativeDirectory", $patchPath
    ) 'vpython compatibility patch preflight failed.' | Out-Host
    Invoke-CheckedNative git @(
      '-C', $script:RepositoryRoot,
      'apply', "--directory=$relativeDirectory", $patchPath
    ) 'Could not apply the vpython compatibility patch.' | Out-Host
    $actualHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if ($actualHash -ne [string]$patch.resultSha256) {
      throw (
        'Patched vpython virtualenv hash mismatch. Expected ' +
        "$($patch.resultSha256), got $actualHash."
      )
    }
  }
  return [pscustomobject]@{
    backend = 'legacy-virtualenv'
    legacyPatched = $true
    scriptSha256 = $actualHash
  }
}

function Get-KirakaraGnPaths {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)][string]$Fingerprint
  )

  $root = Join-Path $Layout.Cache 'gn'
  return [pscustomobject]@{
    root = $root
    source = Join-Path $Layout.Root 'source\gn'
    output = Join-Path $root "out\$($Fingerprint.Substring(0, 16))"
    readyStamp = Join-Path $Layout.State 'gn-ready.json'
  }
}

function Get-KirakaraGnFingerprint {
  param([Parameter(Mandatory = $true)]$Lock)

  $contract = $Lock.projectBootstrap.gn
  $patchPath = Join-Path $script:RepositoryRoot ([string]$contract.patch.path)
  if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
    throw "Pinned GN compatibility patch is missing: $patchPath"
  }
  $patchHash = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash
  if ($patchHash -ne [string]$contract.patch.sha256) {
    throw (
      'Pinned GN compatibility patch hash mismatch. Expected ' +
      "$($contract.patch.sha256), got $patchHash.")
  }
  $modulePath = Join-Path $PSScriptRoot 'project_engine_bootstrap.psm1'
  $moduleHash = (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash
  $inputs = [ordered]@{
    schemaVersion = 1
    contract = $contract
    depotToolsRevision = [string]$Lock.depotTools.revision
    visualStudioVersion = [string]$Lock.hostBaseline.visualStudioVersion
    msvcToolsetVersion = [string]$Lock.hostBaseline.msvcToolsetVersion
    msvcCompilerVersion = [string]$Lock.hostBaseline.msvcCompilerVersion
    windowsSdkVersion = [string]$Lock.hostBaseline.engineBuildWindowsSdkVersion
    bootstrapModuleSha256 = $moduleHash
  }
  $canonical = $inputs | ConvertTo-Json -Depth 12 -Compress
  return [pscustomobject]@{
    value = Get-KirakaraSha256Text -Text $canonical
    inputs = $inputs
  }
}

function Assert-KirakaraPatchedGnSource {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)]$Contract
  )

  if (-not (Test-Path -LiteralPath (Join-Path $Source '.git'))) {
    throw "Pinned GN source checkout is missing: $Source"
  }
  $head = Get-GitHead $Source
  if ($head -ne [string]$Contract.revision) {
    throw "Pinned GN revision mismatch. Expected $($Contract.revision), got $head."
  }
  $originOutput = @(& git -C $Source remote get-url origin 2>$null)
  if ($LASTEXITCODE -ne 0 -or $originOutput.Count -ne 1) {
    throw "Cannot validate pinned GN origin: $Source"
  }
  $origin = ([string]$originOutput[0]).Trim().TrimEnd('/')
  $expectedOrigin = ([string]$Contract.repository).Trim().TrimEnd('/')
  if (-not $origin.Equals(
      $expectedOrigin, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Pinned GN origin mismatch. Expected '$expectedOrigin', got '$origin'."
  }
  $autoCrlfOutput = @(& git -C $Source config --local --get core.autocrlf)
  if ($LASTEXITCODE -ne 0 -or $autoCrlfOutput.Count -ne 1 -or
      ([string]$autoCrlfOutput[0]).Trim() -cne 'false') {
    throw 'Pinned GN checkout must set local core.autocrlf=false before checkout.'
  }

  $sourceFiles = [System.Collections.Generic.List[string]]::new()
  $expectedChangedFiles = @($Contract.sourceFiles | ForEach-Object {
      ([string]$_.path).Replace('\', '/')
    } | Sort-Object)
  foreach ($entry in @($Contract.sourceFiles)) {
    $sourceFile = [IO.Path]::GetFullPath(
      (Join-Path $Source ([string]$entry.path)))
    if (-not (Test-PathWithin $sourceFile $Source) -or
        -not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
      throw "Pinned GN source file is missing or escapes its checkout: $sourceFile"
    }
    $actualHash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
    if ($actualHash -ne [string]$entry.patchedSha256) {
      throw (
        "Patched GN source hash mismatch for $($entry.path). Expected " +
        "$($entry.patchedSha256), got $actualHash.")
    }
    $sourceFiles.Add($sourceFile)
  }
  $changes = @(Get-TrackedGitChanges $Source)
  $changedFiles = @(& git -C $Source diff --name-only HEAD --)
  if ($LASTEXITCODE -ne 0) {
    throw "Cannot enumerate pinned GN changes: $Source"
  }
  $changedFiles = @($changedFiles | ForEach-Object {
      ([string]$_).Trim().Replace('\', '/')
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Sort-Object)
  $stagedFiles = @(& git -C $Source diff --cached --name-only HEAD --)
  if ($LASTEXITCODE -ne 0) {
    throw "Cannot enumerate staged pinned GN changes: $Source"
  }
  $stagedFiles = @($stagedFiles | Where-Object {
      -not [string]::IsNullOrWhiteSpace([string]$_)
    })
  if ($changes.Count -ne $expectedChangedFiles.Count -or
      $changedFiles.Count -ne $expectedChangedFiles.Count -or
      @(Compare-Object $expectedChangedFiles $changedFiles -CaseSensitive).Count -ne 0 -or
      $stagedFiles.Count -ne 0) {
    throw (
      'Pinned GN checkout must contain exactly the one locked, unstaged ' +
      "source patch. Found:`n$($changes -join [Environment]::NewLine)")
  }
  & git -C $Source diff --check | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw 'Pinned GN compatibility patch failed git diff --check.'
  }
  return @($sourceFiles)
}

function Initialize-KirakaraPatchedGnSource {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Paths,
    [Parameter(Mandatory = $true)]$Contract
  )

  New-Item -ItemType Directory -Path $Paths.root -Force | Out-Null
  if (Test-Path -LiteralPath (Join-Path $Paths.source '.git')) {
    Invoke-CheckedNative git @(
      '-C', $Paths.source, 'config', 'core.autocrlf', 'false'
    ) 'Could not lock the GN checkout line-ending policy.' | Out-Null
  }
  $null = Repair-InterruptedManagedGitCheckout `
    -Path $Paths.source `
    -ManagedRoot $Paths.root `
    -Repository ([string]$Contract.repository) `
    -Revision ([string]$Contract.revision) `
    -Label 'project GN source'
  if (-not (Test-Path -LiteralPath $Paths.source -PathType Container)) {
    Write-Host '[Kirakara Engine] Cloning the locked GN source into .kfe/cache/gn...'
    Invoke-CheckedNative git @(
      'clone', '--filter=blob:none', '--no-checkout',
      [string]$Contract.repository, $Paths.source
    ) 'Could not clone the locked GN source.' | Out-Host
    Invoke-CheckedNative git @(
      '-C', $Paths.source, 'config', 'core.autocrlf', 'false'
    ) 'Could not lock the GN checkout line-ending policy.' | Out-Null
    Invoke-CheckedNative git @(
      '-C', $Paths.source, 'fetch', 'origin',
      [string]$Contract.revision
    ) 'Could not fetch the locked GN revision.' | Out-Host
    Invoke-CheckedNative git @(
      '-C', $Paths.source, 'checkout', '--detach',
      [string]$Contract.revision
    ) 'Could not check out the locked GN revision.' | Out-Host
  }
  $shallowOutput = @(& git -C $Paths.source rev-parse --is-shallow-repository)
  if ($LASTEXITCODE -ne 0 -or $shallowOutput.Count -ne 1) {
    throw "Cannot determine whether the pinned GN checkout is shallow: $($Paths.source)"
  }
  if (([string]$shallowOutput[0]).Trim() -eq 'true') {
    Write-Host '[Kirakara Engine] Completing filtered GN commit history for version generation...'
    Invoke-CheckedNative git @(
      '-C', $Paths.source, 'fetch', '--unshallow', '--filter=blob:none', 'origin'
    ) 'Could not complete the pinned GN commit history.' | Out-Host
  }

  $patchPath = Join-Path $script:RepositoryRoot ([string]$Contract.patch.path)
  $patchHash = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash
  if ($patchHash -ne [string]$Contract.patch.sha256) {
    throw (
      'Pinned GN compatibility patch hash mismatch. Expected ' +
      "$($Contract.patch.sha256), got $patchHash.")
  }
  $states = [System.Collections.Generic.List[string]]::new()
  foreach ($entry in @($Contract.sourceFiles)) {
    $sourceFile = [IO.Path]::GetFullPath(
      (Join-Path $Paths.source ([string]$entry.path)))
    if (-not (Test-PathWithin $sourceFile $Paths.source) -or
        -not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
      throw "Pinned GN source file is missing or escapes its checkout: $sourceFile"
    }
    $actualHash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
    if ($actualHash -eq [string]$entry.sourceSha256) {
      $states.Add('stock')
    } elseif ($actualHash -eq [string]$entry.patchedSha256) {
      $states.Add('patched')
    } else {
      throw (
        "Pinned GN source file $($entry.path) is neither stock nor the " +
        "exact locked patch. Expected $($entry.sourceSha256) or " +
        "$($entry.patchedSha256), got $actualHash.")
    }
  }
  $sourceStates = @($states | Sort-Object -Unique)
  if ($sourceStates.Count -ne 1) {
    throw "Pinned GN source files contain a mixed patch state: $($sourceStates -join ', ')."
  }
  if ($sourceStates[0] -eq 'stock') {
    $changes = @(Get-TrackedGitChanges $Paths.source)
    if ($changes.Count -ne 0) {
      throw (
        'Pinned GN source has unrelated tracked changes and will not be ' +
        "overwritten:`n$($changes -join [Environment]::NewLine)")
    }
    Write-Host '[Kirakara Engine] Applying the locked GN Unicode-output patch...'
    Invoke-CheckedNative git @(
      '-C', $Paths.source, 'apply', '--check', $patchPath
    ) 'GN Unicode-output patch preflight failed.' | Out-Host
    Invoke-CheckedNative git @(
      '-C', $Paths.source, 'apply', $patchPath
    ) 'Could not apply the GN Unicode-output patch.' | Out-Host
  }
  $null = Assert-KirakaraPatchedGnSource `
    -Source $Paths.source `
    -Contract $Contract
}

function Invoke-KirakaraLoggedProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [Parameter(Mandatory = $true)][string]$StdoutPath,
    [Parameter(Mandatory = $true)][string]$StderrPath,
    [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
    [hashtable]$Environment = @{}
  )

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  Set-KirakaraProcessArguments -StartInfo $startInfo -Arguments $Arguments
  $startInfo.WorkingDirectory = $WorkingDirectory
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($entry in $Environment.GetEnumerator()) {
    Set-KirakaraProcessEnvironmentValue `
      -StartInfo $startInfo `
      -Name ([string]$entry.Key) `
      -Value ([string]$entry.Value)
  }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $stopwatch = [Diagnostics.Stopwatch]::StartNew()
  try {
    if (-not $process.Start()) {
      throw "Could not start process: $FilePath"
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
      Stop-KirakaraProcessTree -Process $process
    }
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = if ($completed) { $process.ExitCode } else { $null }
  } finally {
    $stopwatch.Stop()
    $process.Dispose()
  }
  $utf8 = [Text.UTF8Encoding]::new($false)
  [IO.File]::WriteAllText($StdoutPath, $stdout, $utf8)
  [IO.File]::WriteAllText($StderrPath, $stderr, $utf8)
  return [pscustomobject]@{
    completed = $completed
    exitCode = $exitCode
    durationMilliseconds = [long]$stopwatch.ElapsedMilliseconds
    stdout = $stdout
    stderr = $stderr
  }
}

function Get-KirakaraProcessFailureTail {
  param([AllowEmptyString()][string]$Stdout, [AllowEmptyString()][string]$Stderr)

  return @(
    (($Stdout + [Environment]::NewLine + $Stderr) -split '\r?\n') |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -Last 40
  ) -join [Environment]::NewLine
}

function Test-KirakaraGnReadyStamp {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)]$Fingerprint,
    [Parameter(Mandatory = $true)][pscustomobject]$Paths
  )

  if (-not (Test-Path -LiteralPath $Paths.readyStamp -PathType Leaf)) {
    return [pscustomobject]@{ ready = $false; reason = 'GN ready stamp is missing' }
  }
  try {
    $stamp = Get-Content -Raw -LiteralPath $Paths.readyStamp -Encoding utf8 |
      ConvertFrom-Json
    if ($stamp.schemaVersion -ne 1) {
      throw "unsupported GN ready stamp schema $($stamp.schemaVersion)"
    }
    if ([string]$stamp.fingerprint -ne [string]$Fingerprint.value) {
      throw 'GN bootstrap fingerprint changed'
    }
    if ([int]$stamp.unitTestCount -ne
        [int]$Lock.projectBootstrap.gn.unitTestCount) {
      throw 'GN unit-test count changed'
    }
    $null = Assert-KirakaraPatchedGnSource `
      -Source $Paths.source `
      -Contract $Lock.projectBootstrap.gn
    $binary = [IO.Path]::GetFullPath(
      (Join-Path $Layout.Root ([string]$stamp.binaryPath)))
    if (-not (Test-PathWithin $binary $Paths.root) -or
        -not (Test-Path -LiteralPath $binary -PathType Leaf)) {
      throw "GN binary is missing or escapes its managed cache: $binary"
    }
    $item = Get-Item -LiteralPath $binary
    if ([long]$item.Length -ne [long]$stamp.binarySize) {
      throw 'GN binary size changed'
    }
    $hash = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
    if ($hash -ne [string]$stamp.binarySha256) {
      throw 'GN binary hash changed'
    }
    foreach ($property in 'buildStdout', 'buildStderr', 'testStdout', 'testStderr') {
      $log = [IO.Path]::GetFullPath(
        (Join-Path $Layout.Root ([string]$stamp.$property)))
      if (-not (Test-PathWithin $log $Layout.Logs) -or
          -not (Test-Path -LiteralPath $log -PathType Leaf)) {
        throw "GN ready-stamp log is missing or outside .kfe/logs: $property"
      }
    }
    return [pscustomobject]@{
      ready = $true
      reason = 'all GN ready-stamp gates passed'
      binary = $binary
      binarySha256 = $hash
      stamp = $stamp
    }
  } catch {
    return [pscustomobject]@{ ready = $false; reason = $_.Exception.Message }
  }
}

function Write-KirakaraGnReadyStamp {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)][pscustomobject]$Paths,
    [Parameter(Mandatory = $true)]$Fingerprint,
    [Parameter(Mandatory = $true)][string]$Binary,
    [Parameter(Mandatory = $true)][int]$UnitTestCount,
    [Parameter(Mandatory = $true)]$BuildResult,
    [Parameter(Mandatory = $true)]$TestResult,
    [Parameter(Mandatory = $true)][hashtable]$Logs
  )

  $binaryItem = Get-Item -LiteralPath $Binary
  $stamp = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    fingerprint = $Fingerprint.value
    fingerprintInputs = $Fingerprint.inputs
    binaryPath = (Get-KirakaraRelativePath `
      -BasePath $Layout.Root -Path $Binary).Replace('\', '/')
    binarySize = [long]$binaryItem.Length
    binarySha256 = (Get-FileHash -LiteralPath $Binary -Algorithm SHA256).Hash
    unitTestCount = $UnitTestCount
    buildDurationMilliseconds = [long]$BuildResult.durationMilliseconds
    testDurationMilliseconds = [long]$TestResult.durationMilliseconds
    buildStdout = (Get-KirakaraRelativePath `
      -BasePath $Layout.Root -Path $Logs.buildStdout).Replace('\', '/')
    buildStderr = (Get-KirakaraRelativePath `
      -BasePath $Layout.Root -Path $Logs.buildStderr).Replace('\', '/')
    testStdout = (Get-KirakaraRelativePath `
      -BasePath $Layout.Root -Path $Logs.testStdout).Replace('\', '/')
    testStderr = (Get-KirakaraRelativePath `
      -BasePath $Layout.Root -Path $Logs.testStderr).Replace('\', '/')
  }
  New-Item -ItemType Directory -Path $Layout.State -Force | Out-Null
  $temporary = Join-Path $Layout.State (
    ".gn-ready-$([Guid]::NewGuid().ToString('N')).tmp")
  try {
    $stamp | ConvertTo-Json -Depth 14 | Set-Content `
      -LiteralPath $temporary `
      -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $Paths.readyStamp -Force
  } finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
      Remove-Item -LiteralPath $temporary -Force
    }
  }
}

function Build-KirakaraPatchedGn {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][pscustomobject]$Paths,
    [Parameter(Mandatory = $true)]$Fingerprint,
    [Parameter(Mandatory = $true)][string]$VisualStudioPath
  )

  $contract = $Lock.projectBootstrap.gn
  $null = Assert-KirakaraPatchedGnSource `
    -Source $Paths.source `
    -Contract $contract
  if (Test-Path -LiteralPath $Paths.output) {
    $output = [IO.Path]::GetFullPath($Paths.output)
    if (-not (Test-PathWithin $output $Paths.root) -or
        $output.TrimEnd('\').Equals(
          ([IO.Path]::GetFullPath($Paths.root)).TrimEnd('\'),
          [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to replace an unexpected GN output directory: $output"
    }
    Remove-Item -LiteralPath $output -Recurse -Force
  }
  New-Item -ItemType Directory -Path $Paths.output -Force | Out-Null
  New-Item -ItemType Directory -Path $Layout.Logs -Force | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $nonce = [Guid]::NewGuid().ToString('N').Substring(0, 8)
  $logs = @{
    buildStdout = Join-Path $Layout.Logs "gn-build-$stamp-$nonce.stdout.log"
    buildStderr = Join-Path $Layout.Logs "gn-build-$stamp-$nonce.stderr.log"
    testStdout = Join-Path $Layout.Logs "gn-test-$stamp-$nonce.stdout.log"
    testStderr = Join-Path $Layout.Logs "gn-test-$stamp-$nonce.stderr.log"
  }

  $vcvars = Join-Path $VisualStudioPath 'VC\Auxiliary\Build\vcvarsall.bat'
  $python = Join-Path $Layout.DepotTools 'python-bin\python3.bat'
  $ninja = Join-Path $Layout.DepotTools 'ninja.bat'
  foreach ($tool in @($vcvars, $python, $ninja)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
      throw "GN build tool is missing: $tool"
    }
    if ($tool.Contains('"')) {
      throw "GN build tool path contains an unsupported quote: $tool"
    }
  }
  $toolsetParts = ([string]$Lock.hostBaseline.msvcToolsetVersion).Split('.')
  if ($toolsetParts.Count -lt 2) {
    throw 'Pinned MSVC toolset version cannot be converted for vcvarsall.'
  }
  $vcvarsToolset = "$($toolsetParts[0]).$($toolsetParts[1])"
  $compilerFlags = @($contract.compilerFlags) -join ' '
  $targets = @($contract.ninjaTargets)
  if (@($targets | Where-Object { [string]$_ -notmatch '^[A-Za-z0-9_.-]+$' }).Count -ne 0) {
    throw 'Pinned GN Ninja target contains unsupported command characters.'
  }
  New-Item -ItemType Directory -Path $Layout.Temp -Force | Out-Null
  $commandFile = Join-Path $Layout.Temp "gn-build-$nonce.cmd"
  $commandLines = @(
    '@echo off',
    'setlocal',
    'set "VSCMD_SKIP_SENDTELEMETRY=1"',
    'call "%KFE_GN_VCVARS%" amd64 %KFE_GN_SDK% -vcvars_ver=%KFE_GN_TOOLSET% >nul',
    'if errorlevel 1 exit /b %errorlevel%',
    'set "CL=%KFE_GN_COMPILER_FLAGS%"',
    'call "%KFE_GN_PYTHON%" "%KFE_GN_SOURCE%\build\gen.py" --out-path="%KFE_GN_OUTPUT%"',
    'if errorlevel 1 exit /b %errorlevel%',
    'call "%KFE_GN_NINJA%" -C "%KFE_GN_OUTPUT%" %KFE_GN_TARGETS%',
    'exit /b %errorlevel%'
  ) -join "`r`n"
  [IO.File]::WriteAllText(
    $commandFile, $commandLines, [Text.Encoding]::ASCII)
  $buildEnvironment = @{
    KFE_GN_VCVARS = $vcvars
    KFE_GN_SDK = [string]$Lock.hostBaseline.engineBuildWindowsSdkVersion
    KFE_GN_TOOLSET = $vcvarsToolset
    KFE_GN_COMPILER_FLAGS = $compilerFlags
    KFE_GN_PYTHON = $python
    KFE_GN_SOURCE = $Paths.source
    KFE_GN_OUTPUT = $Paths.output
    KFE_GN_NINJA = $ninja
    KFE_GN_TARGETS = $targets -join ' '
  }
  Write-Host '[Kirakara Engine] Building the locked GN Unicode-output tool...'
  try {
    $buildResult = Invoke-KirakaraLoggedProcess `
      -FilePath $env:ComSpec `
      -Arguments @('/d', '/c', 'call', $commandFile) `
      -WorkingDirectory $Paths.source `
      -StdoutPath $logs.buildStdout `
      -StderrPath $logs.buildStderr `
      -TimeoutSeconds 3600 `
      -Environment $buildEnvironment
  } finally {
    if (Test-Path -LiteralPath $commandFile -PathType Leaf) {
      Remove-Item -LiteralPath $commandFile -Force
    }
  }
  if (-not $buildResult.completed -or $buildResult.exitCode -ne 0) {
    $tail = Get-KirakaraProcessFailureTail `
      -Stdout $buildResult.stdout `
      -Stderr $buildResult.stderr
    throw "Locked GN build failed. Logs: $($logs.buildStdout), $($logs.buildStderr)`n$tail"
  }

  $binary = Join-Path $Paths.output 'gn.exe'
  $tests = Join-Path $Paths.output 'gn_unittests.exe'
  foreach ($artifact in @($binary, $tests)) {
    if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
      throw "Locked GN build did not produce: $artifact"
    }
  }
  # GN's format tests locate golden files relative to the parent of the test
  # executable, while two upstream utility tests still use narrow temporary
  # file APIs. Stage only their immutable fixtures under .kfe and give the
  # test process a disposable ASCII TEMP directory; the GN binary itself is
  # still built and exercised from the real Unicode repository path.
  $formatSource = Join-Path $Paths.source 'src\gn\format_test_data'
  $formatStage = Join-Path (
    (Split-Path -Parent $Paths.output)) 'src\gn\format_test_data'
  if (-not (Test-PathWithin $formatStage $Paths.root)) {
    throw "Refusing to stage GN test data outside its managed cache: $formatStage"
  }
  if (Test-Path -LiteralPath $formatStage) {
    Remove-Item -LiteralPath $formatStage -Recurse -Force
  }
  New-Item -ItemType Directory -Path (Split-Path -Parent $formatStage) `
    -Force | Out-Null
  Copy-Item -LiteralPath $formatSource -Destination $formatStage -Recurse

  $driveRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Layout.Root))
  $testScratchName = "kfe-gn-test-$([Guid]::NewGuid().ToString('N'))"
  $testScratch = [IO.Path]::GetFullPath((Join-Path $driveRoot $testScratchName))
  if ($testScratch -match '[^\x00-\x7F]' -or
      -not ([IO.Path]::GetDirectoryName($testScratch)).TrimEnd('\').Equals(
        $driveRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
      (Split-Path -Leaf $testScratch) -cne $testScratchName -or
      (Test-Path -LiteralPath $testScratch)) {
    throw "Cannot allocate the exact disposable ASCII GN test root: $testScratch"
  }
  $testTemp = Join-Path $testScratch 'temp'
  New-Item -ItemType Directory -Path $testTemp -Force | Out-Null
  Write-Host (
    '[Kirakara Engine] Running all ' +
    "$($contract.unitTestCount) locked GN unit tests...")
  try {
    $testResult = Invoke-KirakaraLoggedProcess `
      -FilePath $tests `
      -Arguments @() `
      -WorkingDirectory $Paths.source `
      -StdoutPath $logs.testStdout `
      -StderrPath $logs.testStderr `
      -TimeoutSeconds 1800 `
      -Environment @{ TEMP = $testTemp; TMP = $testTemp }
  } finally {
    $resolvedScratch = [IO.Path]::GetFullPath($testScratch)
    if (-not ([IO.Path]::GetDirectoryName($resolvedScratch)).TrimEnd('\').Equals(
        $driveRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedScratch) -cne $testScratchName) {
      throw "Refusing to remove an unexpected GN test root: $resolvedScratch"
    }
    if (Test-Path -LiteralPath $resolvedScratch) {
      Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
    }
  }
  $testMatches = @([regex]::Matches(
      $testResult.stdout,
      '(?m)^\[(\d+)/(\d+)\]\s'))
  $totals = @($testMatches | ForEach-Object {
      [int]$_.Groups[2].Value
    } | Sort-Object -Unique)
  $completedTests = if ($testMatches.Count -eq 0) {
    0
  } else {
    [int](($testMatches | ForEach-Object {
          [int]$_.Groups[1].Value
        } | Measure-Object -Maximum).Maximum)
  }
  if (-not $testResult.completed -or
      $testResult.exitCode -ne 0 -or
      $totals.Count -ne 1 -or
      $totals[0] -ne [int]$contract.unitTestCount -or
      $completedTests -ne [int]$contract.unitTestCount -or
      $testResult.stdout -notmatch '(?m)^PASSED\s*$') {
    $tail = Get-KirakaraProcessFailureTail `
      -Stdout $testResult.stdout `
      -Stderr $testResult.stderr
    throw "Locked GN unit tests failed or were incomplete. Logs: $($logs.testStdout), $($logs.testStderr)`n$tail"
  }
  Write-KirakaraGnReadyStamp `
    -Layout $Layout `
    -Paths $Paths `
    -Fingerprint $Fingerprint `
    -Binary $binary `
    -UnitTestCount $completedTests `
    -BuildResult $buildResult `
    -TestResult $testResult `
    -Logs $logs
}

function Get-KirakaraPriorGnHash {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)][pscustomobject]$Paths
  )

  if (-not (Test-Path -LiteralPath $Paths.readyStamp -PathType Leaf)) {
    return $null
  }
  try {
    $stamp = Get-Content -Raw -LiteralPath $Paths.readyStamp -Encoding utf8 |
      ConvertFrom-Json
    if ($stamp.schemaVersion -ne 1 -or
        [string]$stamp.binarySha256 -notmatch '^[0-9A-F]{64}$') {
      return $null
    }
    $binary = [IO.Path]::GetFullPath(
      (Join-Path $Layout.Root ([string]$stamp.binaryPath)))
    if (-not (Test-PathWithin $binary $Paths.root) -or
        -not (Test-Path -LiteralPath $binary -PathType Leaf)) {
      return $null
    }
    $hash = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
    if ($hash -eq [string]$stamp.binarySha256) {
      return $hash
    }
  } catch {
    return $null
  }
  return $null
}

function Install-KirakaraPatchedGn {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Contract,
    [Parameter(Mandatory = $true)][string]$Binary,
    [AllowNull()][string]$PriorBinarySha256
  )

  $target = Join-Path $Layout.EngineSource 'flutter\third_party\gn\gn.exe'
  if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "Engine dependency checkout is missing the official GN binary: $target"
  }
  $customHash = (Get-FileHash -LiteralPath $Binary -Algorithm SHA256).Hash
  $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
  if ($targetHash -eq $customHash) {
    return $customHash
  }
  $accepted = @(
    [string]$Contract.officialBinarySha256,
    $customHash,
    $PriorBinarySha256
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique
  if ($targetHash -notin $accepted) {
    throw (
      'Refusing to replace an unknown Engine GN binary. Expected the locked ' +
      "official or previously verified local hash, got ${targetHash}: $target")
  }
  $targetItem = Get-Item -LiteralPath $target -Force
  $wasReadOnly = $targetItem.IsReadOnly
  try {
    if ($wasReadOnly) {
      $targetItem.IsReadOnly = $false
    }
    Copy-Item -LiteralPath $Binary -Destination $target -Force
  } finally {
    if ($wasReadOnly -and (Test-Path -LiteralPath $target -PathType Leaf)) {
      (Get-Item -LiteralPath $target -Force).IsReadOnly = $true
    }
  }
  $installedHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
  if ($installedHash -ne $customHash) {
    throw "Installed GN hash mismatch. Expected $customHash, got $installedHash."
  }
  return $installedHash
}

function Ensure-KirakaraPatchedGn {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][string]$VisualStudioPath
  )

  $fingerprint = Get-KirakaraGnFingerprint -Lock $Lock
  $paths = Get-KirakaraGnPaths `
    -Layout $Layout `
    -Fingerprint $fingerprint.value
  $priorHash = Get-KirakaraPriorGnHash -Layout $Layout -Paths $paths
  $ready = Test-KirakaraGnReadyStamp `
    -Layout $Layout `
    -Lock $Lock `
    -Fingerprint $fingerprint `
    -Paths $paths
  if (-not $ready.ready) {
    Write-Host "[Kirakara Engine] GN cache is not reusable: $($ready.reason)"
    Initialize-KirakaraPatchedGnSource `
      -Paths $paths `
      -Contract $Lock.projectBootstrap.gn
    Build-KirakaraPatchedGn `
      -Layout $Layout `
      -Lock $Lock `
      -Paths $paths `
      -Fingerprint $fingerprint `
      -VisualStudioPath $VisualStudioPath
    $ready = Test-KirakaraGnReadyStamp `
      -Layout $Layout `
      -Lock $Lock `
      -Fingerprint $fingerprint `
      -Paths $paths
    if (-not $ready.ready) {
      throw "New GN ready stamp failed its own reuse gate: $($ready.reason)"
    }
  } else {
    Write-Host (
      '[Kirakara Engine] Reusing the verified GN Unicode-output tool ' +
      "($($fingerprint.value.Substring(0, 12))).")
  }
  $installedHash = Install-KirakaraPatchedGn `
    -Layout $Layout `
    -Contract $Lock.projectBootstrap.gn `
    -Binary $ready.binary `
    -PriorBinarySha256 $priorHash
  Write-Host "[Kirakara Engine] Verified repository-local GN: $($installedHash.Substring(0, 12))."
}

function Get-KirakaraNinjaPaths {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)][string]$Fingerprint
  )

  $root = Join-Path $Layout.Cache 'ninja'
  return [pscustomobject]@{
    root = $root
    source = Join-Path $Layout.Root 'source\ninja'
    output = Join-Path $root "out\$($Fingerprint.Substring(0, 16))"
    readyStamp = Join-Path $Layout.State 'ninja-ready.json'
  }
}

function Get-KirakaraNinjaFingerprint {
  param([Parameter(Mandatory = $true)]$Lock)

  $contract = $Lock.projectBootstrap.ninja
  $patchPath = Join-Path $script:RepositoryRoot ([string]$contract.patch.path)
  if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
    throw "Pinned Ninja compatibility patch is missing: $patchPath"
  }
  $patchHash = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash
  if ($patchHash -ne [string]$contract.patch.sha256) {
    throw (
      'Pinned Ninja compatibility patch hash mismatch. Expected ' +
      "$($contract.patch.sha256), got $patchHash.")
  }
  $modulePath = Join-Path $PSScriptRoot 'project_engine_bootstrap.psm1'
  $moduleHash = (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash
  $inputs = [ordered]@{
    schemaVersion = 1
    contract = $contract
    depotToolsRevision = [string]$Lock.depotTools.revision
    visualStudioVersion = [string]$Lock.hostBaseline.visualStudioVersion
    msvcToolsetVersion = [string]$Lock.hostBaseline.msvcToolsetVersion
    msvcCompilerVersion = [string]$Lock.hostBaseline.msvcCompilerVersion
    windowsSdkVersion = [string]$Lock.hostBaseline.engineBuildWindowsSdkVersion
    bootstrapModuleSha256 = $moduleHash
  }
  $canonical = $inputs | ConvertTo-Json -Depth 12 -Compress
  return [pscustomobject]@{
    value = Get-KirakaraSha256Text -Text $canonical
    inputs = $inputs
  }
}

function Assert-KirakaraPatchedNinjaSource {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)]$Contract
  )

  if (-not (Test-Path -LiteralPath (Join-Path $Source '.git'))) {
    throw "Pinned Ninja source checkout is missing: $Source"
  }
  $head = Get-GitHead $Source
  if ($head -ne [string]$Contract.revision) {
    throw "Pinned Ninja revision mismatch. Expected $($Contract.revision), got $head."
  }
  $tree = Get-GitTree $Source
  if ($tree -ne [string]$Contract.sourceTree) {
    throw "Pinned Ninja source tree mismatch. Expected $($Contract.sourceTree), got $tree."
  }
  $originOutput = @(& git -C $Source remote get-url origin 2>$null)
  if ($LASTEXITCODE -ne 0 -or $originOutput.Count -ne 1) {
    throw "Cannot validate pinned Ninja origin: $Source"
  }
  $origin = ([string]$originOutput[0]).Trim().TrimEnd('/')
  $expectedOrigin = ([string]$Contract.repository).Trim().TrimEnd('/')
  if (-not $origin.Equals(
      $expectedOrigin, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Pinned Ninja origin mismatch. Expected '$expectedOrigin', got '$origin'."
  }
  $autoCrlfOutput = @(& git -C $Source config --local --get core.autocrlf)
  if ($LASTEXITCODE -ne 0 -or $autoCrlfOutput.Count -ne 1 -or
      ([string]$autoCrlfOutput[0]).Trim() -cne 'false') {
    throw 'Pinned Ninja checkout must set local core.autocrlf=false before checkout.'
  }

  $sourceFiles = [System.Collections.Generic.List[string]]::new()
  $expectedChangedFiles = @($Contract.sourceFiles | ForEach-Object {
      ([string]$_.path).Replace('\', '/')
    } | Sort-Object)
  foreach ($entry in @($Contract.sourceFiles)) {
    $sourceFile = [IO.Path]::GetFullPath(
      (Join-Path $Source ([string]$entry.path)))
    if (-not (Test-PathWithin $sourceFile $Source) -or
        -not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
      throw "Pinned Ninja source file is missing or escapes its checkout: $sourceFile"
    }
    $actualHash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
    if ($actualHash -ne [string]$entry.patchedSha256) {
      throw (
        "Patched Ninja source hash mismatch for $($entry.path). Expected " +
        "$($entry.patchedSha256), got $actualHash.")
    }
    $sourceFiles.Add($sourceFile)
  }
  $changes = @(Get-TrackedGitChanges $Source)
  $changedFiles = @(& git -C $Source diff --name-only HEAD --)
  if ($LASTEXITCODE -ne 0) {
    throw "Cannot enumerate pinned Ninja changes: $Source"
  }
  $changedFiles = @($changedFiles | ForEach-Object {
      ([string]$_).Trim().Replace('\', '/')
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Sort-Object)
  $stagedFiles = @(& git -C $Source diff --cached --name-only HEAD --)
  if ($LASTEXITCODE -ne 0) {
    throw "Cannot enumerate staged pinned Ninja changes: $Source"
  }
  $stagedFiles = @($stagedFiles | Where-Object {
      -not [string]::IsNullOrWhiteSpace([string]$_)
    })
  if ($changes.Count -ne $expectedChangedFiles.Count -or
      $changedFiles.Count -ne $expectedChangedFiles.Count -or
      @(Compare-Object $expectedChangedFiles $changedFiles -CaseSensitive).Count -ne 0 -or
      $stagedFiles.Count -ne 0) {
    throw (
      'Pinned Ninja checkout must contain exactly the one locked, unstaged ' +
      "source patch. Found:`n$($changes -join [Environment]::NewLine)")
  }
  & git -C $Source diff --check | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw 'Pinned Ninja compatibility patch failed git diff --check.'
  }
  return @($sourceFiles)
}

function Initialize-KirakaraPatchedNinjaSource {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Paths,
    [Parameter(Mandatory = $true)]$Contract
  )

  New-Item -ItemType Directory -Path $Paths.root -Force | Out-Null
  if (Test-Path -LiteralPath (Join-Path $Paths.source '.git')) {
    Invoke-CheckedNative git @(
      '-C', $Paths.source, 'config', 'core.autocrlf', 'false'
    ) 'Could not lock the Ninja checkout line-ending policy.' | Out-Null
  }
  $null = Repair-InterruptedManagedGitCheckout `
    -Path $Paths.source `
    -ManagedRoot $Paths.root `
    -Repository ([string]$Contract.repository) `
    -Revision ([string]$Contract.revision) `
    -Label 'project Ninja source'
  if (-not (Test-Path -LiteralPath $Paths.source -PathType Container)) {
    Write-Host '[Kirakara Engine] Cloning the locked Ninja source into .kfe/cache/ninja...'
    Invoke-CheckedNative git @(
      'clone', '--filter=blob:none', '--no-checkout',
      [string]$Contract.repository, $Paths.source
    ) 'Could not clone the locked Ninja source.' | Out-Host
    Invoke-CheckedNative git @(
      '-C', $Paths.source, 'config', 'core.autocrlf', 'false'
    ) 'Could not lock the Ninja checkout line-ending policy.' | Out-Null
    Invoke-CheckedNative git @(
      '-C', $Paths.source, 'fetch', '--depth=1', 'origin',
      [string]$Contract.revision
    ) 'Could not fetch the locked Ninja revision.' | Out-Host
    Invoke-CheckedNative git @(
      '-C', $Paths.source, 'checkout', '--detach',
      [string]$Contract.revision
    ) 'Could not check out the locked Ninja revision.' | Out-Host
  }

  $patchPath = Join-Path $script:RepositoryRoot ([string]$Contract.patch.path)
  $patchHash = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash
  if ($patchHash -ne [string]$Contract.patch.sha256) {
    throw (
      'Pinned Ninja compatibility patch hash mismatch. Expected ' +
      "$($Contract.patch.sha256), got $patchHash.")
  }
  $states = [System.Collections.Generic.List[string]]::new()
  foreach ($entry in @($Contract.sourceFiles)) {
    $sourceFile = [IO.Path]::GetFullPath(
      (Join-Path $Paths.source ([string]$entry.path)))
    if (-not (Test-PathWithin $sourceFile $Paths.source) -or
        -not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
      throw "Pinned Ninja source file is missing or escapes its checkout: $sourceFile"
    }
    $actualHash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
    if ($actualHash -eq [string]$entry.sourceSha256) {
      $states.Add('stock')
    } elseif ($actualHash -eq [string]$entry.patchedSha256) {
      $states.Add('patched')
    } else {
      throw (
        "Pinned Ninja source file $($entry.path) is neither stock nor the " +
        "exact locked patch. Expected $($entry.sourceSha256) or " +
        "$($entry.patchedSha256), got $actualHash.")
    }
  }
  $sourceStates = @($states | Sort-Object -Unique)
  if ($sourceStates.Count -ne 1) {
    throw "Pinned Ninja source files contain a mixed patch state: $($sourceStates -join ', ')."
  }
  if ($sourceStates[0] -eq 'stock') {
    $changes = @(Get-TrackedGitChanges $Paths.source)
    if ($changes.Count -ne 0) {
      throw (
        'Pinned Ninja source has unrelated tracked changes and will not be ' +
        "overwritten:`n$($changes -join [Environment]::NewLine)")
    }
    Write-Host '[Kirakara Engine] Applying the locked Ninja Unicode-process patch...'
    Invoke-CheckedNative git @(
      '-C', $Paths.source, 'apply', '--check', $patchPath
    ) 'Ninja Unicode-process patch preflight failed.' | Out-Host
    Invoke-CheckedNative git @(
      '-C', $Paths.source, 'apply', $patchPath
    ) 'Could not apply the Ninja Unicode-process patch.' | Out-Host
  }
  $null = Assert-KirakaraPatchedNinjaSource `
    -Source $Paths.source `
    -Contract $Contract
}

function Test-KirakaraNinjaReadyStamp {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)]$Fingerprint,
    [Parameter(Mandatory = $true)][pscustomobject]$Paths
  )

  if (-not (Test-Path -LiteralPath $Paths.readyStamp -PathType Leaf)) {
    return [pscustomobject]@{ ready = $false; reason = 'Ninja ready stamp is missing' }
  }
  try {
    $stamp = Get-Content -Raw -LiteralPath $Paths.readyStamp -Encoding utf8 |
      ConvertFrom-Json
    if ($stamp.schemaVersion -ne 1) {
      throw "unsupported Ninja ready stamp schema $($stamp.schemaVersion)"
    }
    if ([string]$stamp.fingerprint -ne [string]$Fingerprint.value) {
      throw 'Ninja bootstrap fingerprint changed'
    }
    if ([int]$stamp.unitTestCount -ne
        [int]$Lock.projectBootstrap.ninja.unitTestCount) {
      throw 'Ninja unit-test count changed'
    }
    if ([string]$stamp.version -ne
        [string]$Lock.projectBootstrap.ninja.upstreamVersion) {
      throw 'Ninja version changed'
    }
    $null = Assert-KirakaraPatchedNinjaSource `
      -Source $Paths.source `
      -Contract $Lock.projectBootstrap.ninja
    $binary = [IO.Path]::GetFullPath(
      (Join-Path $Layout.Root ([string]$stamp.binaryPath)))
    if (-not (Test-PathWithin $binary $Paths.root) -or
        -not (Test-Path -LiteralPath $binary -PathType Leaf)) {
      throw "Ninja binary is missing or escapes its managed cache: $binary"
    }
    $item = Get-Item -LiteralPath $binary
    if ([long]$item.Length -ne [long]$stamp.binarySize) {
      throw 'Ninja binary size changed'
    }
    $hash = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
    if ($hash -ne [string]$stamp.binarySha256) {
      throw 'Ninja binary hash changed'
    }
    $versionOutput = @(& $binary --version 2>$null)
    if ($LASTEXITCODE -ne 0 -or $versionOutput.Count -ne 1 -or
        ([string]$versionOutput[0]).Trim() -ne [string]$stamp.version) {
      throw 'Ninja binary version probe failed'
    }
    foreach ($property in 'buildStdout', 'buildStderr', 'testStdout', 'testStderr') {
      $log = [IO.Path]::GetFullPath(
        (Join-Path $Layout.Root ([string]$stamp.$property)))
      if (-not (Test-PathWithin $log $Layout.Logs) -or
          -not (Test-Path -LiteralPath $log -PathType Leaf)) {
        throw "Ninja ready-stamp log is missing or outside .kfe/logs: $property"
      }
    }
    return [pscustomobject]@{
      ready = $true
      reason = 'all Ninja ready-stamp gates passed'
      binary = $binary
      binarySha256 = $hash
      stamp = $stamp
    }
  } catch {
    return [pscustomobject]@{ ready = $false; reason = $_.Exception.Message }
  }
}

function Write-KirakaraNinjaReadyStamp {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)][pscustomobject]$Paths,
    [Parameter(Mandatory = $true)]$Fingerprint,
    [Parameter(Mandatory = $true)][string]$Binary,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][int]$UnitTestCount,
    [Parameter(Mandatory = $true)]$BuildResult,
    [Parameter(Mandatory = $true)]$TestResult,
    [Parameter(Mandatory = $true)][hashtable]$Logs
  )

  $binaryItem = Get-Item -LiteralPath $Binary
  $stamp = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    fingerprint = $Fingerprint.value
    fingerprintInputs = $Fingerprint.inputs
    binaryPath = (Get-KirakaraRelativePath `
      -BasePath $Layout.Root -Path $Binary).Replace('\', '/')
    binarySize = [long]$binaryItem.Length
    binarySha256 = (Get-FileHash -LiteralPath $Binary -Algorithm SHA256).Hash
    version = $Version
    unitTestCount = $UnitTestCount
    buildDurationMilliseconds = [long]$BuildResult.durationMilliseconds
    testDurationMilliseconds = [long]$TestResult.durationMilliseconds
    buildStdout = (Get-KirakaraRelativePath `
      -BasePath $Layout.Root -Path $Logs.buildStdout).Replace('\', '/')
    buildStderr = (Get-KirakaraRelativePath `
      -BasePath $Layout.Root -Path $Logs.buildStderr).Replace('\', '/')
    testStdout = (Get-KirakaraRelativePath `
      -BasePath $Layout.Root -Path $Logs.testStdout).Replace('\', '/')
    testStderr = (Get-KirakaraRelativePath `
      -BasePath $Layout.Root -Path $Logs.testStderr).Replace('\', '/')
  }
  New-Item -ItemType Directory -Path $Layout.State -Force | Out-Null
  $temporary = Join-Path $Layout.State (
    ".ninja-ready-$([Guid]::NewGuid().ToString('N')).tmp")
  try {
    $stamp | ConvertTo-Json -Depth 14 | Set-Content `
      -LiteralPath $temporary `
      -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $Paths.readyStamp -Force
  } finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
      Remove-Item -LiteralPath $temporary -Force
    }
  }
}

function Build-KirakaraPatchedNinja {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][pscustomobject]$Paths,
    [Parameter(Mandatory = $true)]$Fingerprint,
    [Parameter(Mandatory = $true)][string]$VisualStudioPath
  )

  $contract = $Lock.projectBootstrap.ninja
  $null = Assert-KirakaraPatchedNinjaSource `
    -Source $Paths.source `
    -Contract $contract
  if (Test-Path -LiteralPath $Paths.output) {
    $output = [IO.Path]::GetFullPath($Paths.output)
    if (-not (Test-PathWithin $output $Paths.root) -or
        $output.TrimEnd('\').Equals(
          ([IO.Path]::GetFullPath($Paths.root)).TrimEnd('\'),
          [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to replace an unexpected Ninja output directory: $output"
    }
    Remove-Item -LiteralPath $output -Recurse -Force
  }
  New-Item -ItemType Directory -Path $Paths.output -Force | Out-Null
  $buildSource = Join-Path $Paths.output 'source'
  New-Item -ItemType Directory -Path $buildSource -Force | Out-Null
  $trackedFiles = @(& git -C $Paths.source ls-files)
  if ($LASTEXITCODE -ne 0 -or $trackedFiles.Count -eq 0) {
    throw "Cannot enumerate the locked Ninja source files: $($Paths.source)"
  }
  foreach ($relativeFile in $trackedFiles) {
    $relative = ([string]$relativeFile).Trim().Replace('/', '\')
    $sourceFile = [IO.Path]::GetFullPath((Join-Path $Paths.source $relative))
    $destination = [IO.Path]::GetFullPath((Join-Path $buildSource $relative))
    if (-not (Test-PathWithin $sourceFile $Paths.source) -or
        -not (Test-PathWithin $destination $buildSource) -or
        -not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
      throw "Refusing to stage an invalid Ninja source path: $relativeFile"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) `
      -Force | Out-Null
    Copy-Item -LiteralPath $sourceFile -Destination $destination -Force
  }
  New-Item -ItemType Directory -Path $Layout.Logs -Force | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $nonce = [Guid]::NewGuid().ToString('N').Substring(0, 8)
  $logs = @{
    buildStdout = Join-Path $Layout.Logs "ninja-build-$stamp-$nonce.stdout.log"
    buildStderr = Join-Path $Layout.Logs "ninja-build-$stamp-$nonce.stderr.log"
    testStdout = Join-Path $Layout.Logs "ninja-test-$stamp-$nonce.stdout.log"
    testStderr = Join-Path $Layout.Logs "ninja-test-$stamp-$nonce.stderr.log"
  }

  $vcvars = Join-Path $VisualStudioPath 'VC\Auxiliary\Build\vcvarsall.bat'
  $python = Join-Path $Layout.DepotTools 'python-bin\python3.bat'
  foreach ($tool in @($vcvars, $python)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
      throw "Ninja build tool is missing: $tool"
    }
    if ($tool.Contains('"')) {
      throw "Ninja build tool path contains an unsupported quote: $tool"
    }
  }
  $toolsetParts = ([string]$Lock.hostBaseline.msvcToolsetVersion).Split('.')
  if ($toolsetParts.Count -lt 2) {
    throw 'Pinned MSVC toolset version cannot be converted for vcvarsall.'
  }
  $vcvarsToolset = "$($toolsetParts[0]).$($toolsetParts[1])"
  $compilerFlags = @($contract.compilerFlags) -join ' '
  $configureArguments = @($contract.configureArguments)
  if (@($configureArguments | Where-Object {
        [string]$_ -notmatch '^--[A-Za-z0-9-]+$'
      }).Count -ne 0) {
    throw 'Pinned Ninja configure argument contains unsupported command characters.'
  }
  $targets = @($contract.ninjaTargets)
  if (@($targets | Where-Object {
        [string]$_ -notmatch '^[A-Za-z0-9_.-]+$'
      }).Count -ne 0) {
    throw 'Pinned Ninja build target contains unsupported command characters.'
  }
  foreach ($path in @($Paths.source, $Paths.output, $buildSource)) {
    if ($path.Contains('"')) {
      throw "Ninja build path contains an unsupported quote: $path"
    }
  }
  New-Item -ItemType Directory -Path $Layout.Temp -Force | Out-Null
  $commandFile = Join-Path $Layout.Temp "ninja-build-$nonce.cmd"
  $commandLines = @(
    '@echo off',
    'setlocal',
    'set "VSCMD_SKIP_SENDTELEMETRY=1"',
    'call "%KFE_NINJA_VCVARS%" amd64 %KFE_NINJA_SDK% -vcvars_ver=%KFE_NINJA_TOOLSET% >nul',
    'if errorlevel 1 exit /b %errorlevel%',
    'set "CL=%KFE_NINJA_COMPILER_FLAGS%"',
    'cd /d "%KFE_NINJA_OUTPUT%"',
    'call "%KFE_NINJA_PYTHON%" "%KFE_NINJA_SOURCE%\configure.py" %KFE_NINJA_CONFIGURE_ARGUMENTS%',
    'if errorlevel 1 exit /b %errorlevel%',
    'call "%KFE_NINJA_OUTPUT%\ninja.exe" %KFE_NINJA_TARGETS%',
    'exit /b %errorlevel%'
  ) -join "`r`n"
  [IO.File]::WriteAllText(
    $commandFile, $commandLines, [Text.Encoding]::ASCII)
  $buildEnvironment = @{
    KFE_NINJA_VCVARS = $vcvars
    KFE_NINJA_SDK = [string]$Lock.hostBaseline.engineBuildWindowsSdkVersion
    KFE_NINJA_TOOLSET = $vcvarsToolset
    KFE_NINJA_COMPILER_FLAGS = $compilerFlags
    KFE_NINJA_PYTHON = $python
    KFE_NINJA_SOURCE = $buildSource
    KFE_NINJA_OUTPUT = $buildSource
    KFE_NINJA_CONFIGURE_ARGUMENTS = $configureArguments -join ' '
    KFE_NINJA_TARGETS = $targets -join ' '
    PYTHONUTF8 = '1'
    PYTHONIOENCODING = 'utf-8'
  }
  Write-Host '[Kirakara Engine] Building the locked Ninja Unicode-process tool...'
  try {
    $buildResult = Invoke-KirakaraLoggedProcess `
      -FilePath $env:ComSpec `
      -Arguments @('/d', '/c', 'call', $commandFile) `
      -WorkingDirectory $buildSource `
      -StdoutPath $logs.buildStdout `
      -StderrPath $logs.buildStderr `
      -TimeoutSeconds 3600 `
      -Environment $buildEnvironment
  } finally {
    if (Test-Path -LiteralPath $commandFile -PathType Leaf) {
      Remove-Item -LiteralPath $commandFile -Force
    }
  }
  if (-not $buildResult.completed -or $buildResult.exitCode -ne 0) {
    $tail = Get-KirakaraProcessFailureTail `
      -Stdout $buildResult.stdout `
      -Stderr $buildResult.stderr
    throw "Locked Ninja build failed. Logs: $($logs.buildStdout), $($logs.buildStderr)`n$tail"
  }

  $binary = Join-Path $buildSource 'ninja.exe'
  $tests = Join-Path $buildSource 'ninja_test.exe'
  foreach ($artifact in @($binary, $tests)) {
    if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
      throw "Locked Ninja build did not produce: $artifact"
    }
  }
  $versionOutput = @(& $binary --version 2>$null)
  if ($LASTEXITCODE -ne 0 -or $versionOutput.Count -ne 1) {
    throw "Locked Ninja version probe failed: $binary"
  }
  $version = ([string]$versionOutput[0]).Trim()
  if ($version -ne [string]$contract.upstreamVersion) {
    throw "Locked Ninja version mismatch. Expected $($contract.upstreamVersion), got $version."
  }

  Write-Host (
    '[Kirakara Engine] Running all ' +
    "$($contract.unitTestCount) locked Ninja unit tests...")
  $testResult = Invoke-KirakaraLoggedProcess `
    -FilePath $tests `
    -Arguments @() `
    -WorkingDirectory $buildSource `
    -StdoutPath $logs.testStdout `
    -StderrPath $logs.testStderr `
    -TimeoutSeconds 1800
  $testMatches = @([regex]::Matches(
      $testResult.stdout,
      '(?m)^\[(\d+)/(\d+)\]\s'))
  $totals = @($testMatches | ForEach-Object {
      [int]$_.Groups[2].Value
    } | Sort-Object -Unique)
  $completedTests = if ($testMatches.Count -eq 0) {
    0
  } else {
    [int](($testMatches | ForEach-Object {
          [int]$_.Groups[1].Value
        } | Measure-Object -Maximum).Maximum)
  }
  if (-not $testResult.completed -or
      $testResult.exitCode -ne 0 -or
      $totals.Count -ne 1 -or
      $totals[0] -ne [int]$contract.unitTestCount -or
      $completedTests -ne [int]$contract.unitTestCount -or
      $testResult.stdout -notmatch '(?m)^passed\s*$' -or
      $testResult.stdout -notmatch '(?m)^\[\d+/\d+\]\s+SubprocessTest\.UnicodeCommandLine\s*$') {
    $tail = Get-KirakaraProcessFailureTail `
      -Stdout $testResult.stdout `
      -Stderr $testResult.stderr
    throw "Locked Ninja unit tests failed or were incomplete. Logs: $($logs.testStdout), $($logs.testStderr)`n$tail"
  }
  Write-KirakaraNinjaReadyStamp `
    -Layout $Layout `
    -Paths $Paths `
    -Fingerprint $Fingerprint `
    -Binary $binary `
    -Version $version `
    -UnitTestCount $completedTests `
    -BuildResult $buildResult `
    -TestResult $testResult `
    -Logs $logs
}

function Get-KirakaraPriorNinjaHash {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)][pscustomobject]$Paths
  )

  if (-not (Test-Path -LiteralPath $Paths.readyStamp -PathType Leaf)) {
    return $null
  }
  try {
    $stamp = Get-Content -Raw -LiteralPath $Paths.readyStamp -Encoding utf8 |
      ConvertFrom-Json
    if ($stamp.schemaVersion -ne 1 -or
        [string]$stamp.binarySha256 -notmatch '^[0-9A-F]{64}$') {
      return $null
    }
    $binary = [IO.Path]::GetFullPath(
      (Join-Path $Layout.Root ([string]$stamp.binaryPath)))
    if (-not (Test-PathWithin $binary $Paths.root) -or
        -not (Test-Path -LiteralPath $binary -PathType Leaf)) {
      return $null
    }
    $hash = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
    if ($hash -eq [string]$stamp.binarySha256) {
      return $hash
    }
  } catch {
    return $null
  }
  return $null
}

function Assert-KirakaraNinjaDependencyPin {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Contract
  )

  $depsPath = Join-Path $Layout.FlutterCheckout 'DEPS'
  if (-not (Test-Path -LiteralPath $depsPath -PathType Leaf)) {
    throw "Engine DEPS file is missing while validating Ninja: $depsPath"
  }
  $deps = Get-Content -Raw -LiteralPath $depsPath -Encoding utf8
  $packagePrefix = ([string]$Contract.cipdPackage) -replace '/windows-amd64$', ''
  if (-not $deps.Contains("'$packagePrefix/`${{platform}}'") -or
      -not $deps.Contains("'$([string]$Contract.cipdVersion)'")) {
    throw (
      'Engine Ninja CIPD pin does not match engine.lock.json. Expected ' +
      "$packagePrefix/`${{platform}} at $($Contract.cipdVersion).")
  }

  $packageRoot = Join-Path $Layout.FlutterCheckout '.cipd\pkgs'
  if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) {
    throw "Engine CIPD package metadata is missing: $packageRoot"
  }
  $matches = @()
  foreach ($directory in @(Get-ChildItem -LiteralPath $packageRoot -Directory)) {
    $descriptionPath = Join-Path $directory.FullName 'description.json'
    $currentPath = Join-Path $directory.FullName '_current.txt'
    if (-not (Test-Path -LiteralPath $descriptionPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
      continue
    }
    try {
      $description = Get-Content -Raw -LiteralPath $descriptionPath -Encoding utf8 |
        ConvertFrom-Json
    } catch {
      continue
    }
    if ([string]$description.package_name -eq [string]$Contract.cipdPackage -and
        [string]$description.subdir -eq 'third_party/ninja') {
      $matches += [pscustomobject]@{
        directory = $directory.FullName
        instance = (Get-Content -Raw -LiteralPath $currentPath -Encoding utf8).Trim()
      }
    }
  }
  if ($matches.Count -ne 1 -or
      [string]$matches[0].instance -ne [string]$Contract.cipdInstance) {
    $found = if ($matches.Count -eq 0) {
      '<none>'
    } else {
      @($matches | ForEach-Object { [string]$_.instance }) -join ', '
    }
    throw (
      'Engine Ninja CIPD instance mismatch. Expected ' +
      "$($Contract.cipdInstance), found $found.")
  }
}

function Install-KirakaraPatchedNinja {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Contract,
    [Parameter(Mandatory = $true)][string]$Binary,
    [AllowNull()][string]$PriorBinarySha256
  )

  Assert-KirakaraNinjaDependencyPin -Layout $Layout -Contract $Contract
  $target = Join-Path $Layout.FlutterCheckout 'third_party\ninja\ninja.exe'
  if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "Engine dependency checkout is missing the official Ninja binary: $target"
  }
  $customHash = (Get-FileHash -LiteralPath $Binary -Algorithm SHA256).Hash
  $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
  if ($targetHash -ne $customHash) {
    $accepted = @(
      [string]$Contract.officialBinarySha256,
      $customHash,
      $PriorBinarySha256
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Sort-Object -Unique
    if ($targetHash -notin $accepted) {
      throw (
        'Refusing to replace an unknown Engine Ninja binary. Expected the ' +
        "locked official or previously verified local hash, got ${targetHash}: $target")
    }
    $targetItem = Get-Item -LiteralPath $target -Force
    $wasReadOnly = $targetItem.IsReadOnly
    try {
      if ($wasReadOnly) {
        $targetItem.IsReadOnly = $false
      }
      Copy-Item -LiteralPath $Binary -Destination $target -Force
    } finally {
      if ($wasReadOnly -and (Test-Path -LiteralPath $target -PathType Leaf)) {
        (Get-Item -LiteralPath $target -Force).IsReadOnly = $true
      }
    }
  }
  $installedHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
  if ($installedHash -ne $customHash) {
    throw "Installed Ninja hash mismatch. Expected $customHash, got $installedHash."
  }
  $versionOutput = @(& $target --version 2>$null)
  if ($LASTEXITCODE -ne 0 -or $versionOutput.Count -ne 1 -or
      ([string]$versionOutput[0]).Trim() -ne [string]$Contract.upstreamVersion) {
    throw "Installed Ninja version probe failed: $target"
  }
  return $installedHash
}

function Ensure-KirakaraPatchedNinja {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][string]$VisualStudioPath
  )

  $fingerprint = Get-KirakaraNinjaFingerprint -Lock $Lock
  $paths = Get-KirakaraNinjaPaths `
    -Layout $Layout `
    -Fingerprint $fingerprint.value
  $priorHash = Get-KirakaraPriorNinjaHash -Layout $Layout -Paths $paths
  $ready = Test-KirakaraNinjaReadyStamp `
    -Layout $Layout `
    -Lock $Lock `
    -Fingerprint $fingerprint `
    -Paths $paths
  if (-not $ready.ready) {
    Write-Host "[Kirakara Engine] Ninja cache is not reusable: $($ready.reason)"
    Initialize-KirakaraPatchedNinjaSource `
      -Paths $paths `
      -Contract $Lock.projectBootstrap.ninja
    Build-KirakaraPatchedNinja `
      -Layout $Layout `
      -Lock $Lock `
      -Paths $paths `
      -Fingerprint $fingerprint `
      -VisualStudioPath $VisualStudioPath
    $ready = Test-KirakaraNinjaReadyStamp `
      -Layout $Layout `
      -Lock $Lock `
      -Fingerprint $fingerprint `
      -Paths $paths
    if (-not $ready.ready) {
      throw "New Ninja ready stamp failed its own reuse gate: $($ready.reason)"
    }
  } else {
    Write-Host (
      '[Kirakara Engine] Reusing the verified Ninja Unicode-process tool ' +
      "($($fingerprint.value.Substring(0, 12))).")
  }
  $installedHash = Install-KirakaraPatchedNinja `
    -Layout $Layout `
    -Contract $Lock.projectBootstrap.ninja `
    -Binary $ready.binary `
    -PriorBinarySha256 $priorHash
  Write-Host "[Kirakara Engine] Verified repository-local Ninja: $($installedHash.Substring(0, 12))."
}

function Get-KirakaraReadyStampPath {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)][string]$Mode
  )
  return Join-Path $Layout.State "$Mode-ready.json"
}

function Test-KirakaraReadyStamp {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$Fingerprint
  )

  $stampPath = Get-KirakaraReadyStampPath -Layout $Layout -Mode $Mode
  if (-not (Test-Path -LiteralPath $stampPath -PathType Leaf)) {
    return [pscustomobject]@{ ready = $false; reason = 'ready stamp is missing' }
  }
  try {
    $stamp = Get-Content -Raw -LiteralPath $stampPath -Encoding utf8 |
      ConvertFrom-Json
    if ($stamp.schemaVersion -ne 1) {
      throw "unsupported ready stamp schema $($stamp.schemaVersion)"
    }
    if ($stamp.mode -ne $Mode) {
      throw "ready stamp mode is '$($stamp.mode)'"
    }
    if ($stamp.fingerprint -ne $Fingerprint) {
      throw 'bootstrap fingerprint changed'
    }
    $build = Get-BuildLock -Lock $Lock -Mode $Mode -Variant patched
    $output = Get-EngineOutputDirectory `
      -Layout $Layout `
      -LocalEngine $build.localEngine
    $expectedArtifacts = @($build.artifacts | ForEach-Object {
        [string]$_.path
      } | Sort-Object)
    $stampArtifacts = @($stamp.artifacts)
    $stampArtifactPaths = @($stampArtifacts | ForEach-Object {
        [string]$_.path
      } | Sort-Object)
    if ($stampArtifactPaths.Count -ne $expectedArtifacts.Count -or
        @(Compare-Object $expectedArtifacts $stampArtifactPaths).Count -ne 0) {
      throw 'ready stamp artifact set does not match engine.lock.json'
    }
    if (@($stampArtifactPaths | Sort-Object -Unique).Count -ne
        $stampArtifactPaths.Count) {
      throw 'ready stamp contains duplicate artifact paths'
    }
    if ([string]$stamp.argsGnSha256 -ne [string]$build.argsGnSha256) {
      throw 'ready stamp GN arguments do not match engine.lock.json'
    }
    foreach ($artifact in $stampArtifacts) {
      $path = Join-Path $output ([string]$artifact.path)
      if (-not (Test-PathWithin $path $output)) {
        throw "artifact path escapes Engine output: $($artifact.path)"
      }
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "artifact is missing: $($artifact.path)"
      }
      $item = Get-Item -LiteralPath $path
      if ([long]$item.Length -ne [long]$artifact.size) {
        throw "artifact size changed: $($artifact.path)"
      }
      $shouldVerifyHash = -not ([string]$artifact.path).EndsWith(
        '.pdb', [StringComparison]::OrdinalIgnoreCase)
      if ([bool]$artifact.verifyHash -ne $shouldVerifyHash) {
        throw "artifact hash policy changed: $($artifact.path)"
      }
      if ($shouldVerifyHash) {
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($hash -ne [string]$artifact.sha256) {
          throw "artifact hash changed: $($artifact.path)"
        }
      }
    }
    $argsGn = Join-Path $output 'args.gn'
    if (-not (Test-Path -LiteralPath $argsGn -PathType Leaf)) {
      throw 'args.gn is missing'
    }
    $argsHash = (Get-FileHash -LiteralPath $argsGn -Algorithm SHA256).Hash
    if ($argsHash -ne [string]$stamp.argsGnSha256) {
      throw 'args.gn changed'
    }
    Assert-AppliedPatchset -Lock $Lock -Layout $Layout
    Assert-PinnedDepotTools -Lock $Lock -Layout $Layout -RequireCleanTree
    return [pscustomobject]@{ ready = $true; reason = 'all ready-stamp gates passed' }
  } catch {
    return [pscustomobject]@{ ready = $false; reason = $_.Exception.Message }
  }
}

function Enter-KirakaraBootstrapLock {
  param([Parameter(Mandatory = $true)][pscustomobject]$Layout)

  New-Item -ItemType Directory -Path $Layout.Locks -Force | Out-Null
  $canonicalRoot = Resolve-KirakaraCanonicalDirectoryPath `
    -Path $script:RepositoryRoot
  $identity = Get-KirakaraSha256Text -Text $canonicalRoot.ToUpperInvariant()
  $mutex = [Threading.Mutex]::new($false, "Local\KirakaraEngine-$($identity.Substring(0, 24))")
  $acquired = $false
  try {
    Write-Host '[Kirakara Engine] Waiting for the repository bootstrap lock...'
    try {
      $acquired = $mutex.WaitOne([TimeSpan]::FromHours(6))
    } catch [Threading.AbandonedMutexException] {
      $acquired = $true
    }
    if (-not $acquired) {
      throw 'Timed out waiting for the repository bootstrap lock after six hours.'
    }
    $ownerPath = Join-Path $Layout.Locks 'owner.json'
    [ordered]@{
      schemaVersion = 1
      processId = $PID
      acquiredAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $ownerPath -Encoding utf8
    return [pscustomobject]@{
      mutex = $mutex
      ownerPath = $ownerPath
      acquired = $true
    }
  } catch {
    if ($acquired) {
      $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
    throw
  }
}

function Exit-KirakaraBootstrapLock {
  param([Parameter(Mandatory = $true)]$Handle)

  if ($Handle.acquired) {
    if (Test-Path -LiteralPath $Handle.ownerPath -PathType Leaf) {
      Remove-Item -LiteralPath $Handle.ownerPath -Force
    }
    $Handle.mutex.ReleaseMutex()
  }
  $Handle.mutex.Dispose()
}

function Assert-KirakaraEngineSourceReady {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][string]$VisualStudioPath,
    [Parameter(Mandatory = $true)][string]$WindowsSdkPath,
    [string]$ProxyUrl
  )

  $sourcePresent = Test-Path -LiteralPath (
    Join-Path $Layout.FlutterCheckout '.git')
  $depotPresent = Test-Path -LiteralPath (Join-Path $Layout.DepotTools '.git')
  $patched = $false
  $patchsetOnly = $false
  $stock = $false
  if ($sourcePresent) {
    try {
      Assert-AppliedPatchset -Lock $Lock -Layout $Layout
      $patched = $true
    } catch {
      try {
        Assert-PinnedFlutterSource -Lock $Lock -Layout $Layout -RequireStockTree
        $stock = $true
      } catch {
        try {
          Assert-AppliedPatchset `
            -Lock $Lock `
            -Layout $Layout `
            -ExcludeRepositoryBootstrap
          $patchsetOnly = $true
        } catch {
          throw (
            'Repository-local Engine source is neither the locked stock tree nor ' +
            "the exact patchset. Refusing to reset it automatically.`n$($_.Exception.Message)"
          )
        }
      }
    }
  }

  $dependencyMarkers = @(
    (Join-Path $Layout.EngineSource 'flutter\tools\gn.bat'),
    (Join-Path $Layout.EngineSource 'flutter\buildtools\windows-x64\clang\bin\llvm-readobj.exe'),
    (Join-Path $Layout.DepotTools 'autoninja.bat')
  )
  $dependenciesPresent = $depotPresent -and @(
    $dependencyMarkers | Where-Object {
      -not (Test-Path -LiteralPath $_ -PathType Leaf)
    }
  ).Count -eq 0

  if (-not $sourcePresent -or -not $dependenciesPresent) {
    if ($patchsetOnly) {
      Write-Host '[Kirakara Engine] Completing the repository-local source patch before dependency synchronization...'
      & (Join-Path $PSScriptRoot 'apply_patches.ps1') `
        -WorkspaceRoot $Layout.Root `
        -Variant patched | Out-Host
      $patched = $true
      $patchsetOnly = $false
    }
    if ($patched) {
      Write-Host '[Kirakara Engine] Temporarily reversing the exact patchset before gclient sync...'
      & (Join-Path $PSScriptRoot 'apply_patches.ps1') `
        -WorkspaceRoot $Layout.Root `
        -Variant stock | Out-Host
      $patched = $false
      $stock = $true
    }
    Write-Host '[Kirakara Engine] Fetching and synchronizing the locked Engine source...'
    & (Join-Path $PSScriptRoot 'fetch_engine.ps1') `
      -WorkspaceRoot $Layout.Root `
      -ProxyUrl $ProxyUrl `
      -VisualStudioPath $VisualStudioPath `
      -WindowsSdkPath $WindowsSdkPath | Out-Host
    $stock = $true
  }

  if (-not $patched) {
    if (-not $stock -and -not $patchsetOnly) {
      Assert-PinnedFlutterSource -Lock $Lock -Layout $Layout -RequireStockTree
    }
    Write-Host '[Kirakara Engine] Applying the locked Kirakara patch stack...'
    & (Join-Path $PSScriptRoot 'apply_patches.ps1') `
      -WorkspaceRoot $Layout.Root `
      -Variant patched | Out-Host
  }
  Assert-AppliedPatchset -Lock $Lock -Layout $Layout
  Assert-PinnedDepotTools -Lock $Lock -Layout $Layout -RequireCleanTree
}

function Write-KirakaraReadyStamp {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)]$Fingerprint,
    [Parameter(Mandatory = $true)][string]$VerificationReport,
    [Parameter(Mandatory = $true)][string]$AbiReport
  )

  $verification = Get-Content -Raw -LiteralPath $VerificationReport -Encoding utf8 |
    ConvertFrom-Json
  $modeReport = @($verification.modes | Where-Object { $_.mode -eq $Mode })
  if ($modeReport.Count -ne 1) {
    throw "Verification report has no unique '$Mode' result: $VerificationReport"
  }
  $artifacts = @($modeReport[0].artifacts | ForEach-Object {
      [ordered]@{
        path = [string]$_.path
        size = [long]$_.size
        sha256 = [string]$_.sha256
        verifyHash = -not ([string]$_.path).EndsWith(
          '.pdb', [StringComparison]::OrdinalIgnoreCase)
      }
    })
  $stamp = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    mode = $Mode
    fingerprint = $Fingerprint.value
    fingerprintInputs = $Fingerprint.inputs
    argsGnSha256 = [string]$modeReport[0].argsGnSha256
    artifacts = $artifacts
    verificationReport = (Get-KirakaraRelativePath `
      -BasePath $Layout.Root -Path $VerificationReport).Replace('\', '/')
    abiReport = (Get-KirakaraRelativePath `
      -BasePath $Layout.Root -Path $AbiReport).Replace('\', '/')
  }
  New-Item -ItemType Directory -Path $Layout.State -Force | Out-Null
  $destination = Get-KirakaraReadyStampPath -Layout $Layout -Mode $Mode
  $temporary = Join-Path $Layout.State (
    ".$Mode-ready-$([Guid]::NewGuid().ToString('N')).tmp")
  try {
    $stamp | ConvertTo-Json -Depth 12 | Set-Content `
      -LiteralPath $temporary `
      -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $destination -Force
  } finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
      Remove-Item -LiteralPath $temporary -Force
    }
  }
}

function Remove-KirakaraExpiredLogs {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Lock
  )

  $limitProperty = $Lock.projectBootstrap.PSObject.Properties['maxLogFiles']
  if ($null -eq $limitProperty -or [int]$limitProperty.Value -lt 1) {
    throw 'projectBootstrap.maxLogFiles must be a positive integer.'
  }
  $limit = [int]$limitProperty.Value
  if (-not (Test-Path -LiteralPath $Layout.Logs -PathType Container)) {
    return
  }

  $protected = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
  if (Test-Path -LiteralPath $Layout.State -PathType Container) {
    foreach ($stampPath in @(Get-ChildItem -LiteralPath $Layout.State `
        -Filter '*-ready.json' -File)) {
      try {
        $stamp = Get-Content -Raw -LiteralPath $stampPath.FullName -Encoding utf8 |
          ConvertFrom-Json
        foreach ($property in @(
            'verificationReport',
            'abiReport',
            'buildStdout',
            'buildStderr',
            'testStdout',
            'testStderr'
          )) {
          if ($null -eq $stamp.PSObject.Properties[$property]) {
            continue
          }
          $relative = [string]$stamp.$property
          if ([string]::IsNullOrWhiteSpace($relative)) {
            continue
          }
          $candidate = [IO.Path]::GetFullPath((Join-Path $Layout.Root $relative))
          if (Test-PathWithin $candidate $Layout.Logs) {
            $null = $protected.Add($candidate)
          }
        }
      } catch {
        Write-Warning "Ignoring unreadable ready stamp during log retention: $($stampPath.FullName)"
      }
    }
  }

  $files = @(Get-ChildItem -LiteralPath $Layout.Logs -File | Sort-Object `
      @{ Expression = 'LastWriteTimeUtc'; Descending = $true }, `
      @{ Expression = 'Name'; Descending = $true })
  $remaining = $files.Count
  for ($index = $files.Count - 1; $index -ge 0; $index--) {
    if ($remaining -le $limit) {
      break
    }
    $file = $files[$index]
    $absolute = [IO.Path]::GetFullPath($file.FullName)
    if ($protected.Contains($absolute)) {
      continue
    }
    if (-not (Test-PathWithin $absolute $Layout.Logs)) {
      throw "Refusing to remove a log outside .kfe/logs: $absolute"
    }
    Remove-Item -LiteralPath $absolute -Force
    $remaining--
  }
  if ($remaining -gt $limit) {
    Write-Warning (
      "Log retention kept $remaining files because current ready stamps protect " +
      "more than the configured limit of $limit.")
  }
}

function Ensure-KirakaraProjectEngine {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][string]$FlutterSdkRoot,
    [Parameter(Mandatory = $true)]
    [ValidateSet('debug', 'profile', 'release')]
    [string]$Mode,
    [ValidateRange(0, 256)][int]$Jobs = 0,
    [string]$ProxyUrl,
    [string]$WindowsSdkPath = 'C:\Program Files (x86)\Windows Kits\10'
  )

  $fingerprint = Get-KirakaraBootstrapFingerprint -Lock $Lock -Mode $Mode
  $ready = Test-KirakaraReadyStamp `
    -Layout $Layout `
    -Lock $Lock `
    -Mode $Mode `
    -Fingerprint $fingerprint.value
  if ($ready.ready) {
    Write-Host "[Kirakara Engine] Reusing verified $Mode Engine ($($fingerprint.value.Substring(0, 12)))."
    return
  }

  # Engine builds pin an older MSVC toolset than the current Flutter Windows
  # App generator may select. The build scripts intentionally set these
  # process variables while compiling the Engine, but they must not leak into
  # the subsequent `flutter run/build`: on VS 2026, VCToolsVersion=14.34 with
  # the default v145 App project fails during CMake's compiler probe.
  $toolchainEnvironment = Get-KirakaraEngineToolchainEnvironmentSnapshot
  $handle = Enter-KirakaraBootstrapLock -Layout $Layout
  try {
    $fingerprint = Get-KirakaraBootstrapFingerprint -Lock $Lock -Mode $Mode
    $ready = Test-KirakaraReadyStamp `
      -Layout $Layout `
      -Lock $Lock `
      -Mode $Mode `
      -Fingerprint $fingerprint.value
    if ($ready.ready) {
      Write-Host "[Kirakara Engine] Another process completed the verified $Mode Engine."
      return
    }
    Write-Host "[Kirakara Engine] $Mode cache is not reusable: $($ready.reason)"
    $preflight = Assert-KirakaraBootstrapPreflight `
      -Layout $Layout `
      -Lock $Lock `
      -WindowsSdkPath $WindowsSdkPath
    Assert-KirakaraEngineSourceReady `
      -Layout $Layout `
      -Lock $Lock `
      -VisualStudioPath $preflight.visualStudioPath `
      -WindowsSdkPath $preflight.windowsSdkPath `
      -ProxyUrl $ProxyUrl
    $null = Repair-KirakaraVpythonVirtualenv -Layout $Layout -Lock $Lock
    Ensure-KirakaraPatchedGn `
      -Layout $Layout `
      -Lock $Lock `
      -VisualStudioPath $preflight.visualStudioPath
    Ensure-KirakaraPatchedNinja `
      -Layout $Layout `
      -Lock $Lock `
      -VisualStudioPath $preflight.visualStudioPath

    Write-Host "[Kirakara Engine] Building only the requested $Mode Engine mode..."
    & (Join-Path $PSScriptRoot 'build_windows_engine.ps1') `
      -WorkspaceRoot $Layout.Root `
      -Mode $Mode `
      -Variant patched `
      -Jobs $Jobs `
      -ProxyUrl $ProxyUrl `
      -VisualStudioPath $preflight.visualStudioPath `
      -WindowsSdkPath $preflight.windowsSdkPath | Out-Host

    New-Item -ItemType Directory -Path $Layout.Logs -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $nonce = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $verificationReport = Join-Path $Layout.Logs `
      "verify-$Mode-$stamp-$nonce.json"
    $abiReport = Join-Path $Layout.Logs "abi-$Mode-$stamp-$nonce.json"
    Write-Host '[Kirakara Engine] Verifying source, GN, toolchain, exports and artifacts...'
    & (Join-Path $PSScriptRoot 'verify_engine_bundle.ps1') `
      -WorkspaceRoot $Layout.Root `
      -FlutterSdkRoot $FlutterSdkRoot `
      -Mode $Mode `
      -Variant patched `
      -ReportPath $verificationReport `
      -CaptureArtifactHashes | Out-Host
    Write-Host '[Kirakara Engine] Exercising the versioned compositor ABI gate...'
    & (Join-Path $PSScriptRoot 'test_engine_abi_gate.ps1') `
      -FlutterSdkRoot $FlutterSdkRoot `
      -WorkspaceRoot $Layout.Root `
      -Mode $Mode `
      -ReportPath $abiReport `
      -AllowUnlockedArtifacts | Out-Host
    Write-KirakaraReadyStamp `
      -Layout $Layout `
      -Lock $Lock `
      -Mode $Mode `
      -Fingerprint $fingerprint `
      -VerificationReport $verificationReport `
      -AbiReport $abiReport

    $ready = Test-KirakaraReadyStamp `
      -Layout $Layout `
      -Lock $Lock `
      -Mode $Mode `
      -Fingerprint $fingerprint.value
    if (-not $ready.ready) {
      throw "New $Mode ready stamp failed its own reuse gate: $($ready.reason)"
    }
    Remove-KirakaraExpiredLogs -Layout $Layout -Lock $Lock
    Write-Host "[Kirakara Engine] $Mode Engine is verified and ready."
  } finally {
    try {
      Restore-KirakaraEngineToolchainEnvironment `
        -Snapshot $toolchainEnvironment
    } finally {
      Exit-KirakaraBootstrapLock -Handle $handle
    }
  }
}

function Get-KirakaraEngineStatus {
  $layout=Get-KirakaraProjectLayout; $lock=Get-EngineLock
  $modes=foreach ($mode in 'debug','profile','release') {
    $identity=Get-PrebuiltEngineIdentity $lock $mode
    $cacheKey=Get-PrebuiltEngineCacheKey $identity.value
    $readyPath=Join-Path $layout.Root ("prebuilt/$mode/"+$cacheKey+'/ready.json')
    $stampPresent=Test-Path -LiteralPath $readyPath -PathType Leaf
    if ($stampPresent) { [Kirakara.Artifacts.Security]::NoReparse($readyPath) }
    $sourceFingerprint=Get-KirakaraBootstrapFingerprint -Lock $lock -Mode $mode
    $source=Test-KirakaraReadyStamp -Layout $layout -Lock $lock -Mode $mode -Fingerprint $sourceFingerprint.value
    $configured=$false
    try { $null=Get-PrebuiltEngineEntry $lock $mode; $configured=$true } catch {}
    $selected=$false
    $selectionFile=Join-Path $layout.State "engine-selection-$mode.json"
    if (Test-Path -LiteralPath $selectionFile -PathType Leaf) {
      try {
        [Kirakara.Artifacts.Security]::NoReparse($selectionFile)
        $selection=Get-Content -Raw -LiteralPath $selectionFile -Encoding utf8|ConvertFrom-Json
        $schema=$selection.PSObject.Properties['schemaVersion']
        $selected=($null -ne $schema -and $schema.Value -eq 1 -and
          $selection.kind -ceq 'prebuilt' -and
          $selection.identityHash -ceq $identity.value -and
          $null -ne $selection.entry -and
          $selection.entry.identityHash -ceq $identity.value)
      } catch {
        $selected=$false
      }
    }
    [ordered]@{mode=$mode;prebuiltConfigured=$configured;prebuiltSelected=$selected
      prebuiltStampPresent=$stampPresent
      sourceReady=[bool]$source.ready;identityHash=$identity.value;fingerprint=$sourceFingerprint.value
      ready=(($stampPresent -and ($configured -or $selected)) -or [bool]$source.ready)
      reason='status 只报告状态；实际复用必须重新校验完整包与 ABI。'}
  }
  return [ordered]@{schemaVersion=3;workspace=$layout.Root
    workspaceExists=Test-Path -LiteralPath $layout.Root -PathType Container;modes=@($modes)}
}

function Assert-KirakaraSourceEngineReady {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('debug', 'profile', 'release')]
    [string]$Mode
  )

  $layout = Get-KirakaraProjectLayout
  $lock = Get-EngineLock
  $fingerprint = Get-KirakaraBootstrapFingerprint -Lock $lock -Mode $Mode
  $state = Test-KirakaraReadyStamp `
    -Layout $layout `
    -Lock $lock `
    -Mode $Mode `
    -Fingerprint $fingerprint.value
  if (-not $state.ready) {
    throw (
      "Repository-local $Mode Engine is not ready: $($state.reason). " +
      "请显式运行 '.\flutterw engine prepare $Mode --from-source' 重新验证源码产物；普通 prepare 选择预编译包。"
    )
  }
  $build = Get-BuildLock -Lock $lock -Mode $Mode -Variant patched
  return [pscustomobject]@{
    mode = $Mode
    fingerprint = $fingerprint.value
    output = Get-EngineOutputDirectory `
      -Layout $layout `
      -LocalEngine $build.localEngine
  }
}

function Remove-KirakaraEngineMode {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('debug', 'profile', 'release')]
    [string]$Mode
  )

  $layout = Get-KirakaraProjectLayout
  $lock = Get-EngineLock
  $build = Get-BuildLock -Lock $lock -Mode $Mode -Variant patched
  $output = Get-EngineOutputDirectory `
    -Layout $layout `
    -LocalEngine $build.localEngine
  $outRoot = Join-Path $layout.Root 'out'
  if (-not (Test-PathWithin $output $outRoot)) {
    throw "Refusing to remove an Engine output outside .kfe/out: $output"
  }
  if (Test-Path -LiteralPath $output) {
    Remove-Item -LiteralPath $output -Recurse -Force
  }
  $stamp = Get-KirakaraReadyStampPath -Layout $layout -Mode $Mode
  if (Test-Path -LiteralPath $stamp -PathType Leaf) {
    Remove-Item -LiteralPath $stamp -Force
  }
  Write-Host "Removed repository-local $Mode Engine output and ready stamp."
}

function Remove-KirakaraProjectWorkspace {
  $layout = Get-KirakaraProjectLayout
  $expected = [IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot '.kfe'))
  $actual = [IO.Path]::GetFullPath($layout.Root)
  if (-not $actual.TrimEnd('\').Equals(
      $expected.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to purge unexpected path: $actual"
  }
  if (Test-Path -LiteralPath $actual) {
    Remove-Item -LiteralPath $actual -Recurse -Force
  }
  Write-Host "Removed the repository-local Kirakara Engine workspace: $actual"
}

function Get-KirakaraSelectedEngine {
  param([Parameter(Mandatory)]$Layout,[Parameter(Mandatory)]$Lock,
        [Parameter(Mandatory)][string]$Mode,[string]$Package,[string]$LockPath,[switch]$ForcePrebuilt)
  $selectionFile = Join-Path $Layout.State "engine-selection-$Mode.json"
  $identity = Get-PrebuiltEngineIdentity $Lock $Mode
  if (-not $ForcePrebuilt -and (Test-Path -LiteralPath $selectionFile -PathType Leaf)) {
    [Kirakara.Artifacts.Security]::NoReparse($selectionFile)
    $selection = Get-Content -Raw -LiteralPath $selectionFile -Encoding utf8 |
      ConvertFrom-Json
    $schemaVersion = $selection.PSObject.Properties['schemaVersion']
    if ($null -eq $schemaVersion -or $schemaVersion.Value -ne 1 -or
        $selection.identityHash -cne $identity.value) {
      throw '仓库内 Engine 选择已经过期；请重新执行 engine prepare。'
    }
    if ($selection.kind -ceq 'source') {
      $source = Assert-KirakaraSourceEngineReady -Mode $Mode
      return [pscustomobject]@{kind='source';mode=$Mode;output=$source.output;outputRoot=$Layout.OutputRoot
        localEngine=$identity.build.localEngine;localEngineHost=$identity.build.localEngineHost;identityHash=$identity.value}
    }
    if ($selection.kind -ceq 'prebuilt') {
      if ($null -eq $selection.entry) {
        throw '仓库内预编译 Engine 选择缺少可信包记录；请重新执行 engine prepare。'
      }
      return Ensure-PrebuiltEngine -Layout $Layout -Lock $Lock -Mode $Mode `
        -TrustedEntry $selection.entry
    }
    throw '仓库内 Engine 选择类型无效；请重新执行 engine prepare。'
  }
  return Ensure-PrebuiltEngine -Layout $Layout -Lock $Lock -Mode $Mode -Package $Package -LockPath $LockPath
}

function Write-KirakaraEngineSelection {
  param(
    [Parameter(Mandatory)]$Layout,
    [Parameter(Mandatory)][ValidateSet('debug','profile','release')][string]$Mode,
    [Parameter(Mandatory)][ValidateSet('source','prebuilt')][string]$Kind,
    [Parameter(Mandatory)][string]$IdentityHash,
    $Entry
  )
  if ($IdentityHash -cnotmatch '^[A-F0-9]{64}$') {
    throw 'Engine 选择身份哈希无效。'
  }
  $null = New-Item -ItemType Directory -Path $Layout.State -Force
  $selectionFile = Join-Path $Layout.State "engine-selection-$Mode.json"
  [Kirakara.Artifacts.Security]::NoReparse($selectionFile)
  $record = [ordered]@{
    schemaVersion = 1
    kind = $Kind
    identityHash = $IdentityHash
  }
  if ($Kind -ceq 'prebuilt') {
    if ($null -eq $Entry -or $Entry.identityHash -cne $IdentityHash) {
      throw '预编译 Engine 选择缺少匹配的可信包记录。'
    }
    $record.entry = [ordered]@{
      identityHash = [string]$Entry.identityHash
      url = $null
      size = [long]$Entry.size
      sha256 = [string]$Entry.sha256
      manifestSha256 = [string]$Entry.manifestSha256
    }
  }
  $temporary = Join-Path $Layout.State (
    ".engine-selection-$Mode-$([Guid]::NewGuid().ToString('N')).tmp")
  try {
    [IO.File]::WriteAllText(
      $temporary,
      ($record | ConvertTo-Json -Depth 5),
      [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $selectionFile -Force
  } finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
      Remove-Item -LiteralPath $temporary -Force
    }
  }
}

function Assert-KirakaraProjectEngineReady {
  param([Parameter(Mandatory)][ValidateSet('debug','profile','release')][string]$Mode)
  return Get-KirakaraSelectedEngine -Layout (Get-KirakaraProjectLayout) -Lock (Get-EngineLock) -Mode $Mode
}

function Invoke-KirakaraEngineCommand {
  param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments)
  $command = if ($Arguments.Count -eq 0) { 'status' } else { $Arguments[0] }
  switch ($command) {
    'status' { Get-KirakaraEngineStatus | ConvertTo-Json -Depth 8 | Write-Host; return 0 }
    'doctor' {
      $layout = Get-KirakaraProjectLayout
      $lock = Get-EngineLock
      Set-KirakaraGitProcessConfiguration
      Set-EngineProcessEnvironment -Layout $layout
      $sdk = Resolve-KirakaraFlutterSdk -Layout $layout -Lock $lock -RequiredMode debug -NoInstall
      $sourcePreflight = $null
      if ($Arguments -contains '--from-source') { $sourcePreflight = Assert-KirakaraBootstrapPreflight -Layout $layout -Lock $lock }
      [ordered]@{schemaVersion=1;flutterSdk=$sdk;sourcePreflight=$sourcePreflight
        prebuilt=Get-KirakaraEngineStatus;passed=$true} | ConvertTo-Json -Depth 9 | Write-Host
      return 0
    }
    'prepare' {
      $mode='debug'; $fromSource=$false; $package=$null; $lockPath=$null; $modeSet=$false
      for ($index=1; $index -lt $Arguments.Count; $index++) {
        $argument=$Arguments[$index]
        if ($argument -in @('debug','profile','release')) {
          if ($modeSet) { throw '只能选择一种 Engine 模式。' }
          $mode=$argument; $modeSet=$true
        } elseif ($argument -eq '--from-source') { $fromSource=$true }
        elseif ($argument -in @('--package','--lock')) {
          if ($index+1 -ge $Arguments.Count) { throw "$argument 缺少文件路径。" }
          $index++
          if ($argument -eq '--package') { $package=$Arguments[$index] } else { $lockPath=$Arguments[$index] }
        } else { throw "未知 Engine prepare 参数：$argument" }
      }
      if ($fromSource -and ($package -or $lockPath)) { throw '--from-source 不能与预编译 ZIP/锁混用。' }
      $layout=Get-KirakaraProjectLayout; $lock=Get-EngineLock
      $selectionFile=Join-Path $layout.State "engine-selection-$mode.json"
      if (-not $fromSource) {
        $trusted=Get-PrebuiltEngineEntry -Lock $lock -Mode $mode -LockPath $lockPath
        $null=Get-KirakaraSelectedEngine -Layout $layout -Lock $lock -Mode $mode -Package $package -LockPath $lockPath -ForcePrebuilt
        Write-KirakaraEngineSelection -Layout $layout -Mode $mode `
          -Kind prebuilt -IdentityHash $trusted.identity.value `
          -Entry $trusted.entry
        Write-Host "[Kirakara] $mode 预编译 Engine 已准备；没有获取 Engine 源码或执行 GN/Ninja。"
        return 0
      }
      $proxyUrl=[Environment]::GetEnvironmentVariable('KIRAKARA_ENGINE_PROXY','Process')
      Set-KirakaraGitProcessConfiguration
      Set-EngineProcessEnvironment -Layout $layout -ProxyUrl $proxyUrl
      $sdk=Resolve-KirakaraFlutterSdk -Layout $layout -Lock $lock -RequiredMode $mode
      $jobs=0
      $jobsText=[Environment]::GetEnvironmentVariable('KIRAKARA_ENGINE_JOBS','Process')
      if (-not [string]::IsNullOrWhiteSpace($jobsText) -and -not [int]::TryParse($jobsText,[ref]$jobs)) {
        throw 'KIRAKARA_ENGINE_JOBS 不是有效整数。'
      }
      Ensure-KirakaraProjectEngine -Layout $layout -Lock $lock -FlutterSdkRoot $sdk.root -Mode $mode -Jobs $jobs -ProxyUrl $proxyUrl
      Write-KirakaraEngineSelection -Layout $layout -Mode $mode `
        -Kind source `
        -IdentityHash (Get-PrebuiltEngineIdentity $lock $mode).value
      return 0
    }
    'clean' {
      $mode=if ($Arguments.Count -ge 2) {$Arguments[1]} else {'debug'}
      if ($mode -notin @('debug','profile','release')) { throw '未知 Engine 模式。' }
      $layout=Get-KirakaraProjectLayout
      $handle=Enter-KirakaraBootstrapLock -Layout $layout
      try {
        Remove-KirakaraEngineMode -Mode $mode
        $prebuilt=Join-Path $layout.Root "prebuilt/$mode"
        [Kirakara.Artifacts.Security]::NoReparse($prebuilt)
        if (Test-Path -LiteralPath $prebuilt) { Remove-Item -LiteralPath $prebuilt -Recurse -Force }
        $selectionFile=Join-Path $layout.State "engine-selection-$mode.json"
        [Kirakara.Artifacts.Security]::NoReparse($selectionFile)
        if (Test-Path -LiteralPath $selectionFile) { Remove-Item -LiteralPath $selectionFile -Force }
      } finally { Exit-KirakaraBootstrapLock -Handle $handle }
      return 0
    }
    'purge' {
      $layout=Get-KirakaraProjectLayout
      $handle=Enter-KirakaraBootstrapLock -Layout $layout
      try { Remove-KirakaraProjectWorkspace } finally { Exit-KirakaraBootstrapLock -Handle $handle }
      return 0
    }
    default { throw '未知命令；使用 engine status/doctor/prepare/clean/purge。' }
  }
}

function Invoke-KirakaraFlutter {
  param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments)
  $layout=Get-KirakaraProjectLayout; $lock=Get-EngineLock
  $plan=Get-KirakaraFlutterInvocationPlan -Arguments $Arguments
  if ($plan.injectEngine) {
    $showHost = Resolve-KirakaraShowHostInput
    $env:KIRAKARA_SHOW_HOST_DLL = $showHost.path
  }
  # Fail before SDK preparation if the selected prebuilt package is unavailable.
  $engine=$null
  if ($plan.needsEngine) { $engine=Get-KirakaraSelectedEngine -Layout $layout -Lock $lock -Mode $plan.mode }
  $proxyUrl=[Environment]::GetEnvironmentVariable('KIRAKARA_ENGINE_PROXY','Process')
  Set-KirakaraGitProcessConfiguration
  Set-EngineProcessEnvironment -Layout $layout -ProxyUrl $proxyUrl
  $requiredMode=if ($plan.needsEngine) {$plan.mode} else {'debug'}
  $sdk=Resolve-KirakaraFlutterSdk -Layout $layout -Lock $lock -RequiredMode $requiredMode
  $null=Ensure-KirakaraSdkTools -Layout $layout -Lock $lock
  Write-Host "[Kirakara] Flutter 工具仅在仓库 SDK 中执行：$($sdk.root)"
  $invokeArguments=[Collections.Generic.List[string]]::new()
  foreach ($argument in $Arguments) { $invokeArguments.Add($argument) }
  if ($plan.injectEngine) {
    Import-Module (Join-Path $script:RepositoryRoot 'native/scripts/native_runtime_package.psm1') -Force -DisableNameChecking
    $nativeRuntime = Ensure-NativeRuntimePackage
    $env:KIRAKARA_NATIVE_RUNTIME_ROOT = $nativeRuntime.runtime
    Import-Module (Join-Path $script:RepositoryRoot 'third_party/scripts/handwriting_package.psm1') -Force -DisableNameChecking
    $handwriting = Ensure-HandwritingPackage
    $env:KIRAKARA_HANDWRITING_PACKAGE_ROOT = $handwriting.root
    Import-Module (Join-Path $script:RepositoryRoot 'third_party/scripts/rime_package.psm1') -Force -DisableNameChecking
    $rimeData = Ensure-RimeDataPackage
    $env:KIRAKARA_RIME_DATA_PACKAGE_ROOT = $rimeData.root
    Invalidate-StaleFlutterWindowsBuildForSdk -FlutterSdkRoot $sdk.root -AppRoot $script:RepositoryRoot | Out-Null
    Invalidate-StaleFlutterEphemeralEngine -EngineOutputDirectory $engine.output -AppRoot $script:RepositoryRoot
    $invokeArguments.Add("--local-engine=$($engine.localEngine)")
    $invokeArguments.Add("--local-engine-host=$($engine.localEngineHost)")
    $invokeArguments.Add("--local-engine-src-path=$($engine.outputRoot)")
  }
  $flutter=Join-Path $sdk.root 'bin/flutter.bat'
  Push-Location $script:RepositoryRoot
  try { & $flutter @invokeArguments | Out-Host; return $LASTEXITCODE }
  finally { Pop-Location }
}

Export-ModuleMember -Function @(
  'Get-KirakaraProjectLayout',
  'Get-KirakaraFlutterInvocationPlan',
  'Get-KirakaraBootstrapFingerprint',
  'Get-KirakaraEngineStatus',
  'Assert-KirakaraProjectEngineReady',
  'Invoke-KirakaraEngineCommand',
  'Invoke-KirakaraFlutter'
)
