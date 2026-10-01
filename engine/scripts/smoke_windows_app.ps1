[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$FlutterSdkRoot,

  [ValidateSet('official', 'local', 'prebuilt')]
  [string]$Engine = 'local',

  [ValidateSet('stock', 'patched')]
  [string]$LocalVariant = 'stock',

  [string]$WorkspaceRoot,

  [ValidateSet('debug', 'profile', 'release')]
  [string]$Mode = 'release',

  [string]$BundlePath,

  [ValidateRange(1, 120)]
  [int]$StartupTimeoutSeconds = 30,

  [ValidateRange(1, 120)]
  [int]$ObserveSeconds = 5,

  [ValidateRange(1, 120)]
  [int]$ShutdownTimeoutSeconds = 20,

  [string]$ReportPath,

  [switch]$RequireLockedArtifacts,

  [switch]$AllowForcedCleanup
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'release_contract.ps1')

function Get-FirewallNotificationProcessIds {
  return @(
    Get-CimInstance Win32_Process -Filter "Name = 'PickerHost.exe'" |
      Where-Object {
        $_.CommandLine -match '(?i)FirewallNotificationDialogServer'
      } |
      ForEach-Object { [int]$_.ProcessId } |
      Sort-Object -Unique
  )
}

function Get-FirewallApplicationRuleIdsForExecutable {
  param([Parameter(Mandatory = $true)][string]$ExecutablePath)

  return @(
    Get-NetFirewallApplicationFilter |
      Where-Object {
        [string]::Equals(
          $_.Program,
          $ExecutablePath,
          [StringComparison]::OrdinalIgnoreCase)
      } |
      ForEach-Object { [string]$_.InstanceID } |
      Sort-Object -Unique
  )
}

if ($RequireLockedArtifacts -and $Engine -ne 'local') {
  throw '-RequireLockedArtifacts applies only to a local Release Engine.'
}

$lock = Get-EngineLock
$flutterRoot = Resolve-UnresolvedPath $FlutterSdkRoot
$flutter = Join-Path $flutterRoot 'bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutter -PathType Leaf)) {
  throw "Flutter SDK is missing flutter.bat: $flutterRoot"
}
if ((Get-GitHead $flutterRoot) -ne $lock.flutter.frameworkRevision) {
  throw 'Flutter Framework revision does not match engine.lock.json.'
}
$sdkEngineRevision = (
  Get-Content -Raw -LiteralPath (Join-Path $flutterRoot 'bin\internal\engine.version')
).Trim()
if ($sdkEngineRevision -ne $lock.flutter.engineRevision) {
  throw 'Flutter SDK Engine revision does not match engine.lock.json.'
}

$buildVariant = switch ($Engine) {
  'local' { $LocalVariant }
  'prebuilt' { 'patched' }
  default { 'stock' }
}
$build = Get-BuildLock `
  -Lock $lock `
  -Mode $Mode `
  -Variant $buildVariant
$layout = $null
$engineDirectory = $null
if ($Engine -eq 'local') {
  if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    throw '-WorkspaceRoot is required for -Engine local.'
  }
  $layout = Get-EngineWorkspaceLayout $WorkspaceRoot
  Assert-ExternalEngineWorkspace $layout
  if ($LocalVariant -eq 'stock') {
    Assert-PinnedFlutterSource -Lock $lock -Layout $layout -RequireStockTree
  } else {
    Assert-AppliedPatchset -Lock $lock -Layout $layout
    Assert-MatchingTextFile `
      -ExpectedPath (Join-Path $layout.EngineSource `
        'flutter\shell\platform\windows\kirakara_flutter_compositor_api.h') `
      -ActualPath (Join-Path (Get-AppRepositoryRoot) `
        'engine\include\kirakara_flutter_compositor_api.h') `
      -Label 'Kirakara compositor ABI header'
  }
  $engineDirectory = Get-EngineOutputDirectory `
    -Layout $layout `
    -LocalEngine $build.localEngine
  if ($RequireLockedArtifacts) {
    $artifactContract = Get-KirakaraReleaseArtifactContract `
      -Lock $lock `
      -Layout $layout `
      -Build $build
    Assert-LockedEngineArtifacts `
      -Build $artifactContract `
      -OutputDirectory $engineDirectory
  } else {
    Assert-UsableEngineArtifacts `
      -Layout $layout `
      -Lock $lock `
      -Build $build `
      -Mode $Mode `
      -Variant $LocalVariant `
      -OutputDirectory $engineDirectory
  }
} elseif ($Engine -eq 'prebuilt') {
  Import-Module (Join-Path $PSScriptRoot 'project_engine_bootstrap.psm1') `
    -DisableNameChecking
  $selectedEngine = Assert-KirakaraProjectEngineReady -Mode $Mode
  if ($selectedEngine.kind -cne 'prebuilt') {
    throw "当前 $Mode Engine 选择不是预编译包。"
  }
  $engineDirectory = $selectedEngine.output
} else {
  if ($LocalVariant -ne 'stock') {
    throw '-LocalVariant patched applies only to -Engine local.'
  }
  $officialDirectoryName = switch ($Mode) {
    'debug' { 'windows-x64' }
    'profile' { 'windows-x64-profile' }
    'release' { 'windows-x64-release' }
  }
  $engineDirectory = Join-Path $flutterRoot `
    "bin\cache\artifacts\engine\$officialDirectoryName"
}

$configuration = switch ($Mode) {
  'debug' { 'Debug' }
  'profile' { 'Profile' }
  'release' { 'Release' }
}
$bundle = if ([string]::IsNullOrWhiteSpace($BundlePath)) {
  Join-Path (Get-AppRepositoryRoot) "build\windows\x64\runner\$configuration"
} else {
  Resolve-UnresolvedPath $BundlePath
}
if (-not (Test-Path -LiteralPath $bundle -PathType Container)) {
  throw "Kirakara App bundle directory is missing: $bundle"
}
$executable = Join-Path $bundle 'kirakara_app.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
  throw "Kirakara App bundle is missing. Build it before smoke testing: $executable"
}
Assert-MatchingFile `
  -ExpectedPath (Join-Path $engineDirectory 'flutter_windows.dll') `
  -ActualPath (Join-Path $bundle 'flutter_windows.dll') `
  -Label "App $Mode flutter_windows.dll for $Engine Engine"
$icuDirectory = if ($Engine -in @('local', 'prebuilt')) {
  $engineDirectory
} else {
  Join-Path $flutterRoot 'bin\cache\artifacts\engine\windows-x64'
}
Assert-MatchingFile `
  -ExpectedPath (Join-Path $icuDirectory 'icudtl.dat') `
  -ActualPath (Join-Path $bundle 'data\icudtl.dat') `
  -Label "App $Mode icudtl.dat for $Engine Engine"

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $engineLabel = if ($Engine -eq 'local') {
    "$Engine-$LocalVariant"
  } else {
    $Engine
  }
  $ReportPath = Join-Path (Get-AppRepositoryRoot) `
    "build\diagnostics\engine\app-smoke-$engineLabel-$Mode-$stamp.json"
}
$absoluteReport = Resolve-UnresolvedPath $ReportPath
if (Test-Path -LiteralPath $absoluteReport) {
  throw "ReportPath already exists; preserve it or choose another path: $absoluteReport"
}
New-Item -ItemType Directory -Path (Split-Path -Parent $absoluteReport) `
  -Force | Out-Null

$process = [System.Diagnostics.Process]::new()
$process.StartInfo.FileName = $executable
$process.StartInfo.WorkingDirectory = $bundle
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.CreateNoWindow = $false
$process.StartInfo.EnvironmentVariables['KIRAKARA_SMOKE_LAN_LOOPBACK'] = '1'
$firewallNotificationsBefore = @(Get-FirewallNotificationProcessIds)
$firewallApplicationRulesBefore = @(
  Get-FirewallApplicationRuleIdsForExecutable -ExecutablePath $executable
)
$startedAt = (Get-Date).ToUniversalTime()
$inputIdle = $false
$mainWindowHandle = 0
$mainWindowTitle = ''
$responding = $false
$flutterModuleLoaded = $false
$showHostModuleLoaded = $false
$exitedDuringObservation = $false
$closeRequested = $false
$gracefulExit = $false
$forcedCleanup = $false
$exitCode = $null
$failure = $null
$started = $false
$processId = $null
$startupPollCount = 0
$startupWindowWaitMilliseconds = 0
$closeWindowHandle = 0
$shutdownWaitMilliseconds = 0
try {
  if (-not $process.Start()) {
    throw 'Could not start Kirakara App.'
  }
  $started = $true
  $processId = $process.Id
  try {
    $inputIdle = $process.WaitForInputIdle($StartupTimeoutSeconds * 1000)
  } catch [System.InvalidOperationException] {
    $inputIdle = $false
  }
  if (-not $process.HasExited) {
    # WaitForInputIdle can complete before Flutter presents its first frame and
    # shows the top-level window. Discover it with a bounded startup probe; this
    # is test-only and never becomes an application timer.
    $windowStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while (
      -not $process.HasExited -and
      $windowStopwatch.Elapsed.TotalSeconds -lt $StartupTimeoutSeconds
    ) {
      $process.Refresh()
      $mainWindowHandle = [long]$process.MainWindowHandle
      $mainWindowTitle = [string]$process.MainWindowTitle
      # The Windows/Flutter startup path can briefly expose an untitled helper
      # window as Process.MainWindowHandle. Closing that handle does not close
      # the App and makes a healthy run look hung. Wait for the actual Runner
      # top-level window created with the stable title from main.cpp.
      if ($mainWindowHandle -ne 0 -and
          $mainWindowTitle -ceq 'kirakara_app') {
        break
      }
      $startupPollCount++
      Start-Sleep -Milliseconds 100
    }
    $windowStopwatch.Stop()
    $startupWindowWaitMilliseconds = [long]$windowStopwatch.ElapsedMilliseconds
    if ($mainWindowHandle -ne 0 -and
        $mainWindowTitle -ceq 'kirakara_app') {
      $responding = $process.Responding
      $loadedModules = @($process.Modules | ForEach-Object {
          [string]$_.ModuleName
        })
      $flutterModuleLoaded = $loadedModules -icontains 'flutter_windows.dll'
      $showHostModuleLoaded = $loadedModules -icontains 'libshow_host.dll'
    }
    $exitedDuringObservation = $process.WaitForExit($ObserveSeconds * 1000)
  } else {
    $exitedDuringObservation = $true
  }
  if (-not $process.HasExited) {
    # A timed-out WaitForExit can leave Process properties cached. Refresh
    # before resolving the window used by CloseMainWindow; otherwise the smoke
    # harness can report a forced cleanup even though WM_CLOSE exits normally.
    $process.Refresh()
    $closeWindowHandle = [long]$process.MainWindowHandle
    $closeRequested = $process.CloseMainWindow()
    $shutdownStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $gracefulExit = $process.WaitForExit($ShutdownTimeoutSeconds * 1000)
    $shutdownStopwatch.Stop()
    $shutdownWaitMilliseconds = [long]$shutdownStopwatch.ElapsedMilliseconds
  }
  if (-not $process.HasExited) {
    $process.Kill()
    $process.WaitForExit()
    $forcedCleanup = $true
  }
  $exitCode = $process.ExitCode
} catch {
  $failure = $_.Exception.Message
  if ($started -and -not $process.HasExited) {
    $process.Kill()
    $process.WaitForExit()
    $forcedCleanup = $true
    $exitCode = $process.ExitCode
  }
} finally {
  $process.Dispose()
}

# Firewall notifications are spawned out of process by a system service. Give
# that bounded startup consequence time to materialize, then reject any new
# dialog without dismissing it or changing firewall policy.
Start-Sleep -Milliseconds 750
$firewallNotificationsAfter = @(Get-FirewallNotificationProcessIds)
$newFirewallNotifications = @(
  $firewallNotificationsAfter |
    Where-Object { $_ -notin $firewallNotificationsBefore }
)
$firewallPromptGatePassed = $newFirewallNotifications.Count -eq 0
$firewallApplicationRulesAfter = @(
  Get-FirewallApplicationRuleIdsForExecutable -ExecutablePath $executable
)
$newFirewallApplicationRules = @(
  $firewallApplicationRulesAfter |
    Where-Object { $_ -notin $firewallApplicationRulesBefore }
)
$firewallRuleGatePassed = $newFirewallApplicationRules.Count -eq 0

$passed = (
  [string]::IsNullOrWhiteSpace($failure) -and
  $inputIdle -and
  $mainWindowHandle -ne 0 -and
  $mainWindowTitle -ceq 'kirakara_app' -and
  $responding -and
  $flutterModuleLoaded -and
  $showHostModuleLoaded -and
  -not $exitedDuringObservation -and
  $closeRequested -and
  ($gracefulExit -or ($forcedCleanup -and $AllowForcedCleanup)) -and
  $firewallPromptGatePassed -and
  $firewallRuleGatePassed
)
$report = [ordered]@{
  schemaVersion = 6
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  startedAt = $startedAt.ToString('o')
  engine = $Engine
  localVariant = if ($Engine -eq 'local') { $LocalVariant } else { $null }
  mode = $Mode
  engineRevision = $lock.flutter.engineRevision
  patchsetRevision = if ($buildVariant -eq 'patched') {
    $lock.patchset.revision
  } else {
    'stock'
  }
  executable = $executable
  executableSha256 = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
  flutterWindowsDllSha256 = (
    Get-FileHash -LiteralPath (Join-Path $bundle 'flutter_windows.dll') `
      -Algorithm SHA256
  ).Hash
  processId = $processId
  inputIdle = $inputIdle
  startupPollCount = $startupPollCount
  startupWindowWaitMilliseconds = $startupWindowWaitMilliseconds
  mainWindowHandle = $mainWindowHandle
  mainWindowTitle = $mainWindowTitle
  responding = $responding
  flutterModuleLoaded = $flutterModuleLoaded
  showHostModuleLoaded = $showHostModuleLoaded
  exitedDuringObservation = $exitedDuringObservation
  closeWindowHandle = $closeWindowHandle
  closeRequested = $closeRequested
  gracefulExit = $gracefulExit
  shutdownWaitMilliseconds = $shutdownWaitMilliseconds
  forcedCleanup = $forcedCleanup
  allowForcedCleanup = [bool]$AllowForcedCleanup
  lockedArtifactGate = [bool]$RequireLockedArtifacts
  lanServerIsolation = 'loopback-process-override'
  firewallNotificationsBefore = $firewallNotificationsBefore
  firewallNotificationsAfter = $firewallNotificationsAfter
  newFirewallNotifications = $newFirewallNotifications
  firewallPromptGatePassed = $firewallPromptGatePassed
  firewallApplicationRulesBefore = $firewallApplicationRulesBefore
  firewallApplicationRulesAfter = $firewallApplicationRulesAfter
  newFirewallApplicationRules = $newFirewallApplicationRules
  firewallRuleGatePassed = $firewallRuleGatePassed
  exitCode = $exitCode
  failure = $failure
  passed = $passed
}
$report | ConvertTo-Json -Depth 5 | Set-Content `
  -LiteralPath $absoluteReport -Encoding utf8
Write-Host "App smoke report saved to $absoluteReport"

if (-not $passed) {
  throw "Kirakara App $Engine/$Mode smoke did not meet its gate. See $absoluteReport"
}
