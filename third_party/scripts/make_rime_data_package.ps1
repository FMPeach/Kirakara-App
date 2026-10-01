#Requires -Version 7.2
[CmdletBinding()]
param([string]$OutputDirectory,[switch]$Offline,[string]$DataSourceRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'rime_package.psm1') -DisableNameChecking
$expected=Get-RimeDataIdentity
if ([string]::IsNullOrWhiteSpace($DataSourceRoot)) { $DataSourceRoot=Join-Path $repo '.kfe/source/data' }
$DataSourceRoot=[IO.Path]::GetFullPath($DataSourceRoot)
$rimeLicense=@($expected.data.licenseDocuments | Where-Object path -CEQ 'LGPL-3.0.txt')[0]
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory=Join-Path $repo 'build/packages/rime-data' }
$output=[IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Rime 候选包必须生成在当前仓库。' }
[Kirakara.Artifacts.Security]::NoReparse($output)
$null=New-Item -ItemType Directory -Path $output -Force
$archive=Join-Path $output 'kirakara-rime-data-v1.zip'
$candidate=Join-Path $output 'rime-data.candidate.lock.json'
if ((Test-Path -LiteralPath $archive) -or (Test-Path -LiteralPath $candidate)) { throw '候选文件已存在；不覆盖，请指定新目录。' }
$prepareArguments=@{Offline=$Offline;SourceRoot=$DataSourceRoot}
& (Join-Path $PSScriptRoot 'prepare_rime_data_sources.ps1') @prepareArguments
$scratch=Join-Path $repo ('.kfe/tmp/pack-rime-data-'+[guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null=New-Item -ItemType Directory -Path $scratch
function Write-PackageBlob {
  param([string]$Path,[byte[]]$Bytes)
  $to=[Kirakara.Artifacts.Security]::Child($scratch,$Path)
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force
  [IO.File]::WriteAllBytes($to,$Bytes)
}
try {
  foreach ($source in $expected.data.sources) {
    $name=([uri]$source.repository).Segments[-1] -replace '\.git$',''
    $sourceRoot=Join-Path $DataSourceRoot $name
    if ((& git -C $sourceRoot remote get-url origin) -cne $source.repository) { throw 'Rime 数据来源 remote 不匹配。' }
    $bytes=Read-RimeSourceBlob $sourceRoot $source.revision $source.path
    if ($bytes.Length -ne $source.size -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $source.sha256) {
      throw "Rime 原始数据哈希不匹配：$($source.path)"
    }
    $license=Read-RimeSourceBlob $sourceRoot $source.revision $source.licensePath
    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($license)) -cne $source.licenseSha256 -or
        $source.licenseSha256 -cne $rimeLicense.sha256) { throw 'Rime 对应原始许可不匹配。' }
    Write-PackageBlob ('sources/rime/'+$source.path) $bytes
    Write-PackageBlob ('data/'+$source.path) $bytes
  }
  $patch=[Kirakara.Artifacts.Security]::Child($repo,[string]$expected.data.runtimeModification.patch)
  $relative=[IO.Path]::GetRelativePath($repo,(Join-Path $scratch 'data')).Replace('\','/')
  Push-Location $repo
  try {
    & git apply --check --directory=$relative $patch
    if ($LASTEXITCODE) { throw '独立 Rime 补丁不适用；未生成候选包。' }
    & git apply --directory=$relative $patch
    if ($LASTEXITCODE) { throw '独立 Rime 补丁应用失败。' }
  } finally { Pop-Location }
  Assert-ArtifactFile (Join-Path $scratch 'data/default.yaml') $expected.data.runtimeModification.resultFile
  $openccRoot=Join-Path $repo '.kfe/source/librime/deps/opencc'
  if ((& git -C $openccRoot rev-parse HEAD) -cne $expected.opencc.revision) { throw 'OpenCC 固定源码版本不匹配。' }
  foreach ($record in $expected.opencc.runtimeFiles) {
    $from=[Kirakara.Artifacts.Security]::Child((Join-Path $repo '.kfe/native/librime-deps/share/opencc'),[string]$record.path)
    Assert-ArtifactFile $from $record
    Write-PackageBlob ('data/opencc/'+$record.path) ([IO.File]::ReadAllBytes($from))
  }
  # Export only the exact corresponding data sources, recipes and attribution.
  # No complete native source trees, build caches or binaries enter the ZIP.
  $sourceTar=Join-Path $scratch ('sources/'+$expected.opencc.sourceArchive.path)
  $sourcePaths=@($expected.opencc.sourceArchive.paths)
  & git -C $openccRoot archive --format=tar "--output=$sourceTar" $expected.opencc.revision @sourcePaths
  if ($LASTEXITCODE) { throw 'OpenCC 对应数据源码导出失败。' }
  Assert-ArtifactFile $sourceTar $expected.opencc.sourceArchive
  Write-PackageBlob 'licenses/OpenCC-Apache-2.0.txt' (Read-RimeSourceBlob $openccRoot $expected.opencc.revision 'LICENSE')
  Write-PackageBlob 'licenses/OpenCC-AUTHORS.txt' (Read-RimeSourceBlob $openccRoot $expected.opencc.revision 'AUTHORS')
  foreach ($record in $expected.data.licenseDocuments) {
    $from=[Kirakara.Artifacts.Security]::Child($repo,[string]$record.sourcePath)
    if (-not (Test-Path -LiteralPath $from)) {
      throw '来源准备后许可全文仍缺失；没有生成候选包。'
    }
    Assert-ArtifactFile $from $record
    Write-PackageBlob ('licenses/'+$record.path) ([IO.File]::ReadAllBytes($from))
  }
  Write-PackageBlob 'modifications/0002-rime-exclude-unused-cangjie.patch' ([IO.File]::ReadAllBytes($patch))
  Write-PackageBlob 'SOURCES.json' ([Text.Encoding]::UTF8.GetBytes(($expected.identity | ConvertTo-Json -Depth 16)))
  $files=@(Get-ChildItem -LiteralPath $scratch -Recurse -File | Sort-Object FullName | ForEach-Object {
    [ordered]@{path=[IO.Path]::GetRelativePath($scratch,$_.FullName).Replace('\','/');size=$_.Length;sha256=Get-ArtifactHash $_.FullName}
  })
  $manifest=[ordered]@{schemaVersion=1;kind='rime-data';identityHash=$expected.value;identity=$expected.identity;files=$files}
  $manifestPath=Join-Path $scratch 'manifest.json'
  [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($false))
  Assert-RimeDataContents $scratch $manifest $expected
  [IO.Compression.ZipFile]::CreateFromDirectory($scratch,$archive,[IO.Compression.CompressionLevel]::Optimal,$false)
  $entry=[ordered]@{identityHash=$expected.value;url=$null;size=(Get-Item -LiteralPath $archive).Length
    sha256=Get-ArtifactHash $archive;manifestSha256=Get-ArtifactHash $manifestPath}
  [ordered]@{schemaVersion=1;rime=[ordered]@{dataPackage=$entry}} | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $candidate -Encoding utf8
  Write-Host "Rime 候选数据包：$archive"
  Write-Host "候选锁：$candidate"
  Write-Host '保留原始 schema/词典、配置补丁、OpenCC 对应数据源码与许可；没有发布 Release。'
} finally {
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  if (-not $scratch.StartsWith($repo+'\.kfe\tmp\pack-rime-data-',[StringComparison]::OrdinalIgnoreCase)) { throw '清理目标越界。' }
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
