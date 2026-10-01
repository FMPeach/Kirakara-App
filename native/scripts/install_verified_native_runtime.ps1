#Requires -Version 7.2
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$RimeReleaseArchive,
  [Parameter(Mandatory)][string]$MozcBridge,
  [Parameter(Mandatory)][string]$ZinniaPrebuiltRoot,
  [string]$OutputRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$workspace = Join-Path $repository '.kfe'
Import-Module (Join-Path $repository `
    'engine/scripts/artifact_package.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot `
    'native_runtime_package.psm1') -DisableNameChecking

function Resolve-WorkspaceInput {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][ValidateSet('Leaf', 'Container')]
      [string]$PathType
  )
  $absolute = [IO.Path]::GetFullPath(
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
  $prefix = $workspace.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  if (-not $absolute.StartsWith(
      $prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "IME 候选输入必须位于当前仓库 .kfe：$absolute"
  }
  [Kirakara.Artifacts.Security]::NoReparse($absolute)
  if (-not (Test-Path -LiteralPath $absolute -PathType $PathType)) {
    throw "IME 候选输入不存在：$absolute"
  }
  return $absolute
}

function Copy-StagedFile {
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$RelativePath
  )
  [Kirakara.Artifacts.Security]::NoReparse($Source)
  $destination = [Kirakara.Artifacts.Security]::Child($Root, $RelativePath)
  $null = New-Item -ItemType Directory -Path (
    Split-Path -Parent $destination) -Force
  Copy-Item -LiteralPath $Source -Destination $destination
  return $destination
}

$expected = Get-NativeRuntimeIdentity
$identity = $expected.identity
$rimeArchive = Resolve-WorkspaceInput $RimeReleaseArchive Leaf
$mozc = Resolve-WorkspaceInput $MozcBridge Leaf
$zinniaRoot = Resolve-WorkspaceInput $ZinniaPrebuiltRoot Container

Assert-ArtifactFile $rimeArchive $identity.rime.asset
Assert-ArtifactFile $mozc $identity.mozc.executable
$zinniaInputs = [ordered]@{
  header = [ordered]@{
    path = Join-Path $zinniaRoot 'include/zinnia.h'
    record = $identity.zinnia.header
  }
  debug = [ordered]@{
    path = Join-Path $zinniaRoot 'Debug/kirakara_zinnia.lib'
    record = $identity.zinnia.debugLibrary
  }
  release = [ordered]@{
    path = Join-Path $zinniaRoot 'Release/kirakara_zinnia.lib'
    record = $identity.zinnia.releaseLibrary
  }
  provenance = [ordered]@{
    path = Join-Path $zinniaRoot 'provenance.json'
    record = $identity.zinnia.provenance
  }
  license = [ordered]@{
    path = Join-Path $zinniaRoot 'COPYING'
    record = $identity.zinnia.license
  }
}
foreach ($input in $zinniaInputs.Values) {
  Assert-ArtifactFile $input.path $input.record
}
Assert-ZinniaLibraryContract $zinniaInputs.debug.path Debug
Assert-ZinniaLibraryContract $zinniaInputs.release.path Release

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path $workspace 'native/ime-runtime-staging-v2'
}
$output = [IO.Path]::GetFullPath($OutputRoot)
$workspacePrefix = $workspace.TrimEnd('\', '/') + '\'
if (-not $output.StartsWith(
    $workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'IME runtime staging 只能写入当前仓库 .kfe。'
}
[Kirakara.Artifacts.Security]::NoReparse($output)
if (Test-Path -LiteralPath $output) {
  throw "IME runtime staging 已存在，不覆盖：$output"
}

$scratch = Join-Path $workspace (
  'tmp/stage-ime-runtime-' + [Guid]::NewGuid().ToString('N'))
$extract = Join-Path $scratch 'extract-rime'
$staged = Join-Path $scratch 'publish'
$runtime = Join-Path $staged 'runtime'
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null = New-Item -ItemType Directory -Path $extract -Force
try {
  & tar.exe -xf $rimeArchive -C $extract ([string]$identity.rime.dll.archivePath)
  if ($LASTEXITCODE -ne 0) {
    throw "Rime 官方资产解压失败（$LASTEXITCODE）。"
  }
  $rimeDll = [Kirakara.Artifacts.Security]::Child(
    $extract, [string]$identity.rime.dll.archivePath)
  Assert-ArtifactFile $rimeDll $identity.rime.dll

  $null = Copy-StagedFile $rimeDll $runtime `
    'ime/rime/windows/rime.dll'
  $null = Copy-StagedFile $mozc $runtime `
    'ime/mozc/windows/runtime/kirakara_mozc_bridge.exe'
  $null = Copy-StagedFile $zinniaInputs.header.path $runtime `
    'ime/zinnia/windows/include/zinnia.h'
  $null = Copy-StagedFile $zinniaInputs.debug.path $runtime `
    'ime/zinnia/windows/lib/Debug/kirakara_zinnia.lib'
  $null = Copy-StagedFile $zinniaInputs.release.path $runtime `
    'ime/zinnia/windows/lib/Release/kirakara_zinnia.lib'
  $null = Copy-StagedFile $zinniaInputs.provenance.path $runtime `
    'ime/zinnia/windows/provenance.json'

  $runtimeProvenance = [ordered]@{
    schemaVersion = 2
    kind = 'ime-runtime'
    identityHash = [string]$expected.value
    identity = $identity
  }
  $null = New-Item -ItemType Directory -Path $runtime -Force
  [IO.File]::WriteAllText(
    (Join-Path $runtime 'ime-runtime-provenance.json'),
    ($runtimeProvenance | ConvertTo-Json -Depth 20),
    [Text.UTF8Encoding]::new($false))

  Assert-NativeRuntimeDirectory -RuntimeRoot $runtime -Expected $expected
  $parent = Split-Path -Parent $output
  [Kirakara.Artifacts.Security]::NoReparse($parent)
  $null = New-Item -ItemType Directory -Path $parent -Force
  [IO.Directory]::Move($staged, $output)
  Assert-NativeRuntimeDirectory -RuntimeRoot (
    Join-Path $output 'runtime') -Expected $expected

  Write-Host "IME runtime staging 已生成：$output"
  [pscustomobject]@{
    root = $output
    identityHash = $expected.value
    rimeSha256 = Get-ArtifactHash (
      Join-Path $output 'runtime/ime/rime/windows/rime.dll')
    mozcSha256 = Get-ArtifactHash (
      Join-Path $output `
        'runtime/ime/mozc/windows/runtime/kirakara_mozc_bridge.exe')
    zinniaDebugSha256 = Get-ArtifactHash (
      Join-Path $output `
        'runtime/ime/zinnia/windows/lib/Debug/kirakara_zinnia.lib')
    zinniaReleaseSha256 = Get-ArtifactHash (
      Join-Path $output `
        'runtime/ime/zinnia/windows/lib/Release/kirakara_zinnia.lib')
  }
} finally {
  $expectedPrefix = Join-Path $workspace 'tmp/stage-ime-runtime-'
  if (-not $scratch.StartsWith(
      $expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'IME runtime staging 临时目录越界。'
  }
  if (Test-Path -LiteralPath $scratch) {
    [Kirakara.Artifacts.Security]::NoReparse($scratch)
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
}
