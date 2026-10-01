Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'engine/scripts/artifact_package.psm1') -DisableNameChecking

function Get-HandwritingIdentity {
  $lock = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'third_party/data.lock.json') | ConvertFrom-Json
  $data = $lock.zinniaTomoe
  if ($lock.schemaVersion -ne 1 -or $data.license -cne 'LGPL-2.1' -or -not $data.reproductionVerified) {
    throw '手写模型的来源、许可证或精确复现契约尚未通过。'
  }
  $names = @($data.models | ForEach-Object path)
  if ($names.Count -ne 2 -or $names -cnotcontains 'handwriting-ja.model' -or
      $names -cnotcontains 'handwriting-zh_CN.model') { throw '必须同时保留中文和日文手写模型。' }
  [Kirakara.Artifacts.Security]::RelativePath([string]$data.sourceRevision) | Out-Null
  foreach ($hash in @($data.sourceSha256,$data.sourceLicenseSha256) + @($data.models | ForEach-Object { $_.sha256; $_.sourceSha256 })) {
    if ([string]$hash -notmatch '^[A-Fa-f0-9]{64}$') { throw '模型来源契约缺少有效哈希。' }
  }
  $identity = [ordered]@{ packageFormatVersion = 1; kind = 'handwriting'; license = $data.license
    sourceRevision = $data.sourceRevision; sourceUrl = $data.sourceUrl; sourceSha256 = $data.sourceSha256; sourceSize = $data.sourceSize
    sourceLicensePath = $data.sourceLicensePath; sourceLicenseSha256 = $data.sourceLicenseSha256
    converterRevision = $data.converterRevision; converterArguments = @($data.converterArguments)
    models = @($data.models | ForEach-Object { [ordered]@{path=$_.path;size=$_.size;sha256=$_.sha256
      sourcePath=$_.sourcePath;sourceSha256=$_.sourceSha256} }) }
  return [pscustomobject]@{ value = Get-ArtifactTextHash ($identity | ConvertTo-Json -Depth 12 -Compress)
    identity = $identity; data = $data }
}

function Get-HandwritingEntry {
  param([string]$LockPath)
  if ([string]::IsNullOrWhiteSpace($LockPath)) { $LockPath = $env:KIRAKARA_DATA_PACKAGE_LOCK }
  if ([string]::IsNullOrWhiteSpace($LockPath)) { $LockPath = Join-Path $script:RepositoryRoot 'third_party/data.lock.json' }
  [Kirakara.Artifacts.Security]::NoReparse($LockPath)
  $lock = Get-Content -Raw -LiteralPath $LockPath | ConvertFrom-Json
  if ($lock.schemaVersion -ne 1) { throw '第三方数据包锁格式不受支持。' }
  $entry = $lock.zinniaTomoe.binaryPackage
  $expected = Get-HandwritingIdentity
  if ($null -eq $entry) {
    throw '维护者尚未配置手写数据包下载。请使用审核后的本地模型 ZIP 与候选锁；不会禁用手写，也不会自动编译原生依赖。'
  }
  if ($entry.identityHash -cne $expected.value) { throw '手写数据包身份与当前模型来源契约不匹配。' }
  return [pscustomobject]@{ entry = $entry; expected = $expected }
}

function Assert-HandwritingContents {
  param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)]$Manifest,[Parameter(Mandatory)]$Expected)
  if ((Get-ArtifactTextHash ($Manifest.identity | ConvertTo-Json -Depth 12 -Compress)) -cne $Expected.value) {
    throw '手写包的模型、来源或许可证身份错误。'
  }
  $data = $Expected.data
  $required = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($model in $data.models) {
    $path = 'models/' + $model.path
    $null = $required.Add($path)
    Assert-ArtifactFile ([Kirakara.Artifacts.Security]::Child($Root,$path)) $model
    $text = 'sources/' + $model.sourcePath
    $null = $required.Add($text)
    if ((Get-ArtifactHash ([Kirakara.Artifacts.Security]::Child($Root,$text))) -ine $model.sourceSha256) {
      throw '模型对应文本源码哈希不匹配。'
    }
  }
  $archive = 'sources/' + $data.sourceRevision + '.tar.bz2'
  $null = $required.Add($archive)
  Assert-ArtifactFile ([Kirakara.Artifacts.Security]::Child($Root,$archive)) @{size=$data.sourceSize;sha256=$data.sourceSha256}
  $license = 'licenses/LGPL-2.1.txt'
  $null = $required.Add($license)
  if ((Get-ArtifactHash ([Kirakara.Artifacts.Security]::Child($Root,$license))) -ine $data.sourceLicenseSha256) {
    throw '手写包未保留准确的上游 LGPL-2.1 全文。'
  }
  $null = $required.Add('SOURCES.json')
  $sources = Get-Content -Raw -LiteralPath (Join-Path $Root 'SOURCES.json') | ConvertFrom-Json
  if ((Get-ArtifactTextHash ($sources | ConvertTo-Json -Depth 12 -Compress)) -cne $Expected.value) {
    throw '手写包源码清单与锁定输入不匹配。'
  }
  if (@($Manifest.files).Count -ne $required.Count) { throw '手写包包含缺失或未经批准的文件。' }
  foreach ($record in $Manifest.files) {
    if (-not $required.Contains([string]$record.path)) { throw '手写包包含非模型/来源/许可文件。' }
  }
}

function Get-HandwritingSelectedEntry {
  param([Parameter(Mandatory)]$Expected)
  $path = Join-Path $script:RepositoryRoot '.kfe/state/handwriting-selection.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return $null
  }
  [Kirakara.Artifacts.Security]::NoReparse($path)
  $selection = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
  $schemaVersion = $selection.PSObject.Properties['schemaVersion']
  if ($null -eq $schemaVersion -or $schemaVersion.Value -ne 1 -or
      $selection.kind -cne 'handwriting-data' -or
      $selection.identityHash -cne $Expected.value -or
      $null -eq $selection.entry -or
      $selection.entry.identityHash -cne $Expected.value) {
    throw '仓库内手写数据包选择已经过期；请重新执行 data prepare handwriting。'
  }
  return $selection.entry
}

function Write-HandwritingSelectedEntry {
  param([Parameter(Mandatory)]$Expected,[Parameter(Mandatory)]$Entry)
  if ($Entry.identityHash -cne $Expected.value) {
    throw '手写数据包选择缺少匹配的可信包记录。'
  }
  $state = Join-Path $script:RepositoryRoot '.kfe/state'
  $null = New-Item -ItemType Directory -Path $state -Force
  $path = Join-Path $state 'handwriting-selection.json'
  [Kirakara.Artifacts.Security]::NoReparse($path)
  $record = [ordered]@{
    schemaVersion = 1
    kind = 'handwriting-data'
    identityHash = $Expected.value
    entry = [ordered]@{
      identityHash = [string]$Entry.identityHash
      url = $null
      size = [long]$Entry.size
      sha256 = [string]$Entry.sha256
      manifestSha256 = [string]$Entry.manifestSha256
    }
  }
  $temporary = Join-Path $state (
    '.handwriting-selection-' + [Guid]::NewGuid().ToString('N') + '.tmp')
  try {
    [IO.File]::WriteAllText(
      $temporary,
      ($record | ConvertTo-Json -Depth 5),
      [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $path -Force
  } finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
      Remove-Item -LiteralPath $temporary -Force
    }
  }
}

function Ensure-HandwritingPackage {
  param([string]$Package,[string]$LockPath)
  $expected = Get-HandwritingIdentity
  $processLock = [Environment]::GetEnvironmentVariable(
    'KIRAKARA_DATA_PACKAGE_LOCK', 'Process')
  $storedEntry = $null
  if ([string]::IsNullOrWhiteSpace($Package) -and
      [string]::IsNullOrWhiteSpace($LockPath) -and
      [string]::IsNullOrWhiteSpace($processLock)) {
    $storedEntry = Get-HandwritingSelectedEntry -Expected $expected
  }
  if ($null -ne $storedEntry) {
    $selection = [pscustomobject]@{ entry = $storedEntry; expected = $expected }
  } else {
    $selection = Get-HandwritingEntry $LockPath
  }
  $workspace = Join-Path $script:RepositoryRoot '.kfe'
  $destination = Join-Path $workspace ('prebuilt/handwriting/' + $expected.value)
  $dataModule = $ExecutionContext.SessionState.Module
  $verify = {
    param($root,$manifest)
    & $dataModule { param($root,$manifest,$expected) Assert-HandwritingContents $root $manifest $expected } $root $manifest $expected
  }.GetNewClosure()
  $root = Install-ArtifactPackage -Workspace $workspace -Destination $destination -Kind handwriting-data `
    -IdentityHash $expected.value -Entry $selection.entry -Verify $verify -LocalArchive $Package -MaxExpandedBytes 268435456
  if ($null -eq $storedEntry) {
    Write-HandwritingSelectedEntry -Expected $expected -Entry $selection.entry
  }
  return [pscustomobject]@{root=$root;models=Join-Path $root 'models';identityHash=$expected.value}
}

function Invoke-KirakaraDataCommand {
  param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments)
  if ($Arguments.Count -ge 2 -and $Arguments[1] -eq 'rime') {
    Import-Module (Join-Path $PSScriptRoot 'rime_package.psm1') -DisableNameChecking
    return Invoke-RimeDataCommand -Arguments $Arguments
  }
  if ($Arguments.Count -eq 0 -or $Arguments[0] -eq 'status') {
    $expected = Get-HandwritingIdentity
    $destination = Join-Path $script:RepositoryRoot ('.kfe/prebuilt/handwriting/' + $expected.value)
    [ordered]@{kind='handwriting';identityHash=$expected.value;root=$destination
      readyStampExists=Test-Path -LiteralPath (Join-Path $destination 'ready.json')
      reproductionVerified=$true;formalReleasePublished=$false} | ConvertTo-Json | Write-Host
    return 0
  }
  if ($Arguments[0] -ne 'prepare' -or $Arguments.Count -lt 2 -or $Arguments[1] -ne 'handwriting') {
    throw '数据命令：data status [rime]，或 data prepare handwriting/rime [--package ZIP] [--lock 候选锁]。'
  }
  $package = $null; $lockPath = $null
  for ($index=2; $index -lt $Arguments.Count; $index++) {
    $option = $Arguments[$index]
    if ($option -notin @('--package','--lock') -or $index+1 -ge $Arguments.Count) { throw '未知或缺少路径的数据准备参数。' }
    $index++
    if ($option -eq '--package') { $package=$Arguments[$index] } else { $lockPath=$Arguments[$index] }
  }
  $null = Ensure-HandwritingPackage -Package $package -LockPath $lockPath
  Write-Host '[Kirakara] 中日手写模型及对应源码、许可证已校验并准备；没有修改系统。'
  return 0
}

Export-ModuleMember -Function @('Get-HandwritingIdentity','Get-HandwritingEntry','Assert-HandwritingContents',
  'Ensure-HandwritingPackage','Invoke-KirakaraDataCommand')
