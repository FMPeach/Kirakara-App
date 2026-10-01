#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Wrapper,[Parameter(Mandatory)][string]$ArgumentsFile)
$ErrorActionPreference = 'Stop'
# A hidden Windows child otherwise inherits the ANSI code page for host output.
# Set both writers only in this test child so redirected Chinese logs are UTF-8.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$arguments = @(Get-Content -Raw -LiteralPath $ArgumentsFile -Encoding utf8 | ConvertFrom-Json)
& $Wrapper @arguments
exit $LASTEXITCODE
