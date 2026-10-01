#Requires -Version 7.2
[CmdletBinding()]
param(
  [string]$Package = '.\build\packages\ime-runtime\kirakara-ime-runtime-windows-x64-v2.zip',
  [string]$CandidateLock = '.\build\packages\ime-runtime\ime-runtime.candidate.lock.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$workspace = Join-Path $repository '.kfe'
Import-Module (Join-Path $repository `
    'engine/scripts/artifact_package.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot `
    'native_runtime_package.psm1') -Force -DisableNameChecking

function Assert-ExpectedFailure {
  param(
    [Parameter(Mandatory)][scriptblock]$Action,
    [Parameter(Mandatory)][string]$Pattern,
    [Parameter(Mandatory)][string]$Label
  )
  try {
    & $Action
  } catch {
    if ($_.Exception.Message -notmatch $Pattern) {
      throw "$Label 虽被拒绝，但错误不明确：$($_.Exception.Message)"
    }
    return
  }
  throw "$Label 未被拒绝。"
}

function New-RuntimeFixture {
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Root
  )
  $destination = Join-Path $Root $Name
  Copy-Item -LiteralPath $Source -Destination $destination -Recurse
  return $destination
}

function Set-PeMachineX86 {
  param([Parameter(Mandatory)][string]$Path)
  $bytes = [IO.File]::ReadAllBytes($Path)
  $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
  $bytes[$peOffset + 4] = 0x4c
  $bytes[$peOffset + 5] = 0x01
  [IO.File]::WriteAllBytes($Path, $bytes)
}

function Set-FirstCoffMemberMachineX86 {
  param([Parameter(Mandatory)][string]$Path)
  $bytes = [IO.File]::ReadAllBytes($Path)
  $offset = 8
  while ($offset + 60 -le $bytes.Length) {
    $header = [Text.Encoding]::ASCII.GetString($bytes, $offset, 60)
    $size = [long]::Parse($header.Substring(48, 10).Trim())
    $name = $header.Substring(0, 16).Trim()
    $dataOffset = $offset + 60
    if (-not $name.StartsWith('/') -and $size -ge 20) {
      $bytes[$dataOffset] = 0x4c
      $bytes[$dataOffset + 1] = 0x01
      [IO.File]::WriteAllBytes($Path, $bytes)
      return
    }
    $offset = $dataOffset + $size
    if (($offset % 2) -ne 0) { $offset++ }
  }
  throw '测试夹具未找到可修改的 COFF 成员。'
}

$packagePath = [IO.Path]::GetFullPath(
  $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
    $Package))
$lockPath = [IO.Path]::GetFullPath(
  $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
    $CandidateLock))
$expected = Get-NativeRuntimeIdentity
$entry = Get-NativeRuntimeEntry -LockPath $lockPath
Assert-ArtifactFile $packagePath $entry.entry

$installed = Ensure-NativeRuntimePackage -Package $packagePath `
  -LockPath $lockPath -ForcePrebuilt
$runtime = $installed.runtime
Assert-NativeRuntimeDirectory $runtime $expected

$archive = [IO.Compression.ZipFile]::OpenRead($packagePath)
try {
  $names = @($archive.Entries | ForEach-Object { $_.FullName })
  if ($names -contains '' -or
      @($names | Where-Object {
          $_ -match '(?i)(libshow_host|\.pdb$|\.obj$|(^|/)(source|src|build|cache|models?|data)(/|$))'
        }).Count -ne 0) {
    throw 'IME 候选 ZIP 混入 Show、源码、模型、数据、PDB、OBJ 或缓存。'
  }
  foreach ($required in @(
      'runtime/ime/rime/windows/rime.dll',
      'runtime/ime/mozc/windows/runtime/kirakara_mozc_bridge.exe',
      'runtime/ime/zinnia/windows/include/zinnia.h',
      'runtime/ime/zinnia/windows/lib/Debug/kirakara_zinnia.lib',
      'runtime/ime/zinnia/windows/lib/Release/kirakara_zinnia.lib',
      'licenses/librime-BSD-3-Clause.txt',
      'licenses/Mozc-BSD-3-Clause.txt',
      'licenses/Zinnia-BSD-3-Clause.txt')) {
    if (@($names | Where-Object { $_ -ceq $required }).Count -ne 1) {
      throw "IME 候选 ZIP 缺少或重复文件：$required"
    }
  }
} finally {
  $archive.Dispose()
}

$moduleText = Get-Content -Raw -LiteralPath (
  Join-Path $PSScriptRoot 'native_runtime_package.psm1')
$bootstrapText = Get-Content -Raw -LiteralPath (
  Join-Path $repository 'engine/scripts/project_engine_bootstrap.psm1')
$runnerCmake = Get-Content -Raw -LiteralPath (
  Join-Path $repository 'windows/runner/CMakeLists.txt')
foreach ($forbidden in @(
    'Write-NativeRuntimeSourceSelection',
    '.kfe/source',
    'prepare_zinnia_sources',
    'build_librime.ps1',
    'bazel.exe',
    'cl.exe')) {
  if ($moduleText.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
    throw "普通 IME 包模块仍含源码构建入口：$forbidden"
  }
}
foreach ($forbidden in @(
    'build_zinnia_prebuilt',
    'prepare_zinnia_sources',
    'build_librime.ps1',
    'bazel.exe')) {
  if ($bootstrapText.Contains(
      $forbidden, [StringComparison]::OrdinalIgnoreCase)) {
    throw "普通 flutterw 路由仍可触发输入法构建：$forbidden"
  }
}
if ($runnerCmake -match '(?i)ZINNIA_SOURCE_DIR|add_subdirectory\([^\r\n]*zinnia' -or
    -not $runnerCmake.Contains('IMPORTED_LOCATION_PROFILE') -or
    -not $runnerCmake.Contains('zinnia/windows/lib/Release')) {
  throw 'Runner 未明确使用预编译 Zinnia，或 Profile 未显式复用 Release。'
}

$scratch = Join-Path $workspace (
  'tmp/test-ime-runtime-' + [Guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null = New-Item -ItemType Directory -Path $scratch
try {
  $missing = New-RuntimeFixture $runtime 'missing' $scratch
  Remove-Item -LiteralPath (
    Join-Path $missing 'ime/rime/windows/rime.dll') -Force
  Assert-ExpectedFailure {
    Assert-NativeRuntimeDirectory $missing $expected
  } '缺少必需文件' '缺失文件夹具'

  $corrupt = New-RuntimeFixture $runtime 'corrupt' $scratch
  $corruptHeader = Join-Path $corrupt 'ime/zinnia/windows/include/zinnia.h'
  [IO.File]::AppendAllText(
    $corruptHeader, "`ncorrupt", [Text.UTF8Encoding]::new($false))
  Assert-ExpectedFailure {
    Assert-NativeRuntimeDirectory $corrupt $expected
  } 'SHA-256|大小' '损坏哈希夹具'

  $x86Pe = New-RuntimeFixture $runtime 'x86-pe' $scratch
  Set-PeMachineX86 (
    Join-Path $x86Pe 'ime/rime/windows/rime.dll')
  Assert-ExpectedFailure {
    Assert-NativeRuntimeDirectory $x86Pe $expected
  } 'Windows x64 PE|不是 Windows x64 DLL' 'x86 PE 夹具'

  $x86Lib = New-RuntimeFixture $runtime 'x86-lib' $scratch
  Set-FirstCoffMemberMachineX86 (
    Join-Path $x86Lib `
      'ime/zinnia/windows/lib/Debug/kirakara_zinnia.lib')
  Assert-ExpectedFailure {
    Assert-NativeRuntimeDirectory $x86Lib $expected
  } '不是八成员 Windows x64' 'x86 COFF 夹具'

  $hostPath = New-RuntimeFixture $runtime 'host-path' $scratch
  $provenancePath = Join-Path $hostPath 'ime-runtime-provenance.json'
  $provenance = Get-Content -Raw -LiteralPath $provenancePath |
    ConvertFrom-Json
  $provenance | Add-Member -NotePropertyName injectedHostPath `
    -NotePropertyValue (Join-Path $repository '.kfe/forbidden')
  [IO.File]::WriteAllText(
    $provenancePath,
    ($provenance | ConvertTo-Json -Depth 20),
    [Text.UTF8Encoding]::new($false))
  Assert-ExpectedFailure {
    Assert-NativeRuntimeDirectory $hostPath $expected
  } '宿主机专属路径或标识' '宿主路径夹具'
} finally {
  $expectedPrefix = Join-Path $workspace 'tmp/test-ime-runtime-'
  if (-not $scratch.StartsWith(
      $expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'IME runtime 测试临时目录越界。'
  }
  if (Test-Path -LiteralPath $scratch) {
    [Kirakara.Artifacts.Security]::NoReparse($scratch)
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
}

Write-Host 'IME runtime 包边界、哈希、x64、CRT、路径与普通路由回归测试通过。'
