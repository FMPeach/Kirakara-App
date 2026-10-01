[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('debug','profile','release')][string]$Mode,
  [Parameter(Mandatory)][string]$SourceOutput,
  [string]$FlutterSdkRoot,
  [string]$OutputDirectory,
  [switch]$Symbols
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'artifact_package.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'prebuilt_engine.psm1') -Force -DisableNameChecking
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$lock = Get-Content -Raw -LiteralPath (Join-Path $repo 'engine/engine.lock.json') | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($FlutterSdkRoot)) { $FlutterSdkRoot = Join-Path $repo '.kfe/sdk' }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $repo 'build/packages' }
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $outputRoot.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {
  throw '候选包必须生成在当前仓库内，不修改系统或其它项目。'
}
[Kirakara.Artifacts.Security]::NoReparse($outputRoot)
$null = New-Item -ItemType Directory -Path $outputRoot -Force
$identity = Get-PrebuiltEngineIdentity $lock $Mode
$suffix = if ($Symbols) { '-symbols' } else { '' }
$name = "kirakara-engine-windows-x64-$Mode-v$($lock.patchset.version)$suffix"
$archive = Join-Path $outputRoot ($name+'.zip')
$candidateLock = Join-Path $outputRoot ($name+'.candidate.lock.json')
if ((Test-Path -LiteralPath $archive) -or (Test-Path -LiteralPath $candidateLock)) {
  throw '候选产物已存在；选择新的输出目录，不能覆盖现有产物。'
}
$source = [IO.Path]::GetFullPath($SourceOutput)
[Kirakara.Artifacts.Security]::NoReparse($source)
foreach ($record in $identity.build.artifacts) {
  if (-not $Symbols -and $record.path -like '*.pdb') { continue }
  Assert-ArtifactFile ([Kirakara.Artifacts.Security]::Child($source,[string]$record.path)) $record
}
$temp = Join-Path $repo ('.kfe/tmp/pack-engine-'+[guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp -Force
try {
  $payload = Join-Path $temp ('out/'+$identity.build.localEngine)
  $null = New-Item -ItemType Directory -Path $payload -Force
  if ($Symbols) {
    foreach ($record in $identity.build.artifacts | Where-Object path -Like '*.pdb') {
      Copy-Item -LiteralPath (Join-Path $source $record.path) -Destination (Join-Path $payload $record.path)
    }
  } else {
    $flat = @('args.gn','flutter_windows.dll','flutter_windows.dll.exp','flutter_windows.dll.lib','icudtl.dat',
      'flutter_export.h','flutter_macros.h','flutter_windows.h','flutter_messenger.h',
      'flutter_plugin_registrar.h','flutter_texture_registrar.h','impellerc.exe')
    if ($Mode -ne 'debug') { $flat += 'gen_snapshot.exe' }
    foreach ($file in $flat) {
      Copy-Item -LiteralPath (Join-Path $source $file) -Destination (Join-Path $payload $file)
    }
    foreach ($directory in @('cpp_client_wrapper','dart-sdk','flutter_patched_sdk','shader_lib','gen/dart-pkg/sky_engine')) {
      $from = [Kirakara.Artifacts.Security]::Child($source,$directory)
      [Kirakara.Artifacts.Security]::NoReparse($from)
      foreach ($item in Get-ChildItem -LiteralPath $from -Recurse -File -Force) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '输出包含符号链接，不能盲目打包。' }
        if ($item.Extension -in @('.pdb','.obj','.o','.ninja')) { continue }
        $relative = [IO.Path]::GetRelativePath($source,$item.FullName).Replace('\','/')
        $to = [Kirakara.Artifacts.Security]::Child($payload,$relative)
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force
        Copy-Item -LiteralPath $item.FullName -Destination $to
      }
    }
    foreach ($tool in $lock.prebuiltSdkTools) {
      $from = Join-Path $FlutterSdkRoot ('bin/cache/artifacts/engine/'+$tool.sourcePath)
      Assert-ArtifactFile $from $tool
      $to = [Kirakara.Artifacts.Security]::Child($payload,[string]$tool.outputPath)
      $null = New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force
      Copy-Item -LiteralPath $from -Destination $to
    }
    $sky = Join-Path $payload 'gen/dart-pkg/sky_engine'
    Copy-Item -LiteralPath (Join-Path $FlutterSdkRoot 'bin/cache/pkg/sky_engine/pubspec.yaml') -Destination (Join-Path $sky 'pubspec.yaml')
  }
  Copy-Item -LiteralPath (Join-Path $repo 'engine/licenses') -Destination (Join-Path $temp 'licenses') -Recurse
  Copy-Item -LiteralPath (Join-Path $FlutterSdkRoot 'bin/cache/pkg/sky_engine/license') -Destination (Join-Path $temp 'licenses/Engine-NOTICES.txt')
  Copy-Item -LiteralPath (Join-Path $repo 'engine/MODIFICATIONS.md') -Destination $temp
  Copy-Item -LiteralPath (Join-Path $repo 'engine/engine.lock.json') -Destination $temp
  $files = @(Get-ChildItem -LiteralPath $temp -Recurse -File | Sort-Object FullName | ForEach-Object {
    [ordered]@{path=[IO.Path]::GetRelativePath($temp,$_.FullName).Replace('\','/');size=$_.Length;sha256=Get-ArtifactHash $_.FullName}
  })
  $kind = if ($Symbols) { 'flutter-engine-symbols' } else { 'flutter-engine' }
  $manifest = [ordered]@{schemaVersion=1;kind=$kind;identityHash=$identity.value;identity=$identity.identity;files=$files}
  $manifestPath = Join-Path $temp 'manifest.json'
  [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
  if (-not $Symbols) { Assert-PrebuiltEngineContents $temp $manifest $lock $identity }
  [IO.Compression.ZipFile]::CreateFromDirectory($temp,$archive,[IO.Compression.CompressionLevel]::Optimal,$false)
  $entry = [ordered]@{
    identityHash=$identity.value;url=$null;size=(Get-Item -LiteralPath $archive).Length
    sha256=Get-ArtifactHash $archive;manifestSha256=Get-ArtifactHash $manifestPath
  }
  $candidate = [ordered]@{schemaVersion=1;packageFormatVersion=2;target='windows-x64';
    modes=[ordered]@{debug=$null;profile=$null;release=$null};symbols=[ordered]@{debug=$null;profile=$null;release=$null}}
  if ($Symbols) { $candidate.symbols[$Mode]=$entry } else { $candidate.modes[$Mode]=$entry }
  [IO.File]::WriteAllText($candidateLock,($candidate | ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
  Write-Host "候选包生成：$archive"
  Write-Host "候选锁生成：$candidateLock"
  Write-Host '未更新正式锁、未上传、未创建 GitHub Release。'
} finally {
  [Kirakara.Artifacts.Security]::NoReparse($temp)
  if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
