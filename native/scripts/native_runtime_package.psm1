Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot `
    'engine/scripts/artifact_package.psm1') -DisableNameChecking

$script:RimeRequiredExports = @(
  'RimeSetup',
  'RimeInitialize',
  'RimeFinalize',
  'RimeCreateSession',
  'RimeDestroySession',
  'RimeSelectSchema',
  'RimeSetInput',
  'RimeClearComposition',
  'RimeGetContext',
  'RimeFreeContext',
  'RimeStartMaintenance',
  'RimeJoinMaintenanceThread',
  'RimeCandidateListBegin',
  'RimeCandidateListNext',
  'RimeCandidateListEnd',
  'rime_get_api'
)

function ConvertTo-FileRecord {
  param([Parameter(Mandatory)]$Value)
  return [ordered]@{
    size = [long]$Value.size
    sha256 = [string]$Value.sha256
  }
}

function Assert-RepositoryFileRecord {
  param(
    [Parameter(Mandatory)][string]$RelativePath,
    [Parameter(Mandatory)]$Record
  )
  $path = [Kirakara.Artifacts.Security]::Child(
    $script:RepositoryRoot, $RelativePath)
  Assert-ArtifactFile -Path $path -Record $Record
  return $path
}

function Get-NativeRuntimeIdentity {
  $native = Get-Content -Raw -LiteralPath (
    Join-Path $script:RepositoryRoot 'native/native.lock.json') -Encoding utf8 |
    ConvertFrom-Json
  if ($native.schemaVersion -ne 1 -or $native.target -cne 'windows-x64' -or
      $native.imeRuntime.packageFormatVersion -ne 2 -or
      $native.imeRuntime.architecture -cne 'x64') {
    throw 'IME 原生运行包锁格式或目标不受支持。'
  }

  $rime = $native.librime.prebuiltRuntime
  $mozc = $native.mozc.prebuiltRuntime
  $zinniaBuild = $native.zinnia.prebuiltBuild
  $zinniaArtifacts = $native.zinnia.prebuiltArtifacts
  $null = Assert-RepositoryFileRecord `
    -RelativePath ([string]$rime.licenseFile.path) `
    -Record $rime.licenseFile
  $null = Assert-RepositoryFileRecord `
    -RelativePath ([string]$mozc.licenseFile.path) `
    -Record $mozc.licenseFile
  $null = Assert-RepositoryFileRecord `
    -RelativePath ([string]$native.imeRuntime.zinniaLicenseFile.path) `
    -Record $native.imeRuntime.zinniaLicenseFile
  $bridgeSource = [Kirakara.Artifacts.Security]::Child(
    $script:RepositoryRoot, [string]$native.mozc.bridgeSource)
  Assert-ArtifactFile -Path $bridgeSource -Record ([pscustomobject]@{
      size = [long]$mozc.bridgeSourceSize
      sha256 = [string]$mozc.bridgeSourceSha256
    })

  $identity = [ordered]@{
    packageFormatVersion = 2
    kind = 'ime-runtime'
    target = 'windows-x64'
    architecture = 'x64'
    rime = [ordered]@{
      repository = [string]$native.librime.repository
      version = [string]$rime.version
      releaseUrl = [string]$rime.releaseUrl
      asset = [ordered]@{
        name = [string]$rime.asset.name
        url = [string]$rime.asset.url
        size = [long]$rime.asset.size
        sha256 = [string]$rime.asset.sha256
      }
      dll = [ordered]@{
        archivePath = [string]$rime.dll.archivePath
        size = [long]$rime.dll.size
        sha256 = [string]$rime.dll.sha256
        architecture = [string]$rime.dll.architecture
        requiredExports = @($script:RimeRequiredExports)
        upstreamBuildPathPrefixes = @(
          $rime.dll.upstreamBuildPathPrefixes | ForEach-Object { [string]$_ })
      }
      license = [ordered]@{
        id = [string]$native.librime.license
        path = [string]$rime.licenseFile.path
        size = [long]$rime.licenseFile.size
        sha256 = [string]$rime.licenseFile.sha256
      }
    }
    mozc = [ordered]@{
      repository = [string]$native.mozc.repository
      revision = [string]$native.mozc.revision
      architecture = [string]$mozc.architecture
      buildMode = [string]$mozc.buildMode
      bridgeSource = [string]$native.mozc.bridgeSource
      bridgeSourceSize = [long]$mozc.bridgeSourceSize
      bridgeSourceSha256 = [string]$mozc.bridgeSourceSha256
      executable = ConvertTo-FileRecord $mozc.executable
      fixedInputProbe = [ordered]@{
        input = 'nihongo'
        expectedCandidate = '日本語'
      }
      license = [ordered]@{
        id = [string]$native.mozc.license
        path = [string]$mozc.licenseFile.path
        size = [long]$mozc.licenseFile.size
        sha256 = [string]$mozc.licenseFile.sha256
      }
    }
    zinnia = [ordered]@{
      repository = [string]$native.zinnia.repository
      revision = [string]$native.zinnia.revision
      version = [string]$native.zinnia.version
      architecture = [string]$zinniaBuild.architecture
      platformToolset = [string]$zinniaBuild.platformToolset
      toolsetDirectoryVersion = [string]$zinniaBuild.toolsetDirectoryVersion
      compiler = [ordered]@{
        fileVersion = [string]$zinniaBuild.compilerFileVersion
        sha256 = [string]$zinniaBuild.compilerSha256
      }
      librarian = [ordered]@{
        fileVersion = [string]$zinniaBuild.librarianFileVersion
        sha256 = [string]$zinniaBuild.librarianSha256
      }
      windowsSdkVersion = [string]$zinniaBuild.windowsSdkVersion
      logicalPaths = [ordered]@{
        source = [string]$zinniaBuild.logicalSourceRoot
        build = [string]$zinniaBuild.logicalBuildRoot
        toolset = [string]$zinniaBuild.logicalToolsetRoot
        windowsSdk = [string]$zinniaBuild.logicalWindowsSdkRoot
      }
      flags = [ordered]@{
        common = @($zinniaBuild.commonCompilerFlags)
        debug = @($zinniaBuild.debugCompilerFlags)
        release = @($zinniaBuild.releaseCompilerFlags)
        librarian = @($zinniaBuild.librarianFlags)
      }
      runtimeLibrary = [ordered]@{
        Debug = '/MDd'
        Release = '/MD'
        Profile = [string]$zinniaBuild.profileRuntimeLibrary
      }
      profileLibrary = [string]$zinniaArtifacts.profileUses
      profileReuseExplicit = $true
      header = ConvertTo-FileRecord $zinniaArtifacts.header
      debugLibrary = ConvertTo-FileRecord $zinniaArtifacts.debugLibrary
      releaseLibrary = ConvertTo-FileRecord $zinniaArtifacts.releaseLibrary
      provenance = ConvertTo-FileRecord $zinniaArtifacts.provenance
      reproducibility = [ordered]@{
        builds = [int]$zinniaArtifacts.reproducibleBuilds
        byteIdentical = [bool]$zinniaArtifacts.byteIdentical
        hostSpecificPathMatches = 0
      }
      license = [ordered]@{
        id = [string]$native.zinnia.license
        path = [string]$native.imeRuntime.zinniaLicenseFile.path
        size = [long]$native.imeRuntime.zinniaLicenseFile.size
        sha256 = [string]$native.imeRuntime.zinniaLicenseFile.sha256
      }
    }
  }
  return [pscustomobject]@{
    value = Get-ArtifactTextHash (
      $identity | ConvertTo-Json -Depth 20 -Compress)
    identity = $identity
    native = $native
  }
}

function Get-NativeRuntimeEntry {
  param([string]$LockPath)
  if ([string]::IsNullOrWhiteSpace($LockPath)) {
    $LockPath = [Environment]::GetEnvironmentVariable(
      'KIRAKARA_NATIVE_RUNTIME_LOCK', 'Process')
  }
  if ([string]::IsNullOrWhiteSpace($LockPath)) {
    $LockPath = Join-Path $script:RepositoryRoot 'native/prebuilt.lock.json'
  }
  [Kirakara.Artifacts.Security]::NoReparse($LockPath)
  $lock = Get-Content -Raw -LiteralPath $LockPath -Encoding utf8 |
    ConvertFrom-Json
  if ($lock.schemaVersion -ne 1 -or $lock.packageFormatVersion -ne 2 -or
      $lock.target -cne 'windows-x64') {
    throw 'IME 原生运行包预编译锁格式不受支持。'
  }
  $expected = Get-NativeRuntimeIdentity
  $entry = $lock.imeRuntime
  if ($null -eq $entry) {
    throw '维护者尚未配置 IME 原生运行包下载。请指定已审核的本地 ZIP 与候选锁；不会隐式构建 Rime、Mozc 或 Zinnia。'
  }
  if ($entry.identityHash -cne $expected.value) {
    throw 'IME 原生运行包身份与当前 ABI、工具集或依赖锁不匹配。'
  }
  return [pscustomobject]@{ entry = $entry; expected = $expected }
}

function Get-NativeRuntimeAbsolutePaths {
  param([Parameter(Mandatory)][string]$Path)
  $bytes = [IO.File]::ReadAllBytes($Path)
  $matches = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
  $pattern = '(?i)(?:[a-z]:\\[^\\\x00-\x1f<>:"|?*]{1,120}' +
    '\\[^\\\x00-\x1f<>:"|?*]{1,160}' +
    '(?:\\[^\\\x00-\x1f<>:"|?*]{1,160})*|' +
    '\\\\[a-z0-9._$ -]+\\[a-z0-9._$ -]+' +
    '(?:\\[^\\\x00-\x1f<>:"|?*]{1,160})+)'
  foreach ($text in @(
      [Text.Encoding]::GetEncoding(28591).GetString($bytes),
      [Text.Encoding]::Unicode.GetString($bytes))) {
    foreach ($match in [regex]::Matches($text, $pattern)) {
      $null = $matches.Add($match.Value)
    }
  }
  return @($matches | Sort-Object)
}

function Assert-NativeRuntimeHostPaths {
  param(
    [Parameter(Mandatory)][string]$Path,
    [string[]]$AllowedAbsolutePrefixes = @()
  )
  $bytes = [IO.File]::ReadAllBytes($Path)
  $texts = @(
    [Text.Encoding]::GetEncoding(28591).GetString($bytes),
    [Text.Encoding]::Unicode.GetString($bytes))
  $hostTokens = @(
    $script:RepositoryRoot,
    '.kfe',
    [Environment]::GetFolderPath('UserProfile'),
    [IO.Path]::GetTempPath().TrimEnd('\', '/')) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
  foreach ($token in $hostTokens) {
    foreach ($text in $texts) {
      if ($text.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "IME 原生运行包文件含宿主机专属路径或标识：$Path；$token"
      }
    }
  }
  foreach ($absolute in @(Get-NativeRuntimeAbsolutePaths $Path)) {
    $allowed = @($AllowedAbsolutePrefixes | Where-Object {
        $absolute.StartsWith($_, [StringComparison]::OrdinalIgnoreCase)
      }).Count -ne 0
    if (-not $allowed) {
      throw "IME 原生运行包文件含未声明的绝对路径：$Path；$absolute"
    }
  }
}

function Get-CoffArchiveMachines {
  param([Parameter(Mandatory)][string]$Path)
  $bytes = [IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -lt 8 -or
      [Text.Encoding]::ASCII.GetString($bytes, 0, 8) -cne "!<arch>`n") {
    throw "Zinnia 静态库不是有效 COFF archive：$Path"
  }
  $machines = [Collections.Generic.List[int]]::new()
  $offset = 8
  while ($offset -lt $bytes.Length) {
    if ($offset + 60 -gt $bytes.Length) {
      throw "Zinnia COFF archive 成员头被截断：$Path"
    }
    $header = [Text.Encoding]::ASCII.GetString($bytes, $offset, 60)
    if ($bytes[$offset + 58] -ne 0x60 -or
        $bytes[$offset + 59] -ne 0x0a) {
      throw "Zinnia COFF archive 成员头标记无效：$Path"
    }
    $sizeText = $header.Substring(48, 10).Trim()
    $size = 0L
    if (-not [long]::TryParse($sizeText, [ref]$size) -or $size -lt 0) {
      throw "Zinnia COFF archive 成员大小无效：$Path"
    }
    $name = $header.Substring(0, 16).Trim()
    $dataOffset = $offset + 60
    if ($dataOffset + $size -gt $bytes.Length) {
      throw "Zinnia COFF archive 成员数据被截断：$Path"
    }
    if (-not $name.StartsWith('/') -and $size -ge 20) {
      $machine = [BitConverter]::ToUInt16($bytes, $dataOffset)
      if ($machine -eq 0 -and $size -ge 8 -and
          [BitConverter]::ToUInt16($bytes, $dataOffset + 2) -eq 0xffff) {
        $machine = [BitConverter]::ToUInt16($bytes, $dataOffset + 6)
      }
      $machines.Add([int]$machine)
    }
    $offset = $dataOffset + $size
    if (($offset % 2) -ne 0) { $offset++ }
  }
  return @($machines)
}

function Assert-ZinniaLibraryContract {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][ValidateSet('Debug', 'Release')]
      [string]$Configuration
  )
  $machines = @(Get-CoffArchiveMachines $Path)
  if ($machines.Count -ne 8 -or
      @($machines | Where-Object { $_ -ne 0x8664 }).Count -ne 0) {
    throw "Zinnia $Configuration 静态库不是八成员 Windows x64 COFF archive。"
  }
  $ascii = [Text.Encoding]::GetEncoding(28591).GetString(
    [IO.File]::ReadAllBytes($Path))
  if ($Configuration -ceq 'Debug') {
    if (-not $ascii.Contains('RuntimeLibrary=MDd_DynamicDebug') -or
        $ascii -notmatch '(?i)/DEFAULTLIB:"?MSVCRTD"?' -or
        $ascii.Contains('RuntimeLibrary=MD_DynamicRelease')) {
      throw 'Zinnia Debug 静态库 CRT 契约不是 /MDd。'
    }
  } elseif (-not $ascii.Contains('RuntimeLibrary=MD_DynamicRelease') -or
      $ascii -notmatch '(?i)/DEFAULTLIB:"?MSVCRT"?' -or
      $ascii.Contains('RuntimeLibrary=MDd_DynamicDebug')) {
    throw 'Zinnia Release 静态库 CRT 契约不是 /MD。'
  }
  Assert-NativeRuntimeHostPaths -Path $Path
}

function Invoke-NativeRuntimeMozcProbe {
  param([Parameter(Mandatory)][string]$Executable)
  $scratch = Join-Path $script:RepositoryRoot (
    '.kfe/tmp/ime-runtime-mozc-' + [Guid]::NewGuid().ToString('N'))
  [Kirakara.Artifacts.Security]::NoReparse($scratch)
  $null = New-Item -ItemType Directory -Path $scratch
  try {
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    Set-KirakaraProcessArguments `
      -StartInfo $start `
      -Arguments @('compose', 'nihongo', '0', '25')
    foreach ($name in @('APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP')) {
      Set-KirakaraProcessEnvironmentValue `
        -StartInfo $start -Name $name -Value $scratch
    }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
      Stop-KirakaraProcessTree -Process $process
      $process.WaitForExit()
      throw 'Mozc 候选运行库调用超时。'
    }
    $output = $stdout.GetAwaiter().GetResult()
    $errorOutput = $stderr.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
    $process.Dispose()
    if ($exitCode -ne 0) {
      throw "Mozc 候选运行库调用失败（$exitCode）：$errorOutput"
    }
    $jsonLine = @($output -split "`r?`n" |
        Where-Object { $_.TrimStart().StartsWith('{') } |
        Select-Object -Last 1)
    if ($jsonLine.Count -ne 1) { throw 'Mozc 没有返回有效 JSON。' }
    $result = $jsonLine[0] | ConvertFrom-Json
    $texts = @($result.candidates | ForEach-Object { [string]$_.text })
    if (-not $result.ok -or $texts -cnotcontains '日本語') {
      throw 'Mozc 固定输入没有返回预期日文候选。'
    }
  } finally {
    if (Test-Path -LiteralPath $scratch) {
      [Kirakara.Artifacts.Security]::NoReparse($scratch)
      Remove-Item -LiteralPath $scratch -Recurse -Force
    }
  }
}

function Assert-NativeRuntimeDirectory {
  param(
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [Parameter(Mandatory)]$Expected
  )
  [Kirakara.Artifacts.Security]::NoReparse($RuntimeRoot)
  $relative = [ordered]@{
    provenance = 'ime-runtime-provenance.json'
    rime = 'ime/rime/windows/rime.dll'
    mozc = 'ime/mozc/windows/runtime/kirakara_mozc_bridge.exe'
    zinniaHeader = 'ime/zinnia/windows/include/zinnia.h'
    zinniaDebug = 'ime/zinnia/windows/lib/Debug/kirakara_zinnia.lib'
    zinniaRelease = 'ime/zinnia/windows/lib/Release/kirakara_zinnia.lib'
    zinniaProvenance = 'ime/zinnia/windows/provenance.json'
  }
  $paths = [ordered]@{}
  foreach ($entry in $relative.GetEnumerator()) {
    $path = [Kirakara.Artifacts.Security]::Child($RuntimeRoot, $entry.Value)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "IME 原生运行包缺少必需文件：$($entry.Value)"
    }
    $paths[$entry.Key] = $path
  }
  $actualFiles = @(Get-ChildItem -LiteralPath $RuntimeRoot -Recurse -File |
      ForEach-Object {
        (Get-KirakaraRelativePath `
          -BasePath $RuntimeRoot -Path $_.FullName).Replace('\', '/')
      } | Sort-Object)
  $expectedFiles = @($relative.Values | Sort-Object)
  if ($actualFiles.Count -ne $expectedFiles.Count -or
      (Compare-Object $actualFiles $expectedFiles)) {
    throw 'IME runtime 目录包含未审核文件或缺少文件。'
  }

  $identity = $Expected.identity
  $rimePe = [Kirakara.Artifacts.PeReader]::Read($paths.rime)
  if ($rimePe.Machine -ne 0x8664 -or -not $rimePe.IsDll) {
    throw 'Rime 运行库不是 Windows x64 DLL。'
  }
  foreach ($export in @($identity.rime.dll.requiredExports)) {
    if ($rimePe.Exports -cnotcontains $export) {
      throw "Rime 运行库缺少 Runner ABI 导出：$export"
    }
  }
  $mozcPe = [Kirakara.Artifacts.PeReader]::Read($paths.mozc)
  if ($mozcPe.Machine -ne 0x8664 -or $mozcPe.IsDll) {
    throw 'Mozc 桥接不是 Windows x64 可执行文件。'
  }
  Assert-ZinniaLibraryContract $paths.zinniaDebug Debug
  Assert-ZinniaLibraryContract $paths.zinniaRelease Release

  Assert-ArtifactFile $paths.rime $identity.rime.dll
  Assert-ArtifactFile $paths.mozc $identity.mozc.executable
  Assert-ArtifactFile $paths.zinniaHeader $identity.zinnia.header
  Assert-ArtifactFile $paths.zinniaDebug $identity.zinnia.debugLibrary
  Assert-ArtifactFile $paths.zinniaRelease $identity.zinnia.releaseLibrary
  Assert-ArtifactFile $paths.zinniaProvenance $identity.zinnia.provenance

  $provenance = Get-Content -Raw -LiteralPath $paths.provenance -Encoding utf8 |
    ConvertFrom-Json
  if ($provenance.schemaVersion -ne 2 -or
      $provenance.kind -cne 'ime-runtime' -or
      $provenance.identityHash -cne $Expected.value -or
      (Get-ArtifactTextHash (
        $provenance.identity | ConvertTo-Json -Depth 20 -Compress)) -cne
        $Expected.value) {
    throw 'IME runtime provenance 与锁定身份不匹配。'
  }
  Assert-NativeRuntimeHostPaths $paths.provenance
  Assert-NativeRuntimeHostPaths $paths.mozc
  Assert-NativeRuntimeHostPaths $paths.zinniaHeader
  Assert-NativeRuntimeHostPaths $paths.zinniaProvenance
  Assert-NativeRuntimeHostPaths $paths.rime `
    -AllowedAbsolutePrefixes @($identity.rime.dll.upstreamBuildPathPrefixes)

  $rimeProbe = Join-Path $script:RepositoryRoot `
    'native/scripts/probe_librime.ps1'
  $rimeReport = Join-Path $script:RepositoryRoot (
    '.kfe/tmp/ime-runtime-rime-' + [Guid]::NewGuid().ToString('N') + '.json')
  try {
    & $rimeProbe -DllPath $paths.rime -ReportPath $rimeReport | Out-Host
  } finally {
    if (Test-Path -LiteralPath $rimeReport -PathType Leaf) {
      [Kirakara.Artifacts.Security]::NoReparse($rimeReport)
      Remove-Item -LiteralPath $rimeReport -Force
    }
  }
  Invoke-NativeRuntimeMozcProbe -Executable $paths.mozc
}

function Assert-NativeRuntimeContents {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)]$Manifest,
    [Parameter(Mandatory)]$Expected
  )
  if ((Get-ArtifactTextHash (
        $Manifest.identity | ConvertTo-Json -Depth 20 -Compress)) -cne
      $Expected.value) {
    throw 'IME 原生运行包的 ABI、工具集或依赖身份错误。'
  }
  $required = @(
    'runtime/ime-runtime-provenance.json',
    'runtime/ime/rime/windows/rime.dll',
    'runtime/ime/mozc/windows/runtime/kirakara_mozc_bridge.exe',
    'runtime/ime/zinnia/windows/include/zinnia.h',
    'runtime/ime/zinnia/windows/lib/Debug/kirakara_zinnia.lib',
    'runtime/ime/zinnia/windows/lib/Release/kirakara_zinnia.lib',
    'runtime/ime/zinnia/windows/provenance.json',
    'licenses/librime-BSD-3-Clause.txt',
    'licenses/Mozc-BSD-3-Clause.txt',
    'licenses/Zinnia-BSD-3-Clause.txt',
    'SOURCES.json'
  )
  $records = @($Manifest.files)
  if ($records.Count -ne $required.Count) {
    throw 'IME 原生运行包文件数量不符合审核白名单。'
  }
  foreach ($relative in $required) {
    if (@($records | Where-Object { $_.path -ceq $relative }).Count -ne 1) {
      throw "IME 原生运行包缺少或重复文件：$relative"
    }
  }
  foreach ($record in $records) {
    if ([string]$record.path -match
        '(?i)(^|/)(libshow_host\.dll|source|src|build|cache|models?|data)(/|$)|\.(pdb|obj)$') {
      throw "IME 原生运行包混入禁止文件或目录：$($record.path)"
    }
  }
  $sourcesPath = [Kirakara.Artifacts.Security]::Child($Root, 'SOURCES.json')
  $sources = Get-Content -Raw -LiteralPath $sourcesPath -Encoding utf8 |
    ConvertFrom-Json
  if ((Get-ArtifactTextHash (
        $sources | ConvertTo-Json -Depth 20 -Compress)) -cne
      $Expected.value) {
    throw 'IME 原生运行包来源清单与当前仓库不匹配。'
  }
  Assert-NativeRuntimeHostPaths $sourcesPath
  foreach ($license in @(
      @{ package = 'licenses/librime-BSD-3-Clause.txt'; record = $Expected.identity.rime.license },
      @{ package = 'licenses/Mozc-BSD-3-Clause.txt'; record = $Expected.identity.mozc.license },
      @{ package = 'licenses/Zinnia-BSD-3-Clause.txt'; record = $Expected.identity.zinnia.license })) {
    Assert-ArtifactFile `
      ([Kirakara.Artifacts.Security]::Child($Root, $license.package)) `
      $license.record
  }
  Assert-NativeRuntimeDirectory -RuntimeRoot (Join-Path $Root 'runtime') `
    -Expected $Expected
}

function Get-NativeRuntimeSelectedRecord {
  param([Parameter(Mandatory)]$Expected)
  $path = Join-Path $script:RepositoryRoot `
    '.kfe/state/ime-runtime-selection.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  [Kirakara.Artifacts.Security]::NoReparse($path)
  $selection = Get-Content -Raw -LiteralPath $path -Encoding utf8 |
    ConvertFrom-Json
  if ($selection.schemaVersion -ne 2 -or
      $selection.kind -cne 'prebuilt' -or
      $selection.identityHash -cne $Expected.value -or
      $null -eq $selection.entry -or
      $selection.entry.identityHash -cne $Expected.value) {
    throw '仓库内 IME 原生运行包选择已经过期；请重新准备预编译包。'
  }
  return $selection
}

function Write-NativeRuntimeSelection {
  param(
    [Parameter(Mandatory)]$Expected,
    [Parameter(Mandatory)]$Entry
  )
  if ($Entry.identityHash -cne $Expected.value) {
    throw 'IME 原生运行包候选锁缺少匹配身份。'
  }
  $state = Join-Path $script:RepositoryRoot '.kfe/state'
  $null = New-Item -ItemType Directory -Path $state -Force
  $path = Join-Path $state 'ime-runtime-selection.json'
  [Kirakara.Artifacts.Security]::NoReparse($path)
  $record = [ordered]@{
    schemaVersion = 2
    kind = 'prebuilt'
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
    '.ime-runtime-selection-' + [Guid]::NewGuid().ToString('N') + '.tmp')
  try {
    [IO.File]::WriteAllText(
      $temporary,
      ($record | ConvertTo-Json -Depth 6),
      [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $path -Force
  } finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
      Remove-Item -LiteralPath $temporary -Force
    }
  }
}

function Ensure-NativeRuntimePackage {
  param([string]$Package, [string]$LockPath, [switch]$ForcePrebuilt)
  $expected = Get-NativeRuntimeIdentity
  $selection = $null
  if (-not $ForcePrebuilt -and
      [string]::IsNullOrWhiteSpace($Package) -and
      [string]::IsNullOrWhiteSpace($LockPath) -and
      [string]::IsNullOrWhiteSpace(
        [Environment]::GetEnvironmentVariable(
          'KIRAKARA_NATIVE_RUNTIME_LOCK', 'Process'))) {
    $selection = Get-NativeRuntimeSelectedRecord -Expected $expected
  }
  if ($null -ne $selection) {
    $entrySelection = [pscustomobject]@{
      entry = $selection.entry
      expected = $expected
    }
  } else {
    $entrySelection = Get-NativeRuntimeEntry -LockPath $LockPath
  }
  $workspace = Join-Path $script:RepositoryRoot '.kfe'
  $destination = Join-Path $workspace (
    'prebuilt/ime-runtime/' + $expected.value)
  $runtimeModule = $ExecutionContext.SessionState.Module
  $verify = {
    param($root, $manifest)
    & $runtimeModule {
      param($root, $manifest, $expected)
      Assert-NativeRuntimeContents $root $manifest $expected
    } $root $manifest $expected
  }.GetNewClosure()
  $root = Install-ArtifactPackage -Workspace $workspace `
    -Destination $destination -Kind ime-runtime `
    -IdentityHash $expected.value -Entry $entrySelection.entry `
    -Verify $verify -LocalArchive $Package -MaxExpandedBytes 268435456
  if ($null -eq $selection) {
    Write-NativeRuntimeSelection -Expected $expected `
      -Entry $entrySelection.entry
  }
  return [pscustomobject]@{
    kind = 'prebuilt'
    root = $root
    runtime = Join-Path $root 'runtime'
    identityHash = $expected.value
  }
}

function Invoke-KirakaraNativeCommand {
  param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments)
  if ($Arguments.Count -eq 0 -or $Arguments[0] -eq 'status') {
    $expected = Get-NativeRuntimeIdentity
    $selection = Get-NativeRuntimeSelectedRecord -Expected $expected
    [ordered]@{
      kind = 'ime-runtime'
      identityHash = $expected.value
      selected = $null -ne $selection
      selectedKind = if ($null -eq $selection) { $null } else { 'prebuilt' }
      formalReleasePublished = $false
    } | ConvertTo-Json | Write-Host
    return 0
  }
  if ($Arguments[0] -ne 'prepare') {
    throw '原生命令：native status，或 native prepare [--package ZIP] [--lock 候选锁]。'
  }
  $package = $null
  $lockPath = $null
  for ($index = 1; $index -lt $Arguments.Count; $index++) {
    $option = $Arguments[$index]
    if ($option -notin @('--package', '--lock') -or
        $index + 1 -ge $Arguments.Count) {
      throw '未知或缺少路径的 IME 原生运行包准备参数。'
    }
    $index++
    if ($option -eq '--package') { $package = $Arguments[$index] }
    else { $lockPath = $Arguments[$index] }
  }
  $null = Ensure-NativeRuntimePackage -Package $package `
    -LockPath $lockPath -ForcePrebuilt
  Write-Host '[Kirakara] IME 原生运行包已校验并准备；没有执行源码构建。'
  return 0
}

Export-ModuleMember -Function @(
  'Get-NativeRuntimeIdentity',
  'Get-NativeRuntimeEntry',
  'Get-NativeRuntimeAbsolutePaths',
  'Get-CoffArchiveMachines',
  'Assert-ZinniaLibraryContract',
  'Assert-NativeRuntimeDirectory',
  'Assert-NativeRuntimeContents',
  'Ensure-NativeRuntimePackage',
  'Invoke-KirakaraNativeCommand')
