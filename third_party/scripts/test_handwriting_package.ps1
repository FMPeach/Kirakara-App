#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Package,[Parameter(Mandatory)][string]$CandidateLock,[string]$ReportPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'handwriting_package.psm1') -DisableNameChecking
$expected = Get-HandwritingIdentity
$entry = (Get-HandwritingEntry -LockPath $CandidateLock).entry
$scratch = Join-Path $repo ('.kfe/tmp/handwriting-test-'+[guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null = New-Item -ItemType Directory -Path $scratch
$results = [Collections.Generic.List[string]]::new()
$verify = { param($root,$manifest) Assert-HandwritingContents $root $manifest $expected }.GetNewClosure()
try {
  Assert-ArtifactFile $Package $entry
  $workspace = Join-Path $scratch 'workspace'
  $destination = Join-Path $workspace ('prebuilt/'+$expected.value)
  $installed = Install-ArtifactPackage -Workspace $workspace -Destination $destination -Kind handwriting-data `
    -IdentityHash $expected.value -Entry $entry -Verify $verify -LocalArchive $Package -MaxExpandedBytes 268435456
  $ready = Get-Content -Raw -LiteralPath (Join-Path $installed 'ready.json')
  $null = Install-ArtifactPackage -Workspace $workspace -Destination $destination -Kind handwriting-data `
    -IdentityHash $expected.value -Entry $entry -Verify $verify -MaxExpandedBytes 268435456
  if ((Get-Content -Raw -LiteralPath (Join-Path $installed 'ready.json')) -cne $ready) { throw '复用意外重写 ready。' }
  $results.Add('正确包安装与完整校验复用')
  $fixture = Join-Path $scratch 'fixture'
  [Kirakara.Artifacts.Security]::ExtractZip([IO.Path]::GetFullPath($Package),$fixture,268435456,30)
  $manifestPath = Join-Path $fixture 'manifest.json'
  $manifestText = Get-Content -Raw -LiteralPath $manifestPath
  $manifest = $manifestText | ConvertFrom-Json
  $wrongIdentity = $manifestText | ConvertFrom-Json
  $wrongIdentity.identity.converterRevision = '0'*40
  $rejected = $false
  try { Assert-HandwritingContents $fixture $wrongIdentity $expected } catch { $rejected = $true }
  if (-not $rejected) { throw '错误来源身份未拒绝。' }
  $results.Add('错误来源身份拒绝')
  $model = Join-Path $fixture ('models/'+$expected.data.models[0].path)
  $stream = [IO.File]::Open($model,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  try { $original = $stream.ReadByte(); $stream.Position = 0; $stream.WriteByte([byte]($original -bxor 1)) }
  finally { $stream.Dispose() }
  try {
    $rejected = $false
    try { Assert-HandwritingContents $fixture $manifest $expected } catch { $rejected = $true }
    if (-not $rejected) { throw '模型篡改未拒绝。' }
  } finally {
    $stream = [IO.File]::Open($model,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { $stream.WriteByte([byte]$original) } finally { $stream.Dispose() }
  }
  $results.Add('模型内容篡改拒绝')
  # Trusted ZIP/manifest hashes alone are not enough: the data contract must
  # still require both languages, corresponding sources and the exact license.
  foreach ($missing in @('models/handwriting-ja.model','licenses/LGPL-2.1.txt',
      ('sources/'+$expected.data.models[0].sourcePath))) {
    $path = [Kirakara.Artifacts.Security]::Child($fixture,$missing)
    $saved = Join-Path $scratch 'saved-file'
    [IO.File]::Move($path,$saved)
    try {
      $negative = $manifestText | ConvertFrom-Json
      $negative.files = @($negative.files | Where-Object path -CNE $missing)
      [IO.File]::WriteAllText($manifestPath,($negative|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
      $negativeArchive = Join-Path $scratch ('negative-'+$results.Count+'.zip')
      [IO.Compression.ZipFile]::CreateFromDirectory($fixture,$negativeArchive,[IO.Compression.CompressionLevel]::Fastest,$false)
      $negativeEntry = [pscustomobject]@{identityHash=$expected.value;url=$null;size=(Get-Item $negativeArchive).Length
        sha256=Get-ArtifactHash $negativeArchive;manifestSha256=Get-ArtifactHash $manifestPath}
      $negativeDestination = Join-Path $workspace ('negative-'+$results.Count)
      $rejected = $false
      try {
        $null = Install-ArtifactPackage -Workspace $workspace -Destination $negativeDestination -Kind handwriting-data `
          -IdentityHash $expected.value -Entry $negativeEntry -Verify $verify -LocalArchive $negativeArchive -MaxExpandedBytes 268435456
      } catch { $rejected = $true }
      if (-not $rejected -or (Test-Path -LiteralPath (Join-Path $negativeDestination 'ready.json'))) {
        throw '缺少模型/来源/许可的可信清单包被接受或留下虚假 ready。'
      }
      $results.Add('必要文件缺失拒绝且没有 ready：'+$missing)
    } finally {
      [IO.File]::Move($saved,$path)
      [IO.File]::WriteAllText($manifestPath,$manifestText,[Text.UTF8Encoding]::new($false))
    }
  }
  $rejected = $false
  try { Get-HandwritingEntry -LockPath (Join-Path $repo 'third_party/data.lock.json') | Out-Null } catch { $rejected = $true }
  if (-not $rejected) { throw '未配置正式模型包未拒绝。' }
  $results.Add('未配置正式包明确拒绝')
  if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath=Join-Path $repo 'build/diagnostics/handwriting-package.json' }
  $report = [IO.Path]::GetFullPath($ReportPath)
  if (-not $report.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '报告必须位于当前仓库。' }
  [Kirakara.Artifacts.Security]::NoReparse($report)
  $null = New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
  [ordered]@{passed=$true;cases=$results.ToArray();identityHash=$expected.value
    formalReleasePublished=$false;appHandwritingUiVerified=$false} | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $report -Encoding utf8
  Write-Host "手写数据包 $($results.Count) 项检查通过；未代替 App 输入法交互测试。报告：$report"
} finally {
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  if (-not $scratch.StartsWith($repo+'\.kfe\tmp\handwriting-test-',[StringComparison]::OrdinalIgnoreCase)) { throw '测试清理路径未通过边界检查。' }
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
