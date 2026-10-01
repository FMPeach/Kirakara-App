#Requires -Version 7.2
[CmdletBinding()]
param([string]$ReportPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'artifact_package.psm1') -DisableNameChecking
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$scratch = Join-Path $repo ('.kfe/tmp/concurrency-test-' + [guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null = New-Item -ItemType Directory -Path $scratch
$children = [Collections.Generic.List[object]]::new()
function Start-InstallerWorker {
  param([string]$Destination, [string]$Name, [switch]$Blocked)
  $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
  $start.UseShellExecute = $false; $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
  foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',
      (Join-Path $PSScriptRoot 'test_artifact_installer_worker.ps1'),
      '-Workspace',$workspace,'-Destination',$Destination,'-EntryPath',$entryPath,
      '-Archive',$archive,'-ResultPath',(Join-Path $scratch "$Name-result.json"),
      '-EnteredPath',(Join-Path $scratch "$Name-entered"))) { $start.ArgumentList.Add($argument) }
  if ($Blocked) { $start.ArgumentList.Add('-GatePath'); $start.ArgumentList.Add($gate) }
  $process = [Diagnostics.Process]::Start($start)
  $child = @{ process = $process; stdout = $process.StandardOutput.ReadToEndAsync()
    stderr = $process.StandardError.ReadToEndAsync() }
  $children.Add($child)
  return $child
}
function Wait-TestFile {
  param([string]$Path, $Child)
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  while (-not (Test-Path -LiteralPath $Path)) {
    if ($Child.process.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw '安装测试子进程没有进入预期门控。' }
    Start-Sleep -Milliseconds 50
  }
}
function Assert-WorkerCompleted {
  param($Child, [string]$Name)
  if (-not $Child.process.WaitForExit(15000)) { throw '安装测试子进程超时。' }
  if ($Child.process.ExitCode -ne 0) { throw "安装测试子进程失败：$($Child.stderr.GetAwaiter().GetResult())" }
  $result = Get-Content -Raw -LiteralPath (Join-Path $scratch "$Name-result.json") | ConvertFrom-Json
  if (-not $result.passed) { throw '安装测试子进程没有成功结果。' }
}
try {
  $fixture = Join-Path $scratch 'fixture'; $null = New-Item -ItemType Directory -Path $fixture
  [IO.File]::WriteAllText((Join-Path $fixture 'payload.txt'),'并发与中断测试数据',[Text.UTF8Encoding]::new($false))
  $identity = 'D' * 64
  $manifest = [ordered]@{ schemaVersion = 1; kind = 'test-data'; identityHash = $identity
    files = @(@{ path = 'payload.txt'; size = (Get-Item (Join-Path $fixture 'payload.txt')).Length
      sha256 = Get-ArtifactHash (Join-Path $fixture 'payload.txt') }) }
  [IO.File]::WriteAllText((Join-Path $fixture 'manifest.json'),($manifest | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
  $archive = Join-Path $scratch 'fixture.zip'; [IO.Compression.ZipFile]::CreateFromDirectory($fixture,$archive)
  $entry = [pscustomobject]@{ url = $null; size = (Get-Item $archive).Length; sha256 = Get-ArtifactHash $archive
    manifestSha256 = Get-ArtifactHash (Join-Path $fixture 'manifest.json'); identityHash = $identity }
  $entryPath = Join-Path $scratch 'entry.json'
  [IO.File]::WriteAllText($entryPath,($entry | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
  $workspace = Join-Path $scratch 'workspace'; $gate = Join-Path $scratch 'gate'
  $destination = Join-Path $workspace 'prebuilt/concurrent'
  $first = Start-InstallerWorker $destination 'first' -Blocked
  Wait-TestFile (Join-Path $scratch 'first-entered') $first
  if (Test-Path -LiteralPath (Join-Path $destination 'ready.json')) { throw '验证尚未完成却出现 ready。' }
  $second = Start-InstallerWorker $destination 'second'
  # Give the second process time to contend for the repository lock.
  Start-Sleep -Milliseconds 500
  if ($second.process.HasExited -or (Test-Path -LiteralPath (Join-Path $scratch 'second-entered'))) {
    throw '第二个安装进程没有等待首个事务。'
  }
  [IO.File]::WriteAllText($gate,'允许测试事务完成')
  Assert-WorkerCompleted $first 'first'; Assert-WorkerCompleted $second 'second'
  $null = Assert-ArtifactManifest $destination test-data $identity $entry -Installed
  if (-not (Test-Path -LiteralPath (Join-Path $destination 'ready.json'))) { throw '并发安装未产生 ready。' }
  Remove-Item -LiteralPath $gate
  $interruptedDestination = Join-Path $workspace 'prebuilt/interrupted'
  $interrupted = Start-InstallerWorker $interruptedDestination 'interrupted' -Blocked
  Wait-TestFile (Join-Path $scratch 'interrupted-entered') $interrupted
  $interrupted.process.Kill($true); $interrupted.process.WaitForExit()
  if (Test-Path -LiteralPath $interruptedDestination) { throw '强制中断留下了虚假安装目录。' }
  $recovery = Start-InstallerWorker $interruptedDestination 'recovery'
  Assert-WorkerCompleted $recovery 'recovery'
  $null = Assert-ArtifactManifest $interruptedDestination test-data $identity $entry -Installed
  if (-not (Test-Path -LiteralPath (Join-Path $interruptedDestination 'ready.json'))) { throw '中断恢复未产生 ready。' }
  if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $repo 'build/diagnostics/prebuilt-concurrency.json' }
  $null = New-Item -ItemType Directory -Path (Split-Path -Parent ([IO.Path]::GetFullPath($ReportPath))) -Force
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),(@{ passed = $true
    twoProcessInstallAndReuse = $true; verificationKillNoFalseReady = $true
    lockReleasedAfterKill = $true; restartRecovery = $true } | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
  Write-Host "预编译并发测试通过：双进程安装/复用、强制中断、锁释放和重启恢复。报告：$ReportPath"
} finally {
  foreach ($child in $children) {
    if (-not $child.process.HasExited) { $child.process.Kill($true); $child.process.WaitForExit() }
    $child.process.Dispose()
  }
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  if (-not [IO.Path]::GetFullPath($scratch).StartsWith((Join-Path $repo '.kfe/tmp/'),[StringComparison]::OrdinalIgnoreCase)) {
    throw '拒绝清理测试范围之外的路径。'
  }
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
