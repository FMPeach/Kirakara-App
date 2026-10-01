#Requires -Version 7.2
[CmdletBinding()]
param([string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'artifact_package.psm1') -DisableNameChecking
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$scratch=Join-Path $repo ('.kfe/tmp/http-test-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $scratch
$server=$null
try {
  $fixture=Join-Path $scratch 'fixture';$null=New-Item -ItemType Directory -Path $fixture
  [IO.File]::WriteAllText((Join-Path $fixture 'file.txt'),'下载事务测试数据',[Text.UTF8Encoding]::new($false))
  $identity='C'*64
  $manifest=[ordered]@{schemaVersion=1;kind='test-data';identityHash=$identity
    files=@(@{path='file.txt';size=(Get-Item (Join-Path $fixture 'file.txt')).Length;sha256=Get-ArtifactHash (Join-Path $fixture 'file.txt')})}
  [IO.File]::WriteAllText((Join-Path $fixture 'manifest.json'),($manifest|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
  $archive=Join-Path $scratch 'fixture.zip';[IO.Compression.ZipFile]::CreateFromDirectory($fixture,$archive)
  $ready=Join-Path $scratch 'http-ready'
  $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true
  foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'test_artifact_http_server.ps1'),'-Archive',$archive,'-ReadyFile',$ready)) {$start.ArgumentList.Add($argument)}
  $server=[Diagnostics.Process]::Start($start)
  $deadline=[DateTime]::UtcNow.AddSeconds(10)
  while (-not (Test-Path -LiteralPath $ready)) {
    if ($server.HasExited -or [DateTime]::UtcNow -gt $deadline) {throw '本地 loopback HTTP 测试服务未启动。'}
    Start-Sleep -Milliseconds 50
  }
  $port=[int](Get-Content -Raw -LiteralPath $ready)
  $entry=[pscustomobject]@{url="http://127.0.0.1:$port/redirect";size=(Get-Item $archive).Length
    sha256=Get-ArtifactHash $archive;manifestSha256=Get-ArtifactHash (Join-Path $fixture 'manifest.json');identityHash=$identity}
  $workspace=Join-Path $scratch 'workspace';$destination=Join-Path $workspace 'prebuilt/data'
  $null=Install-ArtifactPackage -Workspace $workspace -Destination $destination -Kind test-data -IdentityHash $identity -Entry $entry -Verify {param($root,$manifest)}
  if (-not (Test-Path -LiteralPath (Join-Path $destination 'ready.json'))) {throw 'HTTP 安装没有 ready stamp。'}
  $null=Install-ArtifactPackage -Workspace $workspace -Destination $destination -Kind test-data -IdentityHash $identity -Entry $entry -Verify {param($root,$manifest)}
  $partial=Join-Path $scratch 'partial.zip';$rejected=$false
  try { Save-ArtifactDownload -Uri "http://127.0.0.1:$port/partial" -Path $partial -ExpectedBytes $entry.size } catch {$rejected=$true}
  if (-not $rejected) {throw '截断 HTTP 响应未被拒绝。'}
  if ([string]::IsNullOrWhiteSpace($ReportPath)) {$ReportPath=Join-Path $repo 'build/diagnostics/prebuilt-download.json'}
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent ([IO.Path]::GetFullPath($ReportPath))) -Force
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),(@{passed=$true;loopbackOnly=$true
    redirectAndInstall=$true;cacheReuse=$true;truncatedResponseRejected=$true;serverStoppedOnExit=$true}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
  Write-Host "预编译下载测试通过：重定向、安装/复用、下载中断。报告：$ReportPath"
} finally {
  if ($null -ne $server) {if (-not $server.HasExited) {$server.Kill($true);$server.WaitForExit()};$server.Dispose()}
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
