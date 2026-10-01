#Requires -Version 7.2
[CmdletBinding()]
param([switch]$Offline,[string]$SourceRoot,[string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'rime_package.psm1') -DisableNameChecking
$expected=Get-RimeDataIdentity
$workspace=Join-Path $repo '.kfe'
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot=Join-Path $workspace 'source/data' }
$sourceRootPath=[IO.Path]::GetFullPath($SourceRoot)
if (-not $sourceRootPath.StartsWith($workspace+'\',[StringComparison]::OrdinalIgnoreCase)) {
  throw 'Rime 数据来源缓存必须位于当前仓库 .kfe 内。'
}
[Kirakara.Artifacts.Security]::NoReparse($sourceRootPath)
$null=New-Item -ItemType Directory -Path $sourceRootPath -Force
$scratch=Join-Path $workspace ('tmp/rime-data-source-'+[guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null=New-Item -ItemType Directory -Path $scratch
$created=0; $fetched=0; $verified=0
$initialHeads=[ordered]@{}
function Read-SourceHead {
  param([string]$Directory)
  $head=@(& git -C $Directory rev-parse --verify --quiet HEAD)
  $code=$LASTEXITCODE
  if ($code -eq 0 -and $head.Count -eq 1) { return [string]$head[0] }
  if ($code -eq 1 -and $head.Count -eq 0) { return $null }
  throw 'Rime 来源 HEAD 检查失败；不把 Git 错误当作空缓存。'
}
function Assert-GitStorage {
  param([string]$Directory)
  $pending=[Collections.Generic.Stack[string]]::new()
  $pending.Push($Directory)
  while ($pending.Count) {
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($pending.Pop())) {
      $attributes=[IO.File]::GetAttributes($entry)
      if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Rime 来源 Git 元数据包含目录联接或符号链接；不会获取或写入。'
      }
      if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Push($entry) }
    }
  }
}
try {
  foreach ($group in @($expected.data.sources | Group-Object repository)) {
    $url=[string]$group.Name
    $name=([uri]$url).Segments[-1] -replace '\.git$',''
    $directory=Join-Path $sourceRootPath $name
    [Kirakara.Artifacts.Security]::NoReparse($directory)
    if (-not (Test-Path -LiteralPath $directory)) {
      if ($Offline) { throw "离线缺少 Rime 固定来源：$name。不会获取源码。" }
      $initialize=Join-Path $scratch $name
      & git init --quiet $initialize
      if ($LASTEXITCODE) { throw 'Rime 数据来源 Git 缓存初始化失败。' }
      & git -C $initialize remote add origin $url
      if ($LASTEXITCODE) { throw 'Rime 官方来源地址登记失败。' }
      # Complete management metadata exists before the directory is published;
      # a failed network fetch can safely resume without overwriting a worktree.
      [IO.Directory]::Move($initialize,$directory)
      $created++
    }
    if (-not (Test-Path -LiteralPath (Join-Path $directory '.git') -PathType Container)) {
      throw 'Rime 来源目录不是独立 Git 缓存；不覆盖用户文件。'
    }
    [Kirakara.Artifacts.Security]::NoReparse((Join-Path $directory '.git'))
    Assert-GitStorage (Join-Path $directory '.git')
    $top=@(& git -C $directory rev-parse --show-toplevel)
    if ($LASTEXITCODE -or $top.Count -ne 1 -or [IO.Path]::GetFullPath($top[0]) -ine $directory) { throw 'Rime 来源目录属于其他 Git 工作区。' }
    $remote=@(& git -C $directory remote get-url origin)
    if ($LASTEXITCODE -or $remote.Count -ne 1 -or $remote[0] -cne $url) { throw 'Rime 来源 remote 与锁不匹配；不修改现有 remote。' }
    $status=@(& git -C $directory status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -or $status.Count) { throw 'Rime 来源目录存在用户修改或未跟踪文件；不重置或清理。' }
    $initialHeads[$name]=Read-SourceHead $directory
    foreach ($revision in @($group.Group | ForEach-Object revision | Sort-Object -Unique)) {
      & git -C $directory cat-file -e "${revision}^{commit}" 2>$null
      $exists=$LASTEXITCODE -eq 0
      if (-not $exists) {
        if ($Offline) { throw "离线缺少固定 Rime revision：$name。不会更新来源缓存。" }
        Write-Host "[Kirakara] 获取固定 Rime 数据来源：$name"
        # Pin retained objects, not a moving branch. No checkout/pull/reset and
        # no global Git configuration, Flutter source or compiler are invoked.
        & git -C $directory -c core.autocrlf=false fetch --quiet --no-tags --depth=1 origin "${revision}:refs/kirakara-data/$revision"
        if ($LASTEXITCODE) { throw "固定 Rime 数据来源获取失败：$name。保留缓存，联网后可重试。" }
        $fetched++
      }
    }
    foreach ($source in $group.Group) {
      $bytes=Read-RimeSourceBlob $directory $source.revision $source.path
      if ($bytes.Length -ne $source.size -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $source.sha256) {
        throw "Rime 原始数据与固定来源锁不一致：$($source.path)"
      }
      $license=Read-RimeSourceBlob $directory $source.revision $source.licensePath
      if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($license)) -cne $source.licenseSha256) {
        throw 'Rime 对应来源许可哈希不匹配。'
      }
      $verified++
    }
    $afterHead=Read-SourceHead $directory
    $afterStatus=@(& git -C $directory status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -or $initialHeads[$name] -cne $afterHead -or $afterStatus.Count) {
      throw '来源准备改变了已有 HEAD 或工作区内容。'
    }
  }
  foreach ($record in $expected.data.licenseDocuments) {
    $path=[Kirakara.Artifacts.Security]::Child($repo,[string]$record.sourcePath)
    if (-not (Test-Path -LiteralPath $path)) {
      if ($Offline -or $record.PSObject.Properties.Name -notcontains 'sourceUrl') { throw '固定许可全文缺失；不会隐式替换。' }
      if (-not $path.StartsWith($workspace+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '下载的许可只能放入本仓库 .kfe。' }
      $partial=Join-Path $scratch 'license.partial'
      Save-ArtifactDownload -Uri ([uri]$record.sourceUrl) -Path $partial -ExpectedBytes ([long]$record.size)
      Assert-ArtifactFile $partial $record
      $null=New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
      [IO.File]::Move($partial,$path)
    }
    Assert-ArtifactFile $path $record
  }
  if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath=Join-Path $repo 'build/diagnostics/rime-data-sources.json' }
  $report=[IO.Path]::GetFullPath($ReportPath)
  if (-not $report.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '报告必须位于当前仓库。' }
  [Kirakara.Artifacts.Security]::NoReparse($report)
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
  [ordered]@{passed=$true;sourceFiles=$verified;repositories=$initialHeads.Count;sourceRoot=$sourceRootPath
    createdRepositories=$created;fetchedRevisions=$fetched;offline=[bool]$Offline;initialHeads=$initialHeads
    worktreesAndHeadsPreserved=$true;compilerInvoked=$false;engineSourcePrepared=$false;formalReleasePublished=$false} | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath $report -Encoding utf8
  Write-Host "Rime 二十份精确数据及对应许可已核验；没有改变现有 HEAD/工作区或编译。报告：$report"
} finally {
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  if (-not $scratch.StartsWith($workspace+'\tmp\rime-data-source-',[StringComparison]::OrdinalIgnoreCase)) { throw '来源临时目录清理越界。' }
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
# 仅在全部验证和临时目录清理成功后返回成功；不泄漏空 HEAD 的预期 Git 返回码。
$global:LASTEXITCODE=0
