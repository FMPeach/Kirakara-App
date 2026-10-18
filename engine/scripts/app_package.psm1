#Requires -Version 5.1
Set-StrictMode -Version Latest
$script:AppPackageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))

function ConvertTo-KirakaraNumericVersion {
  param([string]$Version, [switch]$Strict)
  if ($Strict -and $Version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+\d+)?$') {
    throw 'Flutter build overrides must be major.minor.patch[-prerelease][+buildNumber].'
  }
  $numbers = @(0,0,0,0)
  $match = [regex]::Match($Version.Trim(), '^[vV]?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?')
  if ($match.Success) {
    $values = @('0','0','0','0')
    for ($i=0; $i -lt 4; $i++) {
      if ($match.Groups[$i+1].Success) { $values[$i] = $match.Groups[$i+1].Value }
    }
    $build = [regex]::Match($Version.Trim(), '\+(\d+)$')
    if ($build.Success) { $values[3] = $build.Groups[1].Value }
    for ($i=0; $i -lt 4; $i++) {
      [uint16]$component = 0
      if (-not [uint16]::TryParse($values[$i], [ref]$component)) {
        if ($Strict) { throw 'Windows numeric version components must be between 0 and 65535.' }
        $numbers = @(0,0,0,0)
        break
      }
      $numbers[$i] = [int]$component
    }
  }
  $buildName = $numbers[0..2] -join '.'
  return [pscustomobject]@{buildVersion=($buildName+'+'+$numbers[3]);buildName=$buildName;buildNumber=[string]$numbers[3];numbers=$numbers}
}

function Get-KirakaraAppPackage {
  param([string]$ConfigPath, [string]$Version, [string]$BuildVersion)
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
  if ([string]::IsNullOrWhiteSpace($Version) -or $Version -match '[\x00-\x1f\x7f]') {
    throw 'Invalid package display version.'
  }
  if ([string]::IsNullOrWhiteSpace($BuildVersion)) { $BuildVersion = $env:KIRAKARA_PACKAGE_BUILD_VERSION }
  # Only Flutter/Windows' machine-readable fields need numbers. The visible
  # version remains the original label, including spaces and release names.
  $numeric = if ([string]::IsNullOrWhiteSpace($BuildVersion)) {
    ConvertTo-KirakaraNumericVersion -Version $Version
  } else {
    ConvertTo-KirakaraNumericVersion -Version $BuildVersion -Strict
  }
  return [pscustomobject]@{name=$config.name;version=$Version;buildVersion=$numeric.buildVersion;developer=$config.developer;buildName=$numeric.buildName;buildNumber=$numeric.buildNumber;numbers=$numeric.numbers}
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
  $buildVersion = if ($hasOverride) {$name+'+'+$number} else {$config.buildVersion}
  $config = Get-KirakaraAppPackage -Version $config.version -BuildVersion $buildVersion
  $env:KIRAKARA_PACKAGE_VERSION = $config.version
  $env:KIRAKARA_PACKAGE_BUILD_VERSION = $config.buildVersion
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
  $version = '"' + $config.version.Replace('\','\\').Replace('"','\"') + '"'
  $text = "#pragma once`n#define KIRAKARA_APP_NAME $name`n#define KIRAKARA_APP_NAME_W L$name`n#define KIRAKARA_APP_DEVELOPER $developer`n#define KIRAKARA_APP_VERSION $version`n#define KIRAKARA_APP_VERSION_NUMBER $($config.numbers -join ',')`n"
  $absolute = [IO.Path]::GetFullPath($Path)
  New-Item -ItemType Directory -Path (Split-Path -Parent $absolute) -Force | Out-Null
  if (-not (Test-Path -LiteralPath $absolute) -or [IO.File]::ReadAllText($absolute) -cne $text) {
    [IO.File]::WriteAllText($absolute, $text, [Text.UTF8Encoding]::new($false))
  }
}

Export-ModuleMember -Function Get-KirakaraAppPackage,Set-KirakaraAppBuildVersion,Write-KirakaraPackageHeader
