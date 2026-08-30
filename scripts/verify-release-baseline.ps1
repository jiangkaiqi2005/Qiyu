$ErrorActionPreference = 'Stop'

function Invoke-Step {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Command
  )

  Write-Host "==> $Name"
  $global:LASTEXITCODE = 0
  # Windows PowerShell 5.1 在 EAP=Stop 下会把原生命令写到 stderr 的
  # 进度与诊断输出（flutter/dart 提示、测试诊断行）误判为致命错误。
  # 步骤内临时降级为 Continue；真实失败仍由下方 LASTEXITCODE 兜底，
  # scriptblock 内显式 throw 的异常照常传播。
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $Command
  } finally {
    $ErrorActionPreference = $previousPreference
  }
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
$hostPubspec = Get-Content -Raw -Encoding UTF8 `
  (Join-Path $hostPath 'pubspec.yaml')
if ($hostPubspec -notmatch '(?m)^version:\s*([0-9A-Za-z.+-]+)\s*$') {
  throw 'Windows host pubspec.yaml is missing a valid version.'
}
$packageVersion = $Matches[1]
$packageArchive = Join-Path $hostPath `
  "build\qiyu-windows-x64-$packageVersion.zip"

Invoke-Step 'Release baseline policy tests' {
  & (Join-Path $repositoryRoot 'scripts\test-release-baseline.ps1')
}

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
  $chromeExecutable = @(
      $env:CHROME_EXECUTABLE,
      'C:\Program Files\Google\Chrome\Application\chrome.exe',
      'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
      (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
      Select-Object -First 1
  $chromiumExecutable = @(
      'C:\Program Files\Chromium\Application\chrome.exe',
      'C:\Program Files (x86)\Chromium\Application\chrome.exe',
      (Join-Path $env:LOCALAPPDATA 'Chromium\Application\chrome.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
      Select-Object -First 1
  $edgeExecutable = @(
      $env:MS_EDGE_EXECUTABLE,
      'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
      'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
      Select-Object -First 1
  $browserPlatform = if ($chromeExecutable) {
    'qiyu_chrome'
  } elseif ($chromiumExecutable) {
    'qiyu_chromium'
  } elseif ($edgeExecutable) {
    'qiyu_edge'
  }
  if (-not $browserPlatform) {
    throw 'Release 门禁需要 Chrome、Chromium 或 Edge 执行真实浏览器侧用例（语音播放、折叠状态存储）。'
  }
  Invoke-Step 'Browser-side tests' {
    dart test --configuration dart_test.browser.yaml `
      --platform $browserPlatform `
      test/voice_player_platform_web_test.dart `
      test/settings_collapse_platform_web_test.dart
  }
  Invoke-Step 'Flutter Web build' {
    flutter build web --no-web-resources-cdn
  }
  $flutterBootstrap = Get-Content -Raw -Encoding UTF8 `
    'build\web\flutter_bootstrap.js'
  if ($flutterBootstrap -notmatch '"useLocalCanvasKit":true') {
    throw 'Flutter Web build is not configured to use its bundled CanvasKit'
  }
  foreach ($resource in @(
    'canvaskit\canvaskit.js',
    'canvaskit\canvaskit.wasm',
    'assets\assets\fonts\NotoSerifSC-QiyuSubset.ttf',
    'assets\assets\fonts\OFL-NotoSerifSC.txt',
    'assets\assets\fonts\MaterialSymbolsOutlined-QiyuSubset.ttf',
    'assets\assets\fonts\APACHE-2.0-MaterialSymbolsOutlined.txt',
    'assets\assets\images\home-night-backdrop.jpg'
  )) {
    if (-not (Test-Path -LiteralPath (Join-Path 'build\web' $resource))) {
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
  Invoke-Step 'Windows package lifecycle tests' {
    & (Join-Path $repositoryRoot 'scripts\test-windows-package.ps1')
  }
  Invoke-Step 'Windows bundle build' {
    & (Join-Path $repositoryRoot 'scripts\build-windows-bundle.ps1') `
      -SkipFlutterBuild
  }
  Invoke-Step 'Windows package verification' {
    & (Join-Path $repositoryRoot 'scripts\verify-windows-package.ps1') `
      -BundlePath $bundlePath -ArchivePath $packageArchive
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

  $smokeOutput = Join-Path $hostPath `
    '.dart_tool\release-bundle-smoke.stdout.txt'
  $smokeError = Join-Path $hostPath `
    '.dart_tool\release-bundle-smoke.stderr.txt'
  $smokeRuntime = Join-Path $hostPath `
    '.dart_tool\release-bundle-smoke-runtime'
  $smokeMemory = Join-Path $hostPath `
    '.dart_tool\release-bundle-smoke-memory'
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

Write-Host '==> Release baseline verification passed without Node/npm'
