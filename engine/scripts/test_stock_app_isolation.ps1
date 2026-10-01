#Requires -Version 7.2
[CmdletBinding()]
param([string]$ReportPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $PSScriptRoot 'artifact_package.psm1') -DisableNameChecking
$scratch = Join-Path $repo ('.kfe/tmp/stock-app-environment-test-'+[guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null = New-Item -ItemType Directory -Path $scratch
$priorDataLock = [Environment]::GetEnvironmentVariable('KIRAKARA_DATA_PACKAGE_LOCK','Process')
function Get-TestEnvironment {
  $values = [ordered]@{}
  foreach ($item in Get-ChildItem Env: | Sort-Object Name) { $values[$item.Name]=$item.Value }
  return ($values | ConvertTo-Json -Compress)
}
try {
  $lock = Join-Path $scratch 'unconfigured-data.json'
  [IO.File]::WriteAllText($lock,'{"schemaVersion":1,"zinniaTomoe":{"binaryPackage":null}}',[Text.UTF8Encoding]::new($false))
  $env:KIRAKARA_DATA_PACKAGE_LOCK = $lock
  $before = Get-TestEnvironment
  $location = (Get-Location).Path
  $rejected = $false
  try {
    & (Join-Path $PSScriptRoot 'build_windows_app.ps1') -FlutterSdkRoot (Join-Path $repo '.kfe/sdk') -Engine official -Mode debug
  } catch {
    if ($_.Exception.Message -notlike '*维护者尚未配置手写数据包下载*') { throw }
    $rejected = $true
  }
  if (-not $rejected) { throw '官方比较入口未在编译前拒绝缺失模型。' }
  if ((Get-TestEnvironment) -cne $before -or (Get-Location).Path -cne $location) {
    throw '官方比较入口失败后没有恢复调用者环境或工作目录。'
  }
  if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath=Join-Path $repo 'build/diagnostics/stock-app-isolation.json' }
  $report = [IO.Path]::GetFullPath($ReportPath)
  if (-not $report.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '报告必须位于当前仓库。' }
  [Kirakara.Artifacts.Security]::NoReparse($report)
  $null = New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
  [ordered]@{passed=$true;scope='官方 App 比较入口的缺包拒绝和进程环境恢复'
    appCompiled=$false;appRunVerified=$false;systemFlutterInvoked=$false} | ConvertTo-Json |
    Set-Content -LiteralPath $report -Encoding utf8
  Write-Host "官方 App 比较入口失败隔离通过；未实际编译 App。报告：$report"
} finally {
  [Environment]::SetEnvironmentVariable('KIRAKARA_DATA_PACKAGE_LOCK',$priorDataLock,'Process')
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
