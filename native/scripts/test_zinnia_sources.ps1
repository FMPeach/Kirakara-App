#Requires -Version 7.2
[CmdletBinding()]
param([string]$SourceRoot,[string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
Import-Module (Join-Path $repo 'third_party/scripts/rime_package.psm1') -DisableNameChecking
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot=Join-Path $repo '.kfe/source/zinnia' }
$source=[IO.Path]::GetFullPath($SourceRoot)
if (-not $source.StartsWith($repo+'\.kfe\',[StringComparison]::OrdinalIgnoreCase)) { throw '测试来源必须在当前 .kfe 内。' }
[Kirakara.Artifacts.Security]::NoReparse($source)
$lock=(Get-Content -Raw -LiteralPath (Join-Path $repo 'native/native.lock.json')|ConvertFrom-Json).zinnia
$prepare=Join-Path $PSScriptRoot 'prepare_zinnia_sources.ps1'
$scratch=Join-Path $repo ('.kfe/tmp/zinnia-source-test-'+[guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null=New-Item -ItemType Directory -Path $scratch
$cases=[Collections.Generic.List[string]]::new()
$link=$null
function Snapshot-Worktree {
  param([string]$Root)
  $state=[Collections.Generic.List[string]]::new()
  foreach ($item in Get-ChildItem -LiteralPath $Root -Recurse -File -Force|Sort-Object FullName) {
    [Kirakara.Artifacts.Security]::NoReparse($item.FullName)
    $relative=[IO.Path]::GetRelativePath($Root,$item.FullName)
    if (-not $relative.StartsWith('.git\',[StringComparison]::OrdinalIgnoreCase)) { $state.Add($relative+':'+(Get-ArtifactHash $item.FullName)) }
  }
  return $state.ToArray() -join "`n"
}
function Copy-Fixture {
  param([string]$Name)
  $root=Join-Path $scratch $Name
  [Kirakara.Artifacts.Security]::NoReparse($root)
  Copy-Item -LiteralPath $source -Destination $root -Recurse
  return $root
}
function Expect-Rejection {
  param([string]$Root,[string]$Message)
  $result=Join-Path $scratch ([guid]::NewGuid().ToString('N')+'.json')
  $failure=$null
  try { & $prepare -Offline -SourceRoot $Root -ReportPath $result }
  catch { $failure=$_.Exception.Message }
  if (-not $failure -or $failure -notlike $Message -or (Test-Path -LiteralPath $result)) {
    throw 'Zinnia 拒绝检查不符合预期或留下成功报告。'
  }
}
try {
  $head=& git -C $source rev-parse HEAD
  if ($LASTEXITCODE) { throw '实际来源 HEAD 不可读。' }
  $sourceBefore=Snapshot-Worktree $source
  $remoteBefore=& git -C $source remote get-url origin
  if ($LASTEXITCODE) { throw '实际来源 remote 不可读。' }
  $existing=Join-Path $scratch 'existing.json'
  & $prepare -Offline -SourceRoot $source -ReportPath $existing
  $record=Get-Content -Raw -LiteralPath $existing|ConvertFrom-Json
  if (-not $record.passed -or $record.sourceInputsVerified -ne 23 -or -not $record.implicitGitFetchDisabled -or $record.createdSource -or
      $record.compilerInvoked -or $record.engineSourcePrepared -or $record.formalReleasePublished) { throw '实际来源复用未正确验证。' }
  $cases.Add('实际二十三项源码/许可内容离线核验，允许正常文本换行，不编译或下载')

  $outside=Join-Path $repo ('build/diagnostics/outside-zinnia-'+[guid]::NewGuid().ToString('N'))
  Expect-Rejection $outside '*来源缓存必须在当前仓库 .kfe 内*'
  if (Test-Path -LiteralPath $outside) { throw '越界来源目录被创建。' }
  $cases.Add('当前 .kfe 以外的来源目标拒绝且不创建')
  Expect-Rejection (Join-Path $repo '.kfe') '*来源缓存必须在当前仓库 .kfe 内*'
  $cases.Add('缓存根目录不能作为来源覆盖目标')

  $missing=Join-Path $scratch 'missing'
  Expect-Rejection $missing '*离线缺少固定 Zinnia 来源*'
  if (Test-Path -LiteralPath $missing) { throw '离线缺失时创建了半成品来源目录。' }
  $cases.Add('离线缺少来源立即拒绝，不下载或初始化')

  $notGit=Join-Path $scratch 'not-git'; $null=New-Item -ItemType Directory -Path $notGit
  $keep=Join-Path $notGit 'keep.txt'; [IO.File]::WriteAllText($keep,'已有用户内容',[Text.UTF8Encoding]::new($false))
  $before=Get-ArtifactHash $keep
  Expect-Rejection $notGit '*不是独立 Git 仓库*'
  if ((Get-ArtifactHash $keep) -cne $before) { throw '非 Git 目录的用户内容被覆盖。' }
  $cases.Add('非 Git 用户目录拒绝并保留')

  $wrongRemote=Copy-Fixture 'wrong-remote'
  & git -C $wrongRemote remote set-url origin 'https://example.invalid/unknown-zinnia.git'
  if ($LASTEXITCODE) { throw '夹具 remote 设置失败。' }
  $config=Join-Path $wrongRemote '.git/config'; $before=Get-ArtifactHash $config
  Expect-Rejection $wrongRemote '*remote 与固定官方来源不同*'
  if ((Get-ArtifactHash $config) -cne $before) { throw '错误 remote 被静默改写。' }
  $cases.Add('错误 remote 拒绝，不替换配置')

  $wrongHead=Copy-Fixture 'wrong-head'
  & git -C $wrongHead symbolic-ref HEAD refs/heads/undefined-test-branch
  if ($LASTEXITCODE) { throw '夹具 HEAD 设置失败。' }
  $before=Get-ArtifactHash (Join-Path $wrongHead '.git/HEAD')
  Expect-Rejection $wrongHead '*HEAD 不属于固定 revision*'
  if ((Get-ArtifactHash (Join-Path $wrongHead '.git/HEAD')) -cne $before) { throw '未知 HEAD 被 checkout/reset。' }
  $cases.Add('未知 HEAD 拒绝且不签出或重置')

  $dirty=Copy-Fixture 'dirty'
  $file=Join-Path $dirty 'zinnia/feature.cpp'
  [IO.File]::AppendAllText($file,"`n// 仅测试夹具的用户修改`n",[Text.UTF8Encoding]::new($false))
  $before=Get-ArtifactHash $file
  Expect-Rejection $dirty '*来源有用户修改/未跟踪文件*'
  if ((Get-ArtifactHash $file) -cne $before) { throw '已跟踪修改被覆盖。' }
  $cases.Add('已跟踪用户修改拒绝并保留')

  $untracked=Copy-Fixture 'untracked'
  $file=Join-Path $untracked 'user-file.keep'
  [IO.File]::WriteAllText($file,'未跟踪用户内容',[Text.UTF8Encoding]::new($false)); $before=Get-ArtifactHash $file
  Expect-Rejection $untracked '*来源有用户修改/未跟踪文件*'
  if ((Get-ArtifactHash $file) -cne $before) { throw '未跟踪内容被清理。' }
  $cases.Add('未跟踪用户文件拒绝并保留')

  $hidden=Copy-Fixture 'hidden-change'
  & git -C $hidden update-index --assume-unchanged -- zinnia/feature.cpp
  if ($LASTEXITCODE) { throw '隐藏修改夹具设置失败。' }
  $file=Join-Path $hidden 'zinnia/feature.cpp'
  [IO.File]::AppendAllText($file,"`n// 仅夹具的隐藏修改`n",[Text.UTF8Encoding]::new($false)); $before=Get-ArtifactHash $file
  if (@(& git -C $hidden status --porcelain --untracked-files=all).Count -or $LASTEXITCODE) { throw '夹具未模拟被状态检查隐藏的修改。' }
  Expect-Rejection $hidden '*实际源码内容与固定 Git 来源不同*'
  if ((Get-ArtifactHash $file) -cne $before) { throw '隐藏修改被覆盖。' }
  $cases.Add('assume-unchanged 隐藏修改仍按源码内容拒绝并保留')

  $damaged=Copy-Fixture 'missing-objects'
  & git -C $damaged config remote.origin.promisor true
  if ($LASTEXITCODE) { throw '缺失对象夹具配置失败。' }
  # 夹具代理限定本机；仍用下方 Git Trace 判定有无获取，不以代理连接失败冒充通过。
  & git -C $damaged config http.proxy 'http://127.0.0.1:1'
  if ($LASTEXITCODE) { throw '缺失对象夹具代理设置失败。' }
  $objects=[IO.Path]::GetFullPath((Join-Path $damaged '.git/objects'))
  if (-not $objects.StartsWith($scratch+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '损坏夹具对象清理越界。' }
  [Kirakara.Artifacts.Security]::NoReparse($objects)
  $objectFiles=@(Get-ChildItem -LiteralPath $objects -Recurse -File -Force)
  if (-not $objectFiles.Count) { throw '夹具原始 Git 对象为空，不能证明损坏缓存行为。' }
  foreach ($object in $objectFiles) {
    if (-not $object.FullName.StartsWith($objects+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '损坏夹具文件清理越界。' }
    [Kirakara.Artifacts.Security]::NoReparse($object.FullName)
    Remove-Item -LiteralPath $object.FullName -Force
  }
  $before=Snapshot-Worktree $damaged
  $trace=Join-Path $scratch 'missing-objects-trace.jsonl'
  $oldTrace=[Environment]::GetEnvironmentVariable('GIT_TRACE2_EVENT','Process')
  try {
    [Environment]::SetEnvironmentVariable('GIT_TRACE2_EVENT',$trace,'Process')
    Expect-Rejection $damaged '*本地 Git 对象缺失或无法读取*'
    $blobFailure=$null
    try { $null=Read-RimeSourceBlob $damaged $lock.revision $lock.licenseFile.path -NoLazyFetch }
    catch { $blobFailure=$_.Exception.Message }
    if (-not $blobFailure) { throw '缺失 Git 对象未被原始文件读取器拒绝。' }
  } finally { [Environment]::SetEnvironmentVariable('GIT_TRACE2_EVENT',$oldTrace,'Process') }
  $events=@(Get-Content -LiteralPath $trace|ForEach-Object { $_|ConvertFrom-Json })
  $readCommands=@($events|Where-Object { $_.event -ceq 'start' -and @($_.argv) -contains '--no-lazy-fetch' })
  if (-not @($readCommands|Where-Object { @($_.argv) -contains 'status' }).Count -or
      -not @($readCommands|Where-Object { @($_.argv) -contains 'show' }).Count) { throw 'Git Trace 没有实际观察到两项缺失对象读取，不能宣告无隐式获取。' }
  $fetch=@($events|Where-Object { $_.PSObject.Properties.Name -contains 'argv' -and @($_.argv) -contains 'fetch' })
  if ($fetch.Count -or (Snapshot-Worktree $damaged) -cne $before -or
      @(Get-ChildItem -LiteralPath $objects -Recurse -File -Force).Count) { throw '损坏缓存触发了隐式获取或改写。' }
  $cases.Add('损坏 promisor 缓存及原始对象读取离线拒绝，Git Trace 无隐式 fetch')

  $linked=Copy-Fixture 'linked-metadata'
  $target=Join-Path $scratch 'link-target'; $null=New-Item -ItemType Directory -Path $target
  $keep=Join-Path $target 'keep.txt'; [IO.File]::WriteAllText($keep,'联接目标不修改',[Text.UTF8Encoding]::new($false)); $before=Get-ArtifactHash $keep
  $link=Join-Path $linked '.git/user-link'; $null=New-Item -ItemType Junction -Path $link -Target $target
  Expect-Rejection $linked '*Git 元数据含链接*'
  if ((Get-ArtifactHash $keep) -cne $before) { throw 'Git 元数据联接目标被修改。' }
  $cases.Add('Git 元数据联接拒绝且目标保留')
  Remove-Item -LiteralPath $link; $link=$null

  if ((& git -C $source rev-parse HEAD) -cne $head -or $LASTEXITCODE -or
      (& git -C $source remote get-url origin) -cne $remoteBefore -or $LASTEXITCODE -or
      (Snapshot-Worktree $source) -cne $sourceBefore) { throw '测试改变了实际来源 HEAD、remote 或工作区内容。' }
  if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath=Join-Path $repo 'build/diagnostics/zinnia-source-contract.json' }
  $report=[IO.Path]::GetFullPath($ReportPath)
  if (-not $report.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '报告必须在当前仓库。' }
  [Kirakara.Artifacts.Security]::NoReparse($report)
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
  [ordered]@{passed=$true;cases=$cases.ToArray();sourcesAndHeadsPreserved=$true;implicitFetchCount=0;gitTraceReadCommandsObserved=$readCommands.Count;compilerInvoked=$false;engineSourcePrepared=$false
    appImeUiVerified=$false;formalReleasePublished=$false}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $report -Encoding utf8
  Write-Host "Zinnia 来源 $($cases.Count) 项检查通过。报告：$report"
} finally {
  if ($link -and (Test-Path -LiteralPath $link)) { Remove-Item -LiteralPath $link }
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  if (-not $scratch.StartsWith($repo+'\.kfe\tmp\zinnia-source-test-',[StringComparison]::OrdinalIgnoreCase)) { throw '来源测试清理越界。' }
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
$global:LASTEXITCODE=0
