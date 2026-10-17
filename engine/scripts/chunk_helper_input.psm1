Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $PSScriptRoot 'artifact_package.psm1') -DisableNameChecking

function Resolve-KirakaraChunKHelperInput {
  param([string]$Directory, [string]$ConfigPath, [switch]$Optional)
  $source = 'parameter'
  if ([string]::IsNullOrWhiteSpace($Directory)) {
    $Directory = [Environment]::GetEnvironmentVariable('KIRAKARA_CHUNK_HELPER_ROOT', 'Process')
    $source = 'environment'
  }
  if ([string]::IsNullOrWhiteSpace($Directory)) {
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
      $ConfigPath = Join-Path $script:RepositoryRoot 'config/kirakara.local.json'
    }
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
      $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
      $schema = $config.PSObject.Properties['schemaVersion']
      if ($null -eq $schema -or [int]$schema.Value -ne 1) { throw 'Unsupported Kirakara local configuration schema.' }
      $windows = $config.PSObject.Properties['windows']
      if ($null -ne $windows -and $null -ne $windows.Value) {
        $property = $windows.Value.PSObject.Properties['chunkHelperDirectory']
        if ($null -ne $property) {
          if ($property.Value -isnot [string]) { throw 'windows.chunkHelperDirectory must be a directory string.' }
          $Directory = [string]$property.Value
          $source = 'repository-local-config'
        }
      }
    }
  }
  if ([string]::IsNullOrWhiteSpace($Directory)) {
    if ($Optional) { return $null }
    throw 'Set KIRAKARA_CHUNK_HELPER_ROOT or windows.chunkHelperDirectory to an existing ChunK Helper publish directory.'
  }
  if (-not [IO.Path]::IsPathRooted($Directory)) { throw 'ChunK Helper publish directory must be an absolute path.' }
  if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw "ChunK Helper directory does not exist: $Directory" }
  $directoryPath = (Resolve-Path -LiteralPath $Directory).Path
  $executable = Join-Path $directoryPath 'ChunK Helper.exe'
  if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "ChunK Helper executable is missing: $executable" }
  $pe = [Kirakara.Artifacts.PeReader]::Read($executable)
  if ($pe.Machine -ne 0x8664 -or $pe.IsDll) { throw 'ChunK Helper input must be a Windows x64 executable, not a DLL.' }
  return [pscustomobject]@{
    root = $directoryPath
    executable = $executable
    sha256 = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
    source = $source
  }
}

Export-ModuleMember -Function 'Resolve-KirakaraChunKHelperInput'
