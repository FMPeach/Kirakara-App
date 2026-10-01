#Requires -Version 7.2
[CmdletBinding()]
param([ValidateRange(1,64)][int]$Jobs = 8, [string]$CMake, [switch]$Offline, [string]$ReportPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
$data = (Get-Content -Raw -LiteralPath (Join-Path $repo 'third_party/data.lock.json') | ConvertFrom-Json).zinniaTomoe
$source = Join-Path $repo '.kfe/source/zinnia'
$archive = Join-Path $repo ('.kfe/downloads/' + $data.sourceRevision + '.tar.bz2')
$models = Join-Path $repo '.kfe/source/models'
$output = Join-Path $repo '.kfe/out/zinnia'
$resultsRoot = Join-Path $repo '.kfe/native/models-check'
foreach ($path in @($source,$archive,$models,$output,$resultsRoot)) { [Kirakara.Artifacts.Security]::NoReparse($path) }
& (Join-Path $PSScriptRoot 'prepare_zinnia_sources.ps1') -Offline:$Offline -SourceRoot $source
if (-not (Test-Path -LiteralPath $archive)) {
  if ($Offline) { throw '离线验证缺少官方 Zinnia-Tomoe 源码包。' }
  $null = New-Item -ItemType Directory -Path (Split-Path -Parent $archive) -Force
  Save-ArtifactDownload -Uri $data.sourceUrl -Path $archive -ExpectedBytes $data.sourceSize
}
Assert-ArtifactFile $archive @{ size = $data.sourceSize; sha256 = $data.sourceSha256 }
$modelSource = Join-Path $models $data.sourceRevision
if (-not (Test-Path -LiteralPath $modelSource)) {
  # Even a trusted, hash-pinned source archive is checked before extraction.
  $names = @(& tar -tf $archive)
  if ($LASTEXITCODE -or $names.Count -gt 100) { throw '官方模型源包条目清单无效。' }
  foreach ($name in $names) {
    $relative = [Kirakara.Artifacts.Security]::RelativePath($name.TrimEnd('/'))
    if ($relative -cne $data.sourceRevision -and -not $relative.StartsWith($data.sourceRevision + '/', [StringComparison]::Ordinal)) {
      throw '模型源包存在预期根目录以外的文件。'
    }
  }
  $types = @(& tar -tvf $archive)
  if ($LASTEXITCODE -or @($types | Where-Object { $_ -notmatch '^[-d]' }).Count) { throw '模型源包含链接或异常条目类型。' }
  $temporary = Join-Path $repo ('.kfe/tmp/model-source-' + [guid]::NewGuid().ToString('N'))
  [Kirakara.Artifacts.Security]::NoReparse($temporary)
  $null = New-Item -ItemType Directory -Path $temporary
  try {
    & tar -xf $archive -C $temporary
    if ($LASTEXITCODE) { throw '模型源码解压失败。' }
    $null = New-Item -ItemType Directory -Path $models -Force
    [IO.Directory]::Move((Join-Path $temporary $data.sourceRevision), $modelSource)
  } finally {
    [Kirakara.Artifacts.Security]::NoReparse($temporary)
    Remove-Item -LiteralPath $temporary -Recurse -Force
  }
}
foreach ($model in $data.models) {
  $path = [Kirakara.Artifacts.Security]::Child($models, $model.sourcePath)
  if ((Get-ArtifactHash $path) -ine $model.sourceSha256) { throw '模型文本源码哈希不匹配。' }
}
if ((Get-ArtifactHash (Join-Path $models $data.sourceLicensePath)) -ine $data.sourceLicenseSha256) {
  throw '模型对应的 LGPL-2.1 原始许可证不匹配。'
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath) | Select-Object -First 1
$version = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationVersion) | Select-Object -First 1
if (-not $vs -or -not $version) { throw '需要 Visual Studio C++ 桌面工具；不会自动安装系统组件。' }
if ([string]::IsNullOrWhiteSpace($CMake)) {
  $CMake = Join-Path $vs 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
}
$major = ([version]$version).Major
$pattern = "Visual Studio $major \d{4}"
$generators = (& $CMake --help) | Where-Object { $_ -match "^\s*\*?\s*$pattern\s*=" }
if (-not $generators) { throw 'CMake 缺少当前已安装 Visual Studio 对应的 generator。' }
$generator = [regex]::Match(($generators | Select-Object -First 1),$pattern).Value
& $CMake -S (Join-Path $repo 'native/zinnia') -B $output -G $generator -A x64 "-DZINNIA_SOURCE_DIR=$($source.Replace('\','/'))/zinnia" | Out-Host
if ($LASTEXITCODE) { throw 'Zinnia converter 配置失败。' }
& $CMake --build $output --target kirakara_zinnia_convert --config Release --parallel $Jobs | Out-Host
if ($LASTEXITCODE) { throw 'Zinnia converter 构建失败。' }
$converter = Join-Path $output 'Release/kirakara_zinnia_convert.exe'
$null = New-Item -ItemType Directory -Path $resultsRoot -Force
$records = [Collections.Generic.List[object]]::new()
Push-Location $resultsRoot
try {
  foreach ($model in $data.models) {
    # The upstream converter uses narrow argv/fopen. Relative paths preserve
    # Unicode repository support without changing it or the system code page.
    $input = [IO.Path]::GetRelativePath($resultsRoot, (Join-Path $models $model.sourcePath))
    & $converter $input $model.path | Out-Host
    if ($LASTEXITCODE) { throw 'Zinnia 模型转换失败。' }
    $target = Join-Path $resultsRoot $model.path
    Assert-ArtifactFile $target $model
    $records.Add([ordered]@{ path = $model.path; sha256 = Get-ArtifactHash $target; exactMatch = $true })
  }
} finally { Pop-Location }
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $repo 'build/diagnostics/handwriting-reproduction.json' }
$report = [IO.Path]::GetFullPath($ReportPath)
$prefix = $repo.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
if (-not $report.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw '复现报告必须位于当前仓库。' }
[Kirakara.Artifacts.Security]::NoReparse($report)
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
[IO.File]::WriteAllText($report,([ordered]@{ passed = $true; sourceRevision = $data.sourceRevision
  sourceArchiveSha256 = $data.sourceSha256; converterRevision = $data.converterRevision
  compilerGenerator = $generator; converterSha256 = Get-ArtifactHash $converter
  models = $records.ToArray(); formalReleasePublished = $false } | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Write-Host "中文/日文模型精确复现通过；没有发布模型 Release。报告：$report"
