[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ShowHostDll,

  [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not ('Kirakara.ShowHostAbi.NativeInspector' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Kirakara.ShowHostAbi {
  [StructLayout(LayoutKind.Sequential)]
  public struct StageVisualApi {
    public UInt32 StructSize;
    public UInt32 AbiVersion;
    public UInt64 Capabilities;
    public IntPtr ProtocolRevision;
    public IntPtr CreateSource;
    public IntPtr DestroySource;
    public IntPtr SetActive;
    public IntPtr SetFrameCallback;
    public IntPtr GetStats;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4)]
    public UInt64[] Reserved;
  }

  [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
  internal delegate Int32 GetStageVisualApi(
      UInt32 requestedAbiVersion,
      ref StageVisualApi api);

  public sealed class Inspection {
    public UInt32 StructSize { get; set; }
    public Int32 WrongVersionResult { get; set; }
    public Int32 WrongSizeResult { get; set; }
    public Int32 MatchingResult { get; set; }
    public UInt32 AbiVersion { get; set; }
    public UInt64 Capabilities { get; set; }
    public string ProtocolRevision { get; set; }
    public bool FunctionPointersPresent { get; set; }
    public bool ReservedZero { get; set; }
    public bool DeviceBindingExportPresent { get; set; }
  }

  public static class NativeInspector {
    private const UInt32 ExpectedAbiVersion = 1;
    private const Int32 Success = 0;
    private const Int32 VersionMismatch = 2;
    private const UInt64 RequiredCapabilities = 0x0f;
    private const string ExpectedProtocol = "nt-keyed-latest-v1";

    private static StageVisualApi NewApi(UInt32 size) {
      return new StageVisualApi {
        StructSize = size,
        Reserved = new UInt64[4],
      };
    }

    public static Inspection Inspect(string path) {
      IntPtr library = NativeLibrary.Load(path);
      try {
        IntPtr export;
        if (!NativeLibrary.TryGetExport(
                library, "show_host_get_stage_visual_api", out export)) {
          throw new EntryPointNotFoundException(
              "libshow_host.dll does not export show_host_get_stage_visual_api.");
        }
        IntPtr deviceBindingExport;
        bool deviceBindingExportPresent = NativeLibrary.TryGetExport(
            library,
            "show_host_set_stage_d3d_device",
            out deviceBindingExport);
        if (!deviceBindingExportPresent) {
          throw new EntryPointNotFoundException(
              "libshow_host.dll does not export show_host_set_stage_d3d_device.");
        }
        var getApi = Marshal.GetDelegateForFunctionPointer<GetStageVisualApi>(export);
        UInt32 size = checked((UInt32)Marshal.SizeOf<StageVisualApi>());

        StageVisualApi wrongVersion = NewApi(size);
        Int32 wrongVersionResult = getApi(ExpectedAbiVersion + 1, ref wrongVersion);
        if (wrongVersionResult != VersionMismatch) {
          throw new InvalidOperationException(
              "Show host accepted an unsupported Stage Visual ABI version.");
        }

        StageVisualApi wrongSize = NewApi(size - 1);
        Int32 wrongSizeResult = getApi(ExpectedAbiVersion, ref wrongSize);
        if (wrongSizeResult != VersionMismatch) {
          throw new InvalidOperationException(
              "Show host accepted an incompatible Stage Visual API structure size.");
        }

        StageVisualApi matching = NewApi(size);
        Int32 matchingResult = getApi(ExpectedAbiVersion, ref matching);
        if (matchingResult != Success) {
          throw new InvalidOperationException(
              "Show host rejected the matching Stage Visual ABI.");
        }
        string protocol = Marshal.PtrToStringAnsi(matching.ProtocolRevision);
        bool functionsPresent =
            matching.CreateSource != IntPtr.Zero &&
            matching.DestroySource != IntPtr.Zero &&
            matching.SetActive != IntPtr.Zero &&
            matching.SetFrameCallback != IntPtr.Zero &&
            matching.GetStats != IntPtr.Zero;
        bool reservedZero = matching.Reserved != null;
        if (reservedZero) {
          foreach (UInt64 value in matching.Reserved) {
            if (value != 0) {
              reservedZero = false;
              break;
            }
          }
        }
        if (matching.StructSize != size ||
            matching.AbiVersion != ExpectedAbiVersion ||
            (matching.Capabilities & RequiredCapabilities) != RequiredCapabilities ||
            !String.Equals(protocol, ExpectedProtocol, StringComparison.Ordinal) ||
            !functionsPresent ||
            !reservedZero) {
          throw new InvalidOperationException(
              "Show host returned incompatible Stage Visual metadata or function pointers.");
        }

        return new Inspection {
          StructSize = size,
          WrongVersionResult = wrongVersionResult,
          WrongSizeResult = wrongSizeResult,
          MatchingResult = matchingResult,
          AbiVersion = matching.AbiVersion,
          Capabilities = matching.Capabilities,
          ProtocolRevision = protocol,
          FunctionPointersPresent = functionsPresent,
          ReservedZero = reservedZero,
          DeviceBindingExportPresent = deviceBindingExportPresent,
        };
      } finally {
        NativeLibrary.Free(library);
      }
    }
  }
}
'@
}

$absoluteDll = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
  $ShowHostDll)
if (-not (Test-Path -LiteralPath $absoluteDll -PathType Leaf)) {
  throw "Show host DLL is missing: $absoluteDll"
}
$absoluteDll = (Resolve-Path -LiteralPath $absoluteDll).Path
$inspection = [Kirakara.ShowHostAbi.NativeInspector]::Inspect($absoluteDll)
$dll = Get-Item -LiteralPath $absoluteDll
$report = [ordered]@{
  schemaVersion = 1
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  dllPath = $absoluteDll
  dllSize = [int64]$dll.Length
  dllSha256 = (Get-FileHash -LiteralPath $absoluteDll -Algorithm SHA256).Hash
  structSize = [uint32]$inspection.StructSize
  wrongVersionResult = [int32]$inspection.WrongVersionResult
  wrongSizeResult = [int32]$inspection.WrongSizeResult
  matchingResult = [int32]$inspection.MatchingResult
  abiVersion = [uint32]$inspection.AbiVersion
  capabilities = [uint64]$inspection.Capabilities
  protocolRevision = [string]$inspection.ProtocolRevision
  functionPointersPresent = [bool]$inspection.FunctionPointersPresent
  reservedZero = [bool]$inspection.ReservedZero
  deviceBindingExportPresent = [bool]$inspection.DeviceBindingExportPresent
  passed = $true
}

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
  $absoluteReport = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
    $ReportPath)
  if (Test-Path -LiteralPath $absoluteReport) {
    throw "ReportPath already exists; preserve it or choose another path: $absoluteReport"
  }
  New-Item -ItemType Directory -Path (Split-Path -Parent $absoluteReport) `
    -Force | Out-Null
  $report | ConvertTo-Json -Depth 5 | Set-Content `
    -LiteralPath $absoluteReport `
    -Encoding utf8
  Write-Host "Show host Stage Visual ABI report saved to $absoluteReport"
}

Write-Host (
  'Show host Stage Visual ABI passed: ABI {0}, protocol {1}, SHA-256 {2}.' -f
    $report.abiVersion,
    $report.protocolRevision,
    $report.dllSha256)
[pscustomobject]$report
