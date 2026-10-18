#Requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'app_package.psm1') -Force -DisableNameChecking
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$output=Join-Path $repo ('build/tests/package-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $output -Force | Out-Null
$config=Join-Path $output 'package.json'
$savedConfig=$env:KIRAKARA_PACKAGE_CONFIG; $savedVersion=$env:KIRAKARA_PACKAGE_VERSION
$savedBuildVersion=$env:KIRAKARA_PACKAGE_BUILD_VERSION
$count=0
function Check([bool]$Value,[string]$Label){if(-not $Value){throw "FAIL: $Label"};$script:count++}
try {
  $input=[ordered]@{schemaVersion=1;name=([string][char]0x7EAF+' K test');version='2.3.4+56';developer='Example Team'}
  $input | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding utf8
  $env:KIRAKARA_PACKAGE_CONFIG=$config
  Remove-Item Env:\KIRAKARA_PACKAGE_VERSION -ErrorAction SilentlyContinue
  Remove-Item Env:\KIRAKARA_PACKAGE_BUILD_VERSION -ErrorAction SilentlyContinue
  $package=Get-KirakaraAppPackage
  Check ($package.name -ceq $input.name -and $package.developer -ceq $input.developer) 'Display name and developer come from JSON'
  Check ($package.numbers -join ',' -ceq '2,3,4,56') 'Version maps to four Windows components'
  $arguments=@(Set-KirakaraAppBuildVersion @('build','windows','--release'))
  Check ('--build-name=2.3.4' -in $arguments -and '--build-number=56' -in $arguments) 'Flutter receives configured build version'
  $arguments=@(Set-KirakaraAppBuildVersion @('build','windows','--build-name=9.8.7','--build-number','65'))
  Check ($env:KIRAKARA_PACKAGE_BUILD_VERSION -ceq '9.8.7+65') 'Explicit build arguments win'
  Check ($env:KIRAKARA_PACKAGE_VERSION -ceq '2.3.4+56') 'Build overrides do not change the display version'
  $header=Join-Path $output 'package_info.h'
  Write-KirakaraPackageHeader -Path $header
  $text=[IO.File]::ReadAllText($header)
  Check ($text.Contains($input.name) -and $text.Contains('9,8,7,65') -and $text.Contains('Example Team')) 'Header retains Unicode metadata and actual version'
  $time=(Get-Item -LiteralPath $header).LastWriteTimeUtc
  Write-KirakaraPackageHeader -Path $header
  Check ((Get-Item -LiteralPath $header).LastWriteTimeUtc -eq $time) 'Unchanged metadata does not trigger recompilation'
  Remove-Item Env:\KIRAKARA_PACKAGE_VERSION
  Remove-Item Env:\KIRAKARA_PACKAGE_BUILD_VERSION
  $input.version='v0.1 Beta'
  $input | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding utf8
  $package=Get-KirakaraAppPackage
  Check ($package.version -ceq 'v0.1 Beta' -and ($package.numbers -join ',') -ceq '0,1,0,0') 'One display label automatically supplies valid numeric metadata'
  $arguments=@(Set-KirakaraAppBuildVersion @('run','-d','windows'))
  Check ($env:KIRAKARA_PACKAGE_VERSION -ceq 'v0.1 Beta' -and $env:KIRAKARA_PACKAGE_BUILD_VERSION -ceq '0.1.0+0') 'Run preserves the display label and numeric metadata'
  Check (($arguments -join ' ') -ceq 'run -d windows') 'Run receives no unsupported build flags'
  $arguments=@(Set-KirakaraAppBuildVersion @('build','windows','--debug'))
  Check ('--build-name=0.1.0' -in $arguments -and '--build-number=0' -in $arguments) 'Flutter build receives only the numeric version'
  $arguments=@(Set-KirakaraAppBuildVersion @('build','windows','--build-name=9.8.7','--build-number=65'))
  Check ($env:KIRAKARA_PACKAGE_VERSION -ceq 'v0.1 Beta' -and $env:KIRAKARA_PACKAGE_BUILD_VERSION -ceq '9.8.7+65') 'Explicit numeric overrides retain custom display labels'
  Remove-Item Env:\KIRAKARA_PACKAGE_VERSION
  Remove-Item Env:\KIRAKARA_PACKAGE_BUILD_VERSION
  $package=Get-KirakaraAppPackage -Version 'Preview / Candidate'
  Check ($package.version -ceq 'Preview / Candidate' -and ($package.numbers -join ',') -ceq '0,0,0,0') 'Pure-text display labels also remain buildable'
  $package=Get-KirakaraAppPackage -Version 'v2.3.4.5 Beta'
  Check (($package.numbers -join ',') -ceq '2,3,4,5') 'Four-part display versions retain their numeric parts'
  $package=Get-KirakaraAppPackage -Version 'v2.3.4-rc.1+7'
  Check (($package.numbers -join ',') -ceq '2,3,4,7') 'Release suffixes preserve numeric build metadata'
  $package=Get-KirakaraAppPackage -Version 'v70000.1 Beta'
  Check (($package.numbers -join ',') -ceq '0,0,0,0') 'Unrepresentable labels do not produce invalid Windows resource values'
  $input.version='v0.1 "Beta" \ label'
  $input | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding utf8
  Write-KirakaraPackageHeader -Path $header
  $text=[IO.File]::ReadAllText($header)
  Check ($text.Contains('v0.1 \"Beta\" \\ label') -and $text.Contains('KIRAKARA_APP_VERSION_NUMBER 0,1,0,0')) 'Display labels are escaped for C++ and Windows resources'
  foreach($bad in @('1.2','1.2.3+bad','70000.1.2')) {
    $rejected=$false
    try { Get-KirakaraAppPackage -BuildVersion $bad | Out-Null } catch {$rejected=$true}
    Check $rejected ('Reject invalid Windows version: '+$bad)
  }
  Write-Host ($count.ToString()+' package configuration checks passed.')
} finally {
  [Environment]::SetEnvironmentVariable('KIRAKARA_PACKAGE_CONFIG',$savedConfig,'Process')
  [Environment]::SetEnvironmentVariable('KIRAKARA_PACKAGE_VERSION',$savedVersion,'Process')
  [Environment]::SetEnvironmentVariable('KIRAKARA_PACKAGE_BUILD_VERSION',$savedBuildVersion,'Process')
}
