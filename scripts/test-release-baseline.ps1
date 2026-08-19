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
  'scripts\verify-release-baseline.ps1',
  'scripts\verify-windows-package.ps1',
  'scripts\test-windows-package.ps1'
)
foreach ($relativePath in $requiredReleasePaths) {
  Assert-Condition (Test-Path -LiteralPath (
    Join-Path $repositoryRoot $relativePath
  ) -PathType Leaf) "Release 1 必需文件缺失：$relativePath"
}

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

Write-Host 'Release baseline policy tests passed'
