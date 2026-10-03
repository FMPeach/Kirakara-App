[CmdletBinding()]
param([Parameter(Mandatory)][string]$DllPath,
      [Parameter(Mandatory)][string]$EngineLockPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$lock = Get-Content -Raw -LiteralPath $EngineLockPath -Encoding utf8 |
  ConvertFrom-Json
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Kirakara.PrebuiltAbi {
  public static class Native {
    [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr LoadLibraryExW(string path, IntPtr reserved, uint flags);
    [DllImport("kernel32", CharSet=CharSet.Ansi, SetLastError=true)]
    public static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("kernel32", SetLastError=true)]
    [return:MarshalAs(UnmanagedType.Bool)]
    public static extern bool FreeLibrary(IntPtr module);
  }
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
  public delegate int GetApi(uint version, IntPtr output);
}
'@
$module = [Kirakara.PrebuiltAbi.Native]::LoadLibraryExW(
    [IO.Path]::GetFullPath($DllPath),[IntPtr]::Zero,0x1100)
if ($module -eq [IntPtr]::Zero) {
  throw "Engine DLL 无法加载，Win32 错误码：$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}
$buffer = [IntPtr]::Zero
try {
  $export = [Kirakara.PrebuiltAbi.Native]::GetProcAddress($module,'FlutterDesktopKirakaraCompositorGetApi')
  if ($export -eq [IntPtr]::Zero) { throw 'Engine 缺少版本化合成器导出。' }
  $getApi = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
      $export,[type][Kirakara.PrebuiltAbi.GetApi])
  $size = 88
  $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal($size)
  $zero = [byte[]]::new($size)
  foreach ($test in @(
      @{Version=[uint32]($lock.patchset.abiVersion+1);Size=$size;Expected=2},
      @{Version=[uint32]$lock.patchset.abiVersion;Size=80;Expected=2},
      @{Version=[uint32]$lock.patchset.abiVersion;Size=$size;Expected=0})) {
    [Runtime.InteropServices.Marshal]::Copy($zero,0,$buffer,$size)
    [Runtime.InteropServices.Marshal]::WriteInt32($buffer,0,$test.Size)
    if ($getApi.Invoke($test.Version,$buffer) -ne $test.Expected) {
      throw '合成器 ABI 不匹配或无法正确拒绝错误版本/结构大小。'
    }
  }
  if ([Runtime.InteropServices.Marshal]::ReadInt32($buffer,0) -ne $size -or
      [Runtime.InteropServices.Marshal]::ReadInt32($buffer,4) -ne $lock.patchset.abiVersion -or
      [Runtime.InteropServices.Marshal]::ReadInt32($buffer,8) -ne $lock.patchset.version -or
      [Runtime.InteropServices.Marshal]::PtrToStringAnsi(
        [Runtime.InteropServices.Marshal]::ReadIntPtr($buffer,16)) -cne $lock.patchset.revision -or
      [Runtime.InteropServices.Marshal]::PtrToStringAnsi(
        [Runtime.InteropServices.Marshal]::ReadIntPtr($buffer,24)) -cne $lock.flutter.engineRevision) {
    throw 'Engine 实际 revision/补丁版本与仓库锁文件不匹配。'
  }
  foreach ($offset in @(32,40,48,56,64,72)) {
    if ([Runtime.InteropServices.Marshal]::ReadIntPtr($buffer,$offset) -eq [IntPtr]::Zero) {
      throw '合成器 API 表不完整。'
    }
  }
  @{passed=$true;abiVersion=$lock.patchset.abiVersion;patchsetVersion=$lock.patchset.version} |
    ConvertTo-Json -Compress
} finally {
  if ($buffer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
  if (-not [Kirakara.PrebuiltAbi.Native]::FreeLibrary($module)) { throw 'Engine ABI 探测释放 DLL 失败。' }
}
