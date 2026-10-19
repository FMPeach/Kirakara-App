#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$directory = Join-Path $root ('build/tests/archive-layout-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $directory -Force
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$cases = @(
  @{ entries=@('kirakara_app.exe','flutter_windows.dll','data/app.so','tools/ChunKHelper/ChunK Helper.exe'); accepted=$true },
  # Corresponding-source archives deep inside runtime data are not App wrappers.
  @{ entries=@('kirakara_app.exe','ime/sources/library.zip'); accepted=$true },
  @{ entries=@('Kirakara-App/kirakara_app.exe'); accepted=$false },
  @{ entries=@('build/releases/Kirakara.zip'); accepted=$false },
  @{ entries=@('kirakara_app.exe','Kirakara.zip'); accepted=$false },
  @{ entries=@('kirakara_app.exe','../outside.dll'); accepted=$false },
  @{ entries=@('kirakara_app.exe','/outside.dll'); accepted=$false },
  @{ entries=@('kirakara_app.exe','data\file.txt'); accepted=$false },
  @{ entries=@('kirakara_app.exe','KIRAKARA_APP.EXE'); accepted=$false }
)
$index=0
foreach ($case in $cases) {
  $path = Join-Path $directory ($index.ToString()+'.zip')
  $archive = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($name in $case.entries) {
      $entry = $archive.CreateEntry($name)
      $writer = [IO.StreamWriter]::new($entry.Open())
      try { $writer.Write('layout fixture') } finally { $writer.Dispose() }
    }
  } finally { $archive.Dispose() }
  $accepted=$true
  try { & (Join-Path $root 'tool/check_portable_archive.ps1') -ArchivePath $path | Out-Null } catch { $accepted=$false }
  if ($accepted -ne $case.accepted) { throw "Unexpected archive layout result: case $index" }
  $index++
}
Write-Host "$index portable archive layout checks passed."
