#Requires -Version 7.2
[CmdletBinding()]
param([string]$DllPath,[string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
if ([string]::IsNullOrWhiteSpace($DllPath)) {$DllPath=Join-Path $repo '.kfe/native/runtime/ime/rime/windows/rime.dll'}
$dll=[IO.Path]::GetFullPath($DllPath)
if (-not $dll.StartsWith($repo+'\.kfe\',[StringComparison]::OrdinalIgnoreCase)) {throw '只探测当前仓库内已校验的 librime。'}
[Kirakara.Artifacts.Security]::NoReparse($dll)
$pe=[Kirakara.Artifacts.PeReader]::Read($dll)
if ($pe.Machine -ne 0x8664 -or -not $pe.IsDll) {throw 'librime 不是 x64 DLL。'}
$required=@('RimeSetup','RimeInitialize','RimeFinalize','RimeCreateSession','RimeDestroySession','RimeSelectSchema',
  'RimeSetInput','RimeClearComposition','RimeGetContext','RimeFreeContext','RimeStartMaintenance',
  'RimeJoinMaintenanceThread','RimeCandidateListBegin','RimeCandidateListNext','RimeCandidateListEnd','rime_get_api')
foreach ($name in $required) {if ($pe.Exports -cnotcontains $name) {throw "librime 缺少 Runner 使用的导出：$name"}}
if (-not ('Kirakara.RimeProbe.Native' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Kirakara.RimeProbe {
  public static class Native {
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    public static extern IntPtr LoadLibraryExW(string name,IntPtr file,uint flags);
    [DllImport("kernel32.dll",CharSet=CharSet.Ansi,ExactSpelling=true,SetLastError=true)]
    public static extern IntPtr GetProcAddress(IntPtr module,string name);
    [DllImport("kernel32.dll")] public static extern bool FreeLibrary(IntPtr module);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate IntPtr GetApi();
    public static int ReadApiSize(IntPtr module) {
      var address=GetProcAddress(module,"rime_get_api");
      if(address==IntPtr.Zero) throw new InvalidOperationException("Missing Rime API");
      var api=Marshal.GetDelegateForFunctionPointer<GetApi>(address)();
      if(api==IntPtr.Zero) throw new InvalidOperationException("Null Rime API");
      return Marshal.ReadInt32(api);
    }
  }
}
'@
}
$module=[Kirakara.RimeProbe.Native]::LoadLibraryExW($dll,[IntPtr]::Zero,0x900)
if ($module -eq [IntPtr]::Zero) {throw "librime 加载失败，Windows 错误码：$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"}
try {
  $size=[Kirakara.RimeProbe.Native]::ReadApiSize($module)
  if ($size -lt 128 -or $size -gt 16384) {throw 'Rime API 表长度异常。'}
} finally {$null=[Kirakara.RimeProbe.Native]::FreeLibrary($module)}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {$ReportPath=Join-Path $repo 'build/diagnostics/librime-probe.json'}
$report=[IO.Path]::GetFullPath($ReportPath)
if (-not $report.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) {throw '报告必须位于当前仓库。'}
[Kirakara.Artifacts.Security]::NoReparse($report)
$null=New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
[ordered]@{passed=$true;sha256=Get-ArtifactHash $dll;architecture='x64';requiredExports=$required
  apiDataSize=$size;apiLoaded=$true;userSessionCreated=$false;appImeUiVerified=$false} | ConvertTo-Json -Depth 5 |
  Set-Content -LiteralPath $report -Encoding utf8
Write-Host "librime 导出、加载与 API 表探测通过；未初始化用户会话或验证 App 输入交互。报告：$report"
