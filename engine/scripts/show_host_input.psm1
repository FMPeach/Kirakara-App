Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$script:DefaultLocalConfigurationPath = Join-Path $script:RepositoryRoot `
  'config/kirakara.local.json'
Import-Module (Join-Path $PSScriptRoot 'artifact_package.psm1') `
  -DisableNameChecking

function Get-KirakaraConfiguredShowHostPath {
  param([string]$ConfigPath)

  if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = $script:DefaultLocalConfigurationPath
  }
  $absoluteConfig = $ExecutionContext.SessionState.Path.
    GetUnresolvedProviderPathFromPSPath($ConfigPath)
  $absoluteConfig = [IO.Path]::GetFullPath($absoluteConfig)
  if (-not (Test-Path -LiteralPath $absoluteConfig)) {
    return $null
  }
  if (-not (Test-Path -LiteralPath $absoluteConfig -PathType Leaf)) {
    throw "Kirakara local configuration is not a file: $absoluteConfig"
  }

  try {
    $configuration = Get-Content -Raw -LiteralPath $absoluteConfig -Encoding utf8 |
      ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "Kirakara local configuration is invalid JSON: $absoluteConfig. $($_.Exception.Message)"
  }
  $schemaProperty = $configuration.PSObject.Properties['schemaVersion']
  if ($null -eq $schemaProperty -or [int]$schemaProperty.Value -ne 1) {
    throw "Kirakara local configuration has an unsupported schemaVersion: $absoluteConfig"
  }
  $windowsProperty = $configuration.PSObject.Properties['windows']
  if ($null -eq $windowsProperty -or $null -eq $windowsProperty.Value) {
    throw "Kirakara local configuration is missing windows.showHostDll: $absoluteConfig"
  }
  $showProperty = $windowsProperty.Value.PSObject.Properties['showHostDll']
  if ($null -eq $showProperty -or
      $showProperty.Value -isnot [string] -or
      [string]::IsNullOrWhiteSpace([string]$showProperty.Value)) {
    throw "Kirakara local configuration is missing windows.showHostDll: $absoluteConfig"
  }
  return [pscustomobject]@{
    path = ([string]$showProperty.Value).Trim()
    configPath = $absoluteConfig
  }
}

function Resolve-KirakaraShowHostInput {
  param(
    [string]$Path,
    [string]$ConfigPath
  )

  $source = 'parameter'
  if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = [Environment]::GetEnvironmentVariable(
      'KIRAKARA_SHOW_HOST_DLL', 'Process')
    $source = 'environment'
  }
  if ([string]::IsNullOrWhiteSpace($Path)) {
    $configured = Get-KirakaraConfiguredShowHostPath -ConfigPath $ConfigPath
    if ($null -ne $configured) {
      $Path = $configured.path
      $source = 'repository-local-config'
    }
  }
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw (
      'Windows run/build requires an existing Kirakara Show Windows x64 ' +
      'DLL. Set KIRAKARA_SHOW_HOST_DLL or copy ' +
      'config/kirakara.local.example.json to config/kirakara.local.json ' +
      'and set windows.showHostDll. App will not search, download, or build Show.')
  }
  if (-not [IO.Path]::IsPathRooted($Path)) {
    throw 'Kirakara Show host DLL must be an absolute path.'
  }

  $providerPath = $ExecutionContext.SessionState.Path.
    GetUnresolvedProviderPathFromPSPath($Path)
  if (-not [IO.Path]::IsPathRooted($providerPath)) {
    throw 'Kirakara Show host DLL must be an absolute path.'
  }
  $absolute = [IO.Path]::GetFullPath($providerPath)
  if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
    throw "Kirakara Show host DLL does not exist: $absolute"
  }
  $absolute = (Resolve-Path -LiteralPath $absolute).Path

  try {
    $pe = [Kirakara.Artifacts.PeReader]::Read($absolute)
  } catch {
    throw "Kirakara Show host input is not a valid Windows x64 PE DLL: $absolute. $($_.Exception.Message)"
  }
  if ($pe.Machine -ne 0x8664 -or -not $pe.IsDll) {
    throw "Kirakara Show host input is not a Windows x64 DLL: $absolute"
  }

  $probe = & (Join-Path $script:RepositoryRoot `
      'engine/scripts/verify_show_host_stage_visual_abi.ps1') `
    -ShowHostDll $absolute
  if (-not $probe.passed) {
    throw 'Kirakara Show Stage Visual ABI validation did not pass.'
  }
  return [pscustomobject]@{
    path = $absolute
    sha256 = [string]$probe.dllSha256
    size = [int64]$probe.dllSize
    abiVersion = [uint32]$probe.abiVersion
    capabilities = [uint64]$probe.capabilities
    protocolRevision = [string]$probe.protocolRevision
    source = $source
  }
}

Export-ModuleMember -Function 'Resolve-KirakaraShowHostInput'
