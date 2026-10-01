[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ValidShowHostDll,
  [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $PSScriptRoot 'show_host_input.psm1') `
  -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'project_engine_bootstrap.psm1') `
  -Force -DisableNameChecking

function Expect-Rejection {
  param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory)][scriptblock]$Action)
  try {
    & $Action
  } catch {
    return [ordered]@{ name = $Name; rejected = $true; message = $_.Exception.Message }
  }
  throw "负向场景没有被拒绝：$Name"
}

$source = $ExecutionContext.SessionState.Path.
  GetUnresolvedProviderPathFromPSPath($ValidShowHostDll)
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
  throw "有效 Show DLL 不存在：$source"
}
$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temporary = Join-Path $temporaryParent (
  'Kirakara 外部 Show 契约-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporary
$beforeProcess = [Environment]::GetEnvironmentVariable(
  'KIRAKARA_SHOW_HOST_DLL', 'Process')
$beforeUser = [Environment]::GetEnvironmentVariable(
  'KIRAKARA_SHOW_HOST_DLL', 'User')
$beforeMachine = [Environment]::GetEnvironmentVariable(
  'KIRAKARA_SHOW_HOST_DLL', 'Machine')

try {
  $first = Join-Path $temporary '包厢 一 libshow_host.dll'
  $second = Join-Path $temporary '包厢 二 libshow_host.dll'
  Copy-Item -LiteralPath $source -Destination $first
  Copy-Item -LiteralPath $source -Destination $second

  $localConfiguration = Join-Path $temporary 'kirakara.local.json'
  [ordered]@{
    schemaVersion = 1
    windows = [ordered]@{ showHostDll = $first }
  } | ConvertTo-Json -Depth 4 | Set-Content `
    -LiteralPath $localConfiguration -Encoding utf8

  Remove-Item Env:\KIRAKARA_SHOW_HOST_DLL -ErrorAction SilentlyContinue
  $configuredResult = Resolve-KirakaraShowHostInput `
    -ConfigPath $localConfiguration
  if ($configuredResult.path -cne (Resolve-Path -LiteralPath $first).Path -or
      $configuredResult.source -cne 'repository-local-config') {
    throw 'Show 本机配置没有选择配置中的 DLL。'
  }

  $env:KIRAKARA_SHOW_HOST_DLL = $second
  $environmentResult = Resolve-KirakaraShowHostInput `
    -ConfigPath $localConfiguration
  if ($environmentResult.path -cne (Resolve-Path -LiteralPath $second).Path -or
      $environmentResult.source -cne 'environment') {
    throw 'Show 进程环境变量没有覆盖本机配置。'
  }

  $parameterResult = Resolve-KirakaraShowHostInput -Path $first `
    -ConfigPath $localConfiguration
  if ($parameterResult.path -cne (Resolve-Path -LiteralPath $first).Path -or
      $parameterResult.source -cne 'parameter') {
    throw 'Show 显式参数没有覆盖环境变量和本机配置。'
  }

  $env:KIRAKARA_SHOW_HOST_DLL = $first
  $firstResult = Resolve-KirakaraShowHostInput
  $env:KIRAKARA_SHOW_HOST_DLL = $second
  $secondResult = Resolve-KirakaraShowHostInput
  if ($firstResult.path -ceq $secondResult.path -or
      $firstResult.path -cne (Resolve-Path -LiteralPath $first).Path -or
      $secondResult.path -cne (Resolve-Path -LiteralPath $second).Path) {
    throw '连续 Show 输入没有逐次采用当前进程路径。'
  }

  $rejections = @(
    Expect-Rejection -Name missing -Action {
      Resolve-KirakaraShowHostInput -Path (
        Join-Path $temporary '不存在.dll') | Out-Null
    }
    Expect-Rejection -Name relative -Action {
      Resolve-KirakaraShowHostInput -Path '.\libshow_host.dll' | Out-Null
    }
    Expect-Rejection -Name relativeConfigValue -Action {
      $relativeConfig = Join-Path $temporary 'relative.json'
      [ordered]@{
        schemaVersion = 1
        windows = [ordered]@{ showHostDll = '.\libshow_host.dll' }
      } | ConvertTo-Json -Depth 4 | Set-Content `
        -LiteralPath $relativeConfig -Encoding utf8
      Remove-Item Env:\KIRAKARA_SHOW_HOST_DLL -ErrorAction SilentlyContinue
      Resolve-KirakaraShowHostInput -ConfigPath $relativeConfig | Out-Null
    }
    Expect-Rejection -Name invalidConfigSchema -Action {
      $invalidConfig = Join-Path $temporary 'invalid-schema.json'
      '{"schemaVersion":2,"windows":{"showHostDll":"unused"}}' |
        Set-Content -LiteralPath $invalidConfig -Encoding utf8
      Remove-Item Env:\KIRAKARA_SHOW_HOST_DLL -ErrorAction SilentlyContinue
      Resolve-KirakaraShowHostInput -ConfigPath $invalidConfig | Out-Null
    }
    Expect-Rejection -Name missingInput -Action {
      Remove-Item Env:\KIRAKARA_SHOW_HOST_DLL -ErrorAction SilentlyContinue
      Resolve-KirakaraShowHostInput -ConfigPath (
        Join-Path $temporary 'missing-config.json') | Out-Null
    }
    Expect-Rejection -Name executable -Action {
      Resolve-KirakaraShowHostInput -Path (
        Join-Path $PSHOME 'pwsh.exe') | Out-Null
    }
    Expect-Rejection -Name x86 -Action {
      Resolve-KirakaraShowHostInput -Path (
        Join-Path $env:WINDIR 'SysWOW64\kernel32.dll') | Out-Null
    }
    Expect-Rejection -Name abi -Action {
      Resolve-KirakaraShowHostInput -Path (
        Join-Path $env:WINDIR 'System32\kernel32.dll') | Out-Null
    }
  )

  $pubPlan = Get-KirakaraFlutterInvocationPlan -Arguments @('pub', 'get')
  $otherPlan = Get-KirakaraFlutterInvocationPlan `
    -Arguments @('run', '-d', 'chrome')
  if (-not $pubPlan.needsEngine -or $pubPlan.injectEngine -or
      $otherPlan.needsEngine -or $otherPlan.injectEngine) {
    throw 'pub get 或非 Windows 命令错误进入 Show/IME 注入路径。'
  }

  $bootstrap = Get-Content -Raw -LiteralPath (
    Join-Path $PSScriptRoot 'project_engine_bootstrap.psm1')
  $invokeStart = $bootstrap.IndexOf('function Invoke-KirakaraFlutter')
  $invokeBody = $bootstrap.Substring($invokeStart)
  $showIndex = $invokeBody.IndexOf('Resolve-KirakaraShowHostInput')
  $engineIndex = $invokeBody.IndexOf('Get-KirakaraSelectedEngine')
  $imeIndex = $invokeBody.IndexOf('Ensure-NativeRuntimePackage')
  if ($invokeStart -lt 0 -or $showIndex -lt 0 -or
      $showIndex -ge $engineIndex -or $engineIndex -ge $imeIndex) {
    throw 'Windows wrapper 没有按 Show、Engine、IME 的顺序执行。'
  }

  $cmake = Get-Content -Raw -LiteralPath (
    Join-Path $repository 'windows/CMakeLists.txt')
  foreach ($required in @(
      'unset(KIRAKARA_SHOW_HOST_DLL CACHE)',
      '$ENV{KIRAKARA_SHOW_HOST_DLL}',
      'The App does not search, download, or build Show.')) {
    if (-not $cmake.Contains($required)) {
      throw "Windows CMake 缺少 Show 外部输入契约：$required"
    }
  }
  if ($cmake.Contains('_KIRAKARA_BUNDLED_SHOW_HOST_DLL')) {
    throw 'Windows CMake 仍允许从 App 原生包回退 Show。'
  }

  $exampleConfig = Join-Path $repository `
    'config/kirakara.local.example.json'
  $gitIgnore = Get-Content -Raw -LiteralPath (
    Join-Path $repository '.gitignore')
  if (-not (Test-Path -LiteralPath $exampleConfig -PathType Leaf) -or
      -not $gitIgnore.Contains('/config/kirakara.local.json')) {
    throw '仓库缺少 Show 本机配置模板或忽略规则。'
  }

  if ([Environment]::GetEnvironmentVariable(
        'KIRAKARA_SHOW_HOST_DLL', 'User') -cne $beforeUser -or
      [Environment]::GetEnvironmentVariable(
        'KIRAKARA_SHOW_HOST_DLL', 'Machine') -cne $beforeMachine) {
    throw 'Show 输入检查修改了用户或系统环境变量。'
  }

  $report = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTime]::UtcNow.ToString('o')
    externalUnicodeAndSpacePaths = $true
    consecutivePathsUseCurrentInput = $true
    repositoryLocalConfig = $true
    inputPrecedence = @('parameter', 'environment', 'repository-local-config')
    validDllSha256 = [string]$firstResult.sha256
    pubGetChecksShowOrIme = $false
    nonWindowsChecksShowOrIme = $false
    wrapperOrder = @('show', 'engine', 'ime', 'data')
    cmakeCachesShowPath = $false
    rejections = $rejections
    userAndMachineEnvironmentUnchanged = $true
    passed = $true
  }
  if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $absoluteReport = $ExecutionContext.SessionState.Path.
      GetUnresolvedProviderPathFromPSPath($ReportPath)
    if (Test-Path -LiteralPath $absoluteReport) {
      throw "ReportPath 已存在：$absoluteReport"
    }
    $null = New-Item -ItemType Directory -Path (
      Split-Path -Parent $absoluteReport) -Force
    $report | ConvertTo-Json -Depth 8 | Set-Content `
      -LiteralPath $absoluteReport -Encoding utf8
  }
  [pscustomobject]$report
} finally {
  [Environment]::SetEnvironmentVariable(
    'KIRAKARA_SHOW_HOST_DLL', $beforeProcess, 'Process')
  if (Test-Path -LiteralPath $temporary) {
    $resolvedTemporary = (Resolve-Path -LiteralPath $temporary).Path
    $expectedPrefix = Join-Path $temporaryParent 'Kirakara 外部 Show 契约-'
    if (-not $resolvedTemporary.StartsWith(
        $expectedPrefix, [StringComparison]::Ordinal)) {
      throw "拒绝清理非预期测试目录：$resolvedTemporary"
    }
    Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
  }
}
