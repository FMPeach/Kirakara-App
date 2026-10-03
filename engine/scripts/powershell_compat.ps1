function Get-KirakaraRelativePath {
  param(
    [Parameter(Mandatory = $true)][string]$BasePath,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $base = [IO.Path]::GetFullPath($BasePath)
  $target = [IO.Path]::GetFullPath($Path)
  if ($base.Equals($target, [StringComparison]::OrdinalIgnoreCase)) {
    return '.'
  }
  if (-not ([IO.Path]::GetPathRoot($base).Equals(
        [IO.Path]::GetPathRoot($target),
        [StringComparison]::OrdinalIgnoreCase))) {
    return $target
  }

  $separator = [IO.Path]::DirectorySeparatorChar
  $baseUri = [Uri]::new($base.TrimEnd('\', '/') + $separator)
  $targetUri = [Uri]::new($target)
  return [Uri]::UnescapeDataString(
    $baseUri.MakeRelativeUri($targetUri).ToString()
  ).Replace('/', $separator)
}

function Get-KirakaraSha256Hex {
  param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)

  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    return [BitConverter]::ToString($sha256.ComputeHash($Bytes)).Replace('-', '')
  } finally {
    $sha256.Dispose()
  }
}

function Get-KirakaraFileSha256 {
  param([Parameter(Mandatory = $true)][string]$Path)

  $stream = [IO.File]::OpenRead($Path)
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    return [BitConverter]::ToString(
      $sha256.ComputeHash($stream)).Replace('-', '')
  } finally {
    $sha256.Dispose()
    $stream.Dispose()
  }
}

# Windows PowerShell exposes Get-FileHash through a script module. Nested
# modules do not reliably retain that command when launched from a batch
# wrapper, so keep the SHA-256 operation local and deterministic.
function Get-FileHash {
  [CmdletBinding(DefaultParameterSetName = 'Path')]
  param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Path', Position = 0)]
    [string[]]$Path,
    [Parameter(Mandatory = $true, ParameterSetName = 'LiteralPath')]
    [Alias('PSPath')][string[]]$LiteralPath,
    [ValidateSet('SHA256')][string]$Algorithm = 'SHA256'
  )

  $items = if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') {
    @($LiteralPath | ForEach-Object { Resolve-Path -LiteralPath $_ })
  } else {
    @($Path | ForEach-Object { Resolve-Path -Path $_ })
  }
  foreach ($item in $items) {
    $providerPath = $item.ProviderPath
    if (Test-Path -LiteralPath $providerPath -PathType Container) {
      continue
    }
    [pscustomobject]@{
      Algorithm = 'SHA256'
      Hash = Get-KirakaraFileSha256 -Path $providerPath
      Path = $providerPath
    }
  }
}

function ConvertTo-KirakaraProcessArgument {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Argument)

  if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
    return $Argument
  }

  $builder = [Text.StringBuilder]::new()
  $null = $builder.Append('"')
  $backslashes = 0
  foreach ($character in $Argument.ToCharArray()) {
    if ($character -eq '\') {
      $backslashes++
      continue
    }
    if ($character -eq '"') {
      if ($backslashes -gt 0) {
        $null = $builder.Append(('\' * ($backslashes * 2)))
      }
      $null = $builder.Append('\')
      $null = $builder.Append('"')
    } else {
      if ($backslashes -gt 0) {
        $null = $builder.Append(('\' * $backslashes))
      }
      $null = $builder.Append($character)
    }
    $backslashes = 0
  }
  if ($backslashes -gt 0) {
    $null = $builder.Append(('\' * ($backslashes * 2)))
  }
  $null = $builder.Append('"')
  return $builder.ToString()
}

function Set-KirakaraProcessArguments {
  param(
    [Parameter(Mandatory = $true)]
    [Diagnostics.ProcessStartInfo]$StartInfo,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()][string[]]$Arguments
  )

  if ($null -ne $StartInfo.PSObject.Properties['ArgumentList']) {
    foreach ($argument in $Arguments) {
      $StartInfo.ArgumentList.Add($argument)
    }
    return
  }
  $StartInfo.Arguments = (@($Arguments | ForEach-Object {
        ConvertTo-KirakaraProcessArgument -Argument $_
      }) -join ' ')
}

function Set-KirakaraProcessUtf8Redirection {
  param(
    [Parameter(Mandatory = $true)]
    [Diagnostics.ProcessStartInfo]$StartInfo
  )

  # .NET Framework otherwise inherits the active console code page. Native
  # tools in this repository emit UTF-8, so a GBK console would corrupt JSON
  # before ConvertFrom-Json sees it.
  $utf8 = [Text.UTF8Encoding]::new($false)
  $StartInfo.StandardOutputEncoding = $utf8
  $StartInfo.StandardErrorEncoding = $utf8
}

function Set-KirakaraProcessEnvironmentValue {
  param(
    [Parameter(Mandatory = $true)]
    [Diagnostics.ProcessStartInfo]$StartInfo,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
  )

  # EnvironmentVariables exists in both .NET Framework 4.8 and modern .NET.
  $StartInfo.EnvironmentVariables[$Name] = $Value
}

function Stop-KirakaraProcessTree {
  param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

  try {
    if ($Process.HasExited) {
      return
    }
    $killTree = $Process.GetType().GetMethod(
      'Kill', [type[]]@([bool]))
    if ($null -ne $killTree) {
      $null = $killTree.Invoke($Process, [object[]]@($true))
      return
    }

    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    if (Test-Path -LiteralPath $taskkill -PathType Leaf) {
      & $taskkill /PID $Process.Id /T /F 2>$null | Out-Null
    }
    if (-not $Process.HasExited) {
      $Process.Kill()
    }
  } catch [InvalidOperationException] {
    # The process exited between the state check and termination request.
  }
}

function Move-KirakaraFile {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination,
    [switch]$Overwrite
  )

  if (-not $Overwrite) {
    [IO.File]::Move($Source, $Destination)
    return
  }

  $moveWithOverwrite = [IO.File].GetMethod(
    'Move', [type[]]@([string], [string], [bool]))
  if ($null -ne $moveWithOverwrite) {
    $null = $moveWithOverwrite.Invoke(
      $null, [object[]]@($Source, $Destination, $true))
  } elseif (Test-Path -LiteralPath $Destination -PathType Leaf) {
    $backup = $Destination + '.replace-backup-' + [Guid]::NewGuid().ToString('N')
    try {
      [IO.File]::Replace($Source, $Destination, $backup)
    } finally {
      if (Test-Path -LiteralPath $backup -PathType Leaf) {
        Remove-Item -LiteralPath $backup -Force
      }
    }
  } else {
    [IO.File]::Move($Source, $Destination)
  }
}
