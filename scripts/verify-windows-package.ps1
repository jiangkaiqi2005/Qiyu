[CmdletBinding()]
param(
  [string]$BundlePath,
  [string]$ArchivePath
)

$ErrorActionPreference = 'Stop'

function Get-Sha256Hex {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $stream = [IO.File]::OpenRead($Path)
  try {
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
      return ([BitConverter]::ToString(
        $sha256.ComputeHash($stream)
      )).Replace('-', '')
    } finally {
      $sha256.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
}

function Assert-Condition {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not $Condition) {
    throw $Message
  }
}

if ([string]::IsNullOrWhiteSpace($BundlePath)) {
  $BundlePath = Join-Path (Split-Path -Parent $PSScriptRoot) `
    'apps\qiyu_windows_host\build\windows-bundle'
}
$resolvedBundle = [IO.Path]::GetFullPath($BundlePath)
Assert-Condition (Test-Path -LiteralPath $resolvedBundle -PathType Container) `
  "Windows 候选包目录不存在：$resolvedBundle"

$requiredFiles = @(
  'qiyu_windows_host.exe',
  'web\index.html',
  'web\flutter_bootstrap.js',
  'web\main.dart.wasm',
  'web\main.dart.mjs',
  'web\main.dart.js',
  'web\canvaskit\skwasm.js',
  'web\canvaskit\skwasm.wasm',
  'web\canvaskit\skwasm_heavy.js',
  'web\canvaskit\skwasm_heavy.wasm',
  'web\canvaskit\canvaskit.js',
  'web\canvaskit\canvaskit.wasm',
  'web\canvaskit\chromium\canvaskit.js',
  'web\canvaskit\chromium\canvaskit.wasm',
  'web\assets\NOTICES',
  'web\assets\assets\fonts\OFL-NotoSerifSC.txt',
  'web\assets\assets\fonts\NotoSerifSC-QiyuSubset.ttf',
  'web\assets\assets\fonts\APACHE-2.0-MaterialSymbolsOutlined.txt',
  'web\assets\assets\fonts\MaterialSymbolsOutlined-QiyuSubset.ttf',
  'web\assets\assets\images\home-night-backdrop.jpg',
  'persona-constitution.md',
  'Install-Qiyu.ps1',
  'install.cmd',
  'Uninstall-Qiyu.ps1',
  'uninstall.cmd',
  'licenses\Dart-SDK-LICENSE.txt',
  'licenses\Flutter-LICENSE.txt',
  'licenses\Host-Packages-LICENSES.txt',
  'release.json'
)
foreach ($relativePath in $requiredFiles) {
  Assert-Condition (Test-Path -LiteralPath (Join-Path $resolvedBundle $relativePath)) `
    "Windows 候选包缺少：$relativePath"
}

$release = Get-Content -Raw -Encoding UTF8 `
  (Join-Path $resolvedBundle 'release.json') | ConvertFrom-Json
Assert-Condition ($release.schemaVersion -eq 1) 'release.json schemaVersion 不受支持。'
Assert-Condition ($release.product -eq 'Qiyu') 'release.json 产品标识不正确。'
Assert-Condition ($release.architecture -eq 'x64') 'Windows 候选包不是 x64。'
Assert-Condition (-not [string]::IsNullOrWhiteSpace($release.version)) `
  'release.json 缺少版本号。'

$manifestPaths = @{}
foreach ($entry in $release.files) {
  $normalizedRelative = ([string]$entry.path).Replace('/', '\')
  Assert-Condition (-not $manifestPaths.ContainsKey($normalizedRelative)) `
    "release.json 包含重复文件：$normalizedRelative"
  $manifestPaths[$normalizedRelative] = $true
  $filePath = Join-Path $resolvedBundle $normalizedRelative
  Assert-Condition (Test-Path -LiteralPath $filePath -PathType Leaf) `
    "release.json 指向不存在的文件：$normalizedRelative"
  $file = Get-Item -LiteralPath $filePath
  Assert-Condition ($file.Length -eq [long]$entry.size) `
    "候选包文件大小不匹配：$normalizedRelative"
  $actualHash = Get-Sha256Hex -Path $filePath
  Assert-Condition ($actualHash -eq [string]$entry.sha256) `
    "候选包文件哈希不匹配：$normalizedRelative"
}

$payloadFiles = Get-ChildItem -LiteralPath $resolvedBundle -Recurse -File |
  Where-Object Name -ne 'release.json'
foreach ($file in $payloadFiles) {
  $relative = $file.FullName.Substring($resolvedBundle.Length + 1)
  Assert-Condition ($manifestPaths.ContainsKey($relative)) `
    "候选包存在未进入 hash 清单的文件：$relative"
}

$executablePath = Join-Path $resolvedBundle 'qiyu_windows_host.exe'
$stream = [IO.File]::OpenRead($executablePath)
try {
  $reader = New-Object IO.BinaryReader($stream)
  Assert-Condition ($reader.ReadUInt16() -eq 0x5A4D) '宿主可执行文件不是 PE 文件。'
  $stream.Position = 0x3c
  $peOffset = $reader.ReadInt32()
  $stream.Position = $peOffset
  Assert-Condition ($reader.ReadUInt32() -eq 0x00004550) '宿主 PE 签名无效。'
  Assert-Condition ($reader.ReadUInt16() -eq 0x8664) '宿主 PE 不是 x64 架构。'
} finally {
  $stream.Dispose()
}

$bootstrapPath = Join-Path $resolvedBundle 'web\flutter_bootstrap.js'
$bootstrap = Get-Content -Raw -Encoding UTF8 $bootstrapPath
$index = Get-Content -Raw -Encoding UTF8 `
  (Join-Path $resolvedBundle 'web\index.html')
foreach ($text in @($index, $bootstrap)) {
  Assert-Condition ($text -notmatch '(?i)(src|href)\s*=\s*["'']https?://') `
    'Flutter Web 入口引用了远程静态资源。'
}

$forbiddenNames = @(
  'node.exe', 'npm.cmd', 'package.json', 'package-lock.json',
  'yarn.lock', 'pnpm-lock.yaml'
)
foreach ($name in $forbiddenNames) {
  Assert-Condition (-not (Get-ChildItem -LiteralPath $resolvedBundle -Recurse `
    -Force | Where-Object Name -eq $name)) `
    "候选包含有旧 Node 运行依赖或开发产物：$name"
}
foreach ($directoryName in @('node_modules', 'android', 'ios', 'linux', 'macos')) {
  Assert-Condition (-not (Get-ChildItem -LiteralPath $resolvedBundle -Recurse `
    -Directory -Force | Where-Object Name -eq $directoryName)) `
    "候选包含有非首发平台或开发目录：$directoryName"
}
foreach ($extension in @('.pdb', '.map', '.dart', '.so', '.dylib')) {
  Assert-Condition (-not (Get-ChildItem -LiteralPath $resolvedBundle -Recurse `
    -File | Where-Object Extension -eq $extension)) `
    "候选包含有调试或非 Windows 产物：$extension"
}

$secretPatterns = @(
  'Qiyu_API_KEY',
  'OPENAI_API_KEY',
  'ANTHROPIC_API_KEY',
  'sk-[A-Za-z0-9_-]{20,}'
)
$scanFiles = Get-ChildItem -LiteralPath $resolvedBundle -Recurse -File |
  Where-Object Extension -In @(
    '.html', '.js', '.mjs', '.json', '.md', '.txt', '.ps1', '.cmd'
  ) |
  Where-Object FullName -NotMatch '\\licenses\\' |
  Where-Object Name -ne 'NOTICES'
foreach ($file in $scanFiles) {
  $content = Get-Content -Raw -Encoding UTF8 $file.FullName
  foreach ($pattern in $secretPatterns) {
    Assert-Condition ($content -notmatch $pattern) `
      "候选包疑似含有测试密钥或开发凭据：$($file.FullName)"
  }
}

if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) {
  Assert-Condition (Test-Path -LiteralPath $ArchivePath -PathType Leaf) `
    "Windows 候选 zip 不存在：$ArchivePath"
  $archiveTestRoot = Join-Path ([IO.Path]::GetTempPath()) `
    "qiyu-package-verify-$([Guid]::NewGuid().ToString('N'))"
  try {
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $archiveTestRoot
    $archiveBundle = $archiveTestRoot
    if (-not (Test-Path -LiteralPath (Join-Path $archiveBundle 'release.json'))) {
      $children = @(Get-ChildItem -LiteralPath $archiveTestRoot)
      Assert-Condition (
        $children.Count -eq 1 -and $children[0].PSIsContainer
      ) 'Windows 候选 zip 顶层结构不明确。'
      $archiveBundle = $children[0].FullName
    }
    & $PSCommandPath -BundlePath $archiveBundle
    if (-not $?) {
      throw 'Windows 候选 zip 解包验证失败。'
    }
  } finally {
    $resolvedArchiveTestRoot = [IO.Path]::GetFullPath($archiveTestRoot)
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolvedArchiveTestRoot.StartsWith(
      $resolvedTemp,
      [StringComparison]::OrdinalIgnoreCase
    )) {
      throw "拒绝清理解包验证目录：$resolvedArchiveTestRoot"
    }
    if (Test-Path -LiteralPath $resolvedArchiveTestRoot) {
      Remove-Item -LiteralPath $resolvedArchiveTestRoot -Recurse -Force
    }
  }
}

Write-Host (
  "Windows package verification passed: version=$($release.version), " +
  "files=$($release.files.Count), architecture=x64"
)
