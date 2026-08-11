param(
  [switch]$SkipFlutterBuild
)

$ErrorActionPreference = 'Stop'

function Invoke-Step {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [scriptblock]$Command
  )

  Write-Host "==> $Name"
  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "$Name failed with exit code $LASTEXITCODE"
  }
}

function Remove-GeneratedDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedParent
  )

  $resolvedPath = [IO.Path]::GetFullPath($Path)
  $resolvedParent = [IO.Path]::GetFullPath($ExpectedParent)
  if ([IO.Path]::GetDirectoryName($resolvedPath) -ne $resolvedParent) {
    throw "Refusing to replace unexpected bundle path: $resolvedPath"
  }
  if (Test-Path -LiteralPath $resolvedPath) {
    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
  }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$flutterPath = Join-Path $repositoryRoot 'apps\qiyu_flutter'
$hostPath = Join-Path $repositoryRoot 'apps\qiyu_windows_host'
$hostBuildPath = Join-Path $hostPath 'build'
$bundlePath = Join-Path $hostBuildPath 'windows-bundle'
$stagingParent = Join-Path $hostPath '.dart_tool'
$stagingPath = Join-Path $stagingParent 'windows-bundle-staging'
$flutterWebPath = Join-Path $flutterPath 'build\web'

if (-not $SkipFlutterBuild) {
  Push-Location $flutterPath
  try {
    Invoke-Step 'Flutter dependencies' { flutter pub get }
    Invoke-Step 'Flutter Web build' {
      flutter build web --no-web-resources-cdn
    }
  } finally {
    Pop-Location
  }
}

if (-not (Test-Path -LiteralPath (Join-Path $flutterWebPath 'index.html'))) {
  throw 'Flutter Web build is missing; run without -SkipFlutterBuild'
}

New-Item -ItemType Directory -Force -Path $hostBuildPath | Out-Null
New-Item -ItemType Directory -Force -Path $stagingParent | Out-Null
Remove-GeneratedDirectory -Path $stagingPath -ExpectedParent $stagingParent
New-Item -ItemType Directory -Path $stagingPath | Out-Null

Push-Location $hostPath
try {
  Invoke-Step 'Windows host dependencies' { dart pub get }
  Invoke-Step 'Windows host executable' {
    dart compile exe bin/qiyu_windows_host.dart `
      -o (Join-Path $stagingPath 'qiyu_windows_host.exe')
  }
} finally {
  Pop-Location
}

Copy-Item -LiteralPath $flutterWebPath `
  -Destination (Join-Path $stagingPath 'web') -Recurse
Remove-GeneratedDirectory -Path $bundlePath -ExpectedParent $hostBuildPath
Move-Item -LiteralPath $stagingPath -Destination $bundlePath

Write-Host "==> Windows bundle ready: $bundlePath"
