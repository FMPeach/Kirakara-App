[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$WorkspaceRoot,

  [string]$FlutterSdkRoot,

  [ValidateSet('debug', 'profile', 'release')]
  [string[]]$Mode = @('debug', 'profile', 'release'),

  [ValidateSet('stock', 'patched')]
  [string]$Variant = 'stock',

  [string]$ReportPath,

  [switch]$RequireLockedHashes,

  [switch]$CaptureArtifactHashes
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if ($RequireLockedHashes -and $CaptureArtifactHashes) {
  throw '-RequireLockedHashes and -CaptureArtifactHashes cannot be combined.'
}

function Get-CoffExportNames {
  param(
    [Parameter(Mandatory = $true)][string]$ToolPath,
    [Parameter(Mandatory = $true)][string]$DllPath
  )

  $output = @(& $ToolPath --coff-exports $DllPath)
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    throw "Could not read PE exports from '$DllPath'. Exit code: $exitCode"
  }
  return @($output | ForEach-Object {
      if ($_ -match '^\s*Name: (.+)$') {
        $Matches[1]
      }
    } | Sort-Object)
}

function Get-CoffLinkerVersion {
  param(
    [Parameter(Mandatory = $true)][string]$ToolPath,
    [Parameter(Mandatory = $true)][string]$DllPath
  )

  $output = @(& $ToolPath --file-headers $DllPath)
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    throw "Could not read PE headers from '$DllPath'. Exit code: $exitCode"
  }
  $majorMatches = @($output | Where-Object {
      $_ -match '^\s*MajorLinkerVersion:\s+(\d+)\s*$'
    } | ForEach-Object { $Matches[1] })
  $minorMatches = @($output | Where-Object {
      $_ -match '^\s*MinorLinkerVersion:\s+(\d+)\s*$'
    } | ForEach-Object { $Matches[1] })
  if ($majorMatches.Count -ne 1 -or $minorMatches.Count -ne 1) {
    throw "Could not identify the PE linker version in '$DllPath'."
  }
  return "$($majorMatches[0]).$($minorMatches[0])"
}

$lock = Get-EngineLock
$layout = Get-EngineWorkspaceLayout $WorkspaceRoot
Assert-ExternalEngineWorkspace $layout
if ($Variant -eq 'stock') {
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
Assert-PinnedDepotTools -Lock $lock -Layout $layout -RequireCleanTree

$flutterRoot = $null
$llvmReadObj = $null
if (-not [string]::IsNullOrWhiteSpace($FlutterSdkRoot)) {
  $flutterRoot = Resolve-UnresolvedPath $FlutterSdkRoot
  if (-not (Test-Path -LiteralPath (Join-Path $flutterRoot 'bin\flutter.bat') -PathType Leaf)) {
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
  $llvmReadObj = Join-Path $layout.EngineSource `
    'flutter\buildtools\windows-x64\clang\bin\llvm-readobj.exe'
  if (-not (Test-Path -LiteralPath $llvmReadObj -PathType Leaf)) {
    throw "Pinned Engine toolchain is missing llvm-readobj.exe: $llvmReadObj"
  }
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $ReportPath = Join-Path (Get-AppRepositoryRoot) `
    "build\diagnostics\engine\$Variant-engine-$stamp.json"
}
$absoluteReport = Resolve-UnresolvedPath $ReportPath
if (Test-Path -LiteralPath $absoluteReport) {
  throw "ReportPath already exists; preserve it or choose another path: $absoluteReport"
}
$reportDirectory = Split-Path -Parent $absoluteReport
New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null

$modeReports = @()
$artifactLockFailures = [System.Collections.Generic.List[string]]::new()
foreach ($buildMode in $Mode) {
  $build = Get-BuildLock `
    -Lock $lock `
    -Mode $buildMode `
    -Variant $Variant
  $output = Get-EngineOutputDirectory `
    -Layout $layout `
    -LocalEngine $build.localEngine
  $argsGn = Join-Path $output 'args.gn'
  $toolchainNinja = Join-Path $output 'toolchain.ninja'
  if (-not (Test-Path -LiteralPath $argsGn -PathType Leaf)) {
    throw "GN output is missing for mode '$buildMode': $argsGn"
  }
  if (-not (Test-Path -LiteralPath $toolchainNinja -PathType Leaf)) {
    throw "GN toolchain is missing for mode '$buildMode': $toolchainNinja"
  }
  $toolchainText = Get-Content -Raw -LiteralPath $toolchainNinja
  # GN emits forward slashes when the output directory is outside the Engine
  # source tree. Normalize separators before checking the pinned MSVC path so
  # the repository-local layout is held to the same toolset gate.
  $normalizedToolchainText = $toolchainText.Replace('/', '\')
  $msvcMarker = "\VC\Tools\MSVC\$($lock.hostBaseline.msvcToolsetVersion)\"
  if ($normalizedToolchainText.IndexOf(
      $msvcMarker,
      [System.StringComparison]::OrdinalIgnoreCase
    ) -lt 0) {
    throw "GN toolchain does not use pinned MSVC $($lock.hostBaseline.msvcToolsetVersion) for '$buildMode'."
  }
  $argsText = Get-Content -Raw -LiteralPath $argsGn
  $runtimePattern = '(?m)^flutter_runtime_mode\s*=\s*"{0}"\s*$' -f `
    [regex]::Escape($buildMode)
  if ($argsText -notmatch $runtimePattern) {
    throw "args.gn flutter_runtime_mode mismatch for '$buildMode': $argsGn"
  }
  if ($argsText -notmatch '(?m)^is_official_build\s*=\s*true\s*$') {
    throw "args.gn is not an official Engine build for '$buildMode': $argsGn"
  }
  if ($argsText -notmatch '(?m)^stripped_symbols\s*=\s*false\s*$') {
    throw "args.gn unexpectedly strips symbols for '$buildMode': $argsGn"
  }
  $engineRevisionPattern = '(?m)^engine_version\s*=\s*"{0}"\s*$' -f `
    [regex]::Escape([string]$lock.flutter.engineRevision)
  if ($argsText -notmatch $engineRevisionPattern) {
    throw "args.gn Engine revision mismatch for '$buildMode': $argsGn"
  }
  $contentHashPattern = '(?m)^content_hash\s*=\s*"{0}"\s*$' -f `
    [regex]::Escape([string]$lock.flutter.engineContentHash)
  if ($argsText -notmatch $contentHashPattern) {
    throw "args.gn Engine content hash mismatch for '$buildMode': $argsGn"
  }
  if ($lock.target.os -ne 'windows') {
    throw "Unsupported locked Engine target OS: $($lock.target.os)"
  }
  $targetOsPattern = '(?m)^target_os\s*=\s*"win"\s*$'
  if ($argsText -notmatch $targetOsPattern) {
    throw "args.gn target OS mismatch for '$buildMode': $argsGn"
  }
  $targetCpuPattern = '(?m)^target_cpu\s*=\s*"{0}"\s*$' -f `
    [regex]::Escape([string]$lock.target.architecture)
  if ($argsText -notmatch $targetCpuPattern) {
    throw "args.gn target architecture mismatch for '$buildMode': $argsGn"
  }
  $argsGnHash = (Get-FileHash -LiteralPath $argsGn -Algorithm SHA256).Hash
  $lockedArgsGnHash = [string]$build.argsGnSha256
  if (-not [string]::IsNullOrWhiteSpace($lockedArgsGnHash)) {
    if ($argsGnHash -ne $lockedArgsGnHash) {
      throw "args.gn hash mismatch for '$buildMode'. Expected $lockedArgsGnHash, got $argsGnHash."
    }
  } elseif ($RequireLockedHashes) {
    throw "Build has no locked args.gn hash yet: $buildMode"
  }

  $artifactReports = @()
  foreach ($artifact in $build.artifacts) {
    $artifactPath = Join-Path $output $artifact.path
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
      throw "Required Engine artifact is missing: $artifactPath"
    }
    $item = Get-Item -LiteralPath $artifactPath
    $hash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash
    $lockedHash = [string]$artifact.sha256
    $lockedSize = $artifact.size
    $hashMatchesLock = $null
    $sizeMatchesLock = $null
    if (-not [string]::IsNullOrWhiteSpace($lockedHash)) {
      $hashMatchesLock = $hash -eq $lockedHash
      $sizeMatchesLock = [long]$item.Length -eq [long]$lockedSize
      if (-not $hashMatchesLock) {
        $artifactLockFailures.Add(
          "Artifact hash mismatch for $buildMode/$($artifact.path). Expected $lockedHash, got $hash."
        )
      }
      if (-not $sizeMatchesLock) {
        $artifactLockFailures.Add(
          "Artifact size mismatch for $buildMode/$($artifact.path). Expected $lockedSize, got $($item.Length)."
        )
      }
    } elseif ($RequireLockedHashes) {
      $artifactLockFailures.Add(
        "Artifact has no locked hash yet: $buildMode/$($artifact.path)"
      )
    }
    $artifactReports += [ordered]@{
      path = $artifact.path
      size = [long]$item.Length
      sha256 = $hash
      locked = -not [string]::IsNullOrWhiteSpace($lockedHash)
      lockedSize = $lockedSize
      lockedSha256 = $lockedHash
      sizeMatchesLock = $sizeMatchesLock
      hashMatchesLock = $hashMatchesLock
    }
  }

  $officialComparison = $null
  if ($null -ne $flutterRoot) {
    $officialDirectoryName = switch ($buildMode) {
      'debug' { 'windows-x64' }
      'profile' { 'windows-x64-profile' }
      'release' { 'windows-x64-release' }
    }
    $officialDll = Join-Path $flutterRoot `
      "bin\cache\artifacts\engine\$officialDirectoryName\flutter_windows.dll"
    if (-not (Test-Path -LiteralPath $officialDll -PathType Leaf)) {
      throw "Official Flutter Engine DLL is missing: $officialDll"
    }
    $localDll = Join-Path $output 'flutter_windows.dll'
    $expectedLinkerVersion = [string]$lock.hostBaseline.peLinkerVersion
    $officialLinkerVersion = Get-CoffLinkerVersion `
      -ToolPath $llvmReadObj -DllPath $officialDll
    $localLinkerVersion = Get-CoffLinkerVersion `
      -ToolPath $llvmReadObj -DllPath $localDll
    if ($officialLinkerVersion -ne $expectedLinkerVersion) {
      throw "Official '$buildMode' Engine PE linker version mismatch. Expected $expectedLinkerVersion, got $officialLinkerVersion."
    }
    if ($localLinkerVersion -ne $expectedLinkerVersion) {
      throw "Local '$buildMode' Engine PE linker version mismatch. Expected $expectedLinkerVersion, got $localLinkerVersion."
    }
    $officialExports = @(Get-CoffExportNames `
        -ToolPath $llvmReadObj -DllPath $officialDll)
    $localExports = @(Get-CoffExportNames `
        -ToolPath $llvmReadObj -DllPath $localDll)
    $expectedAdditionalExports = if ($Variant -eq 'patched') {
      @($lock.patchset.additionalExports | Sort-Object)
    } else {
      @()
    }
    $missingOfficialExports = @(
      $officialExports | Where-Object { $localExports -notcontains $_ }
    )
    $additionalLocalExports = @(
      $localExports | Where-Object { $officialExports -notcontains $_ }
    )
    $missingExpectedExports = @(
      $expectedAdditionalExports |
        Where-Object { $additionalLocalExports -notcontains $_ }
    )
    $unexpectedAdditionalExports = @(
      $additionalLocalExports |
        Where-Object { $expectedAdditionalExports -notcontains $_ }
    )
    if (
      $missingOfficialExports.Count -ne 0 -or
      $missingExpectedExports.Count -ne 0 -or
      $unexpectedAdditionalExports.Count -ne 0
    ) {
      $summary = [ordered]@{
        missingOfficialExports = $missingOfficialExports
        missingExpectedExports = $missingExpectedExports
        unexpectedAdditionalExports = $unexpectedAdditionalExports
      } | ConvertTo-Json -Depth 3
      throw "Public export mismatch for '$Variant/$buildMode':`n$summary"
    }
    $officialItem = Get-Item -LiteralPath $officialDll
    $officialComparison = [ordered]@{
      officialDll = $officialDll
      officialSize = [long]$officialItem.Length
      officialSha256 = (
        Get-FileHash -LiteralPath $officialDll -Algorithm SHA256
      ).Hash
      officialExportCount = $officialExports.Count
      localExportCount = $localExports.Count
      expectedAdditionalExports = @($expectedAdditionalExports)
      additionalLocalExports = $additionalLocalExports
      missingOfficialExports = $missingOfficialExports
      missingExpectedExports = $missingExpectedExports
      unexpectedAdditionalExports = $unexpectedAdditionalExports
      officialLinkerVersion = $officialLinkerVersion
      localLinkerVersion = $localLinkerVersion
    }
  }

  $modeReports += [ordered]@{
    mode = $buildMode
    localEngine = $build.localEngine
    output = $output
    argsGnSha256 = $argsGnHash
    artifacts = $artifactReports
    officialComparison = $officialComparison
  }
}

$report = [ordered]@{
  schemaVersion = 2
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  variant = $Variant
  flutterFrameworkRevision = $lock.flutter.frameworkRevision
  engineRevision = Get-GitHead $layout.FlutterCheckout
  engineSourceTree = Get-GitTree $layout.FlutterCheckout
  engineSourceSnapshotTree = if ($Variant -eq 'stock') {
    Get-GitTree $layout.FlutterCheckout
  } elseif ($layout.Kind -eq 'repository-local') {
    [string]$lock.projectBootstrap.engineSourceTree
  } else {
    [string]$lock.patchset.sourceTree
  }
  engineSourceTreeClean = $Variant -eq 'stock'
  engineSourceMatchesVariant = $true
  engineContentHash = $lock.flutter.engineContentHash
  depotToolsRevision = Get-GitHead $layout.DepotTools
  depotToolsTreeClean = $true
  patchsetRevision = if ($Variant -eq 'stock') {
    'stock'
  } else {
    $lock.patchset.revision
  }
  patchsetVersion = if ($Variant -eq 'stock') {
    0
  } else {
    $lock.patchset.version
  }
  msvcToolsetVersion = $lock.hostBaseline.msvcToolsetVersion
  peLinkerVersion = $lock.hostBaseline.peLinkerVersion
  captureArtifactHashes = [bool]$CaptureArtifactHashes
  lockedArtifactsMatch = $artifactLockFailures.Count -eq 0
  artifactLockFailures = @($artifactLockFailures)
  modes = $modeReports
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $absoluteReport -Encoding utf8
Write-Host "Engine verification report saved to $absoluteReport"

if ($artifactLockFailures.Count -gt 0) {
  $summary = $artifactLockFailures -join [Environment]::NewLine
  if ($CaptureArtifactHashes) {
    Write-Warning (
      "Captured artifact hashes differ from engine.lock.json. " +
      "The lock was not modified:`n$summary"
    )
  } else {
    throw "Engine artifacts do not match engine.lock.json. See $absoluteReport`n$summary"
  }
}
