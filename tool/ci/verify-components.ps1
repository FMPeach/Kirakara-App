#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$ShowDirectory,
  [Parameter(Mandatory)][string]$HelperDirectory,
  [Parameter(Mandatory)][string]$SelectionPath,
  [string]$ReceiptPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $ReceiptPath) { $ReceiptPath = Join-Path $root 'build/actions-test/components.json' }
$selection = Get-Content -LiteralPath $SelectionPath -Raw -Encoding utf8 | ConvertFrom-Json
if ($selection.schemaVersion -ne 1) { throw 'Invalid dependency selection schema.' }
function Test-Component([string]$Directory, [string]$Component, [string]$EntryPoint, $Expected) {
  $Directory = (Resolve-Path -LiteralPath $Directory).Path
  $items = @(Get-Item -LiteralPath $Directory -Force) + @(Get-ChildItem -LiteralPath $Directory -Recurse -Force)
  if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
    throw 'Dependency artifact must not contain filesystem links.'
  }
  $manifestPath = Join-Path $Directory 'component-manifest.json'
  $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
  if ($manifest.schemaVersion -ne 1 -or $manifest.component -cne $Component -or
      $manifest.target -cne 'windows-x64' -or $manifest.entryPoint -cne $EntryPoint -or
      $manifest.source.repository -cne $Expected.repository -or
      $manifest.source.commit -cne $Expected.commit -or
      [string]$manifest.build.runId -cne [string]$Expected.runId -or
      [string]$manifest.build.runAttempt -cne [string]$Expected.runAttempt) {
    throw "Artifact identity does not match the selected build: $Component"
  }
  $known = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($file in @($manifest.files)) {
    if ([string]::IsNullOrWhiteSpace($file.path) -or $file.path -match '(^/|\\|:|[\x00-\x1f]|(^|/)\.{1,2}(/|$))' -or
        -not $known.Add($file.path) -or $file.path -ieq 'component-manifest.json' -or
        $file.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Invalid/duplicate artifact path or hash: $Component" }
    $path = Join-Path $Directory $file.path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-Item -LiteralPath $path).Length -ne $file.size -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $file.sha256) {
      throw "Artifact file differs from manifest: $Component/$($file.path)"
    }
  }
  $actual = @($items | Where-Object { -not $_.PSIsContainer -and $_.FullName -ine $manifestPath })
  if ($actual.Count -ne $known.Count -or -not $known.Contains($EntryPoint)) { throw "Artifact has missing/unlisted files: $Component" }
  return [IO.Path]::GetFullPath((Join-Path $Directory $EntryPoint))
}
$show = Test-Component $ShowDirectory 'show' 'libshow_host.dll' $selection.show
$helper = Test-Component $HelperDirectory 'chunk-helper' 'ChunK Helper.exe' $selection.helper
Import-Module (Join-Path $root 'engine/scripts/show_host_input.psm1') -DisableNameChecking
Import-Module (Join-Path $root 'engine/scripts/chunk_helper_input.psm1') -DisableNameChecking
$null = Resolve-KirakaraShowHostInput -Path $show
$helperRoot = Split-Path -Parent $helper
$null = Resolve-KirakaraChunKHelperInput -Directory $helperRoot
$env:KIRAKARA_SHOW_HOST_DLL = $show
$env:KIRAKARA_CHUNK_HELPER_ROOT = $helperRoot
if ($env:GITHUB_ENV) {
  [IO.File]::AppendAllText($env:GITHUB_ENV,
    "KIRAKARA_SHOW_HOST_DLL=$show`nKIRAKARA_CHUNK_HELPER_ROOT=$helperRoot`n", [Text.UTF8Encoding]::new($false))
}
$null = New-Item -ItemType Directory -Path (Split-Path -Parent ([IO.Path]::GetFullPath($ReceiptPath))) -Force
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReceiptPath),
  ($selection | ConvertTo-Json -Depth 10) + "`n", [Text.UTF8Encoding]::new($false))
Write-Host 'Prebuilt Show and Helper verified. App will only consume these outputs.'
