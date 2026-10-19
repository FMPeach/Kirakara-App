#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ShowDirectory, [Parameter(Mandatory)][string]$HelperDirectory)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$output = Join-Path $root ('build/actions-test/local-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $output -Force
$selection = [ordered]@{ schemaVersion = 1 }
foreach ($spec in @(@{ key='show'; dir=$ShowDirectory }, @{ key='helper'; dir=$HelperDirectory })) {
  $manifest = Get-Content -LiteralPath (Join-Path $spec.dir 'component-manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
  $selection[$spec.key] = [ordered]@{ repository=$manifest.source.repository
    commit=$manifest.source.commit; runId=$manifest.build.runId; runAttempt=$manifest.build.runAttempt }
}
$selectionPath = Join-Path $output 'dependencies.json'
[IO.File]::WriteAllText($selectionPath, ($selection | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
$savedShow=$env:KIRAKARA_SHOW_HOST_DLL; $savedHelper=$env:KIRAKARA_CHUNK_HELPER_ROOT
$savedGitHubEnv=$env:GITHUB_ENV
try {
  Remove-Item Env:\GITHUB_ENV -ErrorAction SilentlyContinue
  & (Join-Path $PSScriptRoot 'verify-components.ps1') -ShowDirectory $ShowDirectory `
    -HelperDirectory $HelperDirectory -SelectionPath $selectionPath -ReceiptPath (Join-Path $output 'components.json')
  & (Join-Path $root 'tool/package_windows.ps1') -OutputDirectory $output
} finally {
  [Environment]::SetEnvironmentVariable('KIRAKARA_SHOW_HOST_DLL',$savedShow,'Process')
  [Environment]::SetEnvironmentVariable('KIRAKARA_CHUNK_HELPER_ROOT',$savedHelper,'Process')
  [Environment]::SetEnvironmentVariable('GITHUB_ENV',$savedGitHubEnv,'Process')
}
