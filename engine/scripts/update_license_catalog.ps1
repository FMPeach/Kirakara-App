#Requires -Version 5.1
[CmdletBinding()]
param([string]$EngineLicenseDirectory)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$output = Join-Path $root 'assets/licenses/catalog.json'
$entries = [Collections.Generic.List[object]]::new()
function AddNotice([string]$Name, [string]$License, [string[]]$Paths) {
  $texts = @($Paths | ForEach-Object {
    $text = [IO.File]::ReadAllText($_).Replace("`r`n","`n").Trim()
    if ($text.Length -lt 50) { throw "License text is incomplete: $_" }
    $text
  })
  $entries.Add([ordered]@{name=$Name;license=$License;texts=$texts})
}
$package = Get-Content -LiteralPath (Join-Path $root 'config/package.json') -Raw -Encoding utf8 | ConvertFrom-Json
AddNotice $package.name 'MIT' @((Join-Path $root 'LICENSE'))
foreach ($spec in @(
  @('librime','BSD-3-Clause','librime-BSD-3-Clause.txt'),
  @('Mozc','BSD-3-Clause / Third-party notices','Mozc-BSD-3-Clause.txt'),
  @('Zinnia','BSD-3-Clause','Zinnia-BSD-3-Clause.txt'),
  @('Rime data','LGPL-3.0','Rime-data-LGPL-3.0.txt'),
  @('Zinnia-Tomoe','LGPL-2.1','Zinnia-Tomoe-LGPL-2.1.txt'),
  @('GNU LGPL supplement','GPL-3.0','GPL-3.0-LGPL-supplement.txt'),
  @('Kirakara Show','MIT','Show-MIT.txt'),
  @('Signalsmith Stretch','MIT','Signalsmith-Stretch-MIT.txt'),
  @('Signalsmith Linear','MIT','Signalsmith-Linear-MIT.txt'))) {
  AddNotice $spec[0] $spec[1] @((Join-Path $root ('third_party/licenses/'+$spec[2])))
}
if (-not [string]::IsNullOrWhiteSpace($EngineLicenseDirectory)) {
  foreach ($spec in @(
    @('Flutter','BSD-3-Clause','Flutter-BSD-3-Clause.txt'),
    @('Dart','BSD-3-Clause','Dart-BSD-3-Clause.txt'),
    @('Skia','BSD-3-Clause','Skia-BSD-3-Clause.txt'),
    @('ICU','ICU','ICU.txt'),
    @('Flutter Engine','Third-party notices','Engine-NOTICES.txt'))) {
    AddNotice $spec[0] $spec[1] @((Join-Path $EngineLicenseDirectory $spec[2]))
  }
} elseif (Test-Path -LiteralPath $output) {
  foreach ($item in (Get-Content -LiteralPath $output -Raw -Encoding utf8 | ConvertFrom-Json)) {
    if ($item.name -in @('Flutter','Dart','Skia','ICU','Flutter Engine')) { $entries.Add($item) }
  }
} else { throw 'Provide the verified Engine licenses directory for the initial catalog.' }
New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
$json = ConvertTo-Json -InputObject @($entries.ToArray()) -Depth 6
[IO.File]::WriteAllText($output, $json + "`n", [Text.UTF8Encoding]::new($false))
