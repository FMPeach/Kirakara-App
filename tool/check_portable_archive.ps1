#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ArchivePath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($ArchivePath))
try {
  if ($null -eq $archive.GetEntry('kirakara_app.exe')) {
    throw 'Portable ZIP must contain kirakara_app.exe at its root, not another ZIP or wrapper directory.'
  }
  $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in $archive.Entries) {
    $name = $entry.FullName
    if (-not $names.Add($name) -or $name -match '(^/|\\|:|(^|/)\.{1,2}(/|$))') {
      throw "Invalid or duplicate portable ZIP entry: $name"
    }
    if ($name -match '^[^/]+\.zip$' -or $name.StartsWith('Kirakara-App/', [StringComparison]::OrdinalIgnoreCase)) {
      throw "Portable ZIP must not wrap the application in another archive or directory: $name"
    }
  }
  Write-Host "Portable ZIP layout verified: executable at root, $($archive.Entries.Count) entries."
} finally { $archive.Dispose() }
