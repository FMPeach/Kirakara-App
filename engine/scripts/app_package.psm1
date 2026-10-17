#Requires -Version 5.1
Set-StrictMode -Version Latest
$script:AppPackageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))

function Get-KirakaraAppPackage {
  param([string]$ConfigPath, [string]$Version)
  if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = $env:KIRAKARA_PACKAGE_CONFIG }
  if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $script:AppPackageRoot 'config/package.json' }
  $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
  if ($config.schemaVersion -ne 1) { throw 'Unsupported package configuration schema.' }
  foreach ($field in @('name','version','developer')) {
    if ($config.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($config.$field) -or $config.$field -match '[\r\n\x00]') {
      throw "Invalid package field: $field"
    }
  }
  if ([string]::IsNullOrWhiteSpace($Version)) { $Version = $env:KIRAKARA_PACKAGE_VERSION }
  if ([string]::IsNullOrWhiteSpace($Version)) { $Version = $config.version }
  if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z.-]+)?(?:\+(\d+))?$') {
    throw 'Package version must be major.minor.patch[-prerelease][+buildNumber].'
  }
  $numbers = @([int]$Matches[1],[int]$Matches[2],[int]$Matches[3],0)
  if ($Matches.ContainsKey(4)) { $numbers[3] = [int]$Matches[4] }
  if (@($numbers | Where-Object { $_ -gt 65535 }).Count) { throw 'Windows version components must be between 0 and 65535.' }
  $buildName = ($Version -split '\+')[0]
  return [pscustomobject]@{name=$config.name;version=$Version;developer=$config.developer;buildName=$buildName;buildNumber=[string]$numbers[3];numbers=$numbers}
}

function Set-KirakaraAppBuildVersion {
  param([Parameter(Mandatory)][string[]]$Arguments)
  $config = Get-KirakaraAppPackage
  $name=$config.buildName; $number=$config.buildNumber
  foreach ($field in @('name','number')) {
    $flag = '--build-' + $field
    for ($i=0; $i -lt $Arguments.Count; $i++) {
      $value=$null
      if ($Arguments[$i].StartsWith($flag+'=')) { $value=$Arguments[$i].Substring($flag.Length+1) }
      elseif ($Arguments[$i] -eq $flag -and $i+1 -lt $Arguments.Count) { $value=$Arguments[$i+1] }
      if ($null -ne $value) { if ($field -eq 'name') {$name=$value} else {$number=$value} }
    }
  }
  $hasOverride = @($Arguments | Where-Object { $_ -match '^--build-(name|number)(=|$)' }).Count -gt 0
  $version = if ($hasOverride) {$name+'+'+$number} else {$config.version}
  $config = Get-KirakaraAppPackage -Version $version
  $env:KIRAKARA_PACKAGE_VERSION = $config.version
  $result = @($Arguments)
  if ($Arguments[0] -eq 'build') {
    if (-not @($Arguments | Where-Object {$_ -eq '--build-name' -or $_.StartsWith('--build-name=')}).Count) { $result += '--build-name='+$config.buildName }
    if (-not @($Arguments | Where-Object {$_ -eq '--build-number' -or $_.StartsWith('--build-number=')}).Count) { $result += '--build-number='+$config.buildNumber }
  }
  return $result
}

function Write-KirakaraPackageHeader {
  param([Parameter(Mandatory)][string]$Path, [string]$ConfigPath)
  $config = Get-KirakaraAppPackage -ConfigPath $ConfigPath
  $name = '"' + $config.name.Replace('\','\\').Replace('"','\"') + '"'
  $developer = '"' + $config.developer.Replace('\','\\').Replace('"','\"') + '"'
  $version = '"' + $config.version + '"'
  $text = "#pragma once`n#define KIRAKARA_APP_NAME $name`n#define KIRAKARA_APP_NAME_W L$name`n#define KIRAKARA_APP_DEVELOPER $developer`n#define KIRAKARA_APP_VERSION $version`n#define KIRAKARA_APP_VERSION_NUMBER $($config.numbers -join ',')`n"
  $absolute = [IO.Path]::GetFullPath($Path)
  New-Item -ItemType Directory -Path (Split-Path -Parent $absolute) -Force | Out-Null
  if (-not (Test-Path -LiteralPath $absolute) -or [IO.File]::ReadAllText($absolute) -cne $text) {
    [IO.File]::WriteAllText($absolute, $text, [Text.UTF8Encoding]::new($false))
  }
}

Export-ModuleMember -Function Get-KirakaraAppPackage,Set-KirakaraAppBuildVersion,Write-KirakaraPackageHeader
