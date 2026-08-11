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
$bundlePath = Join-Path $hostPath 'build\windows-bundle'
$hostExecutable = Join-Path $bundlePath 'qiyu_windows_host.exe'
$bundleWebPath = Join-Path $bundlePath 'web'

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
  Invoke-Step 'Flutter Web build' { flutter build web --no-web-resources-cdn }
  $flutterBootstrap = Get-Content -Raw -Encoding UTF8 'build\web\flutter_bootstrap.js'
  if ($flutterBootstrap -notmatch '"useLocalCanvasKit":true') {
    throw 'Flutter Web build is not configured to use its bundled CanvasKit'
  }
  foreach ($resource in @(
    'canvaskit\canvaskit.js',
    'canvaskit\canvaskit.wasm',
    'assets\assets\fonts\NotoSansSC-QiyuBaseline.ttf',
    'assets\assets\fonts\OFL-NotoSansSC.txt'
  )) {
    if (-not (Test-Path (Join-Path 'build\web' $resource))) {
      throw "Flutter Web build is missing local resource: $resource"
    }
  }
  Write-Host '==> Flutter Web bundled resource check passed'
} finally {
  Pop-Location
}

Push-Location $hostPath
try {
  Invoke-Step 'Windows host dependencies' { dart pub get }
  Invoke-Step 'Windows host analysis' { dart analyze }
  Invoke-Step 'Windows host tests' { dart test }
  Invoke-Step 'Windows bundle build' {
    & (Join-Path $repositoryRoot 'scripts\build-windows-bundle.ps1') `
      -SkipFlutterBuild
  }
  if (-not (Test-Path -LiteralPath (Join-Path $bundleWebPath 'index.html'))) {
    throw 'Windows bundle does not contain Flutter Web assets'
  }

  Push-Location ([IO.Path]::GetTempPath())
  try {
    $preflightOutput = & $hostExecutable --check
  } finally {
    Pop-Location
  }
  if ($LASTEXITCODE -ne 0) {
    throw "Windows host preflight failed with exit code $LASTEXITCODE"
  }
  $preflight = $preflightOutput | ConvertFrom-Json
  if (-not $preflight.ready) {
    throw 'Windows host preflight reported ready=false'
  }
  Write-Host '==> Windows host preflight passed'

  $smokeOutput = Join-Path $hostPath '.dart_tool\bundle-smoke.stdout.txt'
  $smokeError = Join-Path $hostPath '.dart_tool\bundle-smoke.stderr.txt'
  $smokeRuntime = Join-Path $hostPath '.dart_tool\bundle-smoke-runtime'
  $smokeMemory = Join-Path $hostPath '.dart_tool\bundle-smoke-memory'
  Remove-Item -LiteralPath $smokeOutput, $smokeError -Force `
    -ErrorAction SilentlyContinue
  $smokeProcess = $null
  try {
    $smokeProcess = Start-Process -FilePath $hostExecutable `
      -ArgumentList @(
        '--no-browser',
        '--runtime-dir', $smokeRuntime,
        '--memory-dir', $smokeMemory
      ) `
      -WorkingDirectory ([IO.Path]::GetTempPath()) -WindowStyle Hidden `
      -RedirectStandardOutput $smokeOutput `
      -RedirectStandardError $smokeError -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
      Start-Sleep -Milliseconds 200
      $smokeText = if (Test-Path -LiteralPath $smokeOutput) {
        [string](Get-Content -Raw -Encoding UTF8 $smokeOutput)
      } else {
        ''
      }
      $launchUrl = [regex]::Match(
        $smokeText,
        'http://127\.0\.0\.1:\d+/_session/start\?token=[A-Za-z0-9_-]+'
      ).Value
    } while (
      -not $launchUrl -and
      -not $smokeProcess.HasExited -and
      [DateTime]::UtcNow -lt $deadline
    )
    if (-not $launchUrl) {
      $errorText = if (Test-Path -LiteralPath $smokeError) {
        [string](Get-Content -Raw -Encoding UTF8 $smokeError)
      } else {
        ''
      }
      throw "Windows bundle did not publish a launch URL: $errorText"
    }
    $webSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $page = Invoke-WebRequest -Uri $launchUrl -WebSession $webSession `
      -MaximumRedirection 5 -UseBasicParsing
    if (
      $page.StatusCode -ne 200 -or
      $page.Content -notmatch 'flutter_bootstrap\.js'
    ) {
      throw 'Windows bundle did not serve the Flutter application page'
    }
    Write-Host '==> Windows bundle launch smoke test passed'
  } finally {
    if ($smokeProcess -and -not $smokeProcess.HasExited) {
      if ($smokeProcess.Path -ne $hostExecutable) {
        throw 'Refusing to stop an unexpected smoke-test process'
      }
      Stop-Process -Id $smokeProcess.Id
      $smokeProcess.WaitForExit()
    }
  }
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
