#Requires -Version 5.1
[CmdletBinding()]
param([string]$Version, [string]$OutputDirectory, [switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $root 'engine/scripts/app_package.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'engine/scripts/chunk_helper_input.psm1') -Force -DisableNameChecking
$package = Get-KirakaraAppPackage -Version $Version
$helper = Resolve-KirakaraChunKHelperInput
$saved = [Environment]::GetEnvironmentVariable('KIRAKARA_PACKAGE_VERSION','Process')
$savedBuild = [Environment]::GetEnvironmentVariable('KIRAKARA_PACKAGE_BUILD_VERSION','Process')
Push-Location $root
try {
  $env:KIRAKARA_PACKAGE_VERSION = $package.version
  $env:KIRAKARA_PACKAGE_BUILD_VERSION = $package.buildVersion
  if (-not $SkipBuild) {
    & (Join-Path $root 'flutterw.ps1') build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Windows Release build failed.' }
  }
  $bundle = Join-Path $root 'build/windows/x64/runner/Release'
  $executable = Join-Path $bundle 'kirakara_app.exe'
  $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($executable)
  $actualNumbers = @($info.FileMajorPart,$info.FileMinorPart,$info.FileBuildPart,$info.FilePrivatePart)
  if ($info.ProductName -cne $package.name -or $info.CompanyName -cne $package.developer -or
      $info.ProductVersion -cne $package.version -or $info.FileVersion -cne $package.version -or
      ($actualNumbers -join ',') -cne ($package.numbers -join ',')) {
    throw 'Built executable metadata does not match config/package.json; rebuild before packaging.'
  }
  $files = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $prefix = [IO.Path]::GetFullPath($bundle).TrimEnd('\')+'\'
  $manifest = Join-Path $root 'build/windows/x64/install_manifest.txt'
  foreach ($entry in Get-Content -LiteralPath $manifest -Encoding utf8) {
    $full = [IO.Path]::GetFullPath($entry)
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { continue }
    $relative = $full.Substring($prefix.Length)
    if ($relative -match '(^|[\\/])(settings|logs)([\\/]|$)' -or [IO.Path]::GetExtension($relative) -in '.pdb','.log','.dmp','.etl') { continue }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Missing installed file: $relative" }
    $null = $files.Add($full)
  }
  # The runner is built in its final destination, so CMake may omit its
  # self-installing target from install_manifest.txt.
  $null = $files.Add([IO.Path]::GetFullPath($executable))
  $nativeAssets = Join-Path $bundle 'native_assets.json'
  if (Test-Path -LiteralPath $nativeAssets -PathType Leaf) {
    $null = $files.Add([IO.Path]::GetFullPath($nativeAssets))
  }
  foreach ($required in @('kirakara_app.exe','flutter_windows.dll','libshow_host.dll','data/app.so','data/flutter_assets/NOTICES.Z',
      'data/flutter_assets/assets/licenses/catalog.json','tools/ChunKHelper/ChunK Helper.exe','tools/ChunKHelper/ChunK Helper.dll','tools/ChunKHelper/coreclr.dll')) {
    if (-not $files.Contains([IO.Path]::GetFullPath((Join-Path $bundle $required)))) { throw "Runtime file missing from install manifest: $required" }
  }
  $toolPrefix = $helper.root.TrimEnd('\')+'\'
  foreach ($file in Get-ChildItem -LiteralPath $helper.root -File -Recurse) {
    $relative=$file.FullName.Substring($toolPrefix.Length)
    if ($relative -match '(^|[\\/])(settings|logs)([\\/]|$)' -or $file.Extension -in '.pdb','.log','.dmp','.etl') { continue }
    $target=[IO.Path]::GetFullPath((Join-Path $bundle ('tools/ChunKHelper/'+$relative)))
    if (-not $files.Contains($target) -or (Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $target).Hash) {
      throw "Bundled Helper differs from its publish directory: $relative"
    }
  }
  if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $root 'build/releases' }
  $output = [IO.Path]::GetFullPath($OutputDirectory)
  New-Item -ItemType Directory -Path $output -Force | Out-Null
  $name = $package.name -replace '[^\p{L}\p{N}._-]','-'
  $archiveVersion = $package.version -replace '[^\p{L}\p{N}._+-]','-'
  $archivePath = Join-Path $output ($name+'-'+$archiveVersion+'-windows-x64.zip')
  if (Test-Path -LiteralPath $archivePath) { throw "Archive already exists; use another output directory: $archivePath" }
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [IO.Compression.ZipFile]::Open($archivePath,[IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($file in @($files) | Sort-Object) {
      $relative=$file.Substring($prefix.Length).Replace('\','/')
      [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$file,$relative,[IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
  } finally { $archive.Dispose() }
  & (Join-Path $root 'tool/check_portable_archive.ps1') -ArchivePath $archivePath
  $hash=(Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
  [IO.File]::WriteAllText(($archivePath+'.sha256'),$hash+' *'+[IO.Path]::GetFileName($archivePath)+"`n",[Text.UTF8Encoding]::new($false))
  Write-Host "Package: $archivePath"
  Write-Host "SHA-256: $hash"
} finally {
  Pop-Location
  [Environment]::SetEnvironmentVariable('KIRAKARA_PACKAGE_VERSION',$saved,'Process')
  [Environment]::SetEnvironmentVariable('KIRAKARA_PACKAGE_BUILD_VERSION',$savedBuild,'Process')
}
