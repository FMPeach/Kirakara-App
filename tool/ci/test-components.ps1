#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ShowDirectory, [Parameter(Mandatory)][string]$HelperDirectory)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$testRoot = Join-Path $root ('build/actions-test/verify-' + [guid]::NewGuid().ToString('N'))
$show = Join-Path $testRoot 'show'
$helper = Join-Path $testRoot 'helper'
$null = New-Item -ItemType Directory -Path $show,$helper -Force
Copy-Item -LiteralPath (Join-Path $ShowDirectory 'libshow_host.dll') -Destination $show
Copy-Item -LiteralPath (Join-Path $HelperDirectory 'ChunK Helper.exe') -Destination $helper
function Write-Json([string]$Path, $Value) {
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
}
$selection = [ordered]@{ schemaVersion = 1 }
foreach ($spec in @(
  @{ key='show'; component='show'; repo='FMPeach/Kirakara-Show'; entry='libshow_host.dll'; dir=$show },
  @{ key='helper'; component='chunk-helper'; repo='FMPeach/ChunK-Helper'; entry='ChunK Helper.exe'; dir=$helper })) {
  $file = Get-Item -LiteralPath (Join-Path $spec.dir $spec.entry)
  $manifest = [ordered]@{ schemaVersion=1; component=$spec.component; target='windows-x64'
    source=@{ repository=$spec.repo; commit=('a'*40) }; build=@{ runId='42'; runAttempt='1' }
    entryPoint=$spec.entry; files=@(@{ path=$spec.entry; size=$file.Length
      sha256=(Get-FileHash -LiteralPath $file.FullName).Hash }) }
  Write-Json (Join-Path $spec.dir 'component-manifest.json') $manifest
  $selection[$spec.key] = @{ repository=$spec.repo; commit=('a'*40); runId='42'; runAttempt='1' }
}
$selectionPath = Join-Path $testRoot 'selection.json'
Write-Json $selectionPath $selection
$verify = Join-Path $PSScriptRoot 'verify-components.ps1'
$manifestPath = Join-Path $show 'component-manifest.json'
$original = [IO.File]::ReadAllText($manifestPath)
$savedShow=$env:KIRAKARA_SHOW_HOST_DLL; $savedHelper=$env:KIRAKARA_CHUNK_HELPER_ROOT
$savedGitHubEnv=$env:GITHUB_ENV
$count=0
try {
  Remove-Item Env:\GITHUB_ENV -ErrorAction SilentlyContinue
  & $verify -ShowDirectory $show -HelperDirectory $helper -SelectionPath $selectionPath -ReceiptPath (Join-Path $testRoot 'receipt.json')
  if ($env:KIRAKARA_SHOW_HOST_DLL -cne (Join-Path $show 'libshow_host.dll')) { throw 'Explicit DLL was not selected.' }
  $count++
  foreach ($change in @('hash','commit','run','attempt','entry','duplicate','escape','extra')) {
    $manifest = $original | ConvertFrom-Json
    switch ($change) {
      hash { $manifest.files[0].sha256='0'*64 }
      commit { $manifest.source.commit='b'*40 }
      run { $manifest.build.runId='43' }
      attempt { $manifest.build.runAttempt='2' }
      entry { $manifest.entryPoint='other.dll' }
      duplicate { $manifest.files=@($manifest.files[0],$manifest.files[0]) }
      escape { $manifest.files[0].path='../libshow_host.dll' }
      extra { [IO.File]::WriteAllText((Join-Path $show 'unlisted.txt'), 'not-in-manifest') }
    }
    Write-Json $manifestPath $manifest
    $rejected=$false
    try { & $verify -ShowDirectory $show -HelperDirectory $helper -SelectionPath $selectionPath -ReceiptPath (Join-Path $testRoot 'rejected.json') } catch { $rejected=$true }
    if (-not $rejected) { throw "FAIL: invalid artifact accepted ($change)" }
    if (Test-Path -LiteralPath (Join-Path $testRoot 'rejected.json')) { throw 'Rejected input wrote a receipt.' }
    $count++
  }
  Write-Host "$count prebuilt component checks passed. Fixtures: $testRoot"
} finally {
  [Environment]::SetEnvironmentVariable('KIRAKARA_SHOW_HOST_DLL',$savedShow,'Process')
  [Environment]::SetEnvironmentVariable('KIRAKARA_CHUNK_HELPER_ROOT',$savedHelper,'Process')
  [Environment]::SetEnvironmentVariable('GITHUB_ENV',$savedGitHubEnv,'Process')
}
