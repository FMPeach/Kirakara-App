# Kirakara 自有引导代码，采用仓库根 MIT；派生 Flutter tools 保留上游 BSD。
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
Import-Module (Join-Path $PSScriptRoot 'artifact_package.psm1') -DisableNameChecking
$script:ToolsRepository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))

function Get-KirakaraSdkToolsIdentity {
  param([Parameter(Mandatory)]$Lock)
  if ($Lock.sdkToolBootstrap.schemaVersion -ne 1) {throw 'Flutter tools 补丁契约不受支持。'}
  foreach ($patch in $Lock.sdkToolBootstrap.patches) {
    Assert-ArtifactFile ([Kirakara.Artifacts.Security]::Child($script:ToolsRepository,$patch.path)) `
      ([pscustomobject]@{size=(Get-Item (Join-Path $script:ToolsRepository $patch.path)).Length;sha256=$patch.sha256})
  }
  # Tool snapshots/package_config contain absolute source paths. A moved or
  # independently cloned checkout gets its own lightweight tool cache, while
  # portable Engine ZIP identities remain independent of repository paths.
  $identity=[ordered]@{cacheVersion=1;repository=$script:ToolsRepository.ToUpperInvariant()
    frameworkRevision=$Lock.flutter.frameworkRevision
    engineRevision=$Lock.flutter.engineRevision;contract=$Lock.sdkToolBootstrap}
  return Get-ArtifactTextHash ($identity|ConvertTo-Json -Depth 15 -Compress)
}

function Enter-KirakaraToolsFileLock {
  param([Parameter(Mandatory)][string]$Path)
  [Kirakara.Artifacts.Security]::NoReparse($Path)
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
  $deadline=[DateTime]::UtcNow.AddSeconds(30)
  do {
    try {return [IO.File]::Open($Path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch [IO.IOException] {if ([DateTime]::UtcNow -ge $deadline) {throw '等待当前仓库 Flutter 工具缓存锁超时。'}; Start-Sleep -Milliseconds 100}
  } while ($true)
}

function Assert-KirakaraSdkToolsSource {
  param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)]$Lock)
  [Kirakara.Artifacts.Security]::NoReparse($Root)
  if (-not (Test-Path -LiteralPath (Join-Path $Root '.git') -PathType Container)) {throw '派生工具源码缺少来源索引。'}
  $tree=Invoke-CheckedNative git @('-C',$Root,'write-tree') '无法核对派生工具源码树。'
  if ($tree -cne $Lock.sdkToolBootstrap.patchedArchiveTree) {throw '派生工具源码索引与锁定树不匹配；不会覆盖或继续。'}
  Invoke-CheckedNative git @('-C',$Root,'diff-files','--quiet') '派生工具源码有本地修改；不会覆盖。' | Out-Null
}

function Initialize-KirakaraSdkToolsSource {
  param([Parameter(Mandatory)]$Layout,[Parameter(Mandatory)]$Lock,[Parameter(Mandatory)][string]$Root)
  [Kirakara.Artifacts.Security]::NoReparse($Root)
  if (Test-Path -LiteralPath $Root) {Assert-KirakaraSdkToolsSource $Root $Lock;return}
  $temporary=Join-Path $Layout.Temp ('sdk-tools-source-'+[guid]::NewGuid().ToString('N'))
  [Kirakara.Artifacts.Security]::NoReparse($temporary)
  $null=New-Item -ItemType Directory -Path $temporary
  try {
    $archive=Join-Path $temporary 'upstream.zip'
    Invoke-CheckedNative git @('-C',$Layout.FlutterSdk,'archive','--format=zip',"--output=$archive",'HEAD','LICENSE','packages/flutter_tools') '官方工具源码导出失败。' | Out-Host
    $source=Join-Path $temporary 'source'
    [Kirakara.Artifacts.Security]::ExtractZip($archive,$source,268435456,30000)
    Invoke-CheckedNative git @('-C',$source,'init','--quiet') | Out-Host
    Invoke-CheckedNative git @('-C',$source,'config','core.autocrlf','input') | Out-Host
    Invoke-CheckedNative git @('-C',$source,'config','core.safecrlf','false') | Out-Host
    Invoke-CheckedNative git @('-C',$source,'config','core.quotePath','false') | Out-Host
    Invoke-CheckedNative git @('-C',$source,'add','--all') | Out-Host
    Invoke-CheckedNative git @('-C',$source,'checkout-index','--force','--all') | Out-Host
    foreach ($patch in $Lock.sdkToolBootstrap.patches) {
      $path=[Kirakara.Artifacts.Security]::Child($script:ToolsRepository,$patch.path)
      Invoke-CheckedNative git @('-C',$source,'apply','--check',$path) 'Flutter tools 补丁不适用。' | Out-Host
      Invoke-CheckedNative git @('-C',$source,'apply',$path) 'Flutter tools 补丁应用失败。' | Out-Host
    }
    Invoke-CheckedNative git @('-C',$source,'add','--all') | Out-Host
    Assert-KirakaraSdkToolsSource $source $Lock
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $Root) -Force
    [IO.Directory]::Move($source,$Root)
  } finally {
    [Kirakara.Artifacts.Security]::NoReparse($temporary)
    if (Test-Path -LiteralPath $temporary) {Remove-Item -LiteralPath $temporary -Recurse -Force}
  }
}

function Ensure-KirakaraSdkTools {
  param([Parameter(Mandatory)]$Layout,[Parameter(Mandatory)]$Lock)
  Assert-RepositoryEngineWriteWorkspace $Layout
  $identity=Get-KirakaraSdkToolsIdentity $Lock
  $sdk=$Layout.FlutterSdk
  [Kirakara.Artifacts.Security]::NoReparse($sdk)
  if ((Get-GitHead $sdk) -cne $Lock.flutter.frameworkRevision) {throw 'Flutter SDK Framework revision 不匹配。'}
  if (@(Get-TrackedGitChanges $sdk).Count) {throw '官方仓库 SDK 有已跟踪修改；工具补丁只能用于独立派生副本。'}
  foreach ($record in $Lock.sdkToolBootstrap.upstreamFiles) {
    $path=[Kirakara.Artifacts.Security]::Child($sdk,$record.path)
    if ((Get-ArtifactTextHash ([IO.File]::ReadAllText($path).Replace("`r`n","`n"))) -cne $record.normalizedSha256) {
      throw 'Flutter 官方工具文件与锁不匹配；不能使用未核对的 launcher。'
    }
  }
  $tree=Invoke-CheckedNative git @('-C',$sdk,'rev-parse','HEAD:packages/flutter_tools')
  if ($tree -cne $Lock.sdkToolBootstrap.upstreamToolsTree) {throw 'Flutter tools 上游源码树不匹配。'}
  $compiler=[Kirakara.Artifacts.Security]::Child($sdk,$Lock.sdkToolBootstrap.dartCompiler.path)
  Assert-ArtifactFile $compiler $Lock.sdkToolBootstrap.dartCompiler
  $source=Join-Path $Layout.Root ('source/sdk-tools/'+$identity)
  $cache=Join-Path $Layout.Cache ('flutter-tools/'+$identity)
  $snapshot=Join-Path $cache 'flutter_tools.snapshot'
  $readyPath=Join-Path $cache 'ready.json'
  $config=Join-Path $source 'packages/flutter_tools/.dart_tool/package_config.json'
  foreach ($path in @($source,$cache,$snapshot,$readyPath,$config,(Join-Path $sdk 'bin/cache'),
      (Join-Path $sdk 'packages/flutter_tools/.dart_tool'))) {
    [Kirakara.Artifacts.Security]::NoReparse($path)
  }
  $marker='-DKIRAKARA_TOOL_PATCH='+$identity
  $previousArgs=$env:FLUTTER_TOOL_ARGS
  $previousRoot=$env:FLUTTER_ROOT
  $lockHandle=Enter-KirakaraToolsFileLock (Join-Path $Layout.Locks 'flutter-tools.lock')
  $success=$false
  try {
    Initialize-KirakaraSdkToolsSource $Layout $Lock $source
    $env:FLUTTER_ROOT=$sdk
    $env:FLUTTER_TOOL_ARGS=$marker
    $ready=$null
    if (Test-Path -LiteralPath $readyPath) {
      [Kirakara.Artifacts.Security]::NoReparse($readyPath)
      $ready=Get-Content -Raw -LiteralPath $readyPath -Encoding utf8|ConvertFrom-Json
      if ($ready.schemaVersion -ne 1 -or $ready.identityHash -cne $identity) {throw 'Flutter tools 缓存身份不匹配。'}
      Assert-ArtifactFile $snapshot $ready.snapshot
      Assert-ArtifactFile $config $ready.packageConfig
      foreach ($record in $ready.sourceFiles) {Assert-ArtifactFile ([Kirakara.Artifacts.Security]::Child($source,$record.path)) $record}
    } else {
      Write-Host '[Kirakara] 从官方 SDK 导出的派生源码编译轻量 Flutter 工具补丁（不编译 Engine）。'
      # Let the pinned official launcher create its own compile stamp. This also
      # regenerates copied SDK package paths inside this repository's PUB_CACHE.
      Invoke-CheckedNative (Join-Path $sdk 'bin/flutter.bat') @('--version') '官方工具缓存准备失败。' | Out-Host
      $compileStamp=[IO.File]::ReadAllText((Join-Path $sdk 'bin/cache/flutter_tools.stamp'))
      if (-not $compileStamp.Trim().EndsWith(":"+$marker+'"',[StringComparison]::Ordinal)) {throw '官方 launcher 的工具 stamp 格式与已锁定协议不符。'}
      Push-Location (Join-Path $source 'packages/flutter_tools')
      try {Invoke-CheckedNative $compiler @('pub','get','--suppress-analytics') '派生工具依赖准备失败。' | Out-Host}
      finally {Pop-Location}
      $files=@(Invoke-CheckedNative git @('-C',$source,'ls-files') | ForEach-Object {
        $file=[Kirakara.Artifacts.Security]::Child($source,$_)
        [ordered]@{path=$_;size=(Get-Item -LiteralPath $file).Length;sha256=Get-ArtifactHash $file}
      })
      $null=New-Item -ItemType Directory -Path $cache -Force
      $candidate=Join-Path $cache ('snapshot-'+[guid]::NewGuid().ToString('N')+'.tmp')
      try {
        Invoke-CheckedNative $compiler @($marker,'--verbosity=error',"--snapshot=$candidate",'--snapshot-kind=app-jit',
          "--packages=$config",(Join-Path $source 'packages/flutter_tools/bin/flutter_tools.dart'),'--version') '派生工具源码编译失败。' | Out-Host
        if (Test-Path -LiteralPath $snapshot) {
          [Kirakara.Artifacts.Security]::NoReparse($snapshot)
          [IO.File]::Move($snapshot,($snapshot+'.interrupted-'+[guid]::NewGuid().ToString('N')))
        }
        [IO.File]::Move($candidate,$snapshot)
      } finally {if (Test-Path -LiteralPath $candidate) {Remove-Item -LiteralPath $candidate -Force}}
      $ready=[ordered]@{schemaVersion=1;identityHash=$identity;compileStamp=$compileStamp
        snapshot=[ordered]@{size=(Get-Item $snapshot).Length;sha256=Get-ArtifactHash $snapshot}
        packageConfig=[ordered]@{size=(Get-Item $config).Length;sha256=Get-ArtifactHash $config}
        sourceFiles=$files}
      $candidate=Join-Path $cache ('ready-'+[guid]::NewGuid().ToString('N')+'.tmp')
      [IO.File]::WriteAllText($candidate,($ready|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
      [IO.File]::Move($candidate,$readyPath)
    }
    $sdkCache=Join-Path $sdk 'bin/cache'
    $sdkSnapshot=Join-Path $sdkCache 'flutter_tools.snapshot'
    $sdkStamp=Join-Path $sdkCache 'flutter_tools.stamp'
    $sdkLock=Enter-KirakaraToolsFileLock (Join-Path $sdkCache 'flutter.bat.lock')
    try {
      [Kirakara.Artifacts.Security]::NoReparse($sdkSnapshot)
      [Kirakara.Artifacts.Security]::NoReparse($sdkStamp)
      if ((Test-Path -LiteralPath $sdkSnapshot) -and (Get-ArtifactHash $sdkSnapshot) -ceq $ready.snapshot.sha256 -and
          (Test-Path -LiteralPath $sdkStamp) -and [IO.File]::ReadAllText($sdkStamp) -ceq $ready.compileStamp) {
        $success=$true
        return [pscustomobject]@{identityHash=$identity;source=$source;packageConfig=$config;snapshotSha256=$ready.snapshot.sha256;reused=$true}
      }
      # Replace a generated cache, never a DLL or SDK source. Retain the old
      # snapshot because an already-running Dart process may have it mapped.
      $candidate=Join-Path $sdkCache ('kirakara-tools-'+[guid]::NewGuid().ToString('N')+'.tmp')
      Copy-Item -LiteralPath $snapshot -Destination $candidate
      Assert-ArtifactFile $candidate $ready.snapshot
      if (Test-Path -LiteralPath $sdkSnapshot) {[IO.File]::Move($sdkSnapshot,($sdkSnapshot+'.kirakara-old-'+[guid]::NewGuid().ToString('N')))}
      [IO.File]::Move($candidate,$sdkSnapshot)
      $candidate=Join-Path $sdkCache ('kirakara-stamp-'+[guid]::NewGuid().ToString('N')+'.tmp')
      [IO.File]::WriteAllText($candidate,$ready.compileStamp,[Text.UTF8Encoding]::new($false))
      [IO.File]::Move($candidate,$sdkStamp,$true)
      Assert-ArtifactFile $sdkSnapshot $ready.snapshot
    } finally {$sdkLock.Dispose()}
    $success=$true
    return [pscustomobject]@{identityHash=$identity;source=$source;packageConfig=$config;snapshotSha256=$ready.snapshot.sha256;reused=$false}
  } finally {
    $lockHandle.Dispose()
    if (-not $success) {$env:FLUTTER_TOOL_ARGS=$previousArgs;$env:FLUTTER_ROOT=$previousRoot}
  }
}

Export-ModuleMember -Function @('Get-KirakaraSdkToolsIdentity','Ensure-KirakaraSdkTools')
