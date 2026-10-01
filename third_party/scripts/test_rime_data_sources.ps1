#Requires -Version 7.2
[CmdletBinding()]
param([string]$SourceRoot,[string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'rime_package.psm1') -DisableNameChecking
$expected=Get-RimeDataIdentity
$prepare=Join-Path $PSScriptRoot 'prepare_rime_data_sources.ps1'
$scratch=Join-Path $repo ('.kfe/tmp/rime-source-contract-'+[guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null=New-Item -ItemType Directory -Path $scratch
$cases=[Collections.Generic.List[string]]::new()
$storageLink=$null
$firstGroup=@($expected.data.sources | Group-Object repository)[0]
$name=([uri]$firstGroup.Name).Segments[-1] -replace '\.git$',''
$sourceUrl=[string]$firstGroup.Name
function Expect-Rejection {
  param([string]$Root,[string]$Message)
  $rejected=$false
  try { & $prepare -Offline -SourceRoot $Root -ReportPath (Join-Path $scratch 'must-not-pass.json') } catch {
    if ($_.Exception.Message -notlike $Message) { throw }; $rejected=$true
  }
  if (-not $rejected -or (Test-Path -LiteralPath (Join-Path $scratch 'must-not-pass.json'))) { throw '来源拒绝测试没有失败或留下虚假通过报告。' }
}
function Initialize-Fixture {
  param([string]$Root,[string]$Remote)
  $directory=Join-Path $Root $name
  & git init --quiet $directory
  if ($LASTEXITCODE) { throw '来源夹具初始化失败。' }
  & git -C $directory remote add origin $Remote
  if ($LASTEXITCODE) { throw '来源夹具 remote 创建失败。' }
  return $directory
}
try {
  if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot=Join-Path $repo '.kfe/source/data' }
  & $prepare -Offline -SourceRoot $SourceRoot -ReportPath (Join-Path $scratch 'existing.json')
  $existing=Get-Content -Raw -LiteralPath (Join-Path $scratch 'existing.json') | ConvertFrom-Json
  if ($existing.sourceFiles -ne 20 -or $existing.repositories -ne 6 -or $existing.fetchedRevisions -ne 0 -or
      -not $existing.worktreesAndHeadsPreserved) { throw '现有精确来源离线验证结果不完整。' }
  $cases.Add('六来源、二十文件及许可离线校验且 HEAD/工作区不变')
  $outside=Join-Path $repo ('build/diagnostics/outside-rime-source-'+[guid]::NewGuid().ToString('N'))
  Expect-Rejection $outside '*必须位于当前仓库 .kfe*'
  if (Test-Path -LiteralPath $outside) { throw '越界目标被创建。' }
  $cases.Add('当前仓库 .kfe 以外的写入目标拒绝且不创建')
  $missing=Join-Path $scratch 'missing'
  Expect-Rejection $missing '*离线缺少 Rime 固定来源*'
  if (Test-Path -LiteralPath (Join-Path $missing $name)) { throw '离线缺失时初始化了来源 Git 缓存。' }
  $cases.Add('离线缺少来源立即失败，不自动下载')
  $unknown=Join-Path $scratch 'unknown'
  $userFile=Join-Path $unknown ($name+'/user-file.txt')
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $userFile) -Force
  [IO.File]::WriteAllText($userFile,'keep',[Text.UTF8Encoding]::new($false))
  $before=Get-ArtifactHash $userFile
  Expect-Rejection $unknown '*不是独立 Git 缓存*'
  if ((Get-ArtifactHash $userFile) -cne $before) { throw '未知目录里的用户文件被修改。' }
  $cases.Add('未知来源目录拒绝，保留用户文件')
  $wrong=Join-Path $scratch 'wrong-remote'
  $wrongDirectory=Initialize-Fixture $wrong 'https://example.invalid/rime-data.git'
  Expect-Rejection $wrong '*remote 与锁不匹配*'
  if ((& git -C $wrongDirectory remote get-url origin) -cne 'https://example.invalid/rime-data.git') { throw '错误 remote 被擅自修改。' }
  $cases.Add('错误 remote 拒绝且不改配置')
  $dirty=Join-Path $scratch 'dirty'
  $dirtyDirectory=Initialize-Fixture $dirty $sourceUrl
  $tracked=Join-Path $dirtyDirectory 'user-file.txt'
  [IO.File]::WriteAllText($tracked,'original',[Text.UTF8Encoding]::new($false))
  & git -C $dirtyDirectory add -- user-file.txt
  if ($LASTEXITCODE) { throw '来源测试文件登记失败。' }
  & git -C $dirtyDirectory -c user.name=测试 -c user.email=test@example.invalid -c commit.gpgsign=false commit --quiet -m '测试：建立来源保留夹具'
  if ($LASTEXITCODE) { throw '来源测试提交失败。' }
  $head=(& git -C $dirtyDirectory rev-parse HEAD).Trim()
  [IO.File]::WriteAllText($tracked,'user edit',[Text.UTF8Encoding]::new($false))
  $before=Get-ArtifactHash $tracked
  Expect-Rejection $dirty '*存在用户修改或未跟踪文件*'
  if ((Get-ArtifactHash $tracked) -cne $before -or (& git -C $dirtyDirectory rev-parse HEAD) -cne $head) { throw '用户修改或 HEAD 被改变。' }
  $cases.Add('已跟踪用户修改拒绝，不清理或重置 HEAD')
  $untracked=Join-Path $scratch 'untracked'
  $untrackedDirectory=Initialize-Fixture $untracked $sourceUrl
  $userFile=Join-Path $untrackedDirectory 'user-file.txt'
  [IO.File]::WriteAllText($userFile,'keep',[Text.UTF8Encoding]::new($false))
  $before=Get-ArtifactHash $userFile
  Expect-Rejection $untracked '*存在用户修改或未跟踪文件*'
  if ((Get-ArtifactHash $userFile) -cne $before) { throw '未跟踪用户文件被改变。' }
  $cases.Add('未跟踪用户文件拒绝且保留')
  $empty=Join-Path $scratch 'missing-revision'
  $null=Initialize-Fixture $empty $sourceUrl
  Expect-Rejection $empty '*离线缺少固定 Rime revision*'
  $cases.Add('离线缺少特定 revision 明确失败，不接受当前 HEAD 代替')
  $linked=Join-Path $scratch 'linked-storage'
  $linkedDirectory=Initialize-Fixture $linked $sourceUrl
  $target=Join-Path $scratch 'link-target'
  $null=New-Item -ItemType Directory -Path $target
  $targetFile=Join-Path $target 'user-file.txt'
  [IO.File]::WriteAllText($targetFile,'keep',[Text.UTF8Encoding]::new($false))
  $before=Get-ArtifactHash $targetFile
  $storageLink=Join-Path $linkedDirectory '.git/objects/info/test-link'
  $null=New-Item -ItemType Junction -Path $storageLink -Target $target
  Expect-Rejection $linked '*Git 元数据包含目录联接或符号链接*'
  if ((Get-ArtifactHash $targetFile) -cne $before) { throw '联接目标内容被修改。' }
  $cases.Add('Git 元数据内联接拒绝，不跟随或写入目标')
  if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath=Join-Path $repo 'build/diagnostics/rime-data-source-contract.json' }
  $report=[IO.Path]::GetFullPath($ReportPath)
  if (-not $report.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '报告必须位于当前仓库。' }
  [Kirakara.Artifacts.Security]::NoReparse($report)
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
  [ordered]@{passed=$true;cases=$cases.ToArray();onlineColdFetchVerified=$false;sourceWorktreesPreserved=$true
    compilerInvoked=$false;formalReleasePublished=$false} | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath $report -Encoding utf8
  Write-Host "Rime 数据来源 $($cases.Count) 项拒绝/保留检查通过。报告：$report"
} finally {
  if ($storageLink -and (Test-Path -LiteralPath $storageLink)) {
    if (-not $storageLink.StartsWith($scratch+'\',[StringComparison]::OrdinalIgnoreCase) -or
        (Get-Item -LiteralPath $storageLink -Force).LinkType -ne 'Junction') { throw '测试联接清理目标错误。' }
    Remove-Item -LiteralPath $storageLink -Force
  }
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  if (-not $scratch.StartsWith($repo+'\.kfe\tmp\rime-source-contract-',[StringComparison]::OrdinalIgnoreCase)) { throw '测试来源清理目标越界。' }
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
# 拒绝用例内的原生命令失败是被断言的预期结果，不应成为测试进程的退出码。
$global:LASTEXITCODE=0
