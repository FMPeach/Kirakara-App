#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$gate = Join-Path $root 'windows/cmake/prebuilt_zinnia_toolchain.cmake'
$cases = @(
  @{ version='19.51.36243.0'; arch='x64'; msvc='TRUE'; accepted=$true },
  @{ version='19.51.36260.0'; arch='x64'; msvc='TRUE'; accepted=$true },
  @{ version='19.51.36242.0'; arch='x64'; msvc='TRUE'; accepted=$false },
  @{ version='19.50.35719.0'; arch='x64'; msvc='TRUE'; accepted=$false },
  @{ version='19.52.1.0'; arch='x64'; msvc='TRUE'; accepted=$false },
  @{ version='19.51.36260.0'; arch='X86'; msvc='TRUE'; accepted=$false },
  @{ version='19.51.36260.0'; arch='ARM64'; msvc='TRUE'; accepted=$false },
  @{ version='19.51.36260.0'; arch='x64'; msvc='FALSE'; accepted=$false }
)
foreach ($case in $cases) {
  $savedPreference = $ErrorActionPreference
  try {
    # PS 5.1 wraps redirected native stderr as ErrorRecords; rejected fixtures
    # are expected to emit CMake errors, so inspect their exit code explicitly.
    $ErrorActionPreference = 'Continue'
    $output = & cmake "-DMSVC=$($case.msvc)" "-DCMAKE_CXX_COMPILER_ARCHITECTURE_ID=$($case.arch)" `
      "-DCMAKE_CXX_COMPILER_VERSION=$($case.version)" -P $gate 2>&1
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $savedPreference }
  if (($code -eq 0) -ne $case.accepted) { throw "Unexpected toolchain result: $($case | ConvertTo-Json -Compress) $output" }
}
Write-Host "$($cases.Count) Zinnia consumer toolchain checks passed."
exit 0
