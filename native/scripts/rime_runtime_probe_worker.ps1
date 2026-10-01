#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RequestPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
$request=Get-Content -Raw -LiteralPath $RequestPath | ConvertFrom-Json
$scratch=[IO.Path]::GetFullPath([string]$request.state)
if (-not $scratch.StartsWith($repo+'\.kfe\tmp\rime-runtime-test-',[StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($RequestPath)) -cne $scratch -or
    [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$request.result)) -cne $scratch) {
  throw '原生测试状态只能写入本次创建的独立临时目录。'
}
foreach ($path in @($RequestPath,$request.dll,$request.shared,$request.state,$request.result)) {
  $full=[IO.Path]::GetFullPath([string]$path)
  if (-not $full.StartsWith($repo+'\.kfe\',[StringComparison]::OrdinalIgnoreCase)) { throw '原生测试输入/输出必须位于当前仓库 .kfe。' }
  [Kirakara.Artifacts.Security]::NoReparse($full)
}
Add-Type -Path (Join-Path $PSScriptRoot 'rime_runtime_probe.cs')
$result=[Kirakara.RimeRuntimeProbe.Probe]::Run($request.dll,$request.shared,$request.state)
$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $request.result -Encoding utf8
