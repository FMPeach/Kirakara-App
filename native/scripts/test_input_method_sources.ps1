#Requires -Version 7.2
[CmdletBinding()]
param([string]$ReportPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
$native = Get-Content -Raw -LiteralPath (Join-Path $repo 'native/native.lock.json') | ConvertFrom-Json
$data = Get-Content -Raw -LiteralPath (Join-Path $repo 'third_party/data.lock.json') | ConvertFrom-Json
function Read-SourceBlob {
  param([string]$Repository, [string]$Revision, [string]$Path)
  [Kirakara.Artifacts.Security]::NoReparse($Repository)
  if ($Revision -notmatch '^[0-9a-f]{40}$') { throw '来源 revision 无效。' }
  [Kirakara.Artifacts.Security]::RelativePath($Path) | Out-Null
  $start = [Diagnostics.ProcessStartInfo]::new('git')
  $start.UseShellExecute = $false; $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
  foreach ($argument in @('-C',$Repository,'show',"${Revision}:$Path")) { $start.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::Start($start)
  $memory = [IO.MemoryStream]::new()
  try {
    $errorTask = $process.StandardError.ReadToEndAsync()
    $process.StandardOutput.BaseStream.CopyTo($memory)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0 -or $memory.Length -gt 16777216) { throw '固定来源对象不存在或超出数据大小限制。' }
    return ,$memory.ToArray()
  } finally { $memory.Dispose(); $process.Dispose() }
}
if ((& git -C (Join-Path $repo '.kfe/source/zinnia') rev-parse HEAD) -cne $native.zinnia.revision) {
  throw 'Zinnia BSD 源码 revision 不匹配。'
}
if ((& git -C (Join-Path $repo '.kfe/source/librime') rev-parse HEAD) -cne $native.librime.revision) {
  throw 'librime BSD 源码 revision 不匹配。'
}
foreach ($submodule in $native.librime.submodules.PSObject.Properties) {
  $path = Join-Path $repo ('.kfe/source/librime/' + $submodule.Name)
  if ((& git -C $path rev-parse HEAD) -cne $submodule.Value) { throw 'librime 依赖源码 revision 不匹配。' }
}
if (@($data.rime.sources).Count -ne 20) { throw '当前必要 Rime 来源集合不完整。' }
$paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$default = $null
foreach ($record in $data.rime.sources) {
  if (-not $paths.Add($record.path) -or $record.path -match 'cangjie5' -or $record.license -cne 'LGPL-3.0') {
    throw 'Rime 必要来源清单存在重复、未许可的仓颉内容或错误许可证。'
  }
  $repositoryName = ([uri]$record.repository).Segments[-1] -replace '\.git$',''
  if ($repositoryName -notmatch '^rime-[a-z-]+$') { throw '来源仓库名称不受支持。' }
  $repository = Join-Path $repo ('.kfe/source/data/' + $repositoryName)
  if ((& git -C $repository remote get-url origin) -cne $record.repository) { throw 'Rime 来源 remote 不匹配。' }
  $bytes = Read-SourceBlob $repository $record.revision $record.path
  if ($bytes.Length -ne $record.size -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -ine $record.sha256) {
    throw "Rime 数据与固定原始 Git blob 不一致：$($record.path)"
  }
  $license = Read-SourceBlob $repository $record.revision $record.licensePath
  if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($license)) -ine $record.licenseSha256) {
    throw 'Rime 对应来源许可证哈希错误。'
  }
  if ($record.path -ceq 'default.yaml') { $default = $bytes }
}
$scratch = Join-Path $repo ('.kfe/tmp/rime-config-test-' + [guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null = New-Item -ItemType Directory -Path $scratch
try {
  [IO.File]::WriteAllBytes((Join-Path $scratch 'default.yaml'),$default)
  $patch = [Kirakara.Artifacts.Security]::Child($repo, $data.rime.runtimeModification.patch)
  if ((Get-ArtifactHash $patch) -ine $data.rime.runtimeModification.sha256) { throw 'Rime 配置补丁哈希不匹配。' }
  $relative = [IO.Path]::GetRelativePath($repo,$scratch).Replace('\','/')
  Push-Location $repo
  try {
    & git apply --check --directory=$relative $patch
    if ($LASTEXITCODE) { throw 'Rime 排除仓颉的补丁不适用。' }
    & git apply --directory=$relative $patch
    if ($LASTEXITCODE) { throw 'Rime 配置补丁应用失败。' }
  } finally { Pop-Location }
  $updated = [IO.File]::ReadAllText((Join-Path $scratch 'default.yaml'))
  if ($updated -match '(?m)^\s*-\s*schema:\s*cangjie5' -or
      @([regex]::Matches($updated,'(?m)^\s*-\s*schema:')).Count -ne 7) {
    throw '配置补丁没有仅删除未使用的仓颉入口。'
  }
} finally {
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $repo 'build/diagnostics/input-method-sources.json' }
$report = [IO.Path]::GetFullPath($ReportPath)
if (-not $report.StartsWith($repo.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
  throw '来源报告必须位于当前仓库。'
}
[Kirakara.Artifacts.Security]::NoReparse($report)
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
[IO.File]::WriteAllText($report,([ordered]@{ passed = $true; rimeSourceFiles = $paths.Count
  rawBlobAndLicenseHashesVerified = $true; nativeRevisionsVerified = $true
  cangjieRuntimeExcluded = $true; remainingSchemasUnchanged = $true
  fullRuntimeLicenseAuditComplete = $data.rime.auditComplete } | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
Write-Host "输入法来源契约通过：20 份固定数据、对应许可及仓颉排除补丁。报告：$report"
