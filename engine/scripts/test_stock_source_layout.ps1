#Requires -Version 7.2
[CmdletBinding()]
param([string]$ReportPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')
$repo = Get-AppRepositoryRoot
$patched = Get-EngineWorkspaceLayout (Join-Path $repo '.kfe')
$stock = Get-EngineWorkspaceLayout (Join-Path $repo '.kfe/source/stock')
Assert-RepositoryEngineWriteWorkspace $patched
Assert-RepositoryEngineWriteWorkspace $stock
if ($stock.Kind -cne 'repository-stock' -or $stock.FlutterCheckout -ceq $patched.FlutterCheckout -or
    $stock.OutputRoot -ceq $patched.OutputRoot -or $stock.DepotTools -ceq $patched.DepotTools) {
  throw 'Stock 与定制源码、工具或输出未被独立隔离。'
}
$outside = Get-EngineWorkspaceLayout (Join-Path (Split-Path -Parent $repo) 'unmanaged-engine-fixture')
$rejected = $false
try { Assert-RepositoryEngineWriteWorkspace $outside } catch { $rejected = $true }
if (-not $rejected) { throw '外部 Engine 写操作未被拒绝。' }
$fake = $stock.PSObject.Copy()
$fake.OutputRoot = $outside.Root
$rejected = $false
try { Assert-RepositoryEngineWriteWorkspace $fake } catch { $rejected = $true }
if (-not $rejected) { throw '伪造 Stock 输出覆盖未被拒绝。' }
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $repo 'build/diagnostics/stock-source-layout.json' }
$report = [IO.Path]::GetFullPath($ReportPath)
if (-not (Test-PathWithin $report $repo)) { throw '报告必须位于当前仓库。' }
[Kirakara.Artifacts.Security]::NoReparse($report)
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
[IO.File]::WriteAllText($report,(@{ passed = $true; sourceSlotsSeparate = $true; externalWritesRejected = $true
  forgedLayoutRejected = $true; fullEngineBuildExecuted = $false; phase8HardwareRetested = $false } | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
Write-Host "Stock 源码布局和写入边界契约通过；未完整编译 Engine。报告：$report"
