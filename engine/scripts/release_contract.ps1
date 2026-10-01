function Get-KirakaraReleaseArtifactContract {
  param(
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][pscustomobject]$Layout,
    [Parameter(Mandatory = $true)]$Build
  )

  if ([string]$Build.mode -ne 'release') {
    throw "A Release artifact contract cannot be selected for mode '$($Build.mode)'."
  }
  if ($Layout.Kind -ne 'repository-local') {
    return $Build
  }
  $property = $Lock.projectBootstrap.PSObject.Properties['releaseCandidate']
  if (-not $property) {
    throw 'engine.lock.json has no repository-local release candidate.'
  }
  $candidate = $property.Value
  if (
    [int]$candidate.schemaVersion -ne 1 -or
    [string]$candidate.mode -ne 'release' -or
    [string]$candidate.localEngine -ne [string]$Build.localEngine -or
    [string]$candidate.engineSourceTree -ne
      [string]$Lock.projectBootstrap.engineSourceTree -or
    [string]$candidate.argsGnSha256 -ne [string]$Build.argsGnSha256
  ) {
    throw 'Repository-local release candidate metadata is incompatible with the locked Engine build.'
  }
  $expectedPaths = @($Build.artifacts | ForEach-Object {
      [string]$_.path
    } | Sort-Object)
  $candidateArtifacts = @($candidate.artifacts)
  $candidatePaths = @($candidateArtifacts | ForEach-Object {
      [string]$_.path
    } | Sort-Object)
  if (
    $candidatePaths.Count -eq 0 -or
    $candidatePaths.Count -ne $expectedPaths.Count -or
    @($candidatePaths | Sort-Object -Unique).Count -ne $candidatePaths.Count -or
    @(Compare-Object $expectedPaths $candidatePaths).Count -ne 0
  ) {
    throw 'Repository-local release candidate artifact paths do not match the locked Release build.'
  }
  foreach ($artifact in $candidateArtifacts) {
    if (
      [string]::IsNullOrWhiteSpace([string]$artifact.path) -or
      [long]$artifact.size -lt 1 -or
      [string]$artifact.sha256 -notmatch '^[0-9A-F]{64}$'
    ) {
      throw "Repository-local release candidate artifact metadata is invalid: $($artifact.path)"
    }
  }
  return $candidate
}
