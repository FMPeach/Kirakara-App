#Requires -Version 7.0
[CmdletBinding()]
param([string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'artifact_package.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'prebuilt_engine.psm1') -DisableNameChecking
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$scratch=Join-Path $repo ('.kfe/tmp/security-test-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $scratch
$results=[Collections.Generic.List[object]]::new()
function Expect-Rejection {
  param([string]$Name,[scriptblock]$Action)
  $rejected=$false
  try { & $Action | Out-Null } catch { $rejected=$true }
  if (-not $rejected) { throw "负向测试未被拒绝：$Name" }
  $results.Add(@{name=$Name;passed=$true})
}
function Write-TestZip {
  param([string]$Path,[object[]]$Entries)
  $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew)
  $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($item in $Entries) {
      $entry=$zip.CreateEntry([string]$item.name)
      if ($item.ContainsKey('attributes')) { $entry.ExternalAttributes=[int]$item.attributes }
      $content=$entry.Open()
      try {
        $bytes=[Text.Encoding]::UTF8.GetBytes([string]$item.text)
        $content.Write($bytes,0,$bytes.Length)
      } finally { $content.Dispose() }
    }
  } finally { $zip.Dispose(); $stream.Dispose() }
}
try {
  $badPaths=@('../escape','/absolute','C:/absolute','//server/share','back\slash',
    'data:stream','a//b','a/./b','a/../b','NUL.txt','COM1/file','LPT².txt','a.','a ',"bad`nname")
  $counter=0
  foreach ($path in $badPaths) {
    $counter++
    $zip=Join-Path $scratch "bad-$counter.zip"
    $destination=Join-Path $scratch "bad-$counter-out"
    Write-TestZip $zip @(@{name=$path;text='test'})
    Expect-Rejection "unsafe-path-$counter" { [Kirakara.Artifacts.Security]::ExtractZip($zip,$destination,4096,20) }
    if (Test-Path -LiteralPath $destination) { throw '不安全 ZIP 在中央目录验证前已经创建输出。' }
  }
  $badEntries=@(
    @{name='duplicate';entries=@(@{name='same';text='1'},@{name='same';text='2'})},
    @{name='case-file';entries=@(@{name='File';text='1'},@{name='file';text='2'})},
    @{name='case-directory';entries=@(@{name='Dir/a';text='1'},@{name='dir/b';text='2'})},
    @{name='file-directory';entries=@(@{name='parent';text='1'},@{name='parent/child';text='2'})},
    @{name='unix-symlink';entries=@(@{name='link';text='target';attributes=-1577058304})},
    @{name='dos-reparse';entries=@(@{name='link';text='target';attributes=1024})},
    @{name='size-limit';entries=@(@{name='large';text=('a'*4097)})}
  )
  foreach ($case in $badEntries) {
    $zip=Join-Path $scratch ($case.name+'.zip')
    $destination=Join-Path $scratch ($case.name+'-out')
    Write-TestZip $zip $case.entries
    Expect-Rejection $case.name { [Kirakara.Artifacts.Security]::ExtractZip($zip,$destination,4096,20) }
    if (Test-Path -LiteralPath $destination) { throw '危险 ZIP 留下了输出目录。' }
  }
  $identity='A'*64
  $fixture=Join-Path $scratch 'fixture'
  $null=New-Item -ItemType Directory -Path $fixture
  [IO.File]::WriteAllText((Join-Path $fixture 'payload.txt'),'可信测试数据',[Text.UTF8Encoding]::new($false))
  $file=Get-Item -LiteralPath (Join-Path $fixture 'payload.txt')
  $manifest=[ordered]@{schemaVersion=1;kind='test-data';identityHash=$identity
    files=@(@{path='payload.txt';size=$file.Length;sha256=Get-ArtifactHash $file.FullName})}
  [IO.File]::WriteAllText((Join-Path $fixture 'manifest.json'),($manifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  $archive=Join-Path $scratch 'fixture.zip'
  [IO.Compression.ZipFile]::CreateFromDirectory($fixture,$archive)
  $entry=[pscustomobject]@{url=$null;size=(Get-Item $archive).Length;sha256=Get-ArtifactHash $archive
    manifestSha256=Get-ArtifactHash (Join-Path $fixture 'manifest.json');identityHash=$identity}
  $workspace=Join-Path $scratch 'workspace'
  $destination=Join-Path $workspace 'prebuilt/test'
  $parameters=@{Workspace=$workspace;Destination=$destination;Kind='test-data';IdentityHash=$identity
    Entry=$entry;LocalArchive=$archive;Verify={param($root,$manifest) if ($manifest.kind -cne 'test-data') {throw '错误类型'} }}
  $null=Install-ArtifactPackage @parameters
  if (-not (Test-Path -LiteralPath (Join-Path $destination 'ready.json'))) {throw '成功安装没有 ready stamp。'}
  $null=Install-ArtifactPackage @parameters
  $results.Add(@{name='install-and-reuse';passed=$true})
  [IO.File]::WriteAllText((Join-Path $destination 'payload.txt'),'篡改')
  Expect-Rejection 'installed-file-corruption' { Install-ArtifactPackage @parameters }
  $failed=Join-Path $workspace 'prebuilt/failed-validation'
  $failParameters=$parameters.Clone(); $failParameters.Destination=$failed
  $failParameters.Verify={ throw '模拟验证中断' }
  Expect-Rejection 'verification-interruption' { Install-ArtifactPackage @failParameters }
  if (Test-Path -LiteralPath $failed) {throw '验证失败安装了半成品。'}
  $unfinished=Join-Path $workspace 'prebuilt/unfinished'
  $null=New-Item -ItemType Directory -Path $unfinished
  $failParameters=$parameters.Clone(); $failParameters.Destination=$unfinished
  Expect-Rejection 'missing-ready-after-interruption' { Install-ArtifactPackage @failParameters }
  $failParameters=$parameters.Clone(); $failParameters.Destination=Join-Path $scratch 'outside-workspace'
  Expect-Rejection 'outside-workspace' { Install-ArtifactPackage @failParameters }
  $wrongEntry=($entry|ConvertTo-Json|ConvertFrom-Json); $wrongEntry.sha256='B'*64
  $failParameters=$parameters.Clone(); $failParameters.Destination=Join-Path $workspace 'prebuilt/wrong-sha'; $failParameters.Entry=$wrongEntry
  Expect-Rejection 'archive-sha' { Install-ArtifactPackage @failParameters }
  $wrongEntry=($entry|ConvertTo-Json|ConvertFrom-Json); $wrongEntry.manifestSha256='B'*64
  $failParameters.Entry=$wrongEntry
  Expect-Rejection 'trusted-manifest-sha' { Install-ArtifactPackage @failParameters }
  $wrongEntry=($entry|ConvertTo-Json|ConvertFrom-Json); $wrongEntry.identityHash='B'*64
  $failParameters.Entry=$wrongEntry
  Expect-Rejection 'package-identity' { Install-ArtifactPackage @failParameters }
  Expect-Rejection 'plain-http-remote' { Assert-ArtifactDownloadUri ([uri]'http://example.com/engine.zip') }
  Expect-Rejection 'credential-url' { Assert-ArtifactDownloadUri ([uri]'https://user:password@example.com/engine.zip') }
  $lock=Get-Content -Raw -LiteralPath (Join-Path $repo 'engine/engine.lock.json')|ConvertFrom-Json
  $expected=Get-PrebuiltEngineIdentity $lock debug
  $cacheKey=Get-PrebuiltEngineCacheKey $expected.value
  if ($cacheKey.Length -ne 8 -or $cacheKey -cne $expected.value.Substring(0,8)) {
    throw 'Engine 本地缓存键没有稳定缩短为身份哈希前 8 位。'
  }
  Expect-Rejection 'cache-key-requires-full-identity' { Get-PrebuiltEngineCacheKey $cacheKey }
  $results.Add(@{name='eight-character-cache-key';passed=$true})
  $missingExp=[ordered]@{identity=$expected.identity;files=@(Get-PrebuiltEngineRequiredFiles $expected.identity |
    Where-Object {$_ -notlike '*/flutter_windows.dll.exp'} | ForEach-Object {@{path=$_}})}
  $expRejected=$false
  try {Assert-PrebuiltEngineContents $fixture $missingExp $lock $expected -SkipAbiProbe}
  catch {$expRejected=$_.Exception.Message.Contains('flutter_windows.dll.exp')}
  if (-not $expRejected) {throw '包清单缺 EXP 没有在消费契约检查中被明确拒绝。'}
  $results.Add(@{name='required-windows-exp';passed=$true})
  $formalLockPath=Join-Path $repo 'engine/prebuilt.lock.json'
  foreach ($mode in 'debug','profile','release') {
    $selection=Get-PrebuiltEngineEntry $lock $mode $formalLockPath
    Assert-ArtifactDownloadUri ([uri][string]$selection.entry.url)
    if ($selection.entry.identityHash -cne $selection.identity.value) {
      throw "正式 $mode 预编译条目的身份没有绑定当前 Engine 锁。"
    }
    $results.Add(@{name="configured-$mode-trust-entry";passed=$true})
  }
  $unconfiguredLockPath=Join-Path $scratch 'unconfigured-prebuilt.lock.json'
  $unconfiguredLock=[ordered]@{schemaVersion=1;packageFormatVersion=2;target='windows-x64'
    modes=[ordered]@{debug=$null;profile=$null;release=$null}
    symbols=[ordered]@{debug=$null;profile=$null;release=$null}}
  [IO.File]::WriteAllText($unconfiguredLockPath,($unconfiguredLock|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
  foreach ($mode in 'debug','profile','release') {
    Expect-Rejection "unconfigured-$mode-no-source-fallback" { Get-PrebuiltEngineEntry $lock $mode $unconfiguredLockPath }
  }
  $badPe=Join-Path $scratch 'invalid.dll'; [IO.File]::WriteAllBytes($badPe,[byte[]]::new(32))
  Expect-Rejection 'invalid-pe' { [Kirakara.Artifacts.PeReader]::Read($badPe) }
  if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath=Join-Path $repo 'build/diagnostics/prebuilt-security.json' }
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent ([IO.Path]::GetFullPath($ReportPath))) -Force
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),(@{passed=$true;cases=@($results.ToArray())}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  Write-Host "预编译安全测试通过：$($results.Count) 项。报告：$ReportPath"
} finally {
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
