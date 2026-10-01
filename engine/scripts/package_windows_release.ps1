[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$FlutterSdkRoot,

  [Parameter(Mandatory = $true)]
  [string]$WorkspaceRoot,

  [string]$ShowHostDll,

  [string]$OutputDirectory,

  [string]$WindowsSdkPath = 'C:\Program Files (x86)\Windows Kits\10',

  [switch]$SkipRuntimeSmoke
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'release_contract.ps1')
Import-Module (Join-Path $PSScriptRoot 'show_host_input.psm1') `
  -DisableNameChecking

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-DeterministicZip {
  param(
    [Parameter(Mandatory = $true)][string]$SourceDirectory,
    [Parameter(Mandatory = $true)][string]$DestinationPath,
    [Parameter(Mandatory = $true)][string]$EntryPrefix
  )

  if (Test-Path -LiteralPath $DestinationPath) {
    throw "Archive already exists; preserve it or select another output directory: $DestinationPath"
  }
  $source = (Resolve-Path -LiteralPath $SourceDirectory).Path
  $destinationParent = Split-Path -Parent $DestinationPath
  New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
  $stream = [IO.File]::Open(
    $DestinationPath,
    [IO.FileMode]::CreateNew,
    [IO.FileAccess]::ReadWrite,
    [IO.FileShare]::None)
  try {
    $archive = [IO.Compression.ZipArchive]::new(
      $stream,
      [IO.Compression.ZipArchiveMode]::Create,
      $false)
    try {
      $fixedTimestamp = [DateTimeOffset]::new(
        2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
      $files = Get-ChildItem -LiteralPath $source -File -Recurse | Sort-Object {
        [IO.Path]::GetRelativePath($source, $_.FullName)
      }
      foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($source, $file.FullName).Replace('\', '/')
        $entryName = ($EntryPrefix.Trim('/') + '/' + $relative).TrimStart('/')
        $entry = $archive.CreateEntry(
          $entryName,
          [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = $fixedTimestamp
        $input = [IO.File]::OpenRead($file.FullName)
        try {
          $output = $entry.Open()
          try {
            $input.CopyTo($output)
          } finally {
            $output.Dispose()
          }
        } finally {
          $input.Dispose()
        }
      }
    } finally {
      $archive.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
}

function Copy-RelativeFile {
  param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$DestinationRoot
  )

  $relative = [IO.Path]::GetRelativePath($SourceRoot, $SourcePath)
  if ([IO.Path]::IsPathRooted($relative) -or $relative.StartsWith('..')) {
    throw "Source file escapes its root: $SourcePath"
  }
  $destination = Join-Path $DestinationRoot $relative
  New-Item -ItemType Directory -Path (Split-Path -Parent $destination) `
    -Force | Out-Null
  Copy-Item -LiteralPath $SourcePath -Destination $destination
  return $relative
}

function Remove-VerifiedTemporaryDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ExpectedParent,
    [Parameter(Mandatory = $true)][string]$RequiredLeafPrefix
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }
  $resolved = (Resolve-Path -LiteralPath $Path).Path
  $parent = Split-Path -Parent $resolved
  $leaf = Split-Path -Leaf $resolved
  if (
    $parent -ne $ExpectedParent -or
    -not $leaf.StartsWith($RequiredLeafPrefix, [StringComparison]::Ordinal)
  ) {
    throw "Refusing to clean unexpected temporary directory: $resolved"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}

$repository = Get-AppRepositoryRoot
$lock = Get-EngineLock
$flutterRoot = Resolve-UnresolvedPath $FlutterSdkRoot
$showHost = Resolve-KirakaraShowHostInput -Path $ShowHostDll
$showDll = $showHost.path
$showAbi = [pscustomobject]@{
  dllSha256 = [string]$showHost.sha256
  dllSize = [int64]$showHost.size
  abiVersion = [uint32]$showHost.abiVersion
  capabilities = [uint64]$showHost.capabilities
  protocolRevision = [string]$showHost.protocolRevision
}
$layout = Get-EngineWorkspaceLayout $WorkspaceRoot
Assert-ExternalEngineWorkspace $layout
Assert-AppliedPatchset -Lock $lock -Layout $layout
Assert-MatchingTextFile `
  -ExpectedPath (Join-Path $layout.EngineSource `
    'flutter\shell\platform\windows\kirakara_flutter_compositor_api.h') `
  -ActualPath (Join-Path $repository `
    'engine\include\kirakara_flutter_compositor_api.h') `
  -Label 'Kirakara compositor ABI header'

$build = Get-BuildLock -Lock $lock -Mode release -Variant patched
$artifactContract = Get-KirakaraReleaseArtifactContract `
  -Lock $lock `
  -Layout $layout `
  -Build $build
$engineDirectory = Get-EngineOutputDirectory `
  -Layout $layout `
  -LocalEngine $build.localEngine
Assert-LockedEngineArtifacts `
  -Build $artifactContract `
  -OutputDirectory $engineDirectory

$bundle = Join-Path $repository 'build\windows\x64\runner\Release'
if (-not (Test-Path -LiteralPath $bundle -PathType Container)) {
  throw "Release bundle is missing: $bundle"
}
$bundle = (Resolve-Path -LiteralPath $bundle).Path
$executable = Join-Path $bundle 'kirakara_app.exe'
Assert-MatchingFile `
  -ExpectedPath (Join-Path $engineDirectory 'flutter_windows.dll') `
  -ActualPath (Join-Path $bundle 'flutter_windows.dll') `
  -Label 'Release flutter_windows.dll'
Assert-MatchingFile `
  -ExpectedPath (Join-Path $engineDirectory 'icudtl.dat') `
  -ActualPath (Join-Path $bundle 'data\icudtl.dat') `
  -Label 'Release icudtl.dat'
Assert-MatchingFile `
  -ExpectedPath $showDll `
  -ActualPath (Join-Path $bundle 'libshow_host.dll') `
  -Label 'Release Show host DLL'
Assert-WindowsAppDpiAwarenessDisabled `
  -Lock $lock `
  -Executable $executable `
  -WindowsSdkPath $WindowsSdkPath

$pubspec = Get-Content -Raw -LiteralPath (Join-Path $repository 'pubspec.yaml')
if ($pubspec -notmatch '(?m)^version:\s*([^\s]+)\s*$') {
  throw 'pubspec.yaml does not contain a version.'
}
$version = $Matches[1]
$head = Get-GitHead $repository
$shortHead = $head.Substring(0, 12)
$branch = (& git -C $repository branch --show-current).Trim()
if ($LASTEXITCODE -ne 0) {
  throw 'Could not read the App branch.'
}
$statusLines = @(& git -C $repository status --porcelain=v1)
if ($LASTEXITCODE -ne 0) {
  throw 'Could not read the App worktree status.'
}
$dirty = $statusLines.Count -ne 0
$stateSuffix = if ($dirty) { '-dirty' } else { '' }
$packageId = "kirakara-app-$version-windows-x64-engine-v$($lock.patchset.version)-$shortHead$stateSuffix"

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $OutputDirectory = Join-Path $repository 'build\releases'
}
$output = Resolve-UnresolvedPath $OutputDirectory
New-Item -ItemType Directory -Path $output -Force | Out-Null
$output = (Resolve-Path -LiteralPath $output).Path
$smokeReportDirectory = Join-Path $output 'diagnostics'
$staging = Join-Path $output ".staging-$([Guid]::NewGuid().ToString('N'))"
$verification = Join-Path $output ".verify-$([Guid]::NewGuid().ToString('N'))"
$portableRoot = Join-Path $staging $packageId
$installerName = "$packageId-installer"
$installerRoot = Join-Path $staging $installerName
$sourceName = "$packageId-patch-source"
$sourceRoot = Join-Path $staging $sourceName
$portableArchive = Join-Path $output "$packageId-portable.zip"
$installerArchive = Join-Path $output "$installerName.zip"
$sourceArchive = Join-Path $output "$sourceName.zip"
$engineArtifactsName = "$packageId-engine-artifacts"
$engineArtifactsRoot = Join-Path $staging $engineArtifactsName
$engineArchive = Join-Path $output "$engineArtifactsName.zip"
$releaseIndexPath = Join-Path $output "$packageId-release-index.json"

foreach ($path in $portableArchive, $installerArchive, $sourceArchive,
    $engineArchive, $releaseIndexPath) {
  if (Test-Path -LiteralPath $path) {
    throw "Release artifact already exists; preserve it or choose another output directory: $path"
  }
}

try {
  New-Item -ItemType Directory `
    -Path $portableRoot, $installerRoot, $sourceRoot, $engineArtifactsRoot `
    -Force | Out-Null

  $installManifest = Join-Path $repository 'build\windows\x64\install_manifest.txt'
  if (-not (Test-Path -LiteralPath $installManifest -PathType Leaf)) {
    throw "CMake install manifest is missing: $installManifest"
  }
  $selected = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
  $runnerRoot = Join-Path $repository 'build\windows\x64\runner'
  $runnerRoot = [IO.Path]::GetFullPath($runnerRoot)
  $runnerPrefix = $runnerRoot.TrimEnd('\') + '\'
  foreach ($manifestEntry in Get-Content -LiteralPath $installManifest) {
    $manifestPath = [IO.Path]::GetFullPath($manifestEntry)
    if (-not $manifestPath.StartsWith(
        $runnerPrefix,
        [StringComparison]::OrdinalIgnoreCase)) {
      continue
    }
    $runnerRelative = [IO.Path]::GetRelativePath($runnerRoot, $manifestPath)
    $segments = $runnerRelative.Split([IO.Path]::DirectorySeparatorChar)
    if (
      $segments.Count -lt 2 -or
      $segments[0] -notin 'Debug', 'Profile', 'Release'
    ) {
      continue
    }
    $configurationRelative = [string]::Join(
      [IO.Path]::DirectorySeparatorChar,
      [string[]]$segments[1..($segments.Count - 1)])
    $releaseCandidate = Join-Path $bundle $configurationRelative
    if (Test-Path -LiteralPath $releaseCandidate -PathType Leaf) {
      $null = $selected.Add($releaseCandidate)
    }
  }
  foreach ($runtimeDirectoryName in 'data', 'ime') {
    $runtimeDirectory = Join-Path $bundle $runtimeDirectoryName
    if (-not (Test-Path -LiteralPath $runtimeDirectory -PathType Container)) {
      throw "Release runtime directory is missing: $runtimeDirectoryName"
    }
    foreach ($runtimeFile in Get-ChildItem -LiteralPath $runtimeDirectory -File -Recurse) {
      $null = $selected.Add($runtimeFile.FullName)
    }
  }
  foreach ($topLevelFile in Get-ChildItem -LiteralPath $bundle -File) {
    if ($topLevelFile.Extension -in '.exe', '.dll', '.json') {
      $null = $selected.Add($topLevelFile.FullName)
    }
  }

  foreach ($required in 'kirakara_app.exe', 'flutter_windows.dll', 'libshow_host.dll',
      'data\app.so', 'data\icudtl.dat', 'data\flutter_assets\NOTICES.Z') {
    $requiredPath = Join-Path $bundle $required
    if (-not $selected.Contains($requiredPath)) {
      throw "Release selection is missing required file: $required"
    }
  }

  $allBundleFiles = Get-ChildItem -LiteralPath $bundle -File -Recurse
  $unexpected = @()
  foreach ($file in $allBundleFiles) {
    if ($selected.Contains($file.FullName)) {
      continue
    }
    $relative = [IO.Path]::GetRelativePath($bundle, $file.FullName)
    if (
      $relative.StartsWith('settings\', [StringComparison]::OrdinalIgnoreCase) -or
      $file.Extension -in '.log', '.dmp', '.etl'
    ) {
      continue
    }
    $unexpected += $relative
  }
  if ($unexpected.Count -ne 0) {
    throw "Release bundle contains unclassified files: $($unexpected -join ', ')"
  }

  foreach ($sourcePath in @($selected) | Sort-Object) {
    $null = Copy-RelativeFile `
      -SourceRoot $bundle `
      -SourcePath $sourcePath `
      -DestinationRoot $portableRoot
  }

  $runtimeFiles = Get-ChildItem -LiteralPath $portableRoot -File -Recurse | Sort-Object {
    [IO.Path]::GetRelativePath($portableRoot, $_.FullName)
  } | ForEach-Object {
    $relative = [IO.Path]::GetRelativePath($portableRoot, $_.FullName).Replace('\', '/')
    [ordered]@{
      path = $relative
      size = $_.Length
      sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
  }
  [int64]$runtimeBytes = 0
  foreach ($runtimeFile in @($runtimeFiles)) {
    $runtimeBytes += [int64]$runtimeFile['size']
  }
  $releaseManifest = [ordered]@{
    schemaVersion = 1
    productId = 'kirakara-app-windows'
    packageId = $packageId
    version = $version
    target = [ordered]@{ os = 'windows'; architecture = 'x64'; mode = 'release' }
    source = [ordered]@{
      branch = $branch
      commit = $head
      dirty = $dirty
    }
    flutter = [ordered]@{
      version = $lock.flutter.version
      frameworkRevision = $lock.flutter.frameworkRevision
      engineRevision = $lock.flutter.engineRevision
    }
    compositor = [ordered]@{
      abiVersion = $lock.patchset.abiVersion
      patchsetVersion = $lock.patchset.version
      patchsetRevision = $lock.patchset.revision
      patches = @($lock.patchset.patches)
      flutterWindowsDllSha256 = (
        Get-FileHash -LiteralPath (Join-Path $portableRoot 'flutter_windows.dll') `
          -Algorithm SHA256).Hash
    }
    showHost = [ordered]@{
      file = 'libshow_host.dll'
      dllSha256 = [string]$showAbi.dllSha256
      dllSize = [int64]$showAbi.dllSize
      stageVisualAbiVersion = [uint32]$showAbi.abiVersion
      capabilities = [uint64]$showAbi.capabilities
      protocolRevision = [string]$showAbi.protocolRevision
    }
    symbols = [ordered]@{
      includedInRuntimePackage = $false
      file = 'flutter_windows.dll.pdb'
      size = ($artifactContract.artifacts |
          Where-Object path -eq 'flutter_windows.dll.pdb').size
      sha256 = ($artifactContract.artifacts |
          Where-Object path -eq 'flutter_windows.dll.pdb').sha256
    }
    mutableStateExcluded = @('settings/**', '*.log', '*.dmp', '*.etl')
    fileCount = @($runtimeFiles).Count
    totalBytes = $runtimeBytes
    files = @($runtimeFiles)
  }
  $releaseManifest | ConvertTo-Json -Depth 8 | Set-Content `
    -LiteralPath (Join-Path $portableRoot 'release-manifest.json') -Encoding utf8

  $checksumFiles = Get-ChildItem -LiteralPath $portableRoot -File -Recurse | Sort-Object {
    [IO.Path]::GetRelativePath($portableRoot, $_.FullName)
  }
  $checksumLines = foreach ($file in $checksumFiles) {
    $relative = [IO.Path]::GetRelativePath($portableRoot, $file.FullName).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    "$hash *$relative"
  }
  $checksumLines | Set-Content `
    -LiteralPath (Join-Path $portableRoot 'SHA256SUMS.txt') -Encoding ascii

  New-DeterministicZip `
    -SourceDirectory $portableRoot `
    -DestinationPath $portableArchive `
    -EntryPrefix $packageId

  $installerPayload = Join-Path $installerRoot 'payload'
  New-Item -ItemType Directory -Path $installerPayload | Out-Null
  foreach ($item in Get-ChildItem -LiteralPath $portableRoot -Force) {
    Copy-Item -LiteralPath $item.FullName -Destination $installerPayload -Recurse
  }
  Copy-Item `
    -LiteralPath (Join-Path $repository 'engine\packaging\install_windows_portable.ps1') `
    -Destination (Join-Path $installerRoot 'Install-Kirakara.ps1')
  Copy-Item `
    -LiteralPath (Join-Path $repository 'engine\packaging\uninstall_windows_portable.ps1') `
    -Destination (Join-Path $installerRoot 'uninstall_windows_portable.ps1')
  @(
    'Kirakara per-user installer package',
    '',
    'Run in PowerShell:',
    '  .\Install-Kirakara.ps1',
    '',
    'Default destination: %LOCALAPPDATA%\Programs\Kirakara',
    'No administrator privileges are required.',
    'This package is not code-signed; production distribution requires an owner-supplied signing identity.'
  ) | Set-Content -LiteralPath (Join-Path $installerRoot 'README.txt') -Encoding utf8
  New-DeterministicZip `
    -SourceDirectory $installerRoot `
    -DestinationPath $installerArchive `
    -EntryPrefix $installerName

  $sourceCandidates = @()
  foreach ($sourceDirectory in @(
      (Join-Path $repository 'engine'),
      (Join-Path $repository 'docs\windows_compositor'),
      (Join-Path $repository 'docs\windows_clipboard'),
      (Join-Path $repository 'tool\windows_compositor'),
      (Join-Path $repository 'tool\windows_clipboard')
    )) {
    $sourceCandidates += Get-ChildItem -LiteralPath $sourceDirectory -File -Recurse |
      Where-Object {
        $_.FullName -notmatch '[\\/](\.work|artifacts|reports|out)[\\/]' -and
        $_.Extension -in '.ps1', '.psm1', '.patch', '.json', '.md', '.h',
          '.txt', '.gclient', '.cs', '.krl', '.wprp'
      }
  }
  foreach ($relativeSource in @(
      'flutterw.ps1',
      'flutterw.cmd',
      'docs\windows_custom_flutter_compositor_plan.md'
    )) {
    $sourceCandidates += Get-Item -LiteralPath (Join-Path $repository $relativeSource)
  }
  foreach ($sourceFile in $sourceCandidates | Sort-Object FullName -Unique) {
    $null = Copy-RelativeFile `
      -SourceRoot $repository `
      -SourcePath $sourceFile.FullName `
      -DestinationRoot $sourceRoot
  }
  @(
    'Kirakara Windows custom Flutter Engine patch source bundle',
    '',
    "App commit: $head",
    "Worktree dirty while packaged: $dirty",
    "Flutter Framework: $($lock.flutter.frameworkRevision)",
    "Flutter Engine: $($lock.flutter.engineRevision)",
    "Patchset: $($lock.patchset.revision) v$($lock.patchset.version)",
    '',
    'The App repository does not currently declare a project-wide distribution license.',
    'Do not label this candidate as a final public release until the owner supplies one.',
    'Third-party runtime notices remain in data/flutter_assets/NOTICES.Z and ime/**/COPYING*.'
  ) | Set-Content -LiteralPath (Join-Path $sourceRoot 'SOURCE-BUNDLE.txt') -Encoding utf8
  New-DeterministicZip `
    -SourceDirectory $sourceRoot `
    -DestinationPath $sourceArchive `
    -EntryPrefix $sourceName

  $engineArtifactFiles = foreach ($artifact in @($artifactContract.artifacts)) {
    $sourcePath = Join-Path $engineDirectory ([string]$artifact.path)
    $relative = Copy-RelativeFile `
      -SourceRoot $engineDirectory `
      -SourcePath $sourcePath `
      -DestinationRoot $engineArtifactsRoot
    [ordered]@{
      path = $relative.Replace('\', '/')
      size = [int64]$artifact.size
      sha256 = [string]$artifact.sha256
    }
  }
  [ordered]@{
    schemaVersion = 1
    sourceCommit = $head
    engineRevision = $lock.flutter.engineRevision
    patchsetVersion = $lock.patchset.version
    artifactContract = if ($layout.Kind -eq 'repository-local') {
      'projectBootstrap.releaseCandidate'
    } else {
      'patchset.builds.release'
    }
    files = @($engineArtifactFiles)
  } | ConvertTo-Json -Depth 6 | Set-Content `
    -LiteralPath (Join-Path $engineArtifactsRoot 'ENGINE-ARTIFACTS.json') `
    -Encoding utf8
  New-DeterministicZip `
    -SourceDirectory $engineArtifactsRoot `
    -DestinationPath $engineArchive `
    -EntryPrefix $engineArtifactsName

  $portableSmokeReport = $null
  $installerSmokeReport = $null
  if (-not $SkipRuntimeSmoke) {
    New-Item -ItemType Directory -Path $verification | Out-Null
    New-Item -ItemType Directory -Path $smokeReportDirectory -Force | Out-Null

    $portableVerification = Join-Path $verification 'portable'
    Expand-Archive -LiteralPath $portableArchive -DestinationPath $portableVerification
    $portableBundle = Join-Path $portableVerification $packageId
    $portableSmokeReport = Join-Path $smokeReportDirectory `
      "$packageId-portable-smoke.json"
    & (Join-Path $PSScriptRoot 'smoke_windows_app.ps1') `
      -FlutterSdkRoot $flutterRoot `
      -Engine local `
      -LocalVariant patched `
      -WorkspaceRoot $WorkspaceRoot `
      -Mode release `
      -BundlePath $portableBundle `
      -ObserveSeconds 3 `
      -RequireLockedArtifacts `
      -ReportPath $portableSmokeReport

    $installerVerification = Join-Path $verification 'installer'
    Expand-Archive -LiteralPath $installerArchive -DestinationPath $installerVerification
    $installerBundle = Join-Path $installerVerification $installerName
    $installedBundle = Join-Path $verification 'installed-Kirakara'
    & (Join-Path $installerBundle 'Install-Kirakara.ps1') `
      -PayloadPath (Join-Path $installerBundle 'payload') `
      -Destination $installedBundle `
      -NoShortcut
    $installerSmokeReport = Join-Path $smokeReportDirectory `
      "$packageId-installer-smoke.json"
    & (Join-Path $PSScriptRoot 'smoke_windows_app.ps1') `
      -FlutterSdkRoot $flutterRoot `
      -Engine local `
      -LocalVariant patched `
      -WorkspaceRoot $WorkspaceRoot `
      -Mode release `
      -BundlePath $installedBundle `
      -ObserveSeconds 3 `
      -RequireLockedArtifacts `
      -ReportPath $installerSmokeReport
    & (Join-Path $installedBundle 'Uninstall-Kirakara.ps1') `
      -InstallRoot $installedBundle `
      -NoShortcutCleanup
    if (Test-Path -LiteralPath $installedBundle) {
      throw "Installer verification did not remove its exact test installation: $installedBundle"
    }
  }

  $artifacts = foreach ($artifact in $portableArchive, $installerArchive,
      $sourceArchive, $engineArchive) {
    $item = Get-Item -LiteralPath $artifact
    [ordered]@{
      path = [IO.Path]::GetRelativePath($output, $item.FullName).Replace('\', '/')
      size = $item.Length
      sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
    }
  }
  $releaseIndex = [ordered]@{
    schemaVersion = 3
    packageId = $packageId
    sourceCommit = $head
    sourceDirty = $dirty
    runtimeSmokeSkipped = [bool]$SkipRuntimeSmoke
    portableSmokeReport = if ($portableSmokeReport) {
      [IO.Path]::GetRelativePath($output, $portableSmokeReport).Replace('\', '/')
    } else { $null }
    installerSmokeReport = if ($installerSmokeReport) {
      [IO.Path]::GetRelativePath($output, $installerSmokeReport).Replace('\', '/')
    } else { $null }
    productionSigningStatus = 'not-signed-owner-identity-required'
    projectLicenseStatus = 'not-declared-owner-action-required'
    engineArtifactContract = if ($layout.Kind -eq 'repository-local') {
      'projectBootstrap.releaseCandidate'
    } else {
      'patchset.builds.release'
    }
    showHost = [ordered]@{
      dllSha256 = [string]$showAbi.dllSha256
      stageVisualAbiVersion = [uint32]$showAbi.abiVersion
      protocolRevision = [string]$showAbi.protocolRevision
    }
    artifacts = @($artifacts)
    passed = $true
  }
  $releaseIndex | ConvertTo-Json -Depth 6 | Set-Content `
    -LiteralPath $releaseIndexPath -Encoding utf8
} finally {
  Remove-VerifiedTemporaryDirectory `
    -Path $verification `
    -ExpectedParent $output `
    -RequiredLeafPrefix '.verify-'
  Remove-VerifiedTemporaryDirectory `
    -Path $staging `
    -ExpectedParent $output `
    -RequiredLeafPrefix '.staging-'
}

Write-Host "Portable archive: $portableArchive"
Write-Host "Installer archive: $installerArchive"
Write-Host "Patch source archive: $sourceArchive"
Write-Host "Engine artifacts archive: $engineArchive"
Write-Host "Release index: $releaseIndexPath"
