#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'app_package.psm1') -Force -DisableNameChecking
Write-KirakaraPackageHeader -Path $OutputPath
