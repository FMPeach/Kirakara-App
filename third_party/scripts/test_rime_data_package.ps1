#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Package,[Parameter(Mandatory)][string]$CandidateLock,[string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repo 'engine/scripts/artifact_package.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'rime_package.psm1') -DisableNameChecking
$expected=Get-RimeDataIdentity
$entry=(Get-RimeDataEntry $CandidateLock).entry
$scratch=Join-Path $repo ('.kfe/tmp/rime-data-test-'+[guid]::NewGuid().ToString('N'))
[Kirakara.Artifacts.Security]::NoReparse($scratch)
$null=New-Item -ItemType Directory -Path $scratch
$results=[Collections.Generic.List[string]]::new()
$verify={param($root,$manifest) Assert-RimeDataContents $root $manifest $expected}.GetNewClosure()
try {
  Assert-ArtifactFile $Package $entry
  $workspace=Join-Path $scratch 'workspace'
  $destination=Join-Path $workspace ('prebuilt/'+$expected.value)
  $installed=Install-ArtifactPackage -Workspace $workspace -Destination $destination -Kind rime-data `
    -IdentityHash $expected.value -Entry $entry -Verify $verify -LocalArchive $Package -MaxExpandedBytes 67108864
  $ready=Get-Content -Raw -LiteralPath (Join-Path $installed 'ready.json')
  $null=Install-ArtifactPackage -Workspace $workspace -Destination $destination -Kind rime-data `
    -IdentityHash $expected.value -Entry $entry -Verify $verify -MaxExpandedBytes 67108864
  if ((Get-Content -Raw -LiteralPath (Join-Path $installed 'ready.json')) -cne $ready) { throw '复用重写了 ready。' }
  $results.Add('正确包安装、逐文件核验与 ready 复用')
  $default=Get-Content -Raw -LiteralPath (Join-Path $installed 'data/default.yaml')
  if ($default -match '(?m)^\s*-\s*schema:\s*cangjie5' -or
      [regex]::Matches($default,'(?m)^\s*-\s*schema:').Count -ne 7) { throw '配置补丁误改输入方案。' }
  $results.Add('只排除未使用仓颉入口，保留其余七个方案')
  $fixture=Join-Path $scratch 'fixture'
  [Kirakara.Artifacts.Security]::ExtractZip([IO.Path]::GetFullPath($Package),$fixture,67108864,100)
  $manifestPath=Join-Path $fixture 'manifest.json'
  $manifestText=Get-Content -Raw -LiteralPath $manifestPath
  $wrongIdentity=$manifestText | ConvertFrom-Json
  $wrongIdentity.identity.opencc.revision='0'*40
  $rejected=$false
  try { Assert-RimeDataContents $fixture $wrongIdentity $expected } catch {
    if ($_.Exception.Message -notlike '*身份错误*') { throw }; $rejected=$true
  }
  if (-not $rejected) { throw '错误 OpenCC 来源未拒绝。' }
  $results.Add('错误 OpenCC 来源身份拒绝')

  function Assert-NegativePackage {
    param([string]$RelativePath,[ValidateSet('missing','tamper','extra')][string]$Change)
    $path=[Kirakara.Artifacts.Security]::Child($fixture,$RelativePath)
    $saved=Join-Path $scratch 'saved-file'
    if ($Change -ne 'extra') { [IO.File]::Move($path,$saved) }
    try {
      if ($Change -eq 'tamper') {
        $bytes=[IO.File]::ReadAllBytes($saved); $bytes[0]=$bytes[0] -bxor 1
        [IO.File]::WriteAllBytes($path,$bytes)
      } elseif ($Change -eq 'extra') {
        # This is a synthetic filename-only fixture, never a real GPL dictionary.
        [IO.File]::WriteAllText($path,'unexpected',[Text.UTF8Encoding]::new($false))
      }
      $negative=$manifestText | ConvertFrom-Json
      $negative.files=@($negative.files | Where-Object path -CNE $RelativePath)
      if ($Change -ne 'missing') {
        $negative.files+=@([pscustomobject]@{path=$RelativePath;size=(Get-Item -LiteralPath $path).Length;sha256=Get-ArtifactHash $path})
      }
      [IO.File]::WriteAllText($manifestPath,($negative|ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($false))
      $negativeZip=Join-Path $scratch ('negative-'+$results.Count+'.zip')
      [IO.Compression.ZipFile]::CreateFromDirectory($fixture,$negativeZip,[IO.Compression.CompressionLevel]::Fastest,$false)
      # Re-sign the test lock/manifest: the independent source contract must
      # still catch missing sources/licenses and content changed by a packager.
      $negativeEntry=[pscustomobject]@{identityHash=$expected.value;url=$null;size=(Get-Item -LiteralPath $negativeZip).Length
        sha256=Get-ArtifactHash $negativeZip;manifestSha256=Get-ArtifactHash $manifestPath}
      $target=Join-Path $workspace ('negative-'+$results.Count)
      $rejected=$false
      try {
        $null=Install-ArtifactPackage -Workspace $workspace -Destination $target -Kind rime-data `
          -IdentityHash $expected.value -Entry $negativeEntry -Verify $verify -LocalArchive $negativeZip -MaxExpandedBytes 67108864
      } catch {
        if ($_.Exception.Message -notmatch '包文件缺失|缺少对应修改|未经批准|非必要数据') { throw }
        $rejected=$true
      }
      if (-not $rejected -or (Test-Path -LiteralPath (Join-Path $target 'ready.json'))) {
        throw '无效 Rime 数据包被接受或留下虚假 ready。'
      }
      $results.Add("可信清单负向包拒绝且无 ready：$Change $RelativePath")
    } finally {
      if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
      if ($Change -ne 'extra') { [IO.File]::Move($saved,$path) }
      [IO.File]::WriteAllText($manifestPath,$manifestText,[Text.UTF8Encoding]::new($false))
    }
  }
  foreach ($missing in @('data/luna_pinyin_simp.schema.yaml','data/opencc/t2s.json',
      'sources/rime/terra_pinyin.dict.yaml',('sources/'+$expected.opencc.sourceArchive.path),
      'licenses/LGPL-3.0.txt','licenses/GPL-3.0-LGPL-supplement.txt','licenses/CC-BY-SA-3.0.txt',
      'licenses/OpenCC-AUTHORS.txt','modifications/0002-rime-exclude-unused-cangjie.patch')) {
    Assert-NegativePackage $missing missing
  }
  foreach ($changed in @('data/default.yaml','data/opencc/TSCharacters.ocd2','sources/rime/luna_pinyin.dict.yaml')) {
    Assert-NegativePackage $changed tamper
  }
  Assert-NegativePackage 'data/cangjie5.dict.yaml' extra
  $rejected=$false
  try { Get-RimeDataEntry (Join-Path $repo 'third_party/data.lock.json') | Out-Null } catch {
    if ($_.Exception.Message -notlike '*尚未配置 Rime 数据包下载*') { throw }; $rejected=$true
  }
  if (-not $rejected) { throw '未配置正式数据包未拒绝。' }
  $results.Add('未配置正式数据包明确拒绝，不自动源码构建或禁用输入法')
  if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath=Join-Path $repo 'build/diagnostics/rime-data-package.json' }
  $report=[IO.Path]::GetFullPath($ReportPath)
  if (-not $report.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '报告必须位于当前仓库。' }
  [Kirakara.Artifacts.Security]::NoReparse($report)
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force
  [ordered]@{passed=$true;cases=$results.ToArray();identityHash=$expected.value;rimeSourceFiles=20;openccRuntimeFiles=30
    formalReleasePublished=$false;appImeUiVerified=$false;fullRuntimeLicenseAuditComplete=$false} | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $report -Encoding utf8
  Write-Host "Rime 数据包 $($results.Count) 项检查通过；未代替 App 输入法交互。报告：$report"
} finally {
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  if (-not $scratch.StartsWith($repo+'\.kfe\tmp\rime-data-test-',[StringComparison]::OrdinalIgnoreCase)) { throw '测试清理目标越界。' }
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
