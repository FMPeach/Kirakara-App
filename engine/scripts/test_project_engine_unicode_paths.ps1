[CmdletBinding()]
param([string]$ReportPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$modulePath = Join-Path $PSScriptRoot 'project_engine_bootstrap.psm1'
Import-Module $modulePath -Force
. (Join-Path $PSScriptRoot 'common.ps1')

$ready = Assert-KirakaraProjectEngineReady -Mode profile
$output = [IO.Path]::GetFullPath($ready.output)
$shaderArchiver = Join-Path $output 'shader_archiver.exe'
$genSnapshot = Join-Path $output 'gen_snapshot.exe'
$platformKernel = Join-Path $output 'flutter_patched_sdk\platform_strong.dill'
$shaderSource = Join-Path $output `
  'gen\flutter\impeller\entity\gles3\framebuffer_blend.vert.gles'

foreach ($required in @(
    $shaderArchiver,
    $genSnapshot,
    $platformKernel,
    $shaderSource
  )) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required profile Engine artifact is missing: $required"
  }
}

$workspace = Join-Path $repository '.kfe'
$temporaryRoot = [IO.Path]::GetFullPath((Join-Path $workspace 'tmp'))
if (-not (Test-PathWithin $temporaryRoot $workspace)) {
  throw "Temporary root escaped the repository-local workspace: $temporaryRoot"
}
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null

$probeDirectory = [IO.Path]::GetFullPath((Join-Path $temporaryRoot `
  ("unicode-路径-{0}" -f [guid]::NewGuid().ToString('N'))))
if (-not (Test-PathWithin $probeDirectory $temporaryRoot) -or
    $probeDirectory.Equals(
      $temporaryRoot,
      [StringComparison]::OrdinalIgnoreCase
    )) {
  throw "Refusing to use an unsafe Unicode probe directory: $probeDirectory"
}
if ($probeDirectory -notmatch '[^\x00-\x7F]') {
  throw "Unicode probe directory does not contain a non-ASCII segment."
}
if (Test-Path -LiteralPath $probeDirectory) {
  throw "Unicode probe directory already exists: $probeDirectory"
}

$shaderOutputText = ''
$snapshotOutputText = ''
$results = $null
New-Item -ItemType Directory -Path $probeDirectory | Out-Null
try {
  Copy-Item -LiteralPath $shaderSource `
    -Destination (Join-Path $probeDirectory 'shader.vert.gles')

  Push-Location $probeDirectory
  try {
    $shaderOutput = @(
      & $shaderArchiver `
        '--input=shader.vert.gles' `
        '--output=probe.shar' 2>&1
    )
    $shaderExitCode = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  $shaderOutputText = @(
    $shaderOutput | ForEach-Object { $_.ToString() }
  ) -join "`n"
  if ($shaderExitCode -ne 0) {
    throw "shader_archiver Unicode-path probe failed: $shaderOutputText"
  }

  $shaderArchive = Join-Path $probeDirectory 'probe.shar'
  if (-not (Test-Path -LiteralPath $shaderArchive -PathType Leaf) -or
      (Get-Item -LiteralPath $shaderArchive).Length -le 0) {
    throw "shader_archiver did not create a non-empty archive."
  }

  $snapshotPaths = [ordered]@{
    vmData = Join-Path $probeDirectory 'vm_data.bin'
    vmInstructions = Join-Path $probeDirectory 'vm_instructions.bin'
    isolateData = Join-Path $probeDirectory 'isolate_data.bin'
    isolateInstructions = Join-Path $probeDirectory 'isolate_instructions.bin'
  }
  $snapshotArguments = @(
    '--snapshot_kind=core'
    '--enable_mirrors=false'
    "--vm_snapshot_data=$($snapshotPaths.vmData)"
    "--vm_snapshot_instructions=$($snapshotPaths.vmInstructions)"
    "--isolate_snapshot_data=$($snapshotPaths.isolateData)"
    "--isolate_snapshot_instructions=$($snapshotPaths.isolateInstructions)"
    $platformKernel
  )
  $snapshotOutput = @(& $genSnapshot @snapshotArguments 2>&1)
  $snapshotExitCode = $LASTEXITCODE
  $snapshotOutputText = @(
    $snapshotOutput | ForEach-Object { $_.ToString() }
  ) -join "`n"
  if ($snapshotExitCode -ne 0) {
    throw "gen_snapshot Unicode-argument probe failed: $snapshotOutputText"
  }

  $snapshotFiles = [ordered]@{}
  foreach ($entry in $snapshotPaths.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
      throw "gen_snapshot did not create $($entry.Key): $($entry.Value)"
    }
    $length = (Get-Item -LiteralPath $entry.Value).Length
    if ($entry.Key -in @('vmData', 'isolateData') -and $length -le 0) {
      throw "gen_snapshot created an empty $($entry.Key) output."
    }
    $snapshotFiles[$entry.Key] = $length
  }

  $results = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    repository = $repository
    mode = 'profile'
    engineFingerprint = $ready.fingerprint
    unicodePath = $probeDirectory
    pathContainsNonAscii = $true
    shaderArchiver = [ordered]@{
      sha256 = (Get-FileHash -LiteralPath $shaderArchiver -Algorithm SHA256).Hash
      exitCode = $shaderExitCode
      archiveSize = (Get-Item -LiteralPath $shaderArchive).Length
    }
    genSnapshot = [ordered]@{
      sha256 = (Get-FileHash -LiteralPath $genSnapshot -Algorithm SHA256).Hash
      exitCode = $snapshotExitCode
      outputs = $snapshotFiles
    }
    passed = $true
  }
} finally {
  if (-not (Test-PathWithin $probeDirectory $temporaryRoot) -or
      $probeDirectory.Equals(
        $temporaryRoot,
        [StringComparison]::OrdinalIgnoreCase
      )) {
    throw "Refusing to remove an unsafe Unicode probe directory: $probeDirectory"
  }
  if (Test-Path -LiteralPath $probeDirectory) {
    Remove-Item -LiteralPath $probeDirectory -Recurse -Force
  }
}

if ($null -eq $results) {
  throw 'Unicode-path probe did not produce results.'
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $ReportPath = Join-Path $repository `
    "build\diagnostics\engine\project-engine-unicode-paths-$stamp.json"
}
$absoluteReport = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
  $ReportPath)
if (Test-Path -LiteralPath $absoluteReport) {
  throw "ReportPath already exists: $absoluteReport"
}
New-Item -ItemType Directory -Path (Split-Path -Parent $absoluteReport) `
  -Force | Out-Null
$results | ConvertTo-Json -Depth 8 | Set-Content `
  -LiteralPath $absoluteReport `
  -Encoding utf8
Write-Host "Project Engine Unicode-path tests passed. Report: $absoluteReport"
