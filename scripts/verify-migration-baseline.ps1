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

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$corePath = Join-Path $repositoryRoot 'packages\qiyu_behavior_core'
$flutterPath = Join-Path $repositoryRoot 'apps\qiyu_flutter'
$hostPath = Join-Path $repositoryRoot 'apps\qiyu_windows_host'
$hostExecutable = Join-Path $hostPath '.dart_tool\qiyu_windows_host.exe'

Push-Location $corePath
try {
  Invoke-Step 'Dart core dependencies' { dart pub get }
  Invoke-Step 'Dart core analysis' { dart analyze }
  Invoke-Step 'Dart core contract tests' { dart test }
} finally {
  Pop-Location
}

Push-Location $flutterPath
try {
  Invoke-Step 'Flutter dependencies' { flutter pub get }
  Invoke-Step 'Flutter analysis' { flutter analyze }
  Invoke-Step 'Flutter widget tests' { flutter test }
  Invoke-Step 'Flutter Web build' { flutter build web }
} finally {
  Pop-Location
}

Push-Location $hostPath
try {
  Invoke-Step 'Windows host dependencies' { dart pub get }
  Invoke-Step 'Windows host analysis' { dart analyze }
  Invoke-Step 'Windows host tests' { dart test }
  Invoke-Step 'Windows host build' {
    dart compile exe bin/qiyu_windows_host.dart -o $hostExecutable
  }
  $preflightOutput = & $hostExecutable --check
  if ($LASTEXITCODE -ne 0) {
    throw "Windows host preflight failed with exit code $LASTEXITCODE"
  }
  $preflight = $preflightOutput | ConvertFrom-Json
  if (-not $preflight.ready) {
    throw 'Windows host preflight reported ready=false'
  }
  Write-Host '==> Windows host preflight passed'
} finally {
  Pop-Location
}

Push-Location $repositoryRoot
try {
  Invoke-Step 'JavaScript tests' { npm test }
  Invoke-Step 'Golden behavior evaluation' { npm run eval }
} finally {
  Pop-Location
}
