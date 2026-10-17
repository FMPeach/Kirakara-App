#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ValidHelperDirectory)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $PSScriptRoot 'chunk_helper_input.psm1') -Force -DisableNameChecking
$saved = [Environment]::GetEnvironmentVariable('KIRAKARA_CHUNK_HELPER_ROOT', 'Process')
$temp = Join-Path $repository ('build/tests/helper-input-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$checks = @()
function Check([bool]$Value, [string]$Name) {
  if (-not $Value) { throw "FAIL: $Name" }
  $script:checks += $Name
}
function Reject([scriptblock]$Action, [string]$Name) {
  try { & $Action | Out-Null } catch { $script:checks += $Name; return }
  throw "FAIL: expected rejection: $Name"
}
try {
  $valid = Resolve-KirakaraChunKHelperInput -Directory $ValidHelperDirectory
  $a = Join-Path $temp ('publish A ' + [char]0x4E00)
  $b = Join-Path $temp ('publish B ' + [char]0x4E8C)
  New-Item -ItemType Directory -Path $a,$b | Out-Null
  foreach ($root in @($a,$b)) { Copy-Item -LiteralPath $valid.executable -Destination (Join-Path $root 'ChunK Helper.exe') }
  Set-Content -LiteralPath (Join-Path $a 'dependency.txt') -Value 'A' -Encoding ascii
  Set-Content -LiteralPath (Join-Path $b 'dependency.txt') -Value 'BBBB' -Encoding ascii
  # Independent publishers can preserve identical timestamps for changed DLLs.
  foreach ($root in @($a,$b)) {
    (Get-Item -LiteralPath (Join-Path $root 'dependency.txt')).LastWriteTimeUtc = [datetime]'2026-01-01T00:00:00Z'
  }
  New-Item -ItemType Directory -Path (Join-Path $a 'logs') | Out-Null
  Set-Content -LiteralPath (Join-Path $a 'logs/do-not-copy.log') -Value 'private test log' -Encoding ascii
  $config = Join-Path $temp 'local.json'
  @{schemaVersion=1;windows=@{chunkHelperDirectory=$a}} | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding utf8
  Remove-Item Env:\KIRAKARA_CHUNK_HELPER_ROOT -ErrorAction SilentlyContinue
  $fromConfig = Resolve-KirakaraChunKHelperInput -ConfigPath $config
  Check ($fromConfig.root -ceq $a) 'Unicode and space directory configuration'
  $env:KIRAKARA_CHUNK_HELPER_ROOT = $b
  Check ((Resolve-KirakaraChunKHelperInput -ConfigPath $config).root -ceq $b) 'Environment overrides local configuration'
  Check ((Resolve-KirakaraChunKHelperInput -Directory $a -ConfigPath $config).root -ceq $a) 'Explicit input overrides environment'
  Remove-Item Env:\KIRAKARA_CHUNK_HELPER_ROOT
  $empty = Join-Path $temp 'empty.json'
  @{schemaVersion=1;windows=@{}} | ConvertTo-Json | Set-Content -LiteralPath $empty -Encoding utf8
  Check ($null -eq (Resolve-KirakaraChunKHelperInput -ConfigPath $empty -Optional)) 'Optional developer builds need no Helper'
  Reject { Resolve-KirakaraChunKHelperInput -ConfigPath $empty } 'Release input requires Helper'
  Reject { Resolve-KirakaraChunKHelperInput -Directory 'relative/path' } 'Relative input rejected'
  $invalid = Join-Path $temp 'invalid'
  New-Item -ItemType Directory -Path $invalid | Out-Null
  Set-Content -LiteralPath (Join-Path $invalid 'ChunK Helper.exe') -Value 'not PE' -Encoding ascii
  Reject { Resolve-KirakaraChunKHelperInput -Directory $invalid } 'Non-PE input rejected'

  $fixture = Join-Path $temp 'cmake-source'
  $build = Join-Path $temp 'cmake-build'
  $install = Join-Path $temp 'installed'
  New-Item -ItemType Directory -Path $fixture | Out-Null
  $include = (Join-Path $repository 'windows/cmake/chunk_helper.cmake').Replace('\','/')
  "cmake_minimum_required(VERSION 3.14)`nproject(HelperInstall NONE)`ninclude(`"$include`")" |
    Set-Content -LiteralPath (Join-Path $fixture 'CMakeLists.txt') -Encoding utf8
  foreach ($root in @($a,$b)) {
    $env:KIRAKARA_CHUNK_HELPER_ROOT = $root
    & cmake -S $fixture -B $build "-DCMAKE_INSTALL_PREFIX=$install" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed.' }
    & cmake --install $build | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'CMake installation failed.' }
    $actual = (Get-Content -LiteralPath (Join-Path $install 'tools/ChunKHelper/dependency.txt') -Raw).Trim()
    $expected = if ($root -eq $a) {'A'} else {'BBBB'}
    Check ($actual -ceq $expected) ('Dependency copied from current input: ' + $expected)
    Check (-not (Test-Path -LiteralPath (Join-Path $install 'tools/ChunKHelper/logs'))) 'Runtime logs excluded'
    Check (-not (Get-Content -LiteralPath (Join-Path $build 'CMakeCache.txt') -Raw).Contains($root)) 'Input directory not retained in CMake cache'
  }
  $checks | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $temp 'report.json') -Encoding utf8
  Write-Host ($checks.Count.ToString() + ' Helper input/install checks passed.')
} finally {
  [Environment]::SetEnvironmentVariable('KIRAKARA_CHUNK_HELPER_ROOT', $saved, 'Process')
}
