$ErrorActionPreference = 'Stop'

function Assert-Condition {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot

$retiredProductPaths = @(
  'package.json',
  'index.html',
  'sw.js',
  'qiyu.config.example.json',
  'src',
  'test',
  'eval',
  'public',
  'scripts\dev-server.mjs',
  'scripts\run-evals.mjs',
  'scripts\verify-migration-baseline.ps1'
)
foreach ($relativePath in $retiredProductPaths) {
  $retiredPath = Join-Path $repositoryRoot $relativePath
  $hasRetiredContent = if (Test-Path -LiteralPath $retiredPath -PathType Container) {
    $null -ne (Get-ChildItem -LiteralPath $retiredPath -Recurse -File |
      Select-Object -First 1)
  } else {
    Test-Path -LiteralPath $retiredPath
  }
  Assert-Condition (-not $hasRetiredContent) "旧产品轨道仍存在：$relativePath"
}

$requiredReleasePaths = @(
  'contracts\qiyu_behavior_contracts.json',
  'packages\qiyu_behavior_core\test\qiyu_behavior_core_test.dart',
  'scripts\build-windows-bundle.ps1',
  'scripts\windows-bundle-publish.ps1',
  'scripts\test-windows-bundle-publish.ps1',
  'scripts\verify-release-baseline.ps1',
  'scripts\verify-windows-package.ps1',
  'scripts\test-windows-package.ps1'
)
foreach ($relativePath in $requiredReleasePaths) {
  Assert-Condition (Test-Path -LiteralPath (
    Join-Path $repositoryRoot $relativePath
  ) -PathType Leaf) "Release 1 必需文件缺失：$relativePath"
}

$legacyGoldenPath = Join-Path $repositoryRoot `
  'contracts\legacy-migration-golden-cases.json'
Assert-Condition (Test-Path -LiteralPath $legacyGoldenPath -PathType Leaf) `
  '冻结的 legacy migration golden 快照缺失。'
$legacyGolden = @(
  Get-Content -Raw -Encoding UTF8 $legacyGoldenPath | ConvertFrom-Json
)
# ConvertFrom-Json 对顶层数组的包装在 Windows PowerShell 5.1 与
# PowerShell 7 之间存在差异（可能得到嵌套一层的数组）；统一展平，
# 保证下方按 case 计数与比名的断言语义稳定。
if ($legacyGolden.Count -eq 1 -and $legacyGolden[0] -is [System.Array]) {
  $legacyGolden = @($legacyGolden[0])
}
$expectedLegacyGoldenNames = @(
  'low_signal_arrival',
  'fatigue_question',
  'bedtime_diminuendo',
  'earned_teasing',
  'medical_advice_safety',
  'crisis_variant_safety',
  'fatigue_friend_with_work_memory',
  'loss_soulmate_stage',
  'asking_resign_stranger',
  'asking_resign_friend'
)
Assert-Condition ($legacyGolden.Count -eq 10) `
  '冻结的 legacy migration golden 必须保持 10 个场景。'
$legacyGoldenNames = @($legacyGolden.name | Sort-Object -Unique)
$legacyGoldenNameDiff = @(
  Compare-Object `
    ($expectedLegacyGoldenNames | Sort-Object) `
    $legacyGoldenNames
)
Assert-Condition (
  $legacyGoldenNames.Count -eq 10 -and $legacyGoldenNameDiff.Count -eq 0
) '冻结的 legacy migration golden 场景标识集合发生变化。'

$contractTest = Get-Content -Raw -Encoding UTF8 (
  Join-Path $repositoryRoot `
    'packages\qiyu_behavior_core\test\qiyu_behavior_core_test.dart'
)
Assert-Condition (
  $contractTest -match 'contracts/qiyu_behavior_contracts\.json'
) 'Dart 行为核心不再消费语言无关契约 fixture。'

$buildScript = Get-Content -Raw -Encoding UTF8 (
  Join-Path $repositoryRoot 'scripts\build-windows-bundle.ps1'
)
Assert-Condition ($buildScript -notmatch 'package\.json|\bnpm\b|\bnode\b') `
  'Windows 构包脚本仍依赖 Node 产品元数据或命令。'
Assert-Condition ($buildScript -match "'pubspec\.yaml'") `
  'Windows 构包脚本没有从 Dart Host 元数据读取版本。'

& (Join-Path $repositoryRoot 'scripts\test-windows-bundle-publish.ps1')

$verificationScript = Get-Content -Raw -Encoding UTF8 (
  Join-Path $repositoryRoot 'scripts\verify-release-baseline.ps1'
)
Assert-Condition ($verificationScript -notmatch '(?im)^\s*(?:&\s*)?(?:npm|node)\b') `
  'Release 1 全量门禁仍执行 Node/npm。'
foreach ($requiredCommand in @(
  'dart analyze',
  'dart test',
  'flutter analyze',
  'flutter test',
  'flutter build web'
)) {
  Assert-Condition ($verificationScript -match [regex]::Escape($requiredCommand)) `
    "Release 1 全量门禁缺少：$requiredCommand"
}
$browserStep = [regex]::Match(
  $verificationScript,
  "Invoke-Step 'Browser-side tests' \{[\s\S]*?\n  \}"
)
Assert-Condition (
  $browserStep.Success -and
  $browserStep.Value -match 'test/voice_player_platform_web_test\.dart' -and
  $browserStep.Value -match 'test/settings_collapse_platform_web_test\.dart'
) 'Release 1 的两份浏览器侧用例必须直接挂在 Browser-side tests 步骤的命令参数里（挪进步骤外的注释或正文不算接入）。'
Assert-Condition (
  $verificationScript -match 'qiyu_edge' -and
  $verificationScript -match 'qiyu_chrome' -and
  $verificationScript -match 'qiyu_chromium'
) 'Release 1 浏览器语音播放门禁没有同时支持 Chrome/Chromium 与 Edge。'
Assert-Condition (
  $verificationScript -notmatch 'browser voice playback test skipped'
) 'Release 1 不得在没有可用浏览器时跳过语音播放测试并继续成功。'
$browserGuardBlock = [regex]::Match(
  $verificationScript,
  'if \(-not \$browserPlatform\) \{[\s\S]*?\n  \}'
)
Assert-Condition (
  $browserGuardBlock.Success -and
  $browserGuardBlock.Value -match 'throw' -and
  $browserGuardBlock.Value -match 'Chrome、Chromium 或 Edge'
) 'Release 1 的浏览器侧用例缺硬失败：探测不到可用浏览器时，必须在那个探测分支里 throw，不能探测不到就跳过当通过。'

foreach ($relativePath in @(
  'README.md',
  'AGENTS.md',
  'apps\qiyu_windows_host\README.md',
  'docs\engineering\windows-local-web-shell.md',
  'docs\engineering\windows-release-baseline.md',
  'docs\product\release-checklist.md'
)) {
  $content = Get-Content -Raw -Encoding UTF8 (Join-Path $repositoryRoot $relativePath)
  Assert-Condition ($content -notmatch '(?im)^\s*(?:npm|node)\b') `
    "当前运行文档仍给出 Node/npm 命令：$relativePath"
}

$flutterLibPath = Join-Path $repositoryRoot 'apps\qiyu_flutter\lib'
$dartFiles = Get-ChildItem -LiteralPath $flutterLibPath -Recurse -Filter '*.dart'
foreach ($file in $dartFiles) {
  $fileContent = Get-Content -Raw -Encoding UTF8 $file.FullName
  Assert-Condition ($fileContent -notmatch "fontFamily:\s*['""]monospace['""]") `
    "Flutter 代码仍指定未打包等宽字体导致 Web 远程字体回退：$($file.FullName)"
}

Write-Host 'Release baseline policy tests passed'

