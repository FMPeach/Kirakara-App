#Requires -Version 7.2
[CmdletBinding()]
param(
  [string]$VisualStudioPath,
  [string]$CanonicalSourceRoot,
  [string]$OutputRoot,
  [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$workspace = Join-Path $repository '.kfe'
$lock = Get-Content -Raw -LiteralPath (
  Join-Path $repository 'native/native.lock.json') | ConvertFrom-Json
$zinnia = $lock.zinnia
$buildContract = $zinnia.prebuiltBuild
$sourceNames = @(
  'character',
  'feature',
  'libzinnia',
  'param',
  'recognizer',
  'sexp',
  'svm',
  'trainer'
)

Import-Module (Join-Path $repository `
    'engine/scripts/artifact_package.psm1') -DisableNameChecking

function Get-GitLine {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string[]]$Arguments
  )
  $output = @(& git -C $Root @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) {
    throw "Git 校验失败：git -C $Root $($Arguments -join ' ')"
  }
  return ([string]$output[0]).Trim()
}

function Assert-LockedZinniaSource {
  param([Parameter(Mandatory)][string]$Root)
  $absolute = [IO.Path]::GetFullPath($Root)
  if (-not (Test-Path -LiteralPath (Join-Path $absolute '.git'))) {
    throw "Zinnia 来源不是独立 Git checkout：$absolute"
  }
  if ((Get-GitLine $absolute @('rev-parse', 'HEAD')) -cne
      [string]$zinnia.revision) {
    throw 'Zinnia 来源 revision 与锁文件不一致。'
  }
  $status = @(& git -C $absolute status --short --untracked-files=all 2>&1)
  if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) {
    throw 'Zinnia 来源包含本地修改或未跟踪文件；不会清理或继续构建。'
  }
  foreach ($relative in @('zinnia/zinnia.h', 'zinnia/COPYING') +
      @($sourceNames | ForEach-Object { "zinnia/$_.cpp" })) {
    if (-not (Test-Path -LiteralPath (Join-Path $absolute $relative) `
        -PathType Leaf)) {
      throw "Zinnia 固定构建输入缺失：$relative"
    }
  }
  $licensePath = Join-Path $absolute ([string]$zinnia.licenseFile.path)
  $licenseText = [IO.File]::ReadAllText(
    $licensePath, [Text.UTF8Encoding]::new($false))
  $licenseBytes = [Text.UTF8Encoding]::new($false).GetBytes(
    $licenseText.Replace("`r`n", "`n").Replace("`r", "`n"))
  $licenseHash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData($licenseBytes))
  if ($licenseBytes.Length -ne [long]$zinnia.licenseFile.size -or
      $licenseHash -cne [string]$zinnia.licenseFile.sha256) {
    throw 'Zinnia BSD 许可证与锁定 revision 不一致。'
  }
  return $absolute
}

function Resolve-VisualStudio {
  if ([string]::IsNullOrWhiteSpace($VisualStudioPath)) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} `
      'Microsoft Visual Studio/Installer/vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
      throw '缺少 Visual Studio Installer 的 vswhere.exe。'
    }
    $VisualStudioPath = [string](@(& $vswhere -latest -products '*' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath 2>&1) | Select-Object -First 1)
  }
  if ([string]::IsNullOrWhiteSpace($VisualStudioPath)) {
    throw '未找到带 x64 C++ 工具的 Visual Studio。'
  }
  $root = [IO.Path]::GetFullPath($VisualStudioPath)
  $toolset = Join-Path $root (
    'VC/Tools/MSVC/' + [string]$buildContract.toolsetDirectoryVersion)
  $compiler = Join-Path $toolset 'bin/Hostx64/x64/cl.exe'
  $librarian = Join-Path $toolset 'bin/Hostx64/x64/lib.exe'
  $dumpbin = Join-Path $toolset 'bin/Hostx64/x64/dumpbin.exe'
  $vcvars = Join-Path $root 'VC/Auxiliary/Build/vcvarsall.bat'
  foreach ($path in @($compiler, $librarian, $dumpbin, $vcvars)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "锁定的 v145 工具缺失：$path"
    }
  }
  if ((Get-Item -LiteralPath $compiler).VersionInfo.FileVersion -cne
        [string]$buildContract.compilerFileVersion -or
      (Get-ArtifactHash $compiler) -cne
        [string]$buildContract.compilerSha256 -or
      (Get-Item -LiteralPath $librarian).VersionInfo.FileVersion -cne
        [string]$buildContract.librarianFileVersion -or
      (Get-ArtifactHash $librarian) -cne
        [string]$buildContract.librarianSha256) {
    throw 'MSVC v145 编译器或归档器完整身份与锁文件不一致。'
  }
  $sdkInclude = Join-Path ${env:ProgramFiles(x86)} (
    'Windows Kits/10/Include/' + [string]$buildContract.windowsSdkVersion)
  if (-not (Test-Path -LiteralPath $sdkInclude -PathType Container)) {
    throw '锁定的 Windows SDK 不存在。'
  }
  return [pscustomobject]@{
    root = $root
    toolsetRoot = $toolset
    windowsSdkIncludeRoot = $sdkInclude
    compiler = $compiler
    librarian = $librarian
    dumpbin = $dumpbin
    vcvars = $vcvars
  }
}

function Get-HostSpecificStrings {
  param([Parameter(Mandatory)][string]$Path)
  $bytes = [IO.File]::ReadAllBytes($Path)
  $ascii = [Text.Encoding]::Latin1.GetString($bytes)
  $unicode = [Text.Encoding]::Unicode.GetString($bytes)
  $matches = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
  foreach ($text in @($ascii, $unicode)) {
    foreach ($match in [regex]::Matches(
        $text,
        '(?i)(?:[a-z]:\\[^\x00-\x1f<>:"|?*]{1,260}|' +
        '\\\\[a-z0-9._$ -]+\\[a-z0-9._$ -]+' +
        '(?:\\[^\x00-\x1f<>:"|?*]{1,200})?)')) {
      $null = $matches.Add($match.Value)
    }
    foreach ($token in @('.kfe', [Environment]::UserName,
        [Environment]::GetFolderPath('UserProfile'))) {
      if (-not [string]::IsNullOrWhiteSpace($token) -and
          $text.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $null = $matches.Add($token)
      }
    }
  }
  return @($matches | Sort-Object)
}

function Assert-LogicalPathsOnly {
  param([Parameter(Mandatory)][string]$Path)
  $matches = @(Get-HostSpecificStrings $Path)
  if ($matches.Count -ne 0) {
    throw "Zinnia 产物仍含宿主机专属路径：$Path；$($matches -join ' | ')"
  }
  $bytes = [IO.File]::ReadAllBytes($Path)
  $ascii = [Text.Encoding]::Latin1.GetString($bytes)
  $logicalSource = [string]$buildContract.logicalSourceRoot
  if (-not $ascii.Contains($logicalSource,
      [StringComparison]::Ordinal)) {
    throw "Zinnia 产物没有保留预期的逻辑源码路径：$logicalSource"
  }
}

function Write-ResponseFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string[]]$Arguments
  )
  $escaped = @($Arguments | ForEach-Object {
      $argument = $_.Replace('"', '\"')
      if ($argument -match '\s') { '"' + $argument + '"' } else { $argument }
    })
  [IO.File]::WriteAllText(
    $Path, ($escaped -join "`r`n"), [Text.Encoding]::Unicode)
}

function Invoke-PathMapPreflight {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)]$Tools
  )
  $probeResults = [ordered]@{}
  foreach ($entry in @(
      @{ label = 'first'; relative = 'pathmap-first/source' },
      @{ label = 'second'; relative = 'pathmap-second/deeper/source' })) {
    $sourceRoot = Join-Path $Root $entry.relative
    $buildContainer = Join-Path $Root (
      $entry.relative.Replace('/source', '/another'))
    $buildRoot = Join-Path $buildContainer (
      [string]$buildContract.logicalBuildRoot)
    $null = New-Item -ItemType Directory -Path $sourceRoot -Force
    $null = New-Item -ItemType Directory -Path $buildRoot -Force
    $source = Join-Path $sourceRoot 'probe.cpp'
    [IO.File]::WriteAllText(
      $source,
      "extern `"C`" __declspec(dllexport) const char* kz_pathmap_probe() { return __FILE__; }`r`n",
      [Text.UTF8Encoding]::new($false))
    $response = Join-Path $buildRoot 'compiler.rsp'
    Write-ResponseFile -Path $response -Arguments @(
      '/nologo', '/c', '/utf-8', '/EHsc', '/W0', '/FC', '/Z7', '/Brepro',
      '/experimental:deterministic', '/MDd',
      "/pathmap:$sourceRoot=$($buildContract.logicalSourceRoot)",
      "/pathmap:$buildRoot=$($buildContract.logicalBuildRoot)",
      "/pathmap:$($Tools.toolsetRoot)=$($buildContract.logicalToolsetRoot)",
      "/pathmap:$($Tools.windowsSdkIncludeRoot)=$($buildContract.logicalWindowsSdkRoot)"
    )
    $command = Join-Path $buildRoot 'probe.cmd'
    $stdout = Join-Path $buildRoot 'probe.stdout.log'
    $stderr = Join-Path $buildRoot 'probe.stderr.log'
    $lines = @(
      '@echo off',
      'setlocal',
      'set "VSCMD_SKIP_SENDTELEMETRY=1"',
      'call "%KZ_VCVARS%" amd64 %KZ_SDK% -vcvars_ver=%KZ_TOOLSET% >nul',
      'if errorlevel 1 exit /b %errorlevel%',
      'pushd "%KZ_BUILD_CONTAINER%"',
      'cl.exe @"%KZ_RESPONSE%" /Fo:"%KZ_LOGICAL_BUILD%\probe.obj" "%KZ_SOURCE%\probe.cpp"',
      'if errorlevel 1 exit /b %errorlevel%',
      'lib.exe /nologo /Brepro /MACHINE:X64 /OUT:"%KZ_LOGICAL_BUILD%\probe.lib" "%KZ_LOGICAL_BUILD%\probe.obj"',
      'if errorlevel 1 exit /b %errorlevel%',
      'popd',
      'exit /b 0'
    )
    [IO.File]::WriteAllText(
      $command, ($lines -join "`r`n"), [Text.Encoding]::ASCII)
    $environment = [ordered]@{
      KZ_VCVARS = $Tools.vcvars
      KZ_SDK = [string]$buildContract.windowsSdkVersion
      KZ_TOOLSET = ([string]$buildContract.toolsetDirectoryVersion `
          -replace '^(\d+\.\d+).*$', '$1')
      KZ_BUILD_CONTAINER = $buildContainer
      KZ_LOGICAL_BUILD = [string]$buildContract.logicalBuildRoot
      KZ_SOURCE = $sourceRoot
      KZ_RESPONSE = $response
    }
    $start = [Diagnostics.ProcessStartInfo]::new($env:ComSpec)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('/d', '/c', 'call', $command)) {
      $start.ArgumentList.Add($argument)
    }
    foreach ($item in $environment.GetEnumerator()) {
      $start.Environment[$item.Key] = [string]$item.Value
    }
    $process = [Diagnostics.Process]::Start($start)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(120000)) {
      $process.Kill($true)
      $process.WaitForExit()
      throw "MSVC 路径映射预检超时；诊断保留在 $buildRoot"
    }
    $outText = $outTask.GetAwaiter().GetResult()
    $errText = $errTask.GetAwaiter().GetResult()
    [IO.File]::WriteAllText($stdout, $outText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stderr, $errText, [Text.UTF8Encoding]::new($false))
    $exitCode = $process.ExitCode
    $process.Dispose()
    if ($exitCode -ne 0) {
      throw "MSVC 路径映射预检失败（$exitCode）；诊断保留在 $buildRoot"
    }
    if ($outText -match '(?i)warning\s+D9002|warning\s+D9007' -or
        $errText -match '(?i)warning\s+D9002|warning\s+D9007') {
      throw 'MSVC 路径映射预检发现确定性参数被忽略。'
    }
    $object = Join-Path $buildRoot 'probe.obj'
    $library = Join-Path $buildRoot 'probe.lib'
    foreach ($artifact in @($object, $library)) {
      Assert-LogicalPathsOnly $artifact
    }
    $libraryAscii = [Text.Encoding]::Latin1.GetString(
      [IO.File]::ReadAllBytes($library))
    if (-not $libraryAscii.Contains(
        [string]$buildContract.logicalBuildRoot,
        [StringComparison]::Ordinal)) {
      throw 'MSVC 路径映射预检未在归档中保留稳定逻辑构建路径。'
    }
    $probeResults[$entry.label] = [ordered]@{
      object = [ordered]@{
        size = (Get-Item -LiteralPath $object).Length
        sha256 = Get-ArtifactHash $object
      }
      library = [ordered]@{
        size = (Get-Item -LiteralPath $library).Length
        sha256 = Get-ArtifactHash $library
      }
    }
  }
  foreach ($kind in @('object', 'library')) {
    if ($probeResults.first[$kind].size -ne $probeResults.second[$kind].size -or
        $probeResults.first[$kind].sha256 -cne
          $probeResults.second[$kind].sha256) {
      throw "MSVC 路径映射预检的双目录 $kind 产物不一致。"
    }
  }
  return [ordered]@{
    passed = $true
    object = $probeResults.first.object
    library = $probeResults.first.library
  }
}

function Assert-ZinniaLibraryContract {
  param(
    [Parameter(Mandatory)][string]$HeadersPath,
    [Parameter(Mandatory)][string]$DirectivesPath,
    [Parameter(Mandatory)][ValidateSet('Debug', 'Release')]
      [string]$Configuration
  )
  $headers = [IO.File]::ReadAllText($HeadersPath)
  $directives = [IO.File]::ReadAllText($DirectivesPath)
  $x64Members = [regex]::Matches(
    $headers, '(?im)^\s*8664 machine \(x64\)\s*$').Count
  if ($x64Members -ne $sourceNames.Count -or
      $headers -match '(?im)^\s*14C machine \(x86\)\s*$') {
    throw "Zinnia $Configuration 静态库不是完整的 x64 归档。"
  }
  if ($Configuration -ceq 'Debug') {
    if ($directives -notmatch 'RuntimeLibrary=MDd_DynamicDebug' -or
        $directives -notmatch '(?i)/DEFAULTLIB:MSVCRTD' -or
        $directives -match 'RuntimeLibrary=MD_DynamicRelease') {
      throw 'Zinnia Debug 静态库未严格使用 /MDd。'
    }
  } else {
    if ($directives -notmatch 'RuntimeLibrary=MD_DynamicRelease' -or
        $directives -notmatch '(?i)/DEFAULTLIB:MSVCRT' -or
        $directives -match 'RuntimeLibrary=MDd_DynamicDebug') {
      throw 'Zinnia Release 静态库未严格使用 /MD。'
    }
  }
}

function Invoke-ZinniaBuild {
  param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)]$Tools
  )
  $results = [ordered]@{}
  foreach ($configuration in @('Debug', 'Release')) {
    $configRoot = Join-Path $BuildRoot $configuration
    $null = New-Item -ItemType Directory -Path $configRoot -Force
    $flags = @($buildContract.commonCompilerFlags | ForEach-Object { [string]$_ })
    $flags += if ($configuration -ceq 'Debug') {
      @($buildContract.debugCompilerFlags | ForEach-Object { [string]$_ })
    } else {
      @($buildContract.releaseCompilerFlags | ForEach-Object { [string]$_ })
    }
    $flags += @(
      "/I$(Join-Path $SourceRoot 'zinnia')",
      "/pathmap:$SourceRoot=$($buildContract.logicalSourceRoot)",
      "/pathmap:$configRoot=$($buildContract.logicalBuildRoot)",
      "/pathmap:$($Tools.toolsetRoot)=$($buildContract.logicalToolsetRoot)",
      "/pathmap:$($Tools.windowsSdkIncludeRoot)=$($buildContract.logicalWindowsSdkRoot)"
    )
    $response = Join-Path $configRoot 'compiler.rsp'
    Write-ResponseFile -Path $response -Arguments $flags
    $stdout = Join-Path $configRoot 'build.stdout.log'
    $stderr = Join-Path $configRoot 'build.stderr.log'
    $headers = Join-Path $configRoot 'dumpbin-headers.txt'
    $directives = Join-Path $configRoot 'dumpbin-directives.txt'
    $command = Join-Path $configRoot 'build.cmd'
    $objectNames = @($sourceNames | ForEach-Object { "$_.obj" })
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('@echo off')
    $lines.Add('setlocal')
    $lines.Add('set "VSCMD_SKIP_SENDTELEMETRY=1"')
    $lines.Add('call "%KZ_VCVARS%" amd64 %KZ_SDK% -vcvars_ver=%KZ_TOOLSET% >nul')
    $lines.Add('if errorlevel 1 exit /b %errorlevel%')
    $lines.Add('pushd "%KZ_BUILD%"')
    foreach ($name in $sourceNames) {
      $lines.Add((('cl.exe @"%KZ_RESPONSE%" /Fo:{0}.obj ' +
          '"%KZ_SOURCE%\zinnia\{0}.cpp"') -f $name))
      $lines.Add('if errorlevel 1 exit /b %errorlevel%')
    }
    $libraryFlags = @($buildContract.librarianFlags | ForEach-Object {
        [string]$_ }) -join ' '
    $lines.Add(
      "lib.exe $libraryFlags /OUT:kirakara_zinnia.lib $($objectNames -join ' ')")
    $lines.Add('if errorlevel 1 exit /b %errorlevel%')
    $lines.Add('dumpbin.exe /headers kirakara_zinnia.lib > "%KZ_HEADERS%"')
    $lines.Add('if errorlevel 1 exit /b %errorlevel%')
    $lines.Add('dumpbin.exe /directives kirakara_zinnia.lib > "%KZ_DIRECTIVES%"')
    $lines.Add('if errorlevel 1 exit /b %errorlevel%')
    $lines.Add('popd')
    $lines.Add('exit /b 0')
    [IO.File]::WriteAllText(
      $command, ($lines -join "`r`n"), [Text.Encoding]::ASCII)
    $environment = [ordered]@{
      KZ_VCVARS = $Tools.vcvars
      KZ_SDK = [string]$buildContract.windowsSdkVersion
      KZ_TOOLSET = ([string]$buildContract.toolsetDirectoryVersion `
          -replace '^(\d+\.\d+).*$', '$1')
      KZ_BUILD = $configRoot
      KZ_SOURCE = $SourceRoot
      KZ_RESPONSE = $response
      KZ_HEADERS = $headers
      KZ_DIRECTIVES = $directives
    }
    $start = [Diagnostics.ProcessStartInfo]::new($env:ComSpec)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('/d', '/c', 'call', $command)) {
      $start.ArgumentList.Add($argument)
    }
    foreach ($entry in $environment.GetEnumerator()) {
      $start.Environment[$entry.Key] = [string]$entry.Value
    }
    $process = [Diagnostics.Process]::Start($start)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(900000)) {
      $process.Kill($true)
      $process.WaitForExit()
      throw "Zinnia $Label/$configuration 构建超时；诊断保留在 $configRoot"
    }
    $outText = $outTask.GetAwaiter().GetResult()
    $errText = $errTask.GetAwaiter().GetResult()
    [IO.File]::WriteAllText($stdout, $outText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stderr, $errText, [Text.UTF8Encoding]::new($false))
    $exitCode = $process.ExitCode
    $process.Dispose()
    if ($exitCode -ne 0) {
      throw "Zinnia $Label/$configuration 构建失败（$exitCode）；诊断保留在 $configRoot"
    }
    if ($outText -match '(?i)warning\s+D9002|warning\s+D9007' -or
        $errText -match '(?i)warning\s+D9002|warning\s+D9007') {
      throw "Zinnia $Label/$configuration 的确定性参数被编译器忽略。"
    }
    $library = Join-Path $configRoot 'kirakara_zinnia.lib'
    if (-not (Test-Path -LiteralPath $library -PathType Leaf)) {
      throw "Zinnia $Label/$configuration 未生成静态库。"
    }
    Assert-LogicalPathsOnly $library
    Assert-ZinniaLibraryContract -HeadersPath $headers `
      -DirectivesPath $directives -Configuration $configuration
    $results[$configuration] = [ordered]@{
      path = $library
      size = (Get-Item -LiteralPath $library).Length
      sha256 = Get-ArtifactHash $library
    }
  }
  return $results
}

function Get-FirstDifferenceOffset {
  param(
    [Parameter(Mandatory)][string]$Left,
    [Parameter(Mandatory)][string]$Right
  )
  $leftBytes = [IO.File]::ReadAllBytes($Left)
  $rightBytes = [IO.File]::ReadAllBytes($Right)
  $limit = [Math]::Min($leftBytes.Length, $rightBytes.Length)
  for ($index = 0; $index -lt $limit; $index++) {
    if ($leftBytes[$index] -ne $rightBytes[$index]) { return $index }
  }
  if ($leftBytes.Length -ne $rightBytes.Length) { return $limit }
  return -1
}

if ([string]::IsNullOrWhiteSpace($CanonicalSourceRoot)) {
  $CanonicalSourceRoot = Join-Path $workspace 'source/zinnia'
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path $workspace 'native/zinnia-prebuilt-v1'
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $ReportPath = Join-Path $repository `
    'build/diagnostics/zinnia-prebuilt-reproducibility.json'
}

$canonical = Assert-LockedZinniaSource $CanonicalSourceRoot
$tools = Resolve-VisualStudio
$output = [IO.Path]::GetFullPath($OutputRoot)
$workspacePrefix = $workspace.TrimEnd('\', '/') + '\'
if (-not $output.StartsWith(
    $workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Zinnia 预编译产物只能写入当前仓库 .kfe。'
}
if (Test-Path -LiteralPath $output) {
  throw "Zinnia 预编译输出已经存在，不覆盖：$output"
}

$runId = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' +
  [Guid]::NewGuid().ToString('N').Substring(0, 8)
$runRoot = Join-Path $workspace "tmp/zinnia-prebuilt-$runId"
$sourceA = Join-Path $runRoot 'first/source'
$sourceB = Join-Path $runRoot 'second/deeper/source'
$buildA = Join-Path $runRoot 'first/build'
$buildB = Join-Path $runRoot 'second/another/build'
$failureReport = Join-Path $runRoot 'failure.json'
$null = New-Item -ItemType Directory -Path $runRoot -Force

try {
  $pathMapProbe = Invoke-PathMapPreflight -Root $runRoot -Tools $tools
  foreach ($source in @($sourceA, $sourceB)) {
    $parent = Split-Path -Parent $source
    $null = New-Item -ItemType Directory -Path $parent -Force
    & git -c core.autocrlf=false clone --local --no-hardlinks --no-checkout `
      $canonical $source | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Zinnia 本地隔离 clone 失败。' }
    & git -C $source -c core.autocrlf=false checkout --detach `
      ([string]$zinnia.revision) | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Zinnia 固定 revision checkout 失败。' }
    $null = Assert-LockedZinniaSource $source
  }

  $first = Invoke-ZinniaBuild -Label 'first' -SourceRoot $sourceA `
    -BuildRoot $buildA -Tools $tools
  $second = Invoke-ZinniaBuild -Label 'second' -SourceRoot $sourceB `
    -BuildRoot $buildB -Tools $tools

  foreach ($configuration in @('Debug', 'Release')) {
    $left = $first[$configuration]
    $right = $second[$configuration]
    if ($left.size -ne $right.size -or $left.sha256 -cne $right.sha256) {
      $offset = Get-FirstDifferenceOffset -Left $left.path -Right $right.path
      [ordered]@{
        passed = $false
        configuration = $configuration
        first = $left
        second = $right
        firstDifferenceOffset = $offset
        diagnostic = '双目录产物不一致；未发布、未改写或放宽检查。'
      } | ConvertTo-Json -Depth 8 | Set-Content `
        -LiteralPath $failureReport -Encoding utf8
      throw "Zinnia $configuration 双目录产物不一致，首个差异偏移 $offset；诊断：$failureReport"
    }
  }

  $staged = Join-Path $runRoot 'publish'
  foreach ($configuration in @('Debug', 'Release')) {
    $destination = Join-Path $staged "$configuration/kirakara_zinnia.lib"
    $null = New-Item -ItemType Directory -Path (
      Split-Path -Parent $destination) -Force
    Copy-Item -LiteralPath $first[$configuration].path -Destination $destination
  }
  $include = Join-Path $staged 'include'
  $null = New-Item -ItemType Directory -Path $include -Force
  foreach ($item in @(
      @{ source = 'zinnia/zinnia.h'; destination = 'include/zinnia.h' },
      @{ source = [string]$zinnia.licenseFile.path; destination = 'COPYING' })) {
    $text = [IO.File]::ReadAllText(
      (Join-Path $sourceA $item.source), [Text.UTF8Encoding]::new($false))
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    [IO.File]::WriteAllText(
      (Join-Path $staged $item.destination), $normalized,
      [Text.UTF8Encoding]::new($false))
  }
  $header = Join-Path $staged 'include/zinnia.h'
  $license = Join-Path $staged 'COPYING'
  $provenance = [ordered]@{
    schemaVersion = 1
    kind = 'zinnia-windows-x64-static'
    repository = [string]$zinnia.repository
    revision = [string]$zinnia.revision
    version = [string]$zinnia.version
    architecture = [string]$buildContract.architecture
    platformToolset = [string]$buildContract.platformToolset
    toolsetDirectoryVersion = [string]$buildContract.toolsetDirectoryVersion
    compiler = [ordered]@{
      fileVersion = [string]$buildContract.compilerFileVersion
      sha256 = [string]$buildContract.compilerSha256
    }
    librarian = [ordered]@{
      fileVersion = [string]$buildContract.librarianFileVersion
      sha256 = [string]$buildContract.librarianSha256
    }
    windowsSdkVersion = [string]$buildContract.windowsSdkVersion
    logicalPaths = [ordered]@{
      source = [string]$buildContract.logicalSourceRoot
      build = [string]$buildContract.logicalBuildRoot
      toolset = [string]$buildContract.logicalToolsetRoot
      windowsSdk = [string]$buildContract.logicalWindowsSdkRoot
    }
    flags = [ordered]@{
      common = @($buildContract.commonCompilerFlags)
      debug = @($buildContract.debugCompilerFlags)
      release = @($buildContract.releaseCompilerFlags)
      librarian = @($buildContract.librarianFlags)
    }
    runtimeLibrary = [ordered]@{
      Debug = '/MDd'
      Release = '/MD'
      Profile = '/MD'
    }
    profileLibrary = [string]$buildContract.profileLibrary
    profileReuseExplicit = $true
    header = [ordered]@{
      size = (Get-Item -LiteralPath $header).Length
      sha256 = Get-ArtifactHash $header
    }
    license = [ordered]@{
      id = [string]$zinnia.license
      size = (Get-Item -LiteralPath $license).Length
      sha256 = Get-ArtifactHash $license
    }
    libraries = [ordered]@{
      Debug = [ordered]@{
        size = [long]$first.Debug.size
        sha256 = [string]$first.Debug.sha256
      }
      Release = [ordered]@{
        size = [long]$first.Release.size
        sha256 = [string]$first.Release.sha256
      }
    }
    reproducibility = [ordered]@{
      builds = 2
      byteIdentical = $true
      hostSpecificPathMatches = 0
      minimalPathMapProbe = $pathMapProbe
    }
  }
  [IO.File]::WriteAllText(
    (Join-Path $staged 'provenance.json'),
    ($provenance | ConvertTo-Json -Depth 12),
    [Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $staged -Destination $output
  $report = [ordered]@{
    passed = $true
    output = $output
    revision = [string]$zinnia.revision
    toolset = [string]$buildContract.platformToolset
    Debug = $provenance.libraries.Debug
    Release = $provenance.libraries.Release
    header = $provenance.header
    profileUses = [string]$buildContract.profileLibrary
    scratchRetained = $runRoot
  }
  $reportParent = Split-Path -Parent ([IO.Path]::GetFullPath($ReportPath))
  $null = New-Item -ItemType Directory -Path $reportParent -Force
  $report | ConvertTo-Json -Depth 8 | Set-Content `
    -LiteralPath $ReportPath -Encoding utf8
  Write-Host "Zinnia 双目录确定性构建通过；产物：$output"
  $report
} catch {
  if (-not (Test-Path -LiteralPath $failureReport -PathType Leaf)) {
    [ordered]@{
      passed = $false
      message = $_.Exception.Message
      scratchRetained = $runRoot
    } | ConvertTo-Json -Depth 5 | Set-Content `
      -LiteralPath $failureReport -Encoding utf8
  }
  throw
}
