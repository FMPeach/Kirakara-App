Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'powershell_compat.ps1')
if (-not ('Kirakara.Artifacts.Security' -as [type])) {
  $securitySource = Join-Path $PSScriptRoot 'artifact_security.cs'
  if ($PSVersionTable.PSEdition -eq 'Desktop') {
    Add-Type -Path $securitySource -ReferencedAssemblies @(
      'System.dll',
      'System.Core.dll',
      'System.IO.Compression.dll',
      'System.IO.Compression.FileSystem.dll'
    )
  } else {
    Add-Type -Path $securitySource
  }
}
if (-not ('System.Net.Http.HttpClient' -as [type])) {
  Add-Type -AssemblyName System.Net.Http
}

function Get-ArtifactHash {
  param([Parameter(Mandatory)][string]$Path)
  [Kirakara.Artifacts.Security]::NoReparse($Path)
  return Get-KirakaraFileSha256 -Path $Path
}

function Get-ArtifactTextHash {
  param([Parameter(Mandatory)][string]$Text)
  return Get-KirakaraSha256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes($Text))
}

function Assert-ArtifactFile {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Record)
  [Kirakara.Artifacts.Security]::NoReparse($Path)
  if ([string]$Record.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [long]$Record.size -lt 0) {
    throw '包清单缺少有效的 SHA-256 或大小。'
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
      (Get-Item -LiteralPath $Path).Length -ne [long]$Record.size -or
      (Get-ArtifactHash $Path) -ne [string]$Record.sha256) {
    throw "包文件缺失、大小或 SHA-256 不匹配：$Path"
  }
}

function Assert-ArtifactManifest {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Kind,
    [Parameter(Mandatory)][string]$IdentityHash,
    [Parameter(Mandatory)]$Entry,
    [switch]$Installed
  )
  [Kirakara.Artifacts.Security]::NoReparse($Root)
  $manifestPath = [Kirakara.Artifacts.Security]::Child($Root, 'manifest.json')
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
      (Get-ArtifactHash $manifestPath) -ne [string]$Entry.manifestSha256) {
    throw '包 manifest 的可信哈希不匹配。'
  }
  $manifest = Get-Content -Raw -LiteralPath $manifestPath -Encoding utf8 | ConvertFrom-Json
  if ($manifest.schemaVersion -ne 1 -or $manifest.kind -cne $Kind -or
      $manifest.identityHash -cne $IdentityHash -or $Entry.identityHash -cne $IdentityHash) {
    throw '包类型或版本身份与当前仓库的锁文件不匹配。'
  }
  $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $null = $expected.Add('manifest.json')
  if ($Installed) { $null = $expected.Add('ready.json') }
  $records = @($manifest.files)
  if ($records.Count -eq 0 -or $records.Count -gt 30000) { throw '包文件清单数量无效。' }
  foreach ($record in $records) {
    $relative = [Kirakara.Artifacts.Security]::RelativePath([string]$record.path)
    if ($relative -ieq 'ready.json' -or -not $expected.Add($relative)) {
      throw "包清单存在重复、保留或大小写冲突路径：$relative"
    }
    $path = [Kirakara.Artifacts.Security]::Child($Root, $relative)
    Assert-ArtifactFile -Path $path -Record $record
  }
  foreach ($item in Get-ChildItem -LiteralPath $Root -Recurse -Force) {
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '包中不能存在符号链接或 reparse point。' }
    if ($item.PSIsContainer) { continue }
    $relative = (Get-KirakaraRelativePath `
      -BasePath $Root `
      -Path $item.FullName).Replace('\', '/')
    if (-not $expected.Contains($relative)) { throw "包中存在未列入清单的文件：$relative" }
  }
  return $manifest
}

function Assert-ArtifactDownloadUri {
  param([Parameter(Mandatory)][uri]$Uri)
  $loopback = $Uri.Host -in @('localhost', '127.0.0.1', '[::1]', '::1')
  if (-not $Uri.IsAbsoluteUri -or -not [string]::IsNullOrEmpty($Uri.UserInfo) -or
      -not [string]::IsNullOrEmpty($Uri.Fragment) -or
      ($Uri.Scheme -ne 'https' -and -not ($Uri.Scheme -eq 'http' -and $loopback))) {
    throw '下载地址必须为无凭据的 HTTPS；仅本地 loopback 测试允许 HTTP。'
  }
}

function Save-ArtifactDownload {
  param([Parameter(Mandatory)][uri]$Uri, [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$ExpectedBytes)
  Assert-ArtifactDownloadUri $Uri
  $handler = [Net.Http.HttpClientHandler]::new()
  $handler.AllowAutoRedirect = $false
  $client = [Net.Http.HttpClient]::new($handler)
  $client.Timeout = [TimeSpan]::FromMinutes(20)
  $cancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(20))
  $response = $null
  try {
    for ($redirect = 0; $redirect -le 5; $redirect++) {
      Assert-ArtifactDownloadUri $Uri
      $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
          $cancellation.Token).GetAwaiter().GetResult()
      if ([int]$response.StatusCode -in @(301,302,303,307,308)) {
        if ($redirect -eq 5 -or $null -eq $response.Headers.Location) { throw '下载重定向过多或无目标。' }
        $Uri = [uri]::new($Uri, $response.Headers.Location)
        $response.Dispose(); $response = $null
        continue
      }
      $null = $response.EnsureSuccessStatusCode()
      $declared = $response.Content.Headers.ContentLength
      if ($null -ne $declared -and $declared -ne $ExpectedBytes) { throw 'HTTP 包大小与锁文件不匹配。' }
      $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
      $output = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
      try {
        $buffer = [byte[]]::new(65536)
        $total = 0L
        while (($count = $input.ReadAsync($buffer,0,$buffer.Length,$cancellation.Token).GetAwaiter().GetResult()) -gt 0) {
          $total += $count
          if ($total -gt $ExpectedBytes) { throw '下载超过锁定大小。' }
          $output.Write($buffer,0,$count)
        }
        if ($total -ne $ExpectedBytes) { throw '下载中断或长度不完整。' }
      } finally { $output.Dispose(); $input.Dispose() }
      return
    }
  } finally {
    if ($null -ne $response) { $response.Dispose() }
    $cancellation.Dispose(); $client.Dispose(); $handler.Dispose()
  }
}

function Install-ArtifactPackage {
  param(
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][string]$Kind,
    [Parameter(Mandatory)][string]$IdentityHash,
    [Parameter(Mandatory)]$Entry,
    [Parameter(Mandatory)][scriptblock]$Verify,
    [string]$LocalArchive,
    [long]$MaxExpandedBytes = 4294967296
  )
  $workspaceRoot = [IO.Path]::GetFullPath($Workspace)
  $destinationPath = [IO.Path]::GetFullPath($Destination)
  [Kirakara.Artifacts.Security]::NoReparse($workspaceRoot)
  $expectedPrefix = $workspaceRoot.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
  if (-not $destinationPath.StartsWith($expectedPrefix,[StringComparison]::OrdinalIgnoreCase) -or
      $destinationPath -eq $workspaceRoot -or $Kind -notmatch '^[a-z-]+$' -or
      $IdentityHash -notmatch '^[0-9A-F]{64}$') { throw '安装目标必须位于当前仓库 .kfe 内。' }
  foreach ($hash in @($Entry.sha256,$Entry.manifestSha256)) {
    if ([string]$hash -notmatch '^[A-Fa-f0-9]{64}$') { throw '预编译锁缺少可信 SHA-256。' }
  }
  if ([long]$Entry.size -le 0 -or [long]$Entry.size -gt 4294967296) { throw '预编译包锁定大小无效。' }
  foreach ($relative in @('locks','tmp','downloads')) {
    $directory = Join-Path $workspaceRoot $relative
    [Kirakara.Artifacts.Security]::NoReparse($directory)
    $null = New-Item -ItemType Directory -Path $directory -Force
  }
  $lockPath = Join-Path $workspaceRoot "locks/$Kind-$IdentityHash.lock"
  [Kirakara.Artifacts.Security]::NoReparse($lockPath)
  $handle = $null
  $deadline = [DateTime]::UtcNow.AddMinutes(20)
  while ($null -eq $handle) {
    try { $handle = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch [IO.IOException] {
      if ([DateTime]::UtcNow -ge $deadline) { throw '等待其他安装进程超时；没有启动源码构建。' }
      Start-Sleep -Milliseconds 250
    }
  }
  $transaction = Join-Path $workspaceRoot ('tmp/package-'+[guid]::NewGuid().ToString('N'))
  $extract = Join-Path $transaction 'extract'
  try {
    [Kirakara.Artifacts.Security]::NoReparse($destinationPath)
    $readyPath = Join-Path $destinationPath 'ready.json'
    if (Test-Path -LiteralPath $destinationPath) {
      if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) { throw '安装目录存在但没有 ready stamp；请保留诊断并清理该模式后重试。' }
      [Kirakara.Artifacts.Security]::NoReparse($readyPath)
      $ready = Get-Content -Raw -LiteralPath $readyPath -Encoding utf8 |
        ConvertFrom-Json
      if ($ready.schemaVersion -ne 1 -or $ready.identityHash -cne $IdentityHash -or
          $ready.archiveSha256 -ine $Entry.sha256 -or $ready.manifestSha256 -ine $Entry.manifestSha256) { throw 'ready stamp 与当前可信包不匹配。' }
      $manifest = Assert-ArtifactManifest $destinationPath $Kind $IdentityHash $Entry -Installed
      & $Verify $destinationPath $manifest | Out-Null
      Write-Host "[Kirakara] 复用已完整校验的 $Kind 包。"
      return $destinationPath
    }
    $null = New-Item -ItemType Directory -Path $transaction
    $archive = Join-Path $workspaceRoot "downloads/$($Entry.sha256).zip"
    if (-not [string]::IsNullOrWhiteSpace($LocalArchive)) {
      Assert-ArtifactFile -Path $LocalArchive -Record $Entry
      if (-not (Test-Path -LiteralPath $archive)) { Copy-Item -LiteralPath $LocalArchive -Destination $archive }
    } elseif (-not (Test-Path -LiteralPath $archive)) {
      if ([string]::IsNullOrWhiteSpace([string]$Entry.url)) {
        throw '维护者尚未配置正式预编译下载 URL。请指定经过审核的本地包；Engine 源码构建必须显式使用 --from-source。'
      }
      $partial = Join-Path $transaction 'download.partial'
      Save-ArtifactDownload -Uri ([uri]$Entry.url) -Path $partial -ExpectedBytes ([long]$Entry.size)
      Assert-ArtifactFile $partial $Entry
      [IO.File]::Move($partial,$archive)
    }
    Assert-ArtifactFile $archive $Entry
    [Kirakara.Artifacts.Security]::ExtractZip($archive,$extract,$MaxExpandedBytes,30000)
    $manifest = Assert-ArtifactManifest $extract $Kind $IdentityHash $Entry
    & $Verify $extract $manifest | Out-Null
    $parent = Split-Path -Parent $destinationPath
    [Kirakara.Artifacts.Security]::NoReparse($parent)
    $null = New-Item -ItemType Directory -Path $parent -Force
    [IO.Directory]::Move($extract,$destinationPath)
    # All validators have passed, and the complete tree is in its final location.
    # A crash before this final write leaves an explicitly non-ready directory.
    $ready = [ordered]@{
      schemaVersion=1; kind=$Kind; identityHash=$IdentityHash
      archiveSha256=[string]$Entry.sha256; manifestSha256=[string]$Entry.manifestSha256
      installedAt=[DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress
    $stampTmp = Join-Path $destinationPath ('ready-'+[guid]::NewGuid().ToString('N')+'.tmp')
    [IO.File]::WriteAllText($stampTmp,$ready,[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($stampTmp,$readyPath)
    return $destinationPath
  } finally {
    if (Test-Path -LiteralPath $transaction) {
      [Kirakara.Artifacts.Security]::NoReparse($transaction)
      Remove-Item -LiteralPath $transaction -Recurse -Force
    }
    $handle.Dispose()
  }
}

Export-ModuleMember -Function @('Get-ArtifactHash','Get-ArtifactTextHash','Assert-ArtifactFile',
  'Assert-ArtifactManifest','Assert-ArtifactDownloadUri','Save-ArtifactDownload','Install-ArtifactPackage',
  'Get-KirakaraRelativePath','Get-KirakaraSha256Hex','Get-KirakaraFileSha256',
  'Set-KirakaraProcessArguments','Set-KirakaraProcessUtf8Redirection',
  'Set-KirakaraProcessEnvironmentValue','Stop-KirakaraProcessTree','Move-KirakaraFile')
