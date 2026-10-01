#Requires -Version 7.2
[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'handwriting_package.psm1') -DisableNameChecking
$expected = Get-HandwritingIdentity
$data = $expected.data
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory=Join-Path $repo 'build/packages/handwriting' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '候选包必须生成在当前仓库。' }
[Kirakara.Artifacts.Security]::NoReparse($output)
$null = New-Item -ItemType Directory -Path $output -Force
$archive = Join-Path $output 'kirakara-handwriting-v1.zip'
$candidate = Join-Path $output 'handwriting.candidate.lock.json'
if ((Test-Path -LiteralPath $archive) -or (Test-Path -LiteralPath $candidate)) { throw '候选文件已存在，不覆盖。请选择新输出目录。' }
$scratch = Join-Path $repo ('.kfe/tmp/pack-handwriting-'+[guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null = New-Item -ItemType Directory -Path $scratch
try {
  $null = New-Item -ItemType Directory -Path (Join-Path $scratch 'models'),(Join-Path $scratch 'sources'),(Join-Path $scratch 'licenses')
  foreach ($model in $data.models) {
    $from = [Kirakara.Artifacts.Security]::Child((Join-Path $repo '.kfe/native/models-check'),[string]$model.path)
    Assert-ArtifactFile $from $model
    Copy-Item -LiteralPath $from -Destination (Join-Path $scratch ('models/'+$model.path))
    $text = [Kirakara.Artifacts.Security]::Child((Join-Path $repo '.kfe/source/models'),[string]$model.sourcePath)
    if ((Get-ArtifactHash $text) -ine $model.sourceSha256) { throw '对应模型文本源码不匹配。' }
    $to = [Kirakara.Artifacts.Security]::Child($scratch,('sources/'+$model.sourcePath))
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force
    Copy-Item -LiteralPath $text -Destination $to
  }
  $sourceArchive = Join-Path $repo ('.kfe/downloads/'+$data.sourceRevision+'.tar.bz2')
  Assert-ArtifactFile $sourceArchive @{size=$data.sourceSize;sha256=$data.sourceSha256}
  Copy-Item -LiteralPath $sourceArchive -Destination (Join-Path $scratch ('sources/'+$data.sourceRevision+'.tar.bz2'))
  $license = [Kirakara.Artifacts.Security]::Child((Join-Path $repo '.kfe/source/models'),[string]$data.sourceLicensePath)
  if ((Get-ArtifactHash $license) -ine $data.sourceLicenseSha256) { throw '模型源包许可证不匹配。' }
  Copy-Item -LiteralPath $license -Destination (Join-Path $scratch 'licenses/LGPL-2.1.txt')
  [IO.File]::WriteAllText((Join-Path $scratch 'SOURCES.json'),($expected.identity|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
  $files = @(Get-ChildItem -LiteralPath $scratch -Recurse -File | Sort-Object FullName | ForEach-Object {
    [ordered]@{path=[IO.Path]::GetRelativePath($scratch,$_.FullName).Replace('\','/');size=$_.Length;sha256=Get-ArtifactHash $_.FullName}
  })
  $manifest = [ordered]@{schemaVersion=1;kind='handwriting-data';identityHash=$expected.value;identity=$expected.identity;files=$files}
  $manifestPath = Join-Path $scratch 'manifest.json'
  [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
  Assert-HandwritingContents $scratch $manifest $expected
  [IO.Compression.ZipFile]::CreateFromDirectory($scratch,$archive,[IO.Compression.CompressionLevel]::Optimal,$false)
  $entry = [ordered]@{identityHash=$expected.value;url=$null;size=(Get-Item -LiteralPath $archive).Length
    sha256=Get-ArtifactHash $archive;manifestSha256=Get-ArtifactHash $manifestPath}
  [ordered]@{schemaVersion=1;zinniaTomoe=[ordered]@{binaryPackage=$entry}} | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $candidate -Encoding utf8
  Write-Host "手写候选包：$archive"
  Write-Host "候选锁：$candidate"
  Write-Host '包内包含中日模型、精确文本源、官方原始源码包与 LGPL-2.1 全文；未配置正式下载或发布 Release。'
} finally {
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
