[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$WorkspaceRoot,

  [ValidateSet(
    'kirakara',
    'clipboard',
    'critical',
    'compositor',
    'adapter-isolated',
    'full'
  )]
  [string[]]$Suite = @(
    'kirakara',
    'clipboard',
    'critical',
    'compositor',
    'adapter-isolated'
  ),

  [ValidateRange(1, 1800)]
  [int]$TimeoutSeconds = 360,

  [string]$ReportPath,

  [switch]$AllowKnownFullSuiteOrderFailures
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$lock = Get-EngineLock
$layout = Get-EngineWorkspaceLayout $WorkspaceRoot
Assert-ExternalEngineWorkspace $layout
Assert-AppliedPatchset -Lock $lock -Layout $layout

$debugBuild = Get-BuildLock `
  -Lock $lock `
  -Mode debug `
  -Variant patched
$debugOutput = Get-EngineOutputDirectory `
  -Layout $layout `
  -LocalEngine $debugBuild.localEngine
Assert-UsableEngineArtifacts `
  -Layout $layout `
  -Lock $lock `
  -Build $debugBuild `
  -Mode debug `
  -Variant patched `
  -OutputDirectory $debugOutput
$testExecutable = Join-Path $debugOutput 'flutter_windows_unittests.exe'
if (-not (Test-Path -LiteralPath $testExecutable -PathType Leaf)) {
  throw "Windows Engine unit test executable is missing: $testExecutable"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $ReportPath = Join-Path (Get-AppRepositoryRoot) `
    "build\diagnostics\engine\patched-engine-tests-$stamp.json"
}
$absoluteReport = Resolve-UnresolvedPath $ReportPath
if (Test-Path -LiteralPath $absoluteReport) {
  throw "ReportPath already exists; preserve it or choose another path: $absoluteReport"
}
$reportDirectory = Split-Path -Parent $absoluteReport
$logDirectory = Join-Path $reportDirectory `
  ([IO.Path]::GetFileNameWithoutExtension($absoluteReport) + '-logs')
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

$definitions = [ordered]@{
  kirakara = @(
    [ordered]@{
      name = 'kirakara-compositor-api'
      filter = 'KirakaraCompositorApiExportTest.*:KirakaraCompositorApiTest.*'
      expectedTestCount = 6
    }
  )
  clipboard = @(
    [ordered]@{
      name = 'windows-clipboard'
      filter = 'PlatformHandlerTest.*Clipboard*'
      expectedTestCount = 19
    }
  )
  critical = @(
    [ordered]@{
      name = 'critical-scheduling'
      filter = 'FlutterWindowsEngineTest.TaskRunnerDelayedTask:WindowsTest.NextFrameCallback'
      expectedTestCount = 2
    }
  )
  compositor = @(
    [ordered]@{
      name = 'upstream-compositor'
      filter = 'CompositorOpenGLTest.*:CompositorSoftwareTest.*:DisplayManagerWin32Test.*:DpiUtilsTest.*:FlutterWindowsTextureRegistrarTest.*'
      expectedTestCount = 25
    }
  )
  'adapter-isolated' = @(
    [ordered]@{
      name = 'adapter-low-power-isolated'
      filter = 'WindowsTest.GetGraphicsAdapterWithLowPowerPreference'
      expectedTestCount = 1
    },
    [ordered]@{
      name = 'engine-adapter-low-power-isolated'
      filter = 'WindowsTest.GetEngineGraphicsAdapterWithLowPowerPreference'
      expectedTestCount = 1
    }
  )
  full = @(
    [ordered]@{
      name = 'full'
      filter = '*'
      expectedTestCount = 365
    }
  )
}

$requestedSuites = @($Suite | Select-Object -Unique)
if (
  $AllowKnownFullSuiteOrderFailures -and
  $requestedSuites -contains 'full' -and
  $requestedSuites -notcontains 'adapter-isolated'
) {
  throw '-AllowKnownFullSuiteOrderFailures requires -Suite adapter-isolated,full so the isolated controls are recorded in the same report.'
}
$runs = @()
foreach ($suiteName in $requestedSuites) {
  foreach ($definition in $definitions[$suiteName]) {
    Write-Host "Running patched Windows Engine test suite '$($definition.name)'..."
    $runs += Invoke-GTestProcess `
      -Executable $testExecutable `
      -Name $definition.name `
      -Filter $definition.filter `
      -ExpectedTestCount $definition.expectedTestCount `
      -LogDirectory $logDirectory `
      -TimeoutSeconds $TimeoutSeconds
  }
}

$knownFullSuiteFailures = @(
  'WindowsTest.GetEngineGraphicsAdapterWithLowPowerPreference',
  'WindowsTest.GetGraphicsAdapterWithLowPowerPreference'
)
$unexpectedRuns = @()
foreach ($run in $runs) {
  $acceptedKnownFailure = $false
  if (
    $run.name -eq 'full' -and
    $AllowKnownFullSuiteOrderFailures -and
    -not $run.timedOut -and
    $run.exitCode -eq 1
  ) {
    $difference = @(Compare-Object `
        -ReferenceObject $knownFullSuiteFailures `
        -DifferenceObject @($run.failedTests))
    $acceptedKnownFailure = $difference.Count -eq 0
  }
  $run.acceptedKnownOrderDependentFailures = $acceptedKnownFailure
  if (
    $run.timedOut -or
    $run.testCount -ne $run.expectedTestCount -or
    ($run.exitCode -ne 0 -and -not $acceptedKnownFailure)
  ) {
    $unexpectedRuns += $run
  }
}
$report = [ordered]@{
  schemaVersion = 1
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  variant = 'patched'
  engineRevision = Get-GitHead $layout.FlutterCheckout
  engineSourceTree = Get-GitTree $layout.FlutterCheckout
  engineSourceSnapshotTree = $lock.patchset.sourceTree
  patchsetRevision = $lock.patchset.revision
  patchsetVersion = $lock.patchset.version
  debugEngine = $debugBuild.localEngine
  testExecutable = $testExecutable
  testExecutableSha256 = (
    Get-FileHash -LiteralPath $testExecutable -Algorithm SHA256
  ).Hash
  requestedSuites = $requestedSuites
  allowKnownFullSuiteOrderFailures = [bool]$AllowKnownFullSuiteOrderFailures
  knownFullSuiteOrderFailures = $knownFullSuiteFailures
  runs = $runs
  allProcessesExitedZero = @($runs | Where-Object {
      $_.timedOut -or $_.testCount -ne $_.expectedTestCount -or $_.exitCode -ne 0
    }).Count -eq 0
  gatePassed = $unexpectedRuns.Count -eq 0
}
$report | ConvertTo-Json -Depth 8 | Set-Content `
  -LiteralPath $absoluteReport -Encoding utf8
Write-Host "Patched Windows Engine test report saved to $absoluteReport"

if ($unexpectedRuns.Count -ne 0) {
  throw "Patched Windows Engine test run failed or timed out: $($unexpectedRuns.name -join ', ')"
}
