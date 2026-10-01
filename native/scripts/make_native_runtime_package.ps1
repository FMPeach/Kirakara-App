#Requires -Version 7.2
[CmdletBinding()]
param(
  [string]$OutputDirectory,
  [string]$StagingRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$workspace = Join-Path $repository '.kfe'
Import-Module (Join-Path $repository `
    'engine/scripts/artifact_package.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot `
    'native_runtime_package.psm1') -DisableNameChecking

$expected = Get-NativeRuntimeIdentity
if ([string]::IsNullOrWhiteSpace($StagingRoot)) {
  $StagingRoot = Join-Path $workspace 'native/ime-runtime-staging-v2'
}
$staging = [IO.Path]::GetFullPath($StagingRoot)
$workspacePrefix = $workspace.TrimEnd('\', '/') + '\'
if (-not $staging.StartsWith(
    $workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'IME runtime staging 必须位于当前仓库 .kfe。'
}
[Kirakara.Artifacts.Security]::NoReparse($staging)
$runtime = Join-Path $staging 'runtime'
Assert-NativeRuntimeDirectory -RuntimeRoot $runtime -Expected $expected

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $OutputDirectory = Join-Path $repository 'build/packages/ime-runtime'
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith(
    $repository.TrimEnd('\', '/') + '\',
    [StringComparison]::OrdinalIgnoreCase)) {
  throw 'IME runtime 候选包必须生成在当前仓库。'
}
[Kirakara.Artifacts.Security]::NoReparse($output)
$null = New-Item -ItemType Directory -Path $output -Force
$archive = Join-Path $output 'kirakara-ime-runtime-windows-x64-v2.zip'
$candidate = Join-Path $output 'ime-runtime.candidate.lock.json'
if ((Test-Path -LiteralPath $archive) -or
    (Test-Path -LiteralPath $candidate)) {
  throw 'IME runtime 候选文件已存在，不覆盖。请使用新输出目录。'
}

$scratch = Join-Path $workspace (
  'tmp/pack-ime-runtime-' + [Guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null = New-Item -ItemType Directory -Path $scratch
try {
  $runtimeFiles = @(
    'ime-runtime-provenance.json',
    'ime/rime/windows/rime.dll',
    'ime/mozc/windows/runtime/kirakara_mozc_bridge.exe',
    'ime/zinnia/windows/include/zinnia.h',
    'ime/zinnia/windows/lib/Debug/kirakara_zinnia.lib',
    'ime/zinnia/windows/lib/Release/kirakara_zinnia.lib',
    'ime/zinnia/windows/provenance.json'
  )
  foreach ($relative in $runtimeFiles) {
    $source = [Kirakara.Artifacts.Security]::Child($runtime, $relative)
    $destination = [Kirakara.Artifacts.Security]::Child(
      $scratch, ('runtime/' + $relative))
    $null = New-Item -ItemType Directory -Path (
      Split-Path -Parent $destination) -Force
    Copy-Item -LiteralPath $source -Destination $destination
  }
  foreach ($license in @(
      $expected.identity.rime.license,
      $expected.identity.mozc.license,
      $expected.identity.zinnia.license)) {
    $source = [Kirakara.Artifacts.Security]::Child(
      $repository, [string]$license.path)
    Assert-ArtifactFile $source $license
    $destination = Join-Path $scratch (
      'licenses/' + [IO.Path]::GetFileName([string]$license.path))
    $null = New-Item -ItemType Directory -Path (
      Split-Path -Parent $destination) -Force
    Copy-Item -LiteralPath $source -Destination $destination
  }
  [IO.File]::WriteAllText(
    (Join-Path $scratch 'SOURCES.json'),
    ($expected.identity | ConvertTo-Json -Depth 20),
    [Text.UTF8Encoding]::new($false))
  $files = @(Get-ChildItem -LiteralPath $scratch -Recurse -File |
      Sort-Object FullName | ForEach-Object {
        [ordered]@{
          path = [IO.Path]::GetRelativePath(
            $scratch, $_.FullName).Replace('\', '/')
          size = $_.Length
          sha256 = Get-ArtifactHash $_.FullName
        }
      })
  $manifest = [ordered]@{
    schemaVersion = 1
    kind = 'ime-runtime'
    identityHash = $expected.value
    identity = $expected.identity
    files = $files
  }
  $manifestPath = Join-Path $scratch 'manifest.json'
  [IO.File]::WriteAllText(
    $manifestPath,
    ($manifest | ConvertTo-Json -Depth 20),
    [Text.UTF8Encoding]::new($false))
  Assert-NativeRuntimeContents $scratch $manifest $expected
  [IO.Compression.ZipFile]::CreateFromDirectory(
    $scratch, $archive, [IO.Compression.CompressionLevel]::Optimal, $false)
  $entry = [ordered]@{
    identityHash = $expected.value
    url = $null
    size = (Get-Item -LiteralPath $archive).Length
    sha256 = Get-ArtifactHash $archive
    manifestSha256 = Get-ArtifactHash $manifestPath
  }
  [ordered]@{
    schemaVersion = 1
    packageFormatVersion = 2
    target = 'windows-x64'
    formalReleaseAllowed = $false
    imeRuntime = $entry
  } | ConvertTo-Json -Depth 6 | Set-Content `
    -LiteralPath $candidate -Encoding utf8
  Write-Host "IME runtime 候选包：$archive"
  Write-Host "候选锁：$candidate"
  Write-Host '已校验 Rime API、Mozc 固定候选与 Zinnia x64/CRT；没有执行源码构建。'
  [pscustomobject]@{
    archive = $archive
    candidateLock = $candidate
    identityHash = $expected.value
    size = $entry.size
    sha256 = $entry.sha256
    manifestSha256 = $entry.manifestSha256
  }
} finally {
  $expectedPrefix = Join-Path $workspace 'tmp/pack-ime-runtime-'
  if (-not $scratch.StartsWith(
      $expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'IME runtime 打包临时目录越界。'
  }
  if (Test-Path -LiteralPath $scratch) {
    [Kirakara.Artifacts.Security]::NoReparse($scratch)
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
}
