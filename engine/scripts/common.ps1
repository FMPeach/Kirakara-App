Set-StrictMode -Version Latest

function Resolve-UnresolvedPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
    $Path
  )
}

function Get-AppRepositoryRoot {
  return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}

function Get-EngineLockPath {
  return Join-Path (Get-AppRepositoryRoot) 'engine\engine.lock.json'
}

function Get-EngineLock {
  $lockPath = Get-EngineLockPath
  if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    throw "Engine lock file is missing: $lockPath"
  }

  $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
  if ($lock.schemaVersion -ne 1) {
    throw "Unsupported engine lock schema: $($lock.schemaVersion)"
  }
  $patchsetProperty = $lock.PSObject.Properties['patchset']
  $patchset = if ($patchsetProperty) { $patchsetProperty.Value } else { $null }
  if (
    -not $patchset -or
    -not $patchset.PSObject.Properties['abiVersion'] -or
    -not $patchset.PSObject.Properties['version'] -or
    -not $patchset.PSObject.Properties['revision'] -or
    [uint32]$patchset.abiVersion -eq 0 -or
    [uint32]$patchset.version -eq 0 -or
    [string]::IsNullOrWhiteSpace([string]$patchset.revision)
  ) {
    throw 'engine.lock.json is missing the versioned Kirakara patchset contract.'
  }
  return $lock
}

function Get-EngineWorkspaceLayout {
  param([Parameter(Mandatory = $true)][string]$WorkspaceRoot)

  $root = Resolve-UnresolvedPath $WorkspaceRoot
  $appRoot = Get-AppRepositoryRoot
  $repositoryLocalRoot = Join-Path $appRoot '.kfe'
  $repositoryLocal = [IO.Path]::GetFullPath($root).TrimEnd('\', '/').Equals(
    [IO.Path]::GetFullPath($repositoryLocalRoot).TrimEnd('\', '/'),
    [StringComparison]::OrdinalIgnoreCase)
  if ($repositoryLocal) {
    return [pscustomobject]@{
      Kind = 'repository-local'
      Root = $root
      FlutterCheckout = Join-Path $root 'source\flutter'
      EngineSource = Join-Path $root 'source\flutter\engine\src'
      DepotTools = Join-Path $root 'source\depot_tools'
      OutputRoot = $root
      FlutterSdk = Join-Path $root 'sdk'
      PubCache = Join-Path $root 'pub-cache'
      Cache = Join-Path $root 'cache'
      Temp = Join-Path $root 'tmp'
      Logs = Join-Path $root 'logs'
      Locks = Join-Path $root 'locks'
      State = Join-Path $root 'state'
    }
  }
  $stockRoot = Join-Path $repositoryLocalRoot 'source/stock'
  if ([IO.Path]::GetFullPath($root).TrimEnd('\','/').Equals(
      [IO.Path]::GetFullPath($stockRoot).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)) {
    # Keep the unmodified official source separate from the patched checkout.
    # The retained Engine Tool writes its normal out/ tree inside this slot.
    return [pscustomobject]@{
      Kind = 'repository-stock'
      Root = $root
      FlutterCheckout = Join-Path $root 'flutter'
      EngineSource = Join-Path $root 'flutter/engine/src'
      DepotTools = Join-Path $root 'depot_tools'
      OutputRoot = Join-Path $root 'flutter/engine/src'
      FlutterSdk = Join-Path $repositoryLocalRoot 'sdk'
      PubCache = Join-Path $repositoryLocalRoot 'pub-cache'
      Cache = Join-Path $repositoryLocalRoot 'cache/stock'
      Temp = Join-Path $repositoryLocalRoot 'tmp'
      Logs = Join-Path $repositoryLocalRoot 'logs/stock'
      Locks = Join-Path $repositoryLocalRoot 'locks'
      State = Join-Path $repositoryLocalRoot 'state/stock'
    }
  }
  return [pscustomobject]@{
    Kind = 'external'
    Root = $root
    FlutterCheckout = Join-Path $root 'flutter'
    EngineSource = Join-Path $root 'flutter\engine\src'
    DepotTools = Join-Path $root 'depot_tools'
    OutputRoot = Join-Path $root 'flutter\engine\src'
    FlutterSdk = $null
    PubCache = $null
    Cache = $null
    Temp = $null
    Logs = $null
    Locks = $null
    State = $null
  }
}

function Get-EngineOutputDirectory {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)][string]$LocalEngine
  )

  return Join-Path $Layout.OutputRoot "out\$LocalEngine"
}

function Invalidate-StaleFlutterEphemeralEngine {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$EngineOutputDirectory,
    [string]$AppRoot = (Get-AppRepositoryRoot)
  )

  $expectedDirectory = Resolve-UnresolvedPath $EngineOutputDirectory
  $expectedDll = Join-Path $expectedDirectory 'flutter_windows.dll'
  if (-not (Test-Path -LiteralPath $expectedDll -PathType Leaf)) {
    throw "Selected Engine is missing flutter_windows.dll: $expectedDll"
  }

  $repository = Resolve-UnresolvedPath $AppRoot
  $ephemeralDirectory = Join-Path $repository 'windows\flutter\ephemeral'
  $ephemeralDll = Join-Path $ephemeralDirectory 'flutter_windows.dll'
  if (-not (Test-Path -LiteralPath $ephemeralDll -PathType Leaf)) {
    return
  }

  $comparisons = @(
    [pscustomobject]@{ path = 'flutter_windows.dll'; hash = $true },
    [pscustomobject]@{ path = 'flutter_windows.dll.lib'; hash = $true },
    [pscustomobject]@{ path = 'flutter_windows.dll.pdb'; hash = $false },
    [pscustomobject]@{ path = 'icudtl.dat'; hash = $true },
    [pscustomobject]@{ path = 'flutter_export.h'; hash = $true },
    [pscustomobject]@{ path = 'flutter_windows.h'; hash = $true },
    [pscustomobject]@{ path = 'flutter_messenger.h'; hash = $true },
    [pscustomobject]@{ path = 'flutter_plugin_registrar.h'; hash = $true },
    [pscustomobject]@{ path = 'flutter_texture_registrar.h'; hash = $true }
  )
  $reason = $null
  foreach ($comparison in $comparisons) {
    $expected = Join-Path $expectedDirectory $comparison.path
    if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) {
      continue
    }
    $actual = Join-Path $ephemeralDirectory $comparison.path
    if (-not (Test-Path -LiteralPath $actual -PathType Leaf)) {
      $reason = "$($comparison.path) is missing"
      break
    }
    $expectedItem = Get-Item -LiteralPath $expected
    $actualItem = Get-Item -LiteralPath $actual
    if ($expectedItem.Length -ne $actualItem.Length) {
      $reason = "$($comparison.path) size differs"
      break
    }
    if ($comparison.hash) {
      $expectedHash = (Get-FileHash -LiteralPath $expected -Algorithm SHA256).Hash
      $actualHash = (Get-FileHash -LiteralPath $actual -Algorithm SHA256).Hash
      if ($expectedHash -ne $actualHash) {
        $reason = "$($comparison.path) content differs"
        break
      }
    }
  }
  if ([string]::IsNullOrWhiteSpace($reason)) {
    return
  }

  $expectedEphemeral = [IO.Path]::GetFullPath(
    (Join-Path $repository 'windows\flutter\ephemeral\flutter_windows.dll'))
  $actualEphemeral = [IO.Path]::GetFullPath($ephemeralDll)
  if (-not $actualEphemeral.Equals(
      $expectedEphemeral, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to invalidate unexpected Flutter output: $actualEphemeral"
  }
  Write-Host (
    '[Kirakara Engine] Invalidating stale Flutter Engine assembly output: ' +
    "$reason.")
  Remove-Item -LiteralPath $actualEphemeral -Force
}

function Invalidate-StaleFlutterWindowsBuildForSdk {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$FlutterSdkRoot,
    [string]$AppRoot = (Get-AppRepositoryRoot)
  )

  $repository = [IO.Path]::GetFullPath((Resolve-UnresolvedPath $AppRoot))
  foreach ($marker in 'pubspec.yaml', 'windows\CMakeLists.txt') {
    $markerPath = Join-Path $repository $marker
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
      throw "Refusing to invalidate a directory without Flutter App marker: $markerPath"
    }
  }
  $generatedConfig = Join-Path $repository `
    'windows\flutter\ephemeral\generated_config.cmake'
  if (-not (Test-Path -LiteralPath $generatedConfig -PathType Leaf)) {
    return $false
  }

  $configText = Get-Content -Raw -LiteralPath $generatedConfig
  $matches = [regex]::Matches(
    $configText,
    '(?m)^file\(TO_CMAKE_PATH "(?<root>[^"]+)" FLUTTER_ROOT\)\r?$')
  if ($matches.Count -ne 1) {
    throw "Cannot identify the prior Flutter SDK in $generatedConfig"
  }
  $priorText = $matches[0].Groups['root'].Value.Replace('\\', '\')
  $priorRoot = [IO.Path]::GetFullPath((Resolve-UnresolvedPath $priorText))
  $selectedRoot = [IO.Path]::GetFullPath(
    (Resolve-UnresolvedPath $FlutterSdkRoot))
  if ($priorRoot.TrimEnd('\').Equals(
      $selectedRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    return $false
  }

  $windowsBuild = [IO.Path]::GetFullPath(
    (Join-Path $repository 'build\windows\x64'))
  if (-not (Test-PathWithin $windowsBuild $repository)) {
    throw "Refusing to invalidate an unexpected Windows App build: $windowsBuild"
  }
  if (Test-Path -LiteralPath $windowsBuild) {
    Write-Host (
      '[Kirakara Engine] Flutter SDK root changed; invalidating only the ' +
      "generated Windows App build: $priorRoot -> $selectedRoot")
    Remove-Item -LiteralPath $windowsBuild -Recurse -Force
  }
  return $true
}

function Test-PathWithin {
  param(
    [Parameter(Mandatory = $true)][string]$Candidate,
    [Parameter(Mandatory = $true)][string]$Parent
  )

  $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\', '/')
  $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
  if ($candidateFull.Equals(
      $parentFull,
      [System.StringComparison]::OrdinalIgnoreCase
    )) {
    return $true
  }
  return $candidateFull.StartsWith(
    "$parentFull$([System.IO.Path]::DirectorySeparatorChar)",
    [System.StringComparison]::OrdinalIgnoreCase
  )
}

function Assert-ExternalEngineWorkspace {
  param([Parameter(Mandatory = $true)][pscustomobject]$Layout)

  $appRoot = Get-AppRepositoryRoot
  if ($Layout.Kind -in @('repository-local','repository-stock')) {
    $expectedRoot = Join-Path $appRoot '.kfe'
    if ($Layout.Kind -eq 'repository-stock') { $expectedRoot = Join-Path $expectedRoot 'source/stock' }
    if (-not [IO.Path]::GetFullPath($Layout.Root).TrimEnd('\', '/').Equals(
        [IO.Path]::GetFullPath($expectedRoot).TrimEnd('\', '/'),
        [StringComparison]::OrdinalIgnoreCase)) {
      throw "Repository-local Engine workspace must be exactly $expectedRoot"
    }
    return
  }
  if (Test-PathWithin $Layout.Root $appRoot) {
    throw "Engine workspace must be outside the App repository: $($Layout.Root)"
  }

  if ($Layout.Root -match '^[A-Za-z]:\\?$') {
    throw "Refusing to use a drive root as the Engine workspace: $($Layout.Root)"
  }
}

function Invoke-CheckedNative {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
    [string]$FailureMessage = 'Native command failed.'
  )

  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FailureMessage Exit code: $LASTEXITCODE"
  }
}

function Get-GitHead {
  param([Parameter(Mandatory = $true)][string]$Repository)

  $head = & git -C $Repository rev-parse HEAD
  if ($LASTEXITCODE -ne 0) {
    throw "Cannot read Git HEAD: $Repository"
  }
  return ($head | Select-Object -First 1).Trim()
}

function Get-GitTree {
  param([Parameter(Mandatory = $true)][string]$Repository)

  $tree = & git -C $Repository show -s '--format=%T' HEAD
  if ($LASTEXITCODE -ne 0) {
    throw "Cannot read Git tree: $Repository"
  }
  return ($tree | Select-Object -First 1).Trim()
}

function Get-TrackedGitChanges {
  param([Parameter(Mandatory = $true)][string]$Repository)

  $status = @(& git -C $Repository status --porcelain=v1 --untracked-files=no)
  if ($LASTEXITCODE -ne 0) {
    throw "Cannot read Git status: $Repository"
  }
  return @($status | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Repair-InterruptedManagedGitCheckout {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ManagedRoot,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$Revision,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $target = [IO.Path]::GetFullPath((Resolve-UnresolvedPath $Path))
  $root = [IO.Path]::GetFullPath((Resolve-UnresolvedPath $ManagedRoot))
  if (-not (Test-PathWithin $target $root) -or $target.TrimEnd('\', '/').Equals(
      $root.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to repair $Label outside the managed workspace: $target"
  }
  if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    return 'missing'
  }

  $gitDirectory = Join-Path $target '.git'
  if (-not (Test-Path -LiteralPath $gitDirectory)) {
    Write-Warning (
      "Removing interrupted $Label checkout without Git metadata: $target")
    Remove-Item -LiteralPath $target -Recurse -Force
    return 'removed-incomplete'
  }

  $originOutput = @(& git -C $target remote get-url origin 2>$null)
  if ($LASTEXITCODE -ne 0 -or $originOutput.Count -ne 1) {
    throw "Cannot validate the interrupted $Label checkout origin: $target"
  }
  $origin = ([string]$originOutput[0]).Trim().TrimEnd('/')
  $expectedOrigin = $Repository.Trim().TrimEnd('/')
  if (-not $origin.Equals(
      $expectedOrigin, [StringComparison]::OrdinalIgnoreCase)) {
    throw (
      "$Label checkout origin mismatch. Expected '$Repository', got " +
      "'$origin'. Refusing automatic recovery.")
  }

  $headOutput = @(& git -C $target rev-parse --verify HEAD 2>$null)
  $head = if ($LASTEXITCODE -eq 0 -and $headOutput.Count -ge 1) {
    ([string]$headOutput[0]).Trim()
  } else { $null }
  if ($head -eq $Revision) {
    return 'ready'
  }

  $changes = @(Get-TrackedGitChanges $target)
  if ($changes.Count -ne 0) {
    throw (
      "$Label checkout has tracked changes and cannot be resumed safely:`n" +
      ($changes -join [Environment]::NewLine))
  }

  Write-Host (
    "Resuming interrupted $Label checkout at locked revision $Revision...")
  Invoke-CheckedNative git @(
    '-C', $target, 'fetch', '--depth=1', 'origin', $Revision
  ) "Could not fetch the locked $Label revision while resuming."
  Invoke-CheckedNative git @(
    '-C', $target, 'checkout', '--detach', $Revision
  ) "Could not check out the locked $Label revision while resuming."
  $repairedHead = Get-GitHead $target
  if ($repairedHead -ne $Revision) {
    throw (
      "$Label resume completed at the wrong revision. Expected $Revision, " +
      "got $repairedHead.")
  }
  return 'resumed'
}

function Assert-PinnedFlutterBootstrap {
  param(
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][pscustomobject]$Layout
  )

  if (-not (Test-Path -LiteralPath (Join-Path $Layout.FlutterCheckout '.git'))) {
    throw "Flutter bootstrap checkout is missing: $($Layout.FlutterCheckout)"
  }
  $bootstrapHead = Get-GitHead $Layout.FlutterCheckout
  if ($bootstrapHead -ne $Lock.flutter.engineRevision) {
    throw "Flutter bootstrap revision mismatch. Expected $($Lock.flutter.engineRevision), got $bootstrapHead."
  }
}

function Assert-PinnedFlutterSource {
  param(
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [switch]$RequireStockTree
  )

  Assert-PinnedFlutterBootstrap -Lock $Lock -Layout $Layout

  $engineTree = Get-GitTree $Layout.FlutterCheckout
  if ($engineTree -ne $Lock.flutter.engineSourceTree) {
    throw "Engine source tree mismatch. Expected $($Lock.flutter.engineSourceTree), got $engineTree."
  }

  if ($RequireStockTree) {
    $changes = @(Get-TrackedGitChanges $Layout.FlutterCheckout)
    if ($changes.Count -ne 0) {
      throw "Stock Engine source has tracked changes:`n$($changes -join [Environment]::NewLine)"
    }
    Assert-PinnedEngineDependencies `
      -Lock $Lock `
      -Layout $Layout `
      -Variant stock
  }
}

function Assert-PinnedDepotTools {
  param(
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [switch]$RequireCleanTree
  )

  if (-not (Test-Path -LiteralPath (Join-Path $Layout.DepotTools '.git'))) {
    throw "depot_tools checkout is missing: $($Layout.DepotTools)"
  }
  $head = Get-GitHead $Layout.DepotTools
  if ($head -ne $Lock.depotTools.revision) {
    throw "depot_tools revision mismatch. Expected $($Lock.depotTools.revision), got $head."
  }
  if ($RequireCleanTree) {
    $changes = @(Get-TrackedGitChanges $Layout.DepotTools)
    if ($changes.Count -ne 0) {
      throw "depot_tools has tracked changes:`n$($changes -join [Environment]::NewLine)"
    }
  }
}

function Get-BuildLock {
  param(
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][string]$Mode,
    [ValidateSet('stock', 'patched')]
    [string]$Variant = 'stock'
  )

  $builds = if ($Variant -eq 'stock') {
    @($Lock.builds)
  } else {
    @($Lock.patchset.builds)
  }
  $matches = @($builds | Where-Object { $_.mode -eq $Mode })
  if ($matches.Count -ne 1) {
    throw "Expected exactly one $Variant lock entry for build mode '$Mode'."
  }
  return $matches[0]
}

function Remove-TemporaryGitIndex {
  param([Parameter(Mandatory = $true)][string]$IndexPath)

  $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  foreach ($candidate in @($IndexPath, "$IndexPath.lock")) {
    if (-not (Test-Path -LiteralPath $candidate)) {
      continue
    }
    $resolved = [IO.Path]::GetFullPath($candidate)
    if (-not $resolved.StartsWith(
        $tempRoot,
        [StringComparison]::OrdinalIgnoreCase
      )) {
      throw "Refusing to remove a temporary Git index outside the temp directory: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Force
  }
}

function Get-PatchsetExpectedTree {
  param(
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][string]$Repository,
    [AllowNull()][object[]]$Patches
  )

  $patches = if ($null -eq $Patches) {
    @($Lock.patchset.patches)
  } else {
    @($Patches)
  }
  if ($patches.Count -eq 0) {
    throw 'The patched Engine variant has no locked patches.'
  }
  $indexPath = Join-Path ([IO.Path]::GetTempPath()) `
    "kirakara-engine-expected-$([guid]::NewGuid().ToString('N')).index"
  $previousIndex = [Environment]::GetEnvironmentVariable(
    'GIT_INDEX_FILE',
    'Process'
  )
  try {
    $env:GIT_INDEX_FILE = $indexPath
    Invoke-CheckedNative git @('-C', $Repository, 'read-tree', 'HEAD') `
      'Could not initialize the expected patch index.'
    foreach ($patch in $patches) {
      $patchPath = Join-Path (Get-AppRepositoryRoot) $patch.path
      if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
        throw "Patch is missing: $patchPath"
      }
      $actualHash = (
        Get-FileHash -LiteralPath $patchPath -Algorithm SHA256
      ).Hash
      if ($actualHash -ne $patch.sha256) {
        throw "Patch hash mismatch for $($patch.path). Expected $($patch.sha256), got $actualHash."
      }
      Invoke-CheckedNative git @(
        '-C', $Repository, 'apply', '--cached', '--check',
        '--whitespace=error-all', $patchPath
      ) "Patch preflight failed: $($patch.path)"
      Invoke-CheckedNative git @(
        '-C', $Repository, 'apply', '--cached',
        '--whitespace=error-all', $patchPath
      ) "Could not build the expected tree for patch: $($patch.path)"
    }
    $tree = @(& git -C $Repository write-tree)
    if ($LASTEXITCODE -ne 0 -or $tree.Count -ne 1) {
      throw 'Could not compute the expected patched Engine tree.'
    }
    return $tree[0].Trim()
  } finally {
    if ($null -eq $previousIndex) {
      Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
    } else {
      $env:GIT_INDEX_FILE = $previousIndex
    }
    Remove-TemporaryGitIndex -IndexPath $indexPath
  }
}

function Get-WorkingTreeSnapshot {
  param([Parameter(Mandatory = $true)][string]$Repository)

  $indexPath = Join-Path ([IO.Path]::GetTempPath()) `
    "kirakara-engine-working-$([guid]::NewGuid().ToString('N')).index"
  $previousIndex = [Environment]::GetEnvironmentVariable(
    'GIT_INDEX_FILE',
    'Process'
  )
  try {
    $env:GIT_INDEX_FILE = $indexPath
    Invoke-CheckedNative git @('-C', $Repository, 'read-tree', 'HEAD') `
      'Could not initialize the working-tree snapshot index.'
    Invoke-CheckedNative git @('-C', $Repository, 'add', '-A', '--', '.') `
      'Could not snapshot the Engine working tree.'
    $tree = @(& git -C $Repository write-tree)
    if ($LASTEXITCODE -ne 0 -or $tree.Count -ne 1) {
      throw 'Could not compute the current Engine working-tree snapshot.'
    }
    return $tree[0].Trim()
  } finally {
    if ($null -eq $previousIndex) {
      Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
    } else {
      $env:GIT_INDEX_FILE = $previousIndex
    }
    Remove-TemporaryGitIndex -IndexPath $indexPath
  }
}

function Assert-PinnedEngineDependencies {
  param(
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]
    [ValidateSet('stock', 'patched')]
    [string]$Variant
  )

  $property = $Lock.projectBootstrap.PSObject.Properties[
    'engineDependencyPatches']
  if ($null -eq $property) {
    return
  }

  $checkoutRoot = [IO.Path]::GetFullPath($Layout.FlutterCheckout)
  $checkoutPrefix = $checkoutRoot.TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  foreach ($dependency in @($property.Value)) {
    $name = [string]$dependency.name
    $relative = ([string]$dependency.repositoryPath).Replace(
      '/', [IO.Path]::DirectorySeparatorChar)
    $repository = [IO.Path]::GetFullPath(
      (Join-Path $checkoutRoot $relative))
    if (-not $repository.StartsWith(
        $checkoutPrefix,
        [StringComparison]::OrdinalIgnoreCase
      )) {
      throw "Engine dependency '$name' escapes the Flutter checkout: $repository"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $repository '.git'))) {
      throw "Engine dependency checkout is missing for '$name': $repository"
    }

    $head = Get-GitHead $repository
    if ($head -ne [string]$dependency.revision) {
      throw (
        "Engine dependency '$name' revision mismatch. Expected " +
        "$($dependency.revision), got $head.")
    }
    $sourceTree = Get-GitTree $repository
    if ($sourceTree -ne [string]$dependency.sourceTree) {
      throw (
        "Engine dependency '$name' source tree mismatch. Expected " +
        "$($dependency.sourceTree), got $sourceTree.")
    }

    $expectedTree = $sourceTree
    if ($Variant -eq 'patched') {
      $patches = @($dependency.patches)
      if ($patches.Count -eq 0) {
        throw "Engine dependency '$name' has no locked patches."
      }
      $expectedTree = Get-PatchsetExpectedTree `
        -Lock $Lock `
        -Repository $repository `
        -Patches $patches
      if ($expectedTree -ne [string]$dependency.patchedTree) {
        throw (
          "Engine dependency '$name' patched tree mismatch. Expected " +
          "$($dependency.patchedTree), patches produce $expectedTree.")
      }
    }

    $workingTree = Get-WorkingTreeSnapshot -Repository $repository
    if ($workingTree -ne $expectedTree) {
      $status = @(& git -C $repository status --short)
      throw (
        "Engine dependency '$name' does not match the locked $Variant tree. " +
        "Expected $expectedTree, got $workingTree.`n" +
        ($status -join [Environment]::NewLine))
    }
  }
}

function Assert-AppliedPatchset {
  param(
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [switch]$ExcludeRepositoryBootstrap
  )

  Assert-PinnedFlutterSource -Lock $Lock -Layout $Layout
  $patchsetPatches = @($Lock.patchset.patches)
  $patchsetTree = Get-PatchsetExpectedTree `
    -Lock $Lock `
    -Repository $Layout.FlutterCheckout `
    -Patches $patchsetPatches
  $lockedTree = [string]$Lock.patchset.sourceTree
  if (
    -not [string]::IsNullOrWhiteSpace($lockedTree) -and
    $patchsetTree -ne $lockedTree
  ) {
    throw "Locked patchset tree mismatch. Expected $lockedTree, patches produce $patchsetTree."
  }

  $expectedTree = $patchsetTree
  if ($Layout.Kind -eq 'repository-local' -and
      -not $ExcludeRepositoryBootstrap) {
    $bootstrapPatches = @($Lock.projectBootstrap.engineSourcePatches)
    if ($bootstrapPatches.Count -eq 0) {
      throw 'Repository-local Engine layout has no locked bootstrap source patches.'
    }
    $allPatches = @($patchsetPatches) + @($bootstrapPatches)
    $expectedTree = Get-PatchsetExpectedTree `
      -Lock $Lock `
      -Repository $Layout.FlutterCheckout `
      -Patches $allPatches
    $bootstrapTree = [string]$Lock.projectBootstrap.engineSourceTree
    if ([string]::IsNullOrWhiteSpace($bootstrapTree) -or
        $expectedTree -ne $bootstrapTree) {
      throw (
        'Locked repository-local Engine tree mismatch. Expected ' +
        "$bootstrapTree, patches produce $expectedTree."
      )
    }
  }
  $workingTree = Get-WorkingTreeSnapshot -Repository $Layout.FlutterCheckout
  if ($workingTree -ne $expectedTree) {
    $status = @(& git -C $Layout.FlutterCheckout status --short)
    throw (
      "Engine working tree does not exactly match the locked patchset. " +
      "Expected tree $expectedTree, got $workingTree.`n$($status -join [Environment]::NewLine)"
    )
  }
  if ($Layout.Kind -eq 'repository-local' -and
      -not $ExcludeRepositoryBootstrap) {
    Assert-PinnedEngineDependencies `
      -Lock $Lock `
      -Layout $Layout `
      -Variant patched
  }
}

function Assert-LockedEngineArtifacts {
  param(
    [Parameter(Mandatory = $true)]$Build,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
  )

  foreach ($artifact in $Build.artifacts) {
    $lockedHash = [string]$artifact.sha256
    if ([string]::IsNullOrWhiteSpace($lockedHash)) {
      throw "Engine artifact is not locked: $($Build.mode)/$($artifact.path)"
    }
    $artifactPath = Join-Path $OutputDirectory $artifact.path
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
      throw "Locked Engine artifact is missing: $artifactPath"
    }
    $item = Get-Item -LiteralPath $artifactPath
    if ([long]$item.Length -ne [long]$artifact.size) {
      throw "Engine artifact size mismatch for $($Build.mode)/$($artifact.path). Expected $($artifact.size), got $($item.Length)."
    }
    $actualHash = (
      Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256
    ).Hash
    if ($actualHash -ne $lockedHash) {
      throw "Engine artifact hash mismatch for $($Build.mode)/$($artifact.path). Expected $lockedHash, got $actualHash."
    }
  }
}

function Assert-UsableEngineArtifacts {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)]$Build,
    [Parameter(Mandatory = $true)]
    [ValidateSet('debug', 'profile', 'release')]
    [string]$Mode,
    [Parameter(Mandatory = $true)]
    [ValidateSet('stock', 'patched')]
    [string]$Variant,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
  )

  if ($Layout.Kind -ne 'repository-local') {
    Assert-LockedEngineArtifacts `
      -Build $Build `
      -OutputDirectory $OutputDirectory
    return
  }
  if ($Variant -ne 'patched') {
    throw 'The repository-local workspace contains only the patched Engine variant.'
  }
  Import-Module (Join-Path $PSScriptRoot 'project_engine_bootstrap.psm1') -Force
  $ready = Assert-KirakaraProjectEngineReady -Mode $Mode
  if (-not ([IO.Path]::GetFullPath($ready.output).Equals(
        [IO.Path]::GetFullPath($OutputDirectory),
        [StringComparison]::OrdinalIgnoreCase))) {
    throw "Repository-local ready output mismatch for '$Mode'."
  }
}

function Assert-MatchingFile {
  param(
    [Parameter(Mandatory = $true)][string]$ExpectedPath,
    [Parameter(Mandatory = $true)][string]$ActualPath,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Test-Path -LiteralPath $ExpectedPath -PathType Leaf)) {
    throw "Expected $Label is missing: $ExpectedPath"
  }
  if (-not (Test-Path -LiteralPath $ActualPath -PathType Leaf)) {
    throw "Actual $Label is missing: $ActualPath"
  }
  $expectedHash = (Get-FileHash -LiteralPath $ExpectedPath -Algorithm SHA256).Hash
  $actualHash = (Get-FileHash -LiteralPath $ActualPath -Algorithm SHA256).Hash
  if ($expectedHash -ne $actualHash) {
    throw "$Label mismatch. Expected $expectedHash, got $actualHash."
  }
}

function Assert-MatchingTextFile {
  param(
    [Parameter(Mandatory = $true)][string]$ExpectedPath,
    [Parameter(Mandatory = $true)][string]$ActualPath,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Test-Path -LiteralPath $ExpectedPath -PathType Leaf)) {
    throw "Expected $Label is missing: $ExpectedPath"
  }
  if (-not (Test-Path -LiteralPath $ActualPath -PathType Leaf)) {
    throw "Actual $Label is missing: $ActualPath"
  }
  $expected = [IO.File]::ReadAllText($ExpectedPath).Replace("`r`n", "`n")
  $actual = [IO.File]::ReadAllText($ActualPath).Replace("`r`n", "`n")
  if ($expected -cne $actual) {
    throw "$Label content mismatch. Keep the Runner ABI header synchronized with the patched Engine source."
  }
}

function Invoke-GTestProcess {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Filter,
    [Parameter(Mandatory = $true)][int]$ExpectedTestCount,
    [Parameter(Mandatory = $true)][string]$LogDirectory,
    [Parameter(Mandatory = $true)][int]$TimeoutSeconds
  )

  $stdoutPath = Join-Path $LogDirectory "$Name.stdout.txt"
  $stderrPath = Join-Path $LogDirectory "$Name.stderr.txt"
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $Executable
  $startInfo.Arguments = "--gtest_color=no --gtest_filter=$Filter"
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    if (-not $process.Start()) {
      throw "Could not start Windows Engine tests: $Name"
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
      $process.Kill()
      $process.WaitForExit()
    } else {
      # Flush redirected output before reading the asynchronous tasks.
      $process.WaitForExit()
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = if ($completed) { $process.ExitCode } else { $null }
  } finally {
    $stopwatch.Stop()
    $process.Dispose()
  }

  Set-Content -LiteralPath $stdoutPath -Value $stdout -Encoding utf8
  Set-Content -LiteralPath $stderrPath -Value $stderr -Encoding utf8
  $failedTests = @([regex]::Matches(
      $stdout,
      '(?m)^\[\s+FAILED\s+\]\s+([^\s]+)(?:\s+\(\d+ ms\))?\s*$'
    ) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
  $countMatches = @([regex]::Matches(
      $stdout,
      '(?m)^\[==========\]\s+Running\s+(\d+)\s+tests?\s+from\s+'
    ))
  $testCount = if ($countMatches.Count -eq 1) {
    [int]$countMatches[0].Groups[1].Value
  } else {
    $null
  }

  return [ordered]@{
    name = $Name
    filter = $Filter
    timedOut = -not $completed
    timeoutSeconds = $TimeoutSeconds
    durationMilliseconds = [long]$stopwatch.ElapsedMilliseconds
    exitCode = $exitCode
    expectedTestCount = $ExpectedTestCount
    testCount = $testCount
    failedTests = $failedTests
    stdout = $stdoutPath
    stderr = $stderrPath
  }
}

function Assert-RepositoryEngineWriteWorkspace {
  param([Parameter(Mandatory)]$Layout)
  if ($Layout.Kind -notin @('repository-local','repository-stock')) {
    throw '正式仓库只允许在当前仓库 .kfe 中获取、修改或构建 Engine；外部工作区仅可用于只读检查。'
  }
  Assert-ExternalEngineWorkspace $Layout
  $expected = Get-EngineWorkspaceLayout $Layout.Root
  foreach ($property in @('Kind','FlutterCheckout','EngineSource','DepotTools','OutputRoot','FlutterSdk','PubCache','Cache','Temp','Logs','Locks','State')) {
    if ([string]$Layout.$property -ine [string]$expected.$property) { throw 'Engine 工作区布局包含不属于当前仓库的覆盖路径。' }
  }
  if (-not ('Kirakara.Artifacts.Security' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'artifact_security.cs')
  }
  foreach ($property in @('Root','FlutterCheckout','EngineSource','DepotTools','OutputRoot','FlutterSdk','PubCache','Cache','Temp','Logs','Locks','State')) {
    [Kirakara.Artifacts.Security]::NoReparse([string]$Layout.$property)
  }
}

function Set-EngineProcessEnvironment {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [string]$ProxyUrl,
    [string]$VisualStudioPath,
    [string]$MsvcToolsetVersion,
    [string]$WindowsSdkPath
  )

  $env:DEPOT_TOOLS_UPDATE = '0'
  $env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
  $depotToolPaths = @($Layout.DepotTools)
  if ($Layout.Kind -in @('repository-local','repository-stock')) {
    # GN resolves script_executable from PATH without invoking depot_tools'
    # batch-file shims.  The CIPD-installed vpython3.exe therefore has to
    # precede the checkout when the repository lives below a Unicode path.
    $depotToolPaths = @(
      (Join-Path $Layout.DepotTools '.cipd_bin'),
      $Layout.DepotTools
    )
  }
  $env:Path = "$($depotToolPaths -join ';');$env:Path"
  if ($Layout.Kind -in @('repository-local','repository-stock')) {
    foreach ($directory in @(
        $Layout.PubCache,
        $Layout.Cache,
        $Layout.Temp,
        $Layout.Logs,
        $Layout.Locks,
        $Layout.State
      )) {
      New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $env:PUB_CACHE = $Layout.PubCache
    # Flutter's Windows tool state uses APPDATA, not its SDK cache. Keep tool
    # state process-local as well; flutterw restores the caller's environment.
    $env:APPDATA = Join-Path $Layout.State 'appdata'
    $env:LOCALAPPDATA = Join-Path $Layout.Cache 'localappdata'
    New-Item -ItemType Directory -Path $env:APPDATA,$env:LOCALAPPDATA -Force | Out-Null
    $env:CIPD_CACHE_DIR = Join-Path $Layout.Cache 'cipd'
    $env:VPYTHON_VIRTUALENV_ROOT = Join-Path $Layout.Cache 'vpython'
    $env:DEPOT_TOOLS_CACHE_DIR = Join-Path $Layout.Cache 'depot_tools'
    $env:TEMP = $Layout.Temp
    $env:TMP = $Layout.Temp
    $env:FLUTTER_SKIP_UPDATE_CHECK = 'true'
    $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
    $env:DART_SUPPRESS_ANALYTICS = 'true'
    # The repository may live below a non-ASCII Windows path. Older virtualenv
    # code in the pinned vpython toolchain otherwise decodes child output as
    # UTF-8 while pip emits the active OEM code page, corrupting the path and
    # failing before GN generation.
    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'
    foreach ($directory in @(
        $env:CIPD_CACHE_DIR,
        $env:VPYTHON_VIRTUALENV_ROOT,
        $env:DEPOT_TOOLS_CACHE_DIR
      )) {
      New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($ProxyUrl)) {
    $env:HTTP_PROXY = $ProxyUrl
    $env:HTTPS_PROXY = $ProxyUrl
  }
  if (-not [string]::IsNullOrWhiteSpace($VisualStudioPath)) {
    $env:GYP_MSVS_OVERRIDE_PATH = Resolve-UnresolvedPath $VisualStudioPath
  }
  if (-not [string]::IsNullOrWhiteSpace($MsvcToolsetVersion)) {
    $env:VCToolsVersion = $MsvcToolsetVersion
  }
  if (-not [string]::IsNullOrWhiteSpace($WindowsSdkPath)) {
    $env:WINDOWSSDKDIR = Resolve-UnresolvedPath $WindowsSdkPath
  }
}

function Assert-MsvcToolsetVersion {
  param(
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][string]$VisualStudioPath
  )

  $visualStudio = Resolve-UnresolvedPath $VisualStudioPath
  $version = [string]$Lock.hostBaseline.msvcToolsetVersion
  if ([string]::IsNullOrWhiteSpace($version)) {
    throw 'engine.lock.json does not pin an MSVC toolset version.'
  }
  $toolset = Join-Path $visualStudio "VC\Tools\MSVC\$version"
  $cl = Join-Path $toolset 'bin\Hostx64\x64\cl.exe'
  $requiredPaths = @(
    (Join-Path $toolset 'include'),
    (Join-Path $toolset 'lib\x64'),
    (Join-Path $toolset 'atlmfc\include\atlbase.h'),
    (Join-Path $toolset 'atlmfc\lib\x64\atls.lib'),
    $cl,
    (Join-Path $toolset 'bin\Hostx64\x64\link.exe')
  )
  $missing = @($requiredPaths | Where-Object {
      -not (Test-Path -LiteralPath $_)
    })
  if ($missing.Count -ne 0) {
    throw "The pinned Engine requires MSVC $version. Missing:`n$($missing -join [Environment]::NewLine)"
  }
  $compilerVersion = (Get-Item -LiteralPath $cl).VersionInfo.FileVersion
  if ($compilerVersion -ne [string]$Lock.hostBaseline.msvcCompilerVersion) {
    throw "MSVC compiler version mismatch. Expected $($Lock.hostBaseline.msvcCompilerVersion), got $compilerVersion."
  }
}

function Assert-WindowsSdkVersion {
  param(
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][string]$WindowsSdkPath
  )

  $sdkRoot = Resolve-UnresolvedPath $WindowsSdkPath
  $version = [string]$Lock.hostBaseline.engineBuildWindowsSdkVersion
  $requiredPaths = @(
    (Join-Path $sdkRoot "Include\$version\um"),
    (Join-Path $sdkRoot "Include\$version\ucrt"),
    (Join-Path $sdkRoot "Lib\$version\um\x64"),
    (Join-Path $sdkRoot "Lib\$version\ucrt\x64"),
    (Join-Path $sdkRoot "bin\$version\x64")
  )
  $missing = @($requiredPaths | Where-Object {
      -not (Test-Path -LiteralPath $_ -PathType Container)
    })
  if ($missing.Count -ne 0) {
    throw "The pinned Engine requires Windows SDK $version. Missing:`n$($missing -join [Environment]::NewLine)"
  }
}

function Assert-WindowsAppDpiAwarenessDisabled {
  param(
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string]$WindowsSdkPath
  )

  $executablePath = Resolve-UnresolvedPath $Executable
  if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw "Windows App executable is missing: $executablePath"
  }
  $sdkRoot = Resolve-UnresolvedPath $WindowsSdkPath
  $sdkVersion = [string]$Lock.hostBaseline.engineBuildWindowsSdkVersion
  $manifestTool = Join-Path $sdkRoot "bin\$sdkVersion\x64\mt.exe"
  if (-not (Test-Path -LiteralPath $manifestTool -PathType Leaf)) {
    throw "The pinned Windows manifest tool is missing: $manifestTool"
  }

  $manifestPath = Join-Path ([IO.Path]::GetTempPath()) `
    "kirakara-app-manifest-$([Guid]::NewGuid().ToString('N')).xml"
  try {
    $arguments = @(
      '-nologo',
      "-inputresource:$executablePath;#1",
      "-out:$manifestPath"
    )
    $output = @(& $manifestTool @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
      throw "Could not extract the Windows App manifest from $executablePath.`n$($output -join [Environment]::NewLine)"
    }
    [xml]$manifest = Get-Content -Raw -LiteralPath $manifestPath
    $dpiAwareness = $manifest.SelectSingleNode(
      "//*[local-name()='dpiAwareness']"
    )
    if ($null -eq $dpiAwareness) {
      throw "Windows App manifest has no dpiAwareness element: $executablePath"
    }
    $value = $dpiAwareness.InnerText.Trim()
    if ($value -cne 'false') {
      throw "Windows App manifest must disable DPI awareness with 'false', got '$value': $executablePath"
    }
  } finally {
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
      Remove-Item -LiteralPath $manifestPath -Force
    }
  }
}

function Assert-VisualStudioVersion {
  param(
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][string]$VisualStudioPath
  )

  $installPath = Resolve-UnresolvedPath $VisualStudioPath
  if (-not (Test-Path -LiteralPath $installPath -PathType Container)) {
    throw "Visual Studio installation is missing: $installPath"
  }
  $vswhere = Join-Path ${env:ProgramFiles(x86)} `
    'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "Visual Studio Installer is missing vswhere.exe: $vswhere"
  }

  $versionOutput = @(& $vswhere `
      -path $installPath -property installationVersion)
  $versionExitCode = $LASTEXITCODE
  $version = ($versionOutput | Select-Object -First 1).Trim()
  if ($versionExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($version)) {
    throw "Cannot identify Visual Studio installation: $installPath"
  }
  if ($version -ne [string]$Lock.hostBaseline.visualStudioVersion) {
    throw "Visual Studio version mismatch. Expected $($Lock.hostBaseline.visualStudioVersion), got $version."
  }

  $productOutput = @(& $vswhere -path $installPath -property displayName)
  $productExitCode = $LASTEXITCODE
  $product = ($productOutput | Select-Object -First 1).Trim()
  if ($productExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($product)) {
    throw "Cannot identify Visual Studio product: $installPath"
  }
  if ($product -ne [string]$Lock.hostBaseline.visualStudioProduct) {
    throw "Visual Studio product mismatch. Expected $($Lock.hostBaseline.visualStudioProduct), got $product."
  }
}
