#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('helper')][string]$Component,
  [Parameter(Mandatory)][string]$SelectionPath,
  [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$SelectionPath = [IO.Path]::GetFullPath($SelectionPath)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$selection = Get-Content -LiteralPath $SelectionPath -Raw -Encoding utf8 | ConvertFrom-Json
$expected = $selection.$Component
if ([string]$expected.source -cne 'release' -or
    [string]$expected.repository -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$' -or
    [string]$expected.assetId -notmatch '^[1-9][0-9]*$' -or
    [string]$expected.assetSha256 -notmatch '^[a-fA-F0-9]{64}$' -or
    [long]$expected.assetSize -le 0) {
  throw 'Invalid Release component selection.'
}
if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) { throw 'GH_TOKEN is required to download a Release component.' }
if ((Test-Path -LiteralPath $OutputDirectory) -and
    @(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count) {
  throw 'Release component output directory must be empty.'
}

$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$downloadDirectory = Join-Path (Split-Path -Parent $OutputDirectory) 'downloads'
$null = New-Item -ItemType Directory -Path $downloadDirectory -Force
$archivePath = Join-Path $downloadDirectory ("$Component-$($expected.assetId)-$([Guid]::NewGuid().ToString('N')).zip")
$uri = "https://api.github.com/repos/$($expected.repository)/releases/assets/$($expected.assetId)"
$headers = @{
  Accept = 'application/octet-stream'
  'X-GitHub-Api-Version' = '2022-11-28'
  'User-Agent' = 'Kirakara-App-Actions'
}
$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
if (-not $curl) { throw 'curl.exe is required to download a Release component.' }

try {
  $downloaded = $false
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      $authorization = "header = `"Authorization: Bearer $($env:GH_TOKEN)`""
      $authorization | & $curl.Source --config - --http1.1 --location --fail --silent --show-error `
        --header "Accept: $($headers.Accept)" `
        --header "X-GitHub-Api-Version: $($headers.'X-GitHub-Api-Version')" `
        --header "User-Agent: $($headers.'User-Agent')" `
        --output $archivePath $uri
      if ($LASTEXITCODE -ne 0) { throw "curl.exe failed with exit code $LASTEXITCODE." }
      $downloaded = $true
      break
    } catch {
      if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
      if ($attempt -eq 3) { throw }
      Write-Warning "Release component download failed (attempt $attempt/3); retrying."
      Start-Sleep -Seconds (2 * $attempt)
    }
  }
  if (-not $downloaded) { throw 'Release component download did not complete.' }
  $archive = Get-Item -LiteralPath $archivePath
  if ($archive.Length -ne [long]$expected.assetSize -or
      (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ine [string]$expected.assetSha256) {
    throw 'Downloaded Release component differs from the selected asset metadata.'
  }

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
  try {
    $prefix = $OutputDirectory.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $known = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $zip.Entries) {
      $name = $entry.FullName.Replace('\', '/')
      $trimmed = $name.TrimEnd('/')
      if ([string]::IsNullOrWhiteSpace($trimmed) -or $name.StartsWith('/') -or
          $name -match '(^|/)\.{1,2}(/|$)|:|[\x00-\x1f]' -or -not $known.Add($trimmed)) {
        throw "Unsafe or duplicate Release ZIP entry: $name"
      }
      $target = [IO.Path]::GetFullPath((Join-Path $OutputDirectory $trimmed.Replace('/', [IO.Path]::DirectorySeparatorChar)))
      if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Release ZIP entry escapes output directory: $name"
      }
      if ([string]::IsNullOrEmpty($entry.Name)) {
        $null = New-Item -ItemType Directory -Path $target -Force
        continue
      }
      $parent = Split-Path -Parent $target
      $null = New-Item -ItemType Directory -Path $parent -Force
      $input = $entry.Open()
      $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
      try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
    }
  } finally { $zip.Dispose() }
} finally {
  if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
}

Write-Host "Downloaded verified Release component: $($expected.assetName)"
