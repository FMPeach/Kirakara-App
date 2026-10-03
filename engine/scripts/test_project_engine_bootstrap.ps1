[CmdletBinding()]
param([string]$ReportPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$modulePath = Join-Path $PSScriptRoot 'project_engine_bootstrap.psm1'
Import-Module $modulePath -Force
$bootstrapModule = Get-Module | Where-Object {
  $_.Path -and [IO.Path]::GetFullPath($_.Path).Equals(
    [IO.Path]::GetFullPath($modulePath),
    [StringComparison]::OrdinalIgnoreCase)
} | Select-Object -First 1
if ($null -eq $bootstrapModule) {
  throw "Could not locate imported bootstrap module: $modulePath"
}
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'release_contract.ps1')

function Assert-Equal {
  param(
    [Parameter(Mandatory = $true)][AllowNull()]$Expected,
    [Parameter(Mandatory = $true)][AllowNull()]$Actual,
    [Parameter(Mandatory = $true)][string]$Label
  )
  if ($Expected -cne $Actual) {
    throw "$Label mismatch. Expected '$Expected', got '$Actual'."
  }
}

$cases = @(
  [ordered]@{
    name = 'pub-get-prepares-debug'
    arguments = @('pub', 'get')
    needsEngine = $true
    injectEngine = $false
    mode = 'debug'
  },
  [ordered]@{
    name = 'windows-run-defaults-debug'
    arguments = @('run', '-d', 'windows')
    needsEngine = $true
    injectEngine = $true
    mode = 'debug'
  },
  [ordered]@{
    name = 'windows-run-profile'
    arguments = @('run', '--profile', '--device-id=windows')
    needsEngine = $true
    injectEngine = $true
    mode = 'profile'
  },
  [ordered]@{
    name = 'windows-build-defaults-release'
    arguments = @('build', 'windows')
    needsEngine = $true
    injectEngine = $true
    mode = 'release'
  },
  [ordered]@{
    name = 'windows-build-explicit-debug'
    arguments = @('build', 'windows', '--debug')
    needsEngine = $true
    injectEngine = $true
    mode = 'debug'
  },
  [ordered]@{
    name = 'explicit-chrome-run-stays-official'
    arguments = @('run', '-d=chrome')
    needsEngine = $false
    injectEngine = $false
    mode = $null
  },
  [ordered]@{
    name = 'android-build-stays-official'
    arguments = @('build', 'apk', '--release')
    needsEngine = $false
    injectEngine = $false
    mode = $null
  }
)

$caseReports = foreach ($case in $cases) {
  $plan = Get-KirakaraFlutterInvocationPlan -Arguments $case.arguments
  Assert-Equal -Expected $case.needsEngine -Actual $plan.needsEngine `
    -Label "$($case.name) needsEngine"
  Assert-Equal -Expected $case.injectEngine -Actual $plan.injectEngine `
    -Label "$($case.name) injectEngine"
  Assert-Equal -Expected $case.mode -Actual $plan.mode `
    -Label "$($case.name) mode"
  [ordered]@{
    name = $case.name
    passed = $true
    plan = $plan
  }
}

$failureCases = @(
  [ordered]@{
    name = 'conflicting-modes'
    arguments = @('build', 'windows', '--debug', '--release')
    pattern = 'Conflicting Flutter build modes'
  },
  [ordered]@{
    name = 'manual-local-engine-is-rejected'
    arguments = @('run', '-d', 'windows', '--local-engine=wrong')
    pattern = 'flutterw owns local Engine selection'
  },
  [ordered]@{
    name = 'missing-device-value'
    arguments = @('run', '-d')
    pattern = 'requires a device id'
  }
)

$failureReports = foreach ($case in $failureCases) {
  $message = $null
  try {
    $null = Get-KirakaraFlutterInvocationPlan -Arguments $case.arguments
  } catch {
    $message = $_.Exception.Message
  }
  if ([string]::IsNullOrWhiteSpace($message) -or $message -notmatch $case.pattern) {
    throw "$($case.name) did not fail with the expected message. Actual: $message"
  }
  [ordered]@{
    name = $case.name
    passed = $true
    message = $message
  }
}

$layout = Get-KirakaraProjectLayout
$expectedWorkspace = [IO.Path]::GetFullPath((Join-Path $repository '.kfe'))
Assert-Equal -Expected $expectedWorkspace -Actual $layout.Root `
  -Label 'repository-local workspace'
Assert-Equal -Expected 'repository-local' -Actual $layout.Kind `
  -Label 'repository-local layout kind'
Assert-Equal -Expected (Join-Path $expectedWorkspace 'out') `
  -Actual (Join-Path $layout.OutputRoot 'out') `
  -Label 'repository-local output root'
$canonicalRepository = & $bootstrapModule {
  param($Path)
  Resolve-KirakaraCanonicalDirectoryPath -Path $Path
} $repository
$canonicalAgain = & $bootstrapModule {
  param($Path)
  Resolve-KirakaraCanonicalDirectoryPath -Path $Path
} $canonicalRepository
Assert-Equal -Expected $canonicalRepository -Actual $canonicalAgain `
  -Label 'canonical repository path idempotence'
$repositoryItem = Get-Item -LiteralPath $repository -Force
if (($repositoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -and
    $canonicalRepository.Equals(
      $repository, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Repository reparse point was not resolved for mutex identity.'
}

$toolchainEnvironmentNames = @(
  'GYP_MSVS_OVERRIDE_PATH',
  'VCToolsVersion',
  'WINDOWSSDKDIR'
)
$originalToolchainEnvironment = [ordered]@{}
foreach ($name in $toolchainEnvironmentNames) {
  $originalToolchainEnvironment[$name] =
    [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
  [Environment]::SetEnvironmentVariable(
    'GYP_MSVS_OVERRIDE_PATH', 'original-gyp', 'Process')
  [Environment]::SetEnvironmentVariable(
    'VCToolsVersion', $null, 'Process')
  [Environment]::SetEnvironmentVariable(
    'WINDOWSSDKDIR', 'original-sdk', 'Process')
  $toolchainEnvironmentSnapshot = & $bootstrapModule {
    Get-KirakaraEngineToolchainEnvironmentSnapshot
  }
  foreach ($name in $toolchainEnvironmentNames) {
    [Environment]::SetEnvironmentVariable(
      $name, "leaked-$name", 'Process')
  }
  & $bootstrapModule {
    param($Snapshot)
    Restore-KirakaraEngineToolchainEnvironment -Snapshot $Snapshot
  } $toolchainEnvironmentSnapshot
  Assert-Equal -Expected 'original-gyp' `
    -Actual ([Environment]::GetEnvironmentVariable(
        'GYP_MSVS_OVERRIDE_PATH', 'Process')) `
    -Label 'restored GYP_MSVS_OVERRIDE_PATH'
  $restoredVcToolsVersion = [Environment]::GetEnvironmentVariable(
    'VCToolsVersion', 'Process')
  if (-not [string]::IsNullOrEmpty($restoredVcToolsVersion)) {
    throw "restored VCToolsVersion mismatch. Got '$restoredVcToolsVersion'."
  }
  Assert-Equal -Expected 'original-sdk' `
    -Actual ([Environment]::GetEnvironmentVariable(
        'WINDOWSSDKDIR', 'Process')) `
    -Label 'restored WINDOWSSDKDIR'
} finally {
  foreach ($name in $toolchainEnvironmentNames) {
    [Environment]::SetEnvironmentVariable(
      $name, $originalToolchainEnvironment[$name], 'Process')
  }
}
$toolchainEnvironmentRestore = [ordered]@{
  names = @($toolchainEnvironmentNames)
  preservesExistingValues = $true
  removesPreviouslyAbsentValues = $true
  passed = $true
}

$compatibilityChecks = @()
$relativeBase = Join-Path $repository 'build\diagnostics\PowerShell 兼容路径'
$relativeTarget = Join-Path $relativeBase '子目录\文件.txt'
Assert-Equal -Expected '.' `
  -Actual (Get-KirakaraRelativePath -BasePath $relativeBase -Path $relativeBase) `
  -Label 'PowerShell compatibility same-path relative path'
Assert-Equal -Expected ('子目录' + [IO.Path]::DirectorySeparatorChar + '文件.txt') `
  -Actual (Get-KirakaraRelativePath -BasePath $relativeBase -Path $relativeTarget) `
  -Label 'PowerShell compatibility Unicode relative path'

$argumentCases = @(
  [ordered]@{ input = ''; expected = '""' },
  [ordered]@{ input = 'plain'; expected = 'plain' },
  [ordered]@{ input = '包含 空格'; expected = '"包含 空格"' },
  [ordered]@{ input = 'say"hello'; expected = '"say\"hello"' },
  [ordered]@{ input = 'C:\path with space\'; expected = '"C:\path with space\\"' }
)
foreach ($argumentCase in $argumentCases) {
  Assert-Equal -Expected $argumentCase.expected `
    -Actual (ConvertTo-KirakaraProcessArgument -Argument $argumentCase.input) `
    -Label "PowerShell compatibility process argument '$($argumentCase.input)'"
}
$encodingStartInfo = [Diagnostics.ProcessStartInfo]::new()
Set-KirakaraProcessUtf8Redirection -StartInfo $encodingStartInfo
Assert-Equal -Expected 65001 `
  -Actual $encodingStartInfo.StandardOutputEncoding.CodePage `
  -Label 'PowerShell compatibility standard output encoding'
Assert-Equal -Expected 65001 `
  -Actual $encodingStartInfo.StandardErrorEncoding.CodePage `
  -Label 'PowerShell compatibility standard error encoding'
$compatibilityChecks += [ordered]@{
  relativePaths = $true
  processArgumentQuoting = $true
  redirectedProcessUtf8 = $true
}

$wrapperFirstLine = Get-Content -LiteralPath (Join-Path $repository 'flutterw.ps1') |
  Select-Object -First 1
Assert-Equal -Expected '#Requires -Version 5.1' -Actual $wrapperFirstLine `
  -Label 'PowerShell wrapper version requirement'
$cmdWrapper = Get-Content -Raw -LiteralPath (Join-Path $repository 'flutterw.cmd')
if ($cmdWrapper -notmatch '(?i)WindowsPowerShell\\v1\.0\\powershell\.exe' -or
    $cmdWrapper -match '(?im)^\s*(?:where\s+)?pwsh(?:\.exe)?\b') {
  throw 'flutterw.cmd must use built-in Windows PowerShell without requiring pwsh.'
}

$vscodeSettingsPath = Join-Path $repository '.vscode\settings.json'
$vscodeTasksPath = Join-Path $repository '.vscode\tasks.json'
$vscodeSettings = Get-Content -Raw -Encoding utf8 `
  -LiteralPath $vscodeSettingsPath | ConvertFrom-Json
$vscodeTasks = Get-Content -Raw -Encoding utf8 `
  -LiteralPath $vscodeTasksPath | ConvertFrom-Json
Assert-Equal -Expected $false `
  -Actual ([bool]$vscodeSettings.'dart.showMainCodeLens') `
  -Label 'VS Code main.dart default Run/Debug links'
Assert-Equal -Expected 'windows' `
  -Actual ((@($vscodeSettings.'dart.flutterCreatePlatforms')) -join ',') `
  -Label 'VS Code Flutter create platforms'
Assert-Equal -Expected $false `
  -Actual ([bool]$vscodeSettings.'dart.flutterRememberSelectedDevice') `
  -Label 'VS Code remembered Flutter device'
Assert-Equal -Expected $false `
  -Actual ([bool]$vscodeSettings.'dart.flutterSelectDeviceWhenConnected') `
  -Label 'VS Code connected Flutter device auto-selection'
Assert-Equal -Expected 'never' `
  -Actual ([string]$vscodeSettings.'dart.flutterShowEmulators') `
  -Label 'VS Code Flutter emulator visibility'
Assert-Equal -Expected '-d,windows' `
  -Actual ((@($vscodeSettings.'dart.flutterRunAdditionalArgs')) -join ',') `
  -Label 'VS Code Flutter run target'
foreach ($task in @($vscodeTasks.tasks)) {
  Assert-Equal -Expected '${workspaceFolder}\flutterw.cmd' `
    -Actual ([string]$task.command) `
    -Label "VS Code task '$($task.label)' wrapper"
  if ((@($task.args) -join ' ') -match '(?i)(?:^|\s)android(?:\s|$)|\bapk\b|\baab\b') {
    throw "VS Code task '$($task.label)' contains an Android target."
  }
}
$vscodeRunTask = @($vscodeTasks.tasks | Where-Object {
    $_.label -eq 'Kirakara：运行 main.dart（flutterw）'
  })
Assert-Equal -Expected 1 -Actual $vscodeRunTask.Count `
  -Label 'VS Code Windows run task count'
Assert-Equal -Expected 'run,-d,windows,-t,lib/main.dart' `
  -Actual ((@($vscodeRunTask[0].args)) -join ',') `
  -Label 'VS Code Windows run task arguments'
$vscodeChecks = [ordered]@{
  mainCodeLensDisabled = $true
  windowsOnly = $true
  automaticMobileSelectionDisabled = $true
  tasksUseFlutterWrapper = $true
}

$lock = Get-Content -Raw -LiteralPath (Join-Path $repository `
  'engine\engine.lock.json') | ConvertFrom-Json
$fingerprints = @{}
foreach ($mode in 'debug', 'profile', 'release') {
  $first = Get-KirakaraBootstrapFingerprint -Lock $lock -Mode $mode
  $second = Get-KirakaraBootstrapFingerprint -Lock $lock -Mode $mode
  Assert-Equal -Expected $first.value -Actual $second.value `
    -Label "$mode fingerprint stability"
  $fingerprints[$mode] = $first.value
}
if (@($fingerprints.Values | Sort-Object -Unique).Count -ne 3) {
  throw 'Build-mode fingerprints must be distinct.'
}
$releaseOnlyLock = $lock | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$releaseOnlyLock.projectBootstrap.releaseCandidate.artifacts[0].sha256 = 'A' * 64
$releaseOnlyLock.patchset.builds[2].artifacts[0].sha256 = 'B' * 64
$releaseOnlyLock.builds[2].artifacts[0].sha256 = 'C' * 64
foreach ($mode in 'debug', 'profile', 'release') {
  $releaseOnlyFingerprint = Get-KirakaraBootstrapFingerprint `
    -Lock $releaseOnlyLock `
    -Mode $mode
  Assert-Equal -Expected $fingerprints[$mode] `
    -Actual $releaseOnlyFingerprint.value `
    -Label "$mode release-candidate fingerprint isolation"
}
$buildInputLock = $lock | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$buildInputLock.patchset.version = [uint32]$buildInputLock.patchset.version + 1
$changedBuildFingerprint = Get-KirakaraBootstrapFingerprint `
  -Lock $buildInputLock `
  -Mode debug
if ($changedBuildFingerprint.value -eq $fingerprints.debug) {
  throw 'A build-relevant lock change did not invalidate the Engine fingerprint.'
}
$fingerprintIsolation = [ordered]@{
  releaseCandidateDoesNotInvalidate = $true
  buildInputInvalidates = $true
}

$releaseBuild = Get-BuildLock -Lock $lock -Mode release -Variant patched
$repositoryReleaseContract = Get-KirakaraReleaseArtifactContract `
  -Lock $lock `
  -Layout ([pscustomobject]@{ Kind = 'repository-local' }) `
  -Build $releaseBuild
Assert-Equal -Expected ([string]$lock.projectBootstrap.releaseCandidate.localEngine) `
  -Actual ([string]$repositoryReleaseContract.localEngine) `
  -Label 'repository-local Release contract'
$externalReleaseContract = Get-KirakaraReleaseArtifactContract `
  -Lock $lock `
  -Layout ([pscustomobject]@{ Kind = 'external' }) `
  -Build $releaseBuild
Assert-Equal -Expected ([string]$releaseBuild.artifacts[0].sha256) `
  -Actual ([string]$externalReleaseContract.artifacts[0].sha256) `
  -Label 'external Release contract'
$debugBuild = Get-BuildLock -Lock $lock -Mode debug -Variant patched
$wrongModeMessage = $null
try {
  $null = Get-KirakaraReleaseArtifactContract `
    -Lock $lock `
    -Layout ([pscustomobject]@{ Kind = 'repository-local' }) `
    -Build $debugBuild
} catch {
  $wrongModeMessage = $_.Exception.Message
}
if ($wrongModeMessage -notmatch 'cannot be selected') {
  throw "A non-Release artifact contract was not rejected: $wrongModeMessage"
}
$releaseContractChecks = [ordered]@{
  repositoryLocalUsesCandidate = $true
  externalUsesHistoricalLock = $true
  nonReleaseRejected = $true
}
$toolFingerprints = [ordered]@{}
foreach ($toolName in 'Gn', 'Ninja') {
  $first = & $bootstrapModule {
    param($Lock, $ToolName)
    & "Get-Kirakara${ToolName}Fingerprint" -Lock $Lock
  } $lock $toolName
  $second = & $bootstrapModule {
    param($Lock, $ToolName)
    & "Get-Kirakara${ToolName}Fingerprint" -Lock $Lock
  } $lock $toolName
  Assert-Equal -Expected $first.value -Actual $second.value `
    -Label "$toolName tool fingerprint stability"
  $toolFingerprints[$toolName.ToLowerInvariant()] = $first.value
}

$ignore = Get-Content -LiteralPath (Join-Path $repository '.gitignore')
if ($ignore -notcontains '.kfe/') {
  throw '.gitignore does not exclude the repository-local Engine workspace.'
}

$launcherChecks = @()
foreach ($relativePath in @(
    'tool/build_windows_debug_exe.bat',
    'tool/build_windows_release_exe.bat',
    'tool/run_windows_debug.bat',
    'tool/run_windows_debug_exe.bat'
  )) {
  $launcherPath = Join-Path $repository $relativePath
  $launcher = Get-Content -Raw -LiteralPath $launcherPath
  if ($launcher -notmatch [regex]::Escape('%~dp0..')) {
    throw "$relativePath does not resolve the repository from its own location."
  }
  if ($launcher -notmatch [regex]::Escape('flutterw.cmd')) {
    throw "$relativePath bypasses the repository Flutter wrapper."
  }
  if ($launcher -match '(?im)^\s*flutter(?:\.bat)?\s' -or
      $launcher -match '(?i)[A-Z]:\\Kirakara-App' -or
      $launcher -match '(?i)Program Files\\Flutter') {
    throw "$relativePath contains a bare Flutter command or a machine-specific path."
  }
  $launcherChecks += [ordered]@{
    path = $relativePath
    repositoryRelative = $true
    usesFlutterWrapper = $true
    machineSpecificPathAbsent = $true
  }
}

$scratchParent = Join-Path $repository 'build\diagnostics\engine'
$scratch = Join-Path $scratchParent (
  "project-bootstrap-test-$([Guid]::NewGuid().ToString('N'))")
$ephemeralInvalidation = $null
$sdkSwitchInvalidation = $null
$readyStampChecks = @()
$toolReadyStampChecks = @()
$vpythonBootstrapChecks = @()
$wrapperArgumentChecks = @()
$logRetention = $null
$checkoutRecovery = @()
try {
  $compatibilityScratch = Join-Path $scratch 'powershell-compatibility'
  New-Item -ItemType Directory -Path $compatibilityScratch -Force | Out-Null
  $hashFixture = Join-Path $compatibilityScratch '哈希 夹具.txt'
  [IO.File]::WriteAllText(
    $hashFixture,
    'Kirakara PowerShell 5.1',
    [Text.UTF8Encoding]::new($false))
  $hashStream = [IO.File]::OpenRead($hashFixture)
  $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
  try {
    $expectedHash = [BitConverter]::ToString(
      $hashAlgorithm.ComputeHash($hashStream)).Replace('-', '')
  } finally {
    $hashAlgorithm.Dispose()
    $hashStream.Dispose()
  }
  Assert-Equal -Expected $expectedHash `
    -Actual ((Get-FileHash -LiteralPath $hashFixture).Hash) `
    -Label 'PowerShell compatibility SHA-256 shim'

  $moveSource = Join-Path $compatibilityScratch 'source.txt'
  $moveDestination = Join-Path $compatibilityScratch 'destination.txt'
  [IO.File]::WriteAllText($moveSource, 'new', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($moveDestination, 'old', [Text.UTF8Encoding]::new($false))
  Move-KirakaraFile -Source $moveSource -Destination $moveDestination -Overwrite
  Assert-Equal -Expected 'new' `
    -Actual ([IO.File]::ReadAllText($moveDestination, [Text.Encoding]::UTF8)) `
    -Label 'PowerShell compatibility overwrite move content'
  Assert-Equal -Expected $false -Actual (Test-Path -LiteralPath $moveSource) `
    -Label 'PowerShell compatibility overwrite move source removal'
  $compatibilityChecks += [ordered]@{
    fileHash = $true
    overwriteMove = $true
  }

  $wrapperProbe = Join-Path $scratch 'wrapper-arguments'
  $wrapperProbeScripts = Join-Path $wrapperProbe 'engine\scripts'
  New-Item -ItemType Directory -Path $wrapperProbeScripts -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $repository 'flutterw.ps1') `
    -Destination (Join-Path $wrapperProbe 'flutterw.ps1')
  Copy-Item -LiteralPath (Join-Path $repository 'flutterw.cmd') `
    -Destination (Join-Path $wrapperProbe 'flutterw.cmd')
  $fakeBootstrapModule = @'
function Invoke-KirakaraFlutter {
  param([string[]]$Arguments)
  [IO.File]::WriteAllLines(
    $env:KIRAKARA_WRAPPER_ARGUMENT_REPORT,
    $Arguments,
    [Text.UTF8Encoding]::new($false))
  return 0
}
function Invoke-KirakaraEngineCommand {
  param([string[]]$Arguments)
  return 0
}
Export-ModuleMember -Function Invoke-KirakaraFlutter, Invoke-KirakaraEngineCommand
'@
  [IO.File]::WriteAllText(
    (Join-Path $wrapperProbeScripts 'project_engine_bootstrap.psm1'),
    $fakeBootstrapModule,
    [Text.UTF8Encoding]::new($false))
  $argumentReport = Join-Path $wrapperProbe 'arguments.txt'
  $priorArgumentReport = [Environment]::GetEnvironmentVariable(
    'KIRAKARA_WRAPPER_ARGUMENT_REPORT', 'Process')
  try {
    $env:KIRAKARA_WRAPPER_ARGUMENT_REPORT = $argumentReport
    $windowsPowerShell = Join-Path $env:SystemRoot `
      'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $windowsPowerShell -NoLogo -NoProfile `
      -File (Join-Path $wrapperProbe 'flutterw.ps1') `
      run -d windows
    if ($LASTEXITCODE -ne 0) {
      throw "flutterw.ps1 argument probe failed: $LASTEXITCODE"
    }
    $ps1Arguments = @(Get-Content -LiteralPath $argumentReport)
    Assert-Equal -Expected 'run|-d|windows' `
      -Actual ($ps1Arguments -join '|') `
      -Label 'flutterw.ps1 argument forwarding'
    $wrapperArgumentChecks += [ordered]@{
      entryPoint = 'flutterw.ps1'
      arguments = $ps1Arguments
      passed = $true
    }

    & cmd.exe /d /c (Join-Path $wrapperProbe 'flutterw.cmd') run -d windows
    if ($LASTEXITCODE -ne 0) {
      throw "flutterw.cmd argument probe failed: $LASTEXITCODE"
    }
    $cmdArguments = @(Get-Content -LiteralPath $argumentReport)
    Assert-Equal -Expected 'run|-d|windows' `
      -Actual ($cmdArguments -join '|') `
      -Label 'flutterw.cmd argument forwarding'
    $wrapperArgumentChecks += [ordered]@{
      entryPoint = 'flutterw.cmd'
      arguments = $cmdArguments
      passed = $true
    }
  } finally {
    [Environment]::SetEnvironmentVariable(
      'KIRAKARA_WRAPPER_ARGUMENT_REPORT', $priorArgumentReport, 'Process')
  }

  $expectedOutput = Join-Path $scratch 'engine-output'
  $testApp = Join-Path $scratch 'app'
  $testEphemeral = Join-Path $testApp 'windows\flutter\ephemeral'
  New-Item -ItemType Directory -Path $expectedOutput, $testEphemeral `
    -Force | Out-Null
  $expectedDll = Join-Path $expectedOutput 'flutter_windows.dll'
  $actualDll = Join-Path $testEphemeral 'flutter_windows.dll'
  Set-Content -LiteralPath $expectedDll -Value 'A' -NoNewline
  Set-Content -LiteralPath $actualDll -Value 'A' -NoNewline
  Invalidate-StaleFlutterEphemeralEngine `
    -EngineOutputDirectory $expectedOutput `
    -AppRoot $testApp
  if (-not (Test-Path -LiteralPath $actualDll -PathType Leaf)) {
    throw 'Matching Flutter ephemeral Engine output was invalidated.'
  }
  Set-Content -LiteralPath $expectedDll -Value 'B' -NoNewline
  Invalidate-StaleFlutterEphemeralEngine `
    -EngineOutputDirectory $expectedOutput `
    -AppRoot $testApp
  if (Test-Path -LiteralPath $actualDll -PathType Leaf) {
    throw 'Stale Flutter ephemeral Engine output was not invalidated.'
  }
  $ephemeralInvalidation = [ordered]@{
    matchingOutputPreserved = $true
    staleOutputInvalidated = $true
  }

  $sdkSwitchApp = Join-Path $scratch 'sdk-switch-app'
  $sdkSwitchEphemeral = Join-Path $sdkSwitchApp `
    'windows\flutter\ephemeral'
  $sdkSwitchBuild = Join-Path $sdkSwitchApp 'build\windows\x64'
  New-Item -ItemType Directory `
    -Path $sdkSwitchEphemeral, $sdkSwitchBuild `
    -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $sdkSwitchApp 'pubspec.yaml') `
    -Value 'name: sdk_switch_test' -Encoding utf8
  Set-Content -LiteralPath (Join-Path $sdkSwitchApp `
      'windows\CMakeLists.txt') -Value '# generated test marker' -Encoding utf8
  $sdkConfig = Join-Path $sdkSwitchEphemeral 'generated_config.cmake'
  Set-Content -LiteralPath $sdkConfig -Value (
    'file(TO_CMAKE_PATH "C:\\previous\\flutter" FLUTTER_ROOT)') `
    -Encoding utf8
  Set-Content -LiteralPath (Join-Path $sdkSwitchBuild 'sentinel.txt') `
    -Value 'generated' -NoNewline
  $invalidated = Invalidate-StaleFlutterWindowsBuildForSdk `
    -FlutterSdkRoot 'C:\selected\flutter' `
    -AppRoot $sdkSwitchApp
  if (-not $invalidated -or (Test-Path -LiteralPath $sdkSwitchBuild)) {
    throw 'Flutter SDK switch did not invalidate the generated Windows App build.'
  }
  New-Item -ItemType Directory -Path $sdkSwitchBuild -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $sdkSwitchBuild 'sentinel.txt') `
    -Value 'generated' -NoNewline
  Set-Content -LiteralPath $sdkConfig -Value (
    'file(TO_CMAKE_PATH "C:\\selected\\flutter" FLUTTER_ROOT)') `
    -Encoding utf8
  $preserved = Invalidate-StaleFlutterWindowsBuildForSdk `
    -FlutterSdkRoot 'C:\selected\flutter' `
    -AppRoot $sdkSwitchApp
  if ($preserved -or -not (Test-Path -LiteralPath $sdkSwitchBuild)) {
    throw 'Matching Flutter SDK selection removed the Windows App build.'
  }
  $sdkSwitchInvalidation = [ordered]@{
    changedSdkRemovedGeneratedBuild = $true
    matchingSdkPreservedGeneratedBuild = $true
  }

  $readyPath = Join-Path $layout.State 'debug-ready.json'
  if (Test-Path -LiteralPath $readyPath -PathType Leaf) {
    $originalStamp = Get-Content -Raw -LiteralPath $readyPath | ConvertFrom-Json
    $testLayout = $layout | Select-Object *
    $testLayout.State = Join-Path $scratch 'state'
    New-Item -ItemType Directory -Path $testLayout.State -Force | Out-Null
    $testReadyPath = Join-Path $testLayout.State 'debug-ready.json'

    $missing = & $bootstrapModule {
      param($Layout, $Lock, $Fingerprint)
      Test-KirakaraReadyStamp `
        -Layout $Layout -Lock $Lock -Mode debug -Fingerprint $Fingerprint
    } $testLayout $lock ([string]$originalStamp.fingerprint)
    if ($missing.ready -or $missing.reason -ne 'ready stamp is missing') {
      throw "Missing ready stamp was accepted: $($missing.reason)"
    }
    $readyStampChecks += [ordered]@{
      name = 'missing-ready-stamp'
      passed = $true
      reason = $missing.reason
    }

    $emptyArtifacts = $originalStamp | ConvertTo-Json -Depth 12 |
      ConvertFrom-Json
    $emptyArtifacts.artifacts = @()
    $emptyArtifacts | ConvertTo-Json -Depth 12 | Set-Content `
      -LiteralPath $testReadyPath -Encoding utf8
    $emptyResult = & $bootstrapModule {
      param($Layout, $Lock, $Fingerprint)
      Test-KirakaraReadyStamp `
        -Layout $Layout -Lock $Lock -Mode debug -Fingerprint $Fingerprint
    } $testLayout $lock ([string]$originalStamp.fingerprint)
    if ($emptyResult.ready -or
        $emptyResult.reason -notmatch 'artifact set') {
      throw "Corrupt ready-stamp artifact set was accepted: $($emptyResult.reason)"
    }
    $readyStampChecks += [ordered]@{
      name = 'corrupt-artifact-set'
      passed = $true
      reason = $emptyResult.reason
    }

    $badArgs = $originalStamp | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $badArgs.argsGnSha256 = '0' * 64
    $badArgs | ConvertTo-Json -Depth 12 | Set-Content `
      -LiteralPath $testReadyPath -Encoding utf8
    $argsResult = & $bootstrapModule {
      param($Layout, $Lock, $Fingerprint)
      Test-KirakaraReadyStamp `
        -Layout $Layout -Lock $Lock -Mode debug -Fingerprint $Fingerprint
    } $testLayout $lock ([string]$originalStamp.fingerprint)
    if ($argsResult.ready -or
        $argsResult.reason -notmatch 'GN arguments') {
      throw "Corrupt ready-stamp GN hash was accepted: $($argsResult.reason)"
    }
    $readyStampChecks += [ordered]@{
      name = 'corrupt-gn-hash'
      passed = $true
      reason = $argsResult.reason
    }
  }

  $ninjaFingerprint = & $bootstrapModule {
    param($Lock)
    Get-KirakaraNinjaFingerprint -Lock $Lock
  } $lock
  $ninjaPaths = & $bootstrapModule {
    param($Layout, $Fingerprint)
    Get-KirakaraNinjaPaths -Layout $Layout -Fingerprint $Fingerprint
  } $layout ([string]$ninjaFingerprint.value)
  if (Test-Path -LiteralPath $ninjaPaths.readyStamp -PathType Leaf) {
    $currentNinja = & $bootstrapModule {
      param($Layout, $Lock, $Fingerprint, $Paths)
      Test-KirakaraNinjaReadyStamp `
        -Layout $Layout -Lock $Lock -Fingerprint $Fingerprint -Paths $Paths
    } $layout $lock $ninjaFingerprint $ninjaPaths
    if (-not $currentNinja.ready) {
      throw "Current Ninja ready stamp failed validation: $($currentNinja.reason)"
    }
  $toolReadyStampChecks += [ordered]@{
      name = 'verified-ninja-ready-stamp'
      passed = $true
      reason = $currentNinja.reason
    }

    $toolState = Join-Path $scratch 'tool-state'
    New-Item -ItemType Directory -Path $toolState -Force | Out-Null
    $testNinjaPaths = $ninjaPaths | Select-Object *
    $testNinjaPaths.readyStamp = Join-Path $toolState 'ninja-ready.json'
    $missingNinja = & $bootstrapModule {
      param($Layout, $Lock, $Fingerprint, $Paths)
      Test-KirakaraNinjaReadyStamp `
        -Layout $Layout -Lock $Lock -Fingerprint $Fingerprint -Paths $Paths
    } $layout $lock $ninjaFingerprint $testNinjaPaths
    if ($missingNinja.ready -or
        $missingNinja.reason -ne 'Ninja ready stamp is missing') {
      throw "Missing Ninja ready stamp was accepted: $($missingNinja.reason)"
    }
    $toolReadyStampChecks += [ordered]@{
      name = 'missing-ninja-ready-stamp'
      passed = $true
      reason = $missingNinja.reason
    }

    $ninjaStamp = Get-Content -Raw -LiteralPath $ninjaPaths.readyStamp |
      ConvertFrom-Json
    $badNinjaCount = $ninjaStamp | ConvertTo-Json -Depth 20 |
      ConvertFrom-Json
    $badNinjaCount.unitTestCount = 0
    $badNinjaCount | ConvertTo-Json -Depth 20 | Set-Content `
      -LiteralPath $testNinjaPaths.readyStamp -Encoding utf8
    $countResult = & $bootstrapModule {
      param($Layout, $Lock, $Fingerprint, $Paths)
      Test-KirakaraNinjaReadyStamp `
        -Layout $Layout -Lock $Lock -Fingerprint $Fingerprint -Paths $Paths
    } $layout $lock $ninjaFingerprint $testNinjaPaths
    if ($countResult.ready -or $countResult.reason -notmatch 'test count') {
      throw "Corrupt Ninja test count was accepted: $($countResult.reason)"
    }
    $toolReadyStampChecks += [ordered]@{
      name = 'corrupt-ninja-test-count'
      passed = $true
      reason = $countResult.reason
    }

    $badNinjaHash = $ninjaStamp | ConvertTo-Json -Depth 20 |
      ConvertFrom-Json
    $badNinjaHash.binarySha256 = '0' * 64
    $badNinjaHash | ConvertTo-Json -Depth 20 | Set-Content `
      -LiteralPath $testNinjaPaths.readyStamp -Encoding utf8
    $hashResult = & $bootstrapModule {
      param($Layout, $Lock, $Fingerprint, $Paths)
      Test-KirakaraNinjaReadyStamp `
        -Layout $Layout -Lock $Lock -Fingerprint $Fingerprint -Paths $Paths
    } $layout $lock $ninjaFingerprint $testNinjaPaths
    if ($hashResult.ready -or $hashResult.reason -notmatch 'binary hash') {
      throw "Corrupt Ninja binary hash was accepted: $($hashResult.reason)"
    }
    $toolReadyStampChecks += [ordered]@{
      name = 'corrupt-ninja-binary-hash'
      passed = $true
      reason = $hashResult.reason
    }
  }

  $modernVpythonRoot = Join-Path $scratch 'modern-vpython'
  $modernVpythonCache = Join-Path $modernVpythonRoot 'cache'
  $modernDepotTools = Join-Path $modernVpythonRoot 'depot_tools'
  New-Item -ItemType Directory `
    -Path (Join-Path $modernVpythonCache 'vpython\store'), $modernDepotTools `
    -Force | Out-Null
  $modernVpythonConfig = Join-Path $modernDepotTools 'vpython.toml'
  [IO.File]::WriteAllText(
    $modernVpythonConfig,
    "requires-python = '>=3.11,<3.12'`r`n",
    [Text.UTF8Encoding]::new($false))
  $modernVpythonHash = & $bootstrapModule {
    param($Text)
    Get-KirakaraSha256Text -Text $Text
  } "requires-python = '>=3.11,<3.12'`n"
  $modernVpythonLock = $lock | ConvertTo-Json -Depth 20 | ConvertFrom-Json
  $modernVpythonLock.depotTools.vpythonTomlNormalizedSha256 = $modernVpythonHash
  $modernVpythonLayout = [pscustomobject]@{
    Cache = $modernVpythonCache
    DepotTools = $modernDepotTools
  }
  $modernVpythonResult = & $bootstrapModule {
    param($Layout, $Lock)
    Repair-KirakaraVpythonVirtualenv -Layout $Layout -Lock $Lock
  } $modernVpythonLayout $modernVpythonLock
  Assert-Equal -Expected 'uv' -Actual $modernVpythonResult.backend `
    -Label 'clean vpython backend'
  Assert-Equal -Expected $false -Actual $modernVpythonResult.legacyPatched `
    -Label 'clean vpython legacy patch state'
  $vpythonBootstrapChecks += [ordered]@{
    name = 'clean-cache-uses-locked-uv-backend'
    passed = $true
    configSha256 = $modernVpythonResult.configSha256
  }

  $modernVpythonLock.depotTools.vpythonTomlNormalizedSha256 = '0' * 64
  $vpythonHashMessage = $null
  try {
    $null = & $bootstrapModule {
      param($Layout, $Lock)
      Repair-KirakaraVpythonVirtualenv -Layout $Layout -Lock $Lock
    } $modernVpythonLayout $modernVpythonLock
  } catch {
    $vpythonHashMessage = $_.Exception.Message
  }
  if ($vpythonHashMessage -notmatch 'vpython\.toml hash mismatch') {
    throw "Mismatched vpython.toml was not rejected: $vpythonHashMessage"
  }
  $vpythonBootstrapChecks += [ordered]@{
    name = 'reject-unlocked-uv-config'
    passed = $true
    message = $vpythonHashMessage
  }

  $retentionRoot = Join-Path $scratch 'retention'
  $retentionLayout = $layout | Select-Object *
  $retentionLayout.Root = $retentionRoot
  $retentionLayout.Logs = Join-Path $retentionRoot 'logs'
  $retentionLayout.State = Join-Path $retentionRoot 'state'
  New-Item -ItemType Directory `
    -Path $retentionLayout.Logs, $retentionLayout.State `
    -Force | Out-Null
  foreach ($index in 0..4) {
    $logPath = Join-Path $retentionLayout.Logs "log-$index.json"
    Set-Content -LiteralPath $logPath -Value "{`"index`":$index}" `
      -Encoding utf8
    (Get-Item -LiteralPath $logPath).LastWriteTimeUtc =
      [DateTime]::UtcNow.AddMinutes($index)
  }
  [ordered]@{
    verificationReport = 'logs/log-0.json'
    abiReport = 'logs/log-0.json'
  } | ConvertTo-Json | Set-Content `
    -LiteralPath (Join-Path $retentionLayout.State 'debug-ready.json') `
    -Encoding utf8
  $retentionLock = $lock | ConvertTo-Json -Depth 20 | ConvertFrom-Json
  $retentionLock.projectBootstrap.maxLogFiles = 3
  & $bootstrapModule {
    param($Layout, $Lock)
    Remove-KirakaraExpiredLogs -Layout $Layout -Lock $Lock
  } $retentionLayout $retentionLock
  $retainedNames = @(Get-ChildItem -LiteralPath $retentionLayout.Logs -File |
      Sort-Object Name | ForEach-Object Name)
  foreach ($expectedName in 'log-0.json', 'log-3.json', 'log-4.json') {
    if ($retainedNames -notcontains $expectedName) {
      throw "Log retention removed expected file: $expectedName"
    }
  }
  if ($retainedNames.Count -ne 3) {
    throw "Log retention kept $($retainedNames.Count) files instead of 3."
  }
  $logRetention = [ordered]@{
    limit = 3
    retained = $retainedNames
    protectedReadyStampReportPreserved = $true
  }

  $partialCheckout = Join-Path $scratch 'partial-checkout'
  New-Item -ItemType Directory -Path $partialCheckout -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $partialCheckout 'partial.data') `
    -Value 'interrupted' -NoNewline
  $partialResult = Repair-InterruptedManagedGitCheckout `
    -Path $partialCheckout `
    -ManagedRoot $scratch `
    -Repository 'https://invalid.example/repository.git' `
    -Revision ('0' * 40) `
    -Label 'test partial'
  Assert-Equal -Expected 'removed-incomplete' -Actual $partialResult `
    -Label 'partial checkout repair result'
  if (Test-Path -LiteralPath $partialCheckout) {
    throw 'Interrupted checkout without Git metadata was not removed.'
  }
  $checkoutRecovery += [ordered]@{
    name = 'remove-incomplete-managed-directory'
    passed = $true
  }

  $origin = Join-Path $scratch 'origin'
  Invoke-CheckedNative git @('init', '--initial-branch=main', $origin) `
    'Could not create bootstrap recovery test repository.' | Out-Null
  Invoke-CheckedNative git @('-C', $origin, 'config', 'user.name', 'Kirakara Test') |
    Out-Null
  Invoke-CheckedNative git @('-C', $origin, 'config', 'user.email', 'test@invalid') |
    Out-Null
  $tracked = Join-Path $origin 'tracked.txt'
  Set-Content -LiteralPath $tracked -Value 'first' -NoNewline
  Invoke-CheckedNative git @('-C', $origin, 'add', 'tracked.txt') | Out-Null
  Invoke-CheckedNative git @('-C', $origin, 'commit', '-m', '测试：建立初始源码夹具') | Out-Null
  $firstRevision = Get-GitHead $origin
  Set-Content -LiteralPath $tracked -Value 'second' -NoNewline
  Invoke-CheckedNative git @('-C', $origin, 'commit', '-am', '测试：更新源码夹具') | Out-Null
  $secondRevision = Get-GitHead $origin
  $managedCheckout = Join-Path $scratch 'managed-checkout'
  Invoke-CheckedNative git @('clone', $origin, $managedCheckout) | Out-Null
  $resumeResult = Repair-InterruptedManagedGitCheckout `
    -Path $managedCheckout `
    -ManagedRoot $scratch `
    -Repository $origin `
    -Revision $firstRevision `
    -Label 'test managed'
  Assert-Equal -Expected 'resumed' -Actual $resumeResult `
    -Label 'clean checkout resume result'
  Assert-Equal -Expected $firstRevision -Actual (Get-GitHead $managedCheckout) `
    -Label 'resumed checkout revision'
  $checkoutRecovery += [ordered]@{
    name = 'resume-clean-checkout-at-locked-revision'
    passed = $true
  }

  Set-Content -LiteralPath (Join-Path $managedCheckout 'tracked.txt') `
    -Value 'local change' -NoNewline
  $dirtyMessage = $null
  try {
    $null = Repair-InterruptedManagedGitCheckout `
      -Path $managedCheckout `
      -ManagedRoot $scratch `
      -Repository $origin `
      -Revision $secondRevision `
      -Label 'test managed'
  } catch {
    $dirtyMessage = $_.Exception.Message
  }
  if ($dirtyMessage -notmatch 'tracked changes') {
    throw "Dirty managed checkout was not refused: $dirtyMessage"
  }
  $checkoutRecovery += [ordered]@{
    name = 'refuse-tracked-changes'
    passed = $true
  }

  $unsafeLayout = Get-EngineWorkspaceLayout (Join-Path $repository '.kfe-other')
  $unsafeMessage = $null
  try {
    Assert-ExternalEngineWorkspace $unsafeLayout
  } catch {
    $unsafeMessage = $_.Exception.Message
  }
  if ($unsafeMessage -notmatch 'outside the App repository') {
    throw "Unsafe in-repository workspace was not rejected: $unsafeMessage"
  }
} finally {
  if (Test-Path -LiteralPath $scratch) {
    if (-not (Test-PathWithin $scratch $scratchParent)) {
      throw "Refusing to remove unexpected bootstrap test scratch path: $scratch"
    }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $ReportPath = Join-Path $repository `
    "build\diagnostics\engine\project-bootstrap-tests-$stamp.json"
}
$absoluteReport = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
  $ReportPath)
if (Test-Path -LiteralPath $absoluteReport) {
  throw "ReportPath already exists: $absoluteReport"
}
New-Item -ItemType Directory -Path (Split-Path -Parent $absoluteReport) `
  -Force | Out-Null
[ordered]@{
  schemaVersion = 1
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  workspace = $layout.Root
  canonicalRepository = $canonicalRepository
  powershell7Required = $false
  minimumPowerShellVersion = '5.1'
  powershellCompatibility = @($compatibilityChecks)
  vscode = $vscodeChecks
  invocationCases = @($caseReports)
  rejectionCases = @($failureReports)
  fingerprints = $fingerprints
  fingerprintIsolation = $fingerprintIsolation
  releaseContractChecks = $releaseContractChecks
  toolFingerprints = $toolFingerprints
  toolchainEnvironmentRestore = $toolchainEnvironmentRestore
  ephemeralInvalidation = $ephemeralInvalidation
  sdkSwitchInvalidation = $sdkSwitchInvalidation
  readyStampChecks = @($readyStampChecks)
  toolReadyStampChecks = @($toolReadyStampChecks)
  vpythonBootstrapChecks = @($vpythonBootstrapChecks)
  wrapperArgumentChecks = @($wrapperArgumentChecks)
  launcherChecks = @($launcherChecks)
  logRetention = $logRetention
  checkoutRecovery = @($checkoutRecovery)
  cleanupBoundaryPassed = $true
  passed = $true
} | ConvertTo-Json -Depth 8 | Set-Content `
  -LiteralPath $absoluteReport `
  -Encoding utf8
Write-Host "Project Engine bootstrap tests passed. Report: $absoluteReport"
