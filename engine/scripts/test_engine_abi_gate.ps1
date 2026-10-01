[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$FlutterSdkRoot,

  [Parameter(Mandatory = $true)]
  [string]$WorkspaceRoot,

  [ValidateSet('debug', 'profile', 'release')]
  [string[]]$Mode = @('debug', 'profile', 'release'),

  [string]$ReportPath,

  [switch]$AllowUnlockedArtifacts
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if ([IntPtr]::Size -ne 8) {
  throw 'The Kirakara Windows compositor ABI gate must run in a 64-bit PowerShell process.'
}

if (-not ('Kirakara.EngineAbi.NativeMethods' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Kirakara.EngineAbi {
  public static class NativeMethods {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryExW(
        string fileName, IntPtr file, uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    public static extern IntPtr GetProcAddress(
        IntPtr module, string procedureName);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FreeLibrary(IntPtr module);
  }

  [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
  public delegate int GetApiDelegate(uint requestedAbiVersion, IntPtr api);
}
'@
}

$lock = Get-EngineLock
$flutterRoot = Resolve-UnresolvedPath $FlutterSdkRoot
$layout = Get-EngineWorkspaceLayout $WorkspaceRoot
Assert-ExternalEngineWorkspace $layout
Assert-AppliedPatchset -Lock $lock -Layout $layout

$expectedAbi = [uint32]$lock.patchset.abiVersion
$expectedPatchsetVersion = [uint32]$lock.patchset.version
$expectedPatchsetRevision = [string]$lock.patchset.revision
$expectedEngineRevision = [string]$lock.flutter.engineRevision
$apiStructSize = 88
$versionMismatch = 2
$success = 0
$loadLibrarySearchDllLoadDir = 0x00000100
$loadLibrarySearchDefaultDirs = 0x00001000
$loadFlags = $loadLibrarySearchDllLoadDir -bor $loadLibrarySearchDefaultDirs
$exportName = 'FlutterDesktopKirakaraCompositorGetApi'

function Get-OfficialEngineDirectory {
  param([Parameter(Mandatory = $true)][string]$BuildMode)

  $directoryName = switch ($BuildMode) {
    'debug' { 'windows-x64' }
    'profile' { 'windows-x64-profile' }
    'release' { 'windows-x64-release' }
  }
  return Join-Path $flutterRoot "bin\cache\artifacts\engine\$directoryName"
}

function Invoke-AbiExportProbe {
  param(
    [Parameter(Mandatory = $true)][string]$DllPath,
    [Parameter(Mandatory = $true)][bool]$ExpectExport
  )

  if (-not (Test-Path -LiteralPath $DllPath -PathType Leaf)) {
    throw "Engine DLL is missing: $DllPath"
  }

  $module = [Kirakara.EngineAbi.NativeMethods]::LoadLibraryExW(
    $DllPath,
    [IntPtr]::Zero,
    $loadFlags)
  if ($module -eq [IntPtr]::Zero) {
    $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "LoadLibraryExW failed for '$DllPath' with Win32 error $errorCode."
  }

  try {
    $procedure = [Kirakara.EngineAbi.NativeMethods]::GetProcAddress(
      $module,
      $exportName)
    if (-not $ExpectExport) {
      if ($procedure -ne [IntPtr]::Zero) {
        throw "Stock Engine unexpectedly exports ${exportName}: $DllPath"
      }
      return [ordered]@{
        path = $DllPath
        sha256 = (Get-FileHash -LiteralPath $DllPath -Algorithm SHA256).Hash
        exportPresent = $false
        passed = $true
      }
    }

    if ($procedure -eq [IntPtr]::Zero) {
      throw "Patched Engine is missing ${exportName}: $DllPath"
    }
    $getApi = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
      $procedure,
      [type][Kirakara.EngineAbi.GetApiDelegate])
    $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal($apiStructSize)
    try {
      $zeros = [byte[]]::new($apiStructSize)

      [Runtime.InteropServices.Marshal]::Copy($zeros, 0, $buffer, $apiStructSize)
      [Runtime.InteropServices.Marshal]::WriteInt32($buffer, 0, $apiStructSize)
      $wrongAbiResult = $getApi.Invoke([uint32]($expectedAbi + 1), $buffer)
      if ($wrongAbiResult -ne $versionMismatch) {
        throw "Mismatched ABI returned $wrongAbiResult instead of $versionMismatch."
      }

      [Runtime.InteropServices.Marshal]::Copy($zeros, 0, $buffer, $apiStructSize)
      [Runtime.InteropServices.Marshal]::WriteInt32($buffer, 0, $apiStructSize - 8)
      $wrongSizeResult = $getApi.Invoke([uint32]$expectedAbi, $buffer)
      if ($wrongSizeResult -ne $versionMismatch) {
        throw "Mismatched API struct size returned $wrongSizeResult instead of $versionMismatch."
      }

      [Runtime.InteropServices.Marshal]::Copy($zeros, 0, $buffer, $apiStructSize)
      [Runtime.InteropServices.Marshal]::WriteInt32($buffer, 0, $apiStructSize)
      $exactResult = $getApi.Invoke([uint32]$expectedAbi, $buffer)
      if ($exactResult -ne $success) {
        throw "Exact compositor ABI returned $exactResult instead of $success."
      }

      $actualStructSize = [Runtime.InteropServices.Marshal]::ReadInt32($buffer, 0)
      $actualAbi = [Runtime.InteropServices.Marshal]::ReadInt32($buffer, 4)
      $actualPatchsetVersion = [Runtime.InteropServices.Marshal]::ReadInt32($buffer, 8)
      $patchsetPointer = [Runtime.InteropServices.Marshal]::ReadIntPtr($buffer, 16)
      $enginePointer = [Runtime.InteropServices.Marshal]::ReadIntPtr($buffer, 24)
      $actualPatchsetRevision = [Runtime.InteropServices.Marshal]::PtrToStringAnsi(
        $patchsetPointer)
      $actualEngineRevision = [Runtime.InteropServices.Marshal]::PtrToStringAnsi(
        $enginePointer)
      $functionPointersPresent = $true
      foreach ($offset in 32, 40, 48, 56, 64, 72) {
        if ([Runtime.InteropServices.Marshal]::ReadIntPtr($buffer, $offset) -eq
            [IntPtr]::Zero) {
          $functionPointersPresent = $false
        }
      }

      if (
        $actualStructSize -ne $apiStructSize -or
        $actualAbi -ne $expectedAbi -or
        $actualPatchsetVersion -ne $expectedPatchsetVersion -or
        $actualPatchsetRevision -ne $expectedPatchsetRevision -or
        $actualEngineRevision -ne $expectedEngineRevision -or
        -not $functionPointersPresent
      ) {
        throw 'Patched Engine returned compositor metadata that does not match engine.lock.json.'
      }

      return [ordered]@{
        path = $DllPath
        sha256 = (Get-FileHash -LiteralPath $DllPath -Algorithm SHA256).Hash
        exportPresent = $true
        wrongAbiResult = $wrongAbiResult
        wrongStructSizeResult = $wrongSizeResult
        exactResult = $exactResult
        structSize = $actualStructSize
        abiVersion = $actualAbi
        patchsetVersion = $actualPatchsetVersion
        patchsetRevision = $actualPatchsetRevision
        engineRevision = $actualEngineRevision
        functionPointersPresent = $functionPointersPresent
        passed = $true
      }
    } finally {
      [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
    }
  } finally {
    if (-not [Kirakara.EngineAbi.NativeMethods]::FreeLibrary($module)) {
      $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
      throw "FreeLibrary failed for '$DllPath' with Win32 error $errorCode."
    }
  }
}

$results = @()
foreach ($buildMode in $Mode) {
  $build = Get-BuildLock -Lock $lock -Mode $buildMode -Variant patched
  $patchedDirectory = Get-EngineOutputDirectory `
    -Layout $layout `
    -LocalEngine $build.localEngine
  if (-not $AllowUnlockedArtifacts) {
    Assert-LockedEngineArtifacts -Build $build -OutputDirectory $patchedDirectory
  } elseif (-not (Test-Path -LiteralPath (
      Join-Path $patchedDirectory 'flutter_windows.dll'
    ) -PathType Leaf)) {
    throw "Patched Engine DLL is missing: $patchedDirectory"
  }
  $officialDirectory = Get-OfficialEngineDirectory -BuildMode $buildMode

  $results += [ordered]@{
    mode = $buildMode
    official = Invoke-AbiExportProbe `
      -DllPath (Join-Path $officialDirectory 'flutter_windows.dll') `
      -ExpectExport $false
    patched = Invoke-AbiExportProbe `
      -DllPath (Join-Path $patchedDirectory 'flutter_windows.dll') `
      -ExpectExport $true
  }
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $ReportPath = Join-Path (Get-AppRepositoryRoot) `
    "build\diagnostics\engine\abi-gate-$stamp.json"
}
$absoluteReport = Resolve-UnresolvedPath $ReportPath
if (Test-Path -LiteralPath $absoluteReport) {
  throw "ReportPath already exists; preserve it or choose another path: $absoluteReport"
}
New-Item -ItemType Directory -Path (Split-Path -Parent $absoluteReport) `
  -Force | Out-Null

$report = [ordered]@{
  schemaVersion = 1
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  frameworkRevision = $lock.flutter.frameworkRevision
  engineRevision = $expectedEngineRevision
  patchsetRevision = $expectedPatchsetRevision
  patchsetVersion = $expectedPatchsetVersion
  abiVersion = $expectedAbi
  modes = $results
  passed = $true
}
$report | ConvertTo-Json -Depth 8 | Set-Content `
  -LiteralPath $absoluteReport -Encoding utf8
Write-Host "Engine ABI gate passed. Report: $absoluteReport"
