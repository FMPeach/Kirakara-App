#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackagesDirectory,[string]$ReportPath,[switch]$SkipLaunch,[switch]$VerboseFlutter)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'common.ps1')
Import-Module (Join-Path $PSScriptRoot 'artifact_package.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'prebuilt_engine.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'flutter_sdk_tools.psm1') -DisableNameChecking
$layout=Get-EngineWorkspaceLayout (Join-Path $repo '.kfe')
Assert-RepositoryEngineWriteWorkspace $layout
$lock=Get-EngineLock
$packages=[IO.Path]::GetFullPath($PackagesDirectory)
[Kirakara.Artifacts.Security]::NoReparse($packages)
$scratch=Join-Path $layout.OutputRoot ('engine-app-tests/'+[guid]::NewGuid().ToString('N'))
$app=Join-Path $scratch 'application'
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$environmentBefore=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in Get-ChildItem Env:) {$environmentBefore[$entry.Name]=$entry.Value}
$process=$null
function Invoke-ProbeFlutter {
  param([string[]]$Arguments,[string]$LogName)
  if ($VerboseFlutter) { $Arguments=@('--verbose')+$Arguments }
  & $flutter @Arguments 2>&1 | Tee-Object -FilePath (Join-Path $scratch $LogName) | Out-Host
  if ($LASTEXITCODE) {throw "最小工程 Flutter 命令失败；诊断：$scratch"}
}
try {
  Set-EngineProcessEnvironment -Layout $layout
  $flutter=Join-Path $layout.FlutterSdk 'bin/flutter.bat'
  [Kirakara.Artifacts.Security]::NoReparse($flutter)
  if (-not (Test-Path -LiteralPath $flutter)) {throw '请先通过 flutterw 准备仓库 SDK。'}
  if ((& git -C $layout.FlutterSdk rev-parse HEAD) -cne $lock.flutter.frameworkRevision) {throw '仓库 SDK revision 不匹配。'}
  $null=Ensure-KirakaraSdkTools -Layout $layout -Lock $lock
  $null=New-Item -ItemType Directory -Path $scratch -Force
  Invoke-ProbeFlutter @('create','--platforms','windows','--project-name','kirakara_engine_package_probe','--no-pub',$app) 'create.log'
  Copy-Item -LiteralPath (Join-Path $repo 'engine/tests/package_probe_main.dart') -Destination (Join-Path $app 'lib/main.dart')
  Push-Location $app
  try {
    Invoke-ProbeFlutter @('pub','get') 'pub.log'
    $records=[Collections.Generic.List[object]]::new()
    foreach ($mode in @('debug','profile','release')) {
      $name="kirakara-engine-windows-x64-$mode-v$($lock.patchset.version)"
      $engine=Ensure-PrebuiltEngine -Layout $layout -Lock $lock -Mode $mode `
        -Package (Join-Path $packages ($name+'.zip')) -LockPath (Join-Path $packages ($name+'.candidate.lock.json'))
      Invalidate-StaleFlutterEphemeralEngine -EngineOutputDirectory $engine.output -AppRoot $app
      Invoke-ProbeFlutter @('build','windows',"--$mode","--local-engine=$($engine.localEngine)",
        "--local-engine-host=$($engine.localEngineHost)","--local-engine-src-path=$($engine.outputRoot)") "$mode.log"
      $configuration=if ($mode -eq 'debug') {'Debug'} elseif ($mode -eq 'profile') {'Profile'} else {'Release'}
      $bundle=Join-Path $app "build/windows/x64/runner/$configuration"
      $dll=Join-Path $bundle 'flutter_windows.dll'
      if ((Get-ArtifactHash $dll) -cne (Get-ArtifactHash (Join-Path $engine.output 'flutter_windows.dll'))) {
        throw '最小工程未使用实际选择的定制 Engine。'
      }
      $records.Add([ordered]@{mode=$mode;compiled=$true;engineMatched=$true;dllSha256=Get-ArtifactHash $dll})
    }
  } finally {Pop-Location}
  $firstDartFrame=$false
  if (-not $SkipLaunch) {
    if (-not ('Kirakara.PackageAppProbe.Window' -as [type])) {
      Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace Kirakara.PackageAppProbe {
  public static class Window {
    private delegate bool WindowVisitor(IntPtr window,IntPtr data);
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(WindowVisitor visitor,IntPtr data);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window,out uint processId);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)]
    private static extern int GetClassNameW(IntPtr window,StringBuilder name,int capacity);
    [DllImport("user32.dll",SetLastError=true)]
    public static extern bool PostMessageW(IntPtr window,uint message,IntPtr w,IntPtr l);
    // Process.MainWindowHandle excludes hidden windows. The smoke fixture is
    // intentionally hidden, so identify only our PID's actual Runner class.
    public static IntPtr FindRunnerWindow(int processId) {
      IntPtr result=IntPtr.Zero;
      EnumWindows((window,data)=>{
        uint owner; GetWindowThreadProcessId(window,out owner);
        var name=new StringBuilder(256); GetClassNameW(window,name,name.Capacity);
        if (owner==(uint)processId && name.ToString()=="FLUTTER_RUNNER_WIN32_WINDOW") {
          result=window; return false;
        }
        return true;
      },IntPtr.Zero);
      return result;
    }
  }
}
'@
    }
    $executable=Join-Path $app 'build/windows/x64/runner/Release/kirakara_engine_package_probe.exe'
    $start=[Diagnostics.ProcessStartInfo]::new($executable)
    $start.WorkingDirectory=Split-Path -Parent $executable
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($start)
    $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    do {
      if ($process.HasExited) {throw 'Engine 包最小测试窗口提前退出。'}
      $window=[Kirakara.PackageAppProbe.Window]::FindRunnerWindow($process.Id)
      if ($window -ne [IntPtr]::Zero) {break}
      Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($window -eq [IntPtr]::Zero) {throw '最小测试窗口创建超时。'}
    Start-Sleep -Seconds 2
    if (-not [Kirakara.PackageAppProbe.Window]::PostMessageW($window,0x10,[IntPtr]::Zero,[IntPtr]::Zero)) {throw '无法向测试窗口发送关闭请求。'}
    if (-not $process.WaitForExit(10000)) {throw '最小窗口没有正常退出。'}
    $out=$stdout.GetAwaiter().GetResult(); $err=$stderr.GetAwaiter().GetResult()
    [IO.File]::WriteAllText((Join-Path $scratch 'runtime.log'),$out+"`n"+$err,[Text.UTF8Encoding]::new($false))
    $firstDartFrame=$out.Contains('KIRAKARA_ENGINE_PACKAGE_FIRST_DART_FRAME') -or $err.Contains('KIRAKARA_ENGINE_PACKAGE_FIRST_DART_FRAME')
    if (-not $firstDartFrame -or $process.ExitCode -ne 0) {throw "首帧诊断缺失或测试窗口异常退出；诊断：$scratch"}
  }
  if ([string]::IsNullOrWhiteSpace($ReportPath)) {$ReportPath=Join-Path $repo 'build/diagnostics/prebuilt-flutter-app.json'}
  $report=[IO.Path]::GetFullPath($ReportPath)
  if (-not $report.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) {throw '报告必须位于当前仓库。'}
  [Kirakara.Artifacts.Security]::NoReparse($report)
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
  [ordered]@{passed=$true;scope='最小 Flutter Windows 工程；不是完整 Kirakara App 验收'
    modes=$records.ToArray();releaseFirstDartFrame=$firstDartFrame;launchSkipped=[bool]$SkipLaunch
    kirakaraAppVerified=$false;visualCorrectnessVerified=$false;diagnosticsDirectory=$scratch} | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $report -Encoding utf8
  Write-Host "Engine 包的最小工程三模式编译检查通过。报告：$report"
} finally {
  if ($null -ne $process) {
    if (-not $process.HasExited) {$process.Kill($true);$process.WaitForExit()}
    $process.Dispose()
  }
  foreach ($name in @(Get-ChildItem Env:|ForEach-Object Name)) {
    if (-not $environmentBefore.ContainsKey($name)) {Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue}
  }
  foreach ($entry in $environmentBefore.GetEnumerator()) {[Environment]::SetEnvironmentVariable($entry.Key,$entry.Value,'Process')}
}
