[CmdletBinding()]
param(
  [string]$LogPath
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($LogPath)) {
  $LogPath = Join-Path $PSScriptRoot 'verify-migration-baseline.txt'
}

$repositoryRoot = [IO.Path]::GetFullPath(
  (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
).TrimEnd([IO.Path]::DirectorySeparatorChar)
$resolvedLogPath = [IO.Path]::GetFullPath($LogPath)
$logParent = Split-Path -Parent $resolvedLogPath
New-Item -ItemType Directory -Force -Path $logParent | Out-Null

$redactions = @()
$redactions += ,@($repositoryRoot, '<WORKSPACE>')
$redactions += ,@($repositoryRoot.Replace('\', '/'), '<WORKSPACE>')
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
  [IO.Path]::DirectorySeparatorChar
)
$redactions += ,@($tempRoot, '<TEMP>')
$redactions += ,@($tempRoot.Replace('\', '/'), '<TEMP>')
if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
  $userProfile = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd(
    [IO.Path]::DirectorySeparatorChar
  )
  $redactions += ,@($userProfile, '<USERPROFILE>')
  $redactions += ,@($userProfile.Replace('\', '/'), '<USERPROFILE>')
}

$writer = [IO.StreamWriter]::new(
  $resolvedLogPath,
  $false,
  [Text.UTF8Encoding]::new($false)
)
Push-Location $repositoryRoot
$originalErrorActionPreference = $ErrorActionPreference
try {
  $ErrorActionPreference = 'Continue'
  & npm.cmd run verify:migration-baseline 2>&1 |
    ForEach-Object {
      $line = [string]$_
      foreach ($redaction in $redactions) {
        $line = [regex]::Replace(
          $line,
          [regex]::Escape([string]$redaction[0]),
          [string]$redaction[1],
          [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
      }
      $writer.WriteLine($line.TrimEnd())
      Write-Output $line
    }
  $verifyExitCode = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $originalErrorActionPreference
  Pop-Location
  $writer.Dispose()
}

exit $verifyExitCode
