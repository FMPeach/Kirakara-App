[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$WorkspaceRoot,

  [string]$ProxyUrl,

  [string]$DepotToolsArchivePath,

  [string]$VisualStudioPath,

  [string]$WindowsSdkPath = 'C:\Program Files (x86)\Windows Kits\10',

  [switch]$SkipSync
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$lock = Get-EngineLock
$layout = Get-EngineWorkspaceLayout $WorkspaceRoot
Assert-ExternalEngineWorkspace $layout
Assert-RepositoryEngineWriteWorkspace $layout

New-Item -ItemType Directory -Path $layout.Root -Force | Out-Null
Set-EngineProcessEnvironment `
  -Layout $layout `
  -ProxyUrl $ProxyUrl `
  -VisualStudioPath $VisualStudioPath `
  -MsvcToolsetVersion $lock.hostBaseline.msvcToolsetVersion `
  -WindowsSdkPath $WindowsSdkPath

if ($layout.Kind -in @('repository-local','repository-stock')) {
  $null = Repair-InterruptedManagedGitCheckout `
    -Path $layout.DepotTools `
    -ManagedRoot $layout.Root `
    -Repository ([string]$lock.depotTools.repository) `
    -Revision ([string]$lock.depotTools.revision) `
    -Label 'depot_tools'
  $null = Repair-InterruptedManagedGitCheckout `
    -Path $layout.FlutterCheckout `
    -ManagedRoot $layout.Root `
    -Repository ([string]$lock.flutter.repository) `
    -Revision ([string]$lock.flutter.engineRevision) `
    -Label 'Flutter Engine source'
}

if (-not (Test-Path -LiteralPath $layout.DepotTools)) {
  if (-not [string]::IsNullOrWhiteSpace($DepotToolsArchivePath)) {
    $archive = Resolve-UnresolvedPath $DepotToolsArchivePath
    $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ($archiveHash -ne $lock.depotTools.archiveSha256) {
      throw "depot_tools archive hash mismatch. Expected $($lock.depotTools.archiveSha256), got $archiveHash."
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $layout.DepotTools
  } else {
    Invoke-CheckedNative git @(
      'clone', '--filter=blob:none', '--no-checkout',
      $lock.depotTools.repository, $layout.DepotTools
    ) 'Could not clone depot_tools. Use -DepotToolsArchivePath with the locked official archive if needed.'
    Invoke-CheckedNative git @(
      '-C', $layout.DepotTools, 'checkout', '--detach',
      $lock.depotTools.revision
    ) 'Could not check out the locked depot_tools revision.'
  }
}

Assert-PinnedDepotTools -Lock $lock -Layout $layout -RequireCleanTree

$gitWrapper = Join-Path $layout.DepotTools 'git.bat'
if (-not (Test-Path -LiteralPath $gitWrapper -PathType Leaf)) {
  Invoke-CheckedNative (Join-Path $layout.DepotTools 'cipd_bin_setup.bat') @() `
    'Could not bootstrap the depot_tools CIPD client.'
  Invoke-CheckedNative (Join-Path $layout.DepotTools 'bootstrap\win_tools.bat') @() `
    'Could not bootstrap depot_tools Windows wrappers.'
}

if (-not (Test-Path -LiteralPath $layout.FlutterCheckout)) {
  Invoke-CheckedNative git @(
    'clone', '--filter=blob:none', '--no-checkout',
    $lock.flutter.repository, $layout.FlutterCheckout
  ) 'Could not clone Flutter source.'
  Invoke-CheckedNative git @(
    '-C', $layout.FlutterCheckout, 'fetch', '--depth=1', 'origin',
    $lock.flutter.engineRevision
  ) 'Could not fetch the locked Engine revision.'
  Invoke-CheckedNative git @(
    '-C', $layout.FlutterCheckout, 'checkout', '--detach',
    $lock.flutter.engineRevision
  ) 'Could not check out the locked Engine revision.'
}

Assert-PinnedFlutterBootstrap -Lock $lock -Layout $layout

$gclientSource = Join-Path $layout.FlutterCheckout $lock.gclient.configuration
$gclientTarget = Join-Path $layout.FlutterCheckout '.gclient'
$sourceHash = (Get-FileHash -LiteralPath $gclientSource -Algorithm SHA256).Hash
if ($sourceHash -ne $lock.gclient.configurationSha256) {
  throw "Locked standard.gclient hash mismatch. Expected $($lock.gclient.configurationSha256), got $sourceHash."
}
if (-not (Test-Path -LiteralPath $gclientTarget -PathType Leaf)) {
  Copy-Item -LiteralPath $gclientSource -Destination $gclientTarget
}
$targetHash = (Get-FileHash -LiteralPath $gclientTarget -Algorithm SHA256).Hash
if ($targetHash -ne $sourceHash) {
  throw "Existing .gclient differs from the locked standard.gclient: $gclientTarget"
}

if (-not $SkipSync) {
  Push-Location $layout.FlutterCheckout
  try {
    Invoke-CheckedNative (Join-Path $layout.DepotTools 'gclient.bat') `
      @($lock.gclient.syncArguments) 'gclient sync failed.'
  } finally {
    Pop-Location
  }
}

Assert-PinnedFlutterSource -Lock $lock -Layout $layout -RequireStockTree
Assert-PinnedDepotTools -Lock $lock -Layout $layout -RequireCleanTree
Write-Host "Pinned stock Engine source is ready: $($layout.FlutterCheckout)"
Write-Host "Engine revision: $($lock.flutter.engineRevision)"
Write-Host "Patchset: $($lock.patchset.revision) v$($lock.patchset.version)"
