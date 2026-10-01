#Requires -Version 7.2
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Workspace,
  [Parameter(Mandatory)][string]$Destination,
  [Parameter(Mandatory)][string]$EntryPath,
  [Parameter(Mandatory)][string]$Archive,
  [Parameter(Mandatory)][string]$ResultPath,
  [string]$EnteredPath,
  [string]$GatePath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'artifact_package.psm1') -DisableNameChecking
$entry = Get-Content -Raw -LiteralPath $EntryPath | ConvertFrom-Json
$verify = {
  param($root, $manifest)
  if ($manifest.kind -cne 'test-data') { throw '测试包类型错误。' }
  if ($EnteredPath) { [IO.File]::WriteAllText($EnteredPath, [string]$PID) }
  if ($GatePath) {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $GatePath)) {
      if ([DateTime]::UtcNow -ge $deadline) { throw '测试进程等待门控超时。' }
      # Only the short-lived fault-injection test waits here, not the installer.
      Start-Sleep -Milliseconds 50
    }
  }
}.GetNewClosure()
$path = Install-ArtifactPackage -Workspace $Workspace -Destination $Destination `
  -Kind test-data -IdentityHash $entry.identityHash -Entry $entry `
  -LocalArchive $Archive -Verify $verify
[IO.File]::WriteAllText($ResultPath, (@{ passed = $true; path = $path } | ConvertTo-Json),
  [Text.UTF8Encoding]::new($false))
