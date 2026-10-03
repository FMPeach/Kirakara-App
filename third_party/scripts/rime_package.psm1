Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'engine/scripts/artifact_package.psm1') -Force -DisableNameChecking

function Get-RimeDataIdentity {
  $lock = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'third_party/data.lock.json') -Encoding utf8 |
    ConvertFrom-Json
  $data = $lock.rime
  if ($lock.schemaVersion -ne 1 -or -not $data.sourceInventoryVerified -or @($data.sources).Count -ne 20) {
    throw 'Rime 必要数据的精确来源清单尚未通过。'
  }
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($source in $data.sources) {
    [Kirakara.Artifacts.Security]::RelativePath([string]$source.path) | Out-Null
    if (-not $seen.Add([string]$source.path) -or $source.path -match '[/\\]|cangjie5' -or
        $source.license -cne 'LGPL-3.0' -or $source.revision -cnotmatch '^[0-9a-f]{40}$' -or
        $source.repository -cnotmatch '^https://github\.com/rime/rime-[a-z-]+\.git$') {
      throw 'Rime 数据来源、许可或路径不符合当前必要集合。'
    }
    foreach ($hash in @($source.sha256,$source.licenseSha256)) {
      if ([string]$hash -cnotmatch '^[A-F0-9]{64}$') { throw 'Rime 来源哈希无效。' }
    }
  }
  $patch = [Kirakara.Artifacts.Security]::Child($script:RepositoryRoot,[string]$data.runtimeModification.patch)
  if ((Get-ArtifactHash $patch) -cne $data.runtimeModification.sha256 -or
      $data.runtimeModification.resultFile.path -cne 'default.yaml') { throw 'Rime 独立配置补丁契约不匹配。' }
  $openccPath = [Kirakara.Artifacts.Security]::Child($script:RepositoryRoot,[string]$data.openccLock)
  $opencc = Get-Content -Raw -LiteralPath $openccPath -Encoding utf8 |
    ConvertFrom-Json
  $native = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'native/native.lock.json') -Encoding utf8 |
    ConvertFrom-Json
  if ($opencc.schemaVersion -ne 1 -or $opencc.license -cne 'Apache-2.0' -or
      $opencc.revision -cne $native.librime.submodules.'deps/opencc' -or @($opencc.runtimeFiles).Count -ne 30) {
    throw 'OpenCC 数据与固定 librime 构建来源不匹配。'
  }
  $openccNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($record in $opencc.runtimeFiles) {
    [Kirakara.Artifacts.Security]::RelativePath([string]$record.path) | Out-Null
    if (-not $openccNames.Add([string]$record.path) -or $record.path -notmatch '^[A-Za-z0-9]+\.(json|ocd2)$' -or
        $record.sha256 -cnotmatch '^[A-F0-9]{64}$') { throw 'OpenCC 运行数据清单无效。' }
  }
  $licenseNames = @($data.licenseDocuments | ForEach-Object path)
  if ($licenseNames.Count -ne 3 -or $licenseNames -cnotcontains 'LGPL-3.0.txt' -or
      $licenseNames -cnotcontains 'GPL-3.0-LGPL-supplement.txt' -or $licenseNames -cnotcontains 'CC-BY-SA-3.0.txt') {
    throw 'Rime/引用数据的原始许可全文不完整。'
  }
  foreach ($record in $data.licenseDocuments) {
    [Kirakara.Artifacts.Security]::RelativePath([string]$record.path) | Out-Null
    if ($record.path -match '[/\\]' -or $record.sha256 -cnotmatch '^[A-F0-9]{64}$') { throw 'Rime 许可清单无效。' }
  }
  # Audit/release flags and configured download URLs are not build inputs.
  # Keep raw source copyrights, the one runtime modification and OpenCC apart.
  $identity = [ordered]@{packageFormatVersion=1;kind='rime-data';sources=@($data.sources)
    excludedSchemas=@($data.excludedSchemas);runtimeModification=$data.runtimeModification
    licenseDocuments=@($data.licenseDocuments);opencc=$opencc}
  return [pscustomobject]@{value=Get-ArtifactTextHash ($identity | ConvertTo-Json -Depth 16 -Compress)
    identity=$identity;data=$data;opencc=$opencc}
}

function Get-RimeDataEntry {
  param([string]$LockPath)
  if ([string]::IsNullOrWhiteSpace($LockPath)) { $LockPath=$env:KIRAKARA_RIME_DATA_LOCK }
  if ([string]::IsNullOrWhiteSpace($LockPath)) { $LockPath=Join-Path $script:RepositoryRoot 'third_party/data.lock.json' }
  [Kirakara.Artifacts.Security]::NoReparse($LockPath)
  $lock = Get-Content -Raw -LiteralPath $LockPath -Encoding utf8 |
    ConvertFrom-Json
  if ($lock.schemaVersion -ne 1) { throw 'Rime 数据包锁格式不受支持。' }
  $entry = $lock.rime.dataPackage
  $expected = Get-RimeDataIdentity
  if ($null -eq $entry) {
    throw '维护者尚未配置 Rime 数据包下载。请使用审核后的本地 ZIP 与候选锁；不会禁用拼音或自动开始原生源码构建。'
  }
  if ($entry.identityHash -cne $expected.value) { throw 'Rime 数据包身份与当前来源、补丁或 OpenCC 版本不匹配。' }
  return [pscustomobject]@{entry=$entry;expected=$expected}
}

function Assert-RimeDataContents {
  param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)]$Manifest,[Parameter(Mandatory)]$Expected)
  if ((Get-ArtifactTextHash ($Manifest.identity | ConvertTo-Json -Depth 16 -Compress)) -cne $Expected.value) {
    throw 'Rime 包的来源或修改身份错误。'
  }
  $required = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($source in $Expected.data.sources) {
    $rawPath = 'sources/rime/'+$source.path
    $runtimePath = 'data/'+$source.path
    $null=$required.Add($rawPath); $null=$required.Add($runtimePath)
    Assert-ArtifactFile ([Kirakara.Artifacts.Security]::Child($Root,$rawPath)) $source
    $runtime = if ($source.path -ceq $Expected.data.runtimeModification.resultFile.path) {
      $Expected.data.runtimeModification.resultFile
    } else { $source }
    Assert-ArtifactFile ([Kirakara.Artifacts.Security]::Child($Root,$runtimePath)) $runtime
  }
  foreach ($record in $Expected.opencc.runtimeFiles) {
    $path='data/opencc/'+$record.path; $null=$required.Add($path)
    Assert-ArtifactFile ([Kirakara.Artifacts.Security]::Child($Root,$path)) $record
  }
  $archive='sources/'+$Expected.opencc.sourceArchive.path; $null=$required.Add($archive)
  Assert-ArtifactFile ([Kirakara.Artifacts.Security]::Child($Root,$archive)) $Expected.opencc.sourceArchive
  foreach ($record in $Expected.data.licenseDocuments) {
    $path='licenses/'+$record.path; $null=$required.Add($path)
    Assert-ArtifactFile ([Kirakara.Artifacts.Security]::Child($Root,$path)) $record
  }
  foreach ($record in @(@{path='licenses/OpenCC-Apache-2.0.txt';sha256=$Expected.opencc.licenseSha256},
      @{path='licenses/OpenCC-AUTHORS.txt';sha256=$Expected.opencc.authorsSha256},
      @{path='modifications/0002-rime-exclude-unused-cangjie.patch';sha256=$Expected.data.runtimeModification.sha256})) {
    $null=$required.Add($record.path)
    $path=[Kirakara.Artifacts.Security]::Child($Root,$record.path)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-ArtifactHash $path) -cne $record.sha256) {
      throw 'Rime 包缺少对应修改或 OpenCC 原始许可/署名。'
    }
  }
  $null=$required.Add('SOURCES.json')
  $sources=Get-Content -Raw -LiteralPath (Join-Path $Root 'SOURCES.json') -Encoding utf8|ConvertFrom-Json
  if ((Get-ArtifactTextHash ($sources | ConvertTo-Json -Depth 16 -Compress)) -cne $Expected.value) {
    throw 'Rime 数据包来源清单不匹配。'
  }
  if (@($Manifest.files).Count -ne $required.Count) { throw 'Rime 数据包包含缺失或未经批准的文件。' }
  foreach ($record in $Manifest.files) {
    if (-not $required.Contains([string]$record.path)) { throw 'Rime 数据包包含非必要数据/源码/许可文件。' }
  }
}

function Get-RimeDataSelectedEntry {
  param([Parameter(Mandatory)]$Expected)
  $path=Join-Path $script:RepositoryRoot '.kfe/state/rime-data-selection.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  [Kirakara.Artifacts.Security]::NoReparse($path)
  $selection=Get-Content -Raw -LiteralPath $path -Encoding utf8|ConvertFrom-Json
  $schemaVersion=$selection.PSObject.Properties['schemaVersion']
  if ($null -eq $schemaVersion -or $schemaVersion.Value -ne 1 -or
      $selection.kind -cne 'rime-data' -or
      $selection.identityHash -cne $Expected.value -or $null -eq $selection.entry -or
      $selection.entry.identityHash -cne $Expected.value) {
    throw '仓库内 Rime 数据包选择已经过期；请重新执行 data prepare rime。'
  }
  return $selection.entry
}

function Write-RimeDataSelectedEntry {
  param([Parameter(Mandatory)]$Expected,[Parameter(Mandatory)]$Entry)
  if ($Entry.identityHash -cne $Expected.value) {
    throw 'Rime 数据包选择缺少匹配的可信包记录。'
  }
  $state=Join-Path $script:RepositoryRoot '.kfe/state'
  $null=New-Item -ItemType Directory -Path $state -Force
  $path=Join-Path $state 'rime-data-selection.json'
  [Kirakara.Artifacts.Security]::NoReparse($path)
  $record=[ordered]@{schemaVersion=1;kind='rime-data';identityHash=$Expected.value
    entry=[ordered]@{identityHash=[string]$Entry.identityHash;url=$null;size=[long]$Entry.size
      sha256=[string]$Entry.sha256;manifestSha256=[string]$Entry.manifestSha256}}
  $temporary=Join-Path $state ('.rime-data-selection-'+[Guid]::NewGuid().ToString('N')+'.tmp')
  try {
    [IO.File]::WriteAllText($temporary,($record|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $path -Force
  } finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
      Remove-Item -LiteralPath $temporary -Force
    }
  }
}

function Ensure-RimeDataPackage {
  param([string]$Package,[string]$LockPath)
  $expected=Get-RimeDataIdentity
  $processLock=[Environment]::GetEnvironmentVariable('KIRAKARA_RIME_DATA_LOCK','Process')
  $storedEntry=$null
  if ([string]::IsNullOrWhiteSpace($Package) -and [string]::IsNullOrWhiteSpace($LockPath) -and
      [string]::IsNullOrWhiteSpace($processLock)) {
    $storedEntry=Get-RimeDataSelectedEntry -Expected $expected
  }
  if ($null -ne $storedEntry) {
    $selection=[pscustomobject]@{entry=$storedEntry;expected=$expected}
  } else {
    $selection=Get-RimeDataEntry $LockPath
  }
  $workspace=Join-Path $script:RepositoryRoot '.kfe'
  $destination=Join-Path $workspace ('prebuilt/rime-data/'+$expected.value)
  $dataModule=$ExecutionContext.SessionState.Module
  $verify={
    param($root,$manifest)
    & $dataModule {param($root,$manifest,$expected) Assert-RimeDataContents $root $manifest $expected} $root $manifest $expected
  }.GetNewClosure()
  $root=Install-ArtifactPackage -Workspace $workspace -Destination $destination -Kind rime-data `
    -IdentityHash $expected.value -Entry $selection.entry -Verify $verify -LocalArchive $Package -MaxExpandedBytes 67108864
  if ($null -eq $storedEntry) {
    Write-RimeDataSelectedEntry -Expected $expected -Entry $selection.entry
  }
  return [pscustomobject]@{root=$root;data=Join-Path $root 'data';identityHash=$expected.value}
}

function Read-RimeSourceBlob {
  param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$Revision,[Parameter(Mandatory)][string]$Path,
    [switch]$NoLazyFetch)
  [Kirakara.Artifacts.Security]::NoReparse($Repository)
  [Kirakara.Artifacts.Security]::RelativePath($Path) | Out-Null
  if ($Revision -cnotmatch '^[0-9a-f]{40}$') { throw 'Rime 来源 revision 无效。' }
  $start=[Diagnostics.ProcessStartInfo]::new('git')
  $start.UseShellExecute=$false; $start.CreateNoWindow=$true
  $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
  $arguments = @()
  if ($NoLazyFetch) { $arguments += '--no-lazy-fetch' }
  $arguments += @('-C',$Repository,'show',"${Revision}:$Path")
  Set-KirakaraProcessArguments -StartInfo $start -Arguments $arguments
  $process=[Diagnostics.Process]::Start($start)
  $memory=[IO.MemoryStream]::new()
  try {
    $errorTask=$process.StandardError.ReadToEndAsync()
    $process.StandardOutput.BaseStream.CopyTo($memory)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0 -or $memory.Length -gt 16777216) { throw 'Rime 固定来源对象不存在或过大。' }
    return ,$memory.ToArray()
  } finally { $memory.Dispose(); $process.Dispose() }
}

function Invoke-RimeDataCommand {
  param([Parameter(Mandatory)][string[]]$Arguments)
  if ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'status' -and $Arguments[1] -eq 'rime') {
    $expected=Get-RimeDataIdentity
    $destination=Join-Path $script:RepositoryRoot ('.kfe/prebuilt/rime-data/'+$expected.value)
    [ordered]@{kind='rime';identityHash=$expected.value;root=$destination
      readyStampExists=Test-Path -LiteralPath (Join-Path $destination 'ready.json')
      sourceInventoryVerified=$true;formalReleasePublished=$false} | ConvertTo-Json | Write-Host
    return 0
  }
  if ($Arguments.Count -lt 2 -or $Arguments[0] -ne 'prepare' -or $Arguments[1] -ne 'rime') {
    throw 'Rime 数据命令：data status rime，或 data prepare rime [--package ZIP] [--lock 候选锁]。'
  }
  $package=$null; $lockPath=$null
  for ($index=2;$index -lt $Arguments.Count;$index++) {
    $option=$Arguments[$index]
    if ($option -notin @('--package','--lock') -or $index+1 -ge $Arguments.Count) { throw '未知或缺少路径的 Rime 准备参数。' }
    $index++
    if ($option -eq '--package') { $package=$Arguments[$index] } else { $lockPath=$Arguments[$index] }
  }
  $null=Ensure-RimeDataPackage -Package $package -LockPath $lockPath
  Write-Host '[Kirakara] Rime schema/词典、OpenCC 数据、对应源码及许可已校验并准备；没有修改系统。'
  return 0
}

Export-ModuleMember -Function @('Get-RimeDataIdentity','Get-RimeDataEntry','Assert-RimeDataContents',
  'Ensure-RimeDataPackage','Read-RimeSourceBlob','Invoke-RimeDataCommand')
