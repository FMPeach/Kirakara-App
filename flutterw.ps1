#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Do not turn this entry point into an advanced script. PowerShell common
# parameter abbreviation would otherwise consume Flutter flags such as `-d`
# as the script's `-Debug` switch before they reach the routing layer.
[string[]]$FlutterArguments = @($args | ForEach-Object { [string]$_ })

$processEnvironment = [Collections.Generic.Dictionary[string, string]]::new(
  [StringComparer]::OrdinalIgnoreCase)
foreach ($entry in Get-ChildItem Env:) {
  $processEnvironment[$entry.Name] = $entry.Value
}

$module = Join-Path $PSScriptRoot `
  'engine\scripts\project_engine_bootstrap.psm1'
$exitCode = 1
try {
  Import-Module $module -Force -ErrorAction Stop
  if (
    $FlutterArguments.Count -gt 0 -and
    $FlutterArguments[0] -eq 'engine'
  ) {
    $exitCode = [int](Invoke-KirakaraEngineCommand `
        -Arguments @($FlutterArguments | Select-Object -Skip 1))
  } elseif ($FlutterArguments.Count -gt 0 -and $FlutterArguments[0] -eq 'data') {
    # VS Code terminals are long-lived. Force-refresh repository modules so a
    # pull or local edit cannot leave this invocation running stale code.
    Import-Module (Join-Path $PSScriptRoot 'third_party/scripts/handwriting_package.psm1') -Force -DisableNameChecking -ErrorAction Stop
    $exitCode = [int](Invoke-KirakaraDataCommand -Arguments @($FlutterArguments | Select-Object -Skip 1))
  } elseif ($FlutterArguments.Count -gt 0 -and $FlutterArguments[0] -eq 'native') {
    Import-Module (Join-Path $PSScriptRoot 'native/scripts/native_runtime_package.psm1') -Force -DisableNameChecking -ErrorAction Stop
    $exitCode = [int](Invoke-KirakaraNativeCommand -Arguments @($FlutterArguments | Select-Object -Skip 1))
  } else {
    $exitCode = [int](Invoke-KirakaraFlutter -Arguments $FlutterArguments)
  }
} catch {
  Write-Error $_ -ErrorAction Continue
  $exitCode = 1
} finally {
  foreach ($name in @(Get-ChildItem Env: | ForEach-Object { $_.Name })) {
    if (-not $processEnvironment.ContainsKey($name)) {
      Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue
    }
  }
  foreach ($entry in $processEnvironment.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable(
      $entry.Key, $entry.Value, 'Process')
  }
}
exit $exitCode
