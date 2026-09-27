param(
  [switch]$SkipFlutterBuild
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'windows-bundle-publish.ps1')

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

function Get-RceditPath {
  # rcedit（Electron 出品的开源资源编辑工具）负责把归鸟图标与产品名、版本号
  # 写进宿主 exe。缓存在本机目录，只下载一次；后续构建离线也能跑。
  # 工具缺失且下载失败时明确报错并给获取指引，绝不静默跳过资源嵌入。
  $rceditVersion = '2.0.0'
  $rceditSha256 = '3e7801db1a5edbec91b49a24a094aad776cb4515488ea5a4ca2289c400eade2a'
  $downloadUrl = "https://github.com/electron/rcedit/releases/download/v$rceditVersion/rcedit-x64.exe"
  $cacheDir = Join-Path $env:LOCALAPPDATA 'qiyu-build-tools\rcedit'
  $rceditPath = Join-Path $cacheDir 'rcedit-x64.exe'
  $guidance = @(
    "rcedit（嵌入图标的资源编辑工具）不可用或校验失败：$rceditPath"
    '获取方式（二选一）：'
    "  1. 联网后重跑构建，脚本会自动从 $downloadUrl 下载并缓存到上面的路径；"
    "  2. 离线机器手动下载上述地址的 rcedit-x64.exe（v$rceditVersion，"
    "     SHA256 须为 $rceditSha256），放到 $rceditPath。"
  ) -join "`n"

  if (Test-Path -LiteralPath $rceditPath -PathType Leaf) {
    if ((Get-Sha256Hex -Path $rceditPath) -ne $rceditSha256) {
      throw "缓存的 rcedit SHA256 与预期不符，可能不完整或被改动。`n$guidance"
    }
    return $rceditPath
  }
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
  $client = $null
  $downloaded = $false
  try {
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.WebClient
    for ($attempt = 1; $attempt -le 3; $attempt++) {
      # GitHub 的 release 资产下载时常被重置，失败清掉半截文件再重试。
      if (Test-Path -LiteralPath $rceditPath -PathType Leaf) {
        Remove-Item -LiteralPath $rceditPath -Force
      }
      try {
        $client.DownloadFile($downloadUrl, $rceditPath)
        $downloaded = $true
        break
      } catch {
        Write-Host "==> rcedit 下载失败（第 $attempt 次）：$($_.Exception.Message)"
        Start-Sleep -Seconds 2
      }
    }
  } finally {
    if ($null -ne $client) {
      $client.Dispose()
    }
  }
  if (-not $downloaded) {
    throw "rcedit 下载失败。`n$guidance"
  }
  if ((Get-Sha256Hex -Path $rceditPath) -ne $rceditSha256) {
    Remove-Item -LiteralPath $rceditPath -Force
    throw "下载的 rcedit SHA256 与预期不符，已删除。`n$guidance"
  }
  return $rceditPath
}

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
$hostPubspec = Get-Content -Raw -Encoding UTF8 `
  (Join-Path $hostPath 'pubspec.yaml')
if ($hostPubspec -notmatch '(?m)^version:\s*([0-9A-Za-z.+-]+)\s*$') {
  throw 'Windows host pubspec.yaml is missing a valid version.'
}
$packageVersion = $Matches[1]
$archivePath = Join-Path $hostBuildPath "qiyu-windows-x64-$packageVersion.zip"

if (-not $SkipFlutterBuild) {
  Push-Location $flutterPath
  try {
    Invoke-Step 'Flutter dependencies' { flutter pub get }
    Invoke-Step 'Flutter Web build' {
      flutter build web --wasm --no-web-resources-cdn
    }
  } finally {
    Pop-Location
  }
}

if (-not (Test-Path -LiteralPath (Join-Path $flutterWebPath 'index.html'))) {
  throw 'Flutter Web build is missing; run without -SkipFlutterBuild'
}
foreach ($resource in @(
  'flutter_bootstrap.js',
  'main.dart.wasm',
  'main.dart.mjs',
  'main.dart.js',
  'canvaskit\skwasm.js',
  'canvaskit\skwasm.wasm',
  'canvaskit\skwasm_heavy.js',
  'canvaskit\skwasm_heavy.wasm',
  'canvaskit\canvaskit.js',
  'canvaskit\canvaskit.wasm',
  'canvaskit\chromium\canvaskit.js',
  'canvaskit\chromium\canvaskit.wasm'
)) {
  if (-not (Test-Path -LiteralPath (Join-Path $flutterWebPath $resource))) {
    throw "Flutter Web build is missing renderer resource: $resource"
  }
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

# 把归鸟图标与产品名、版本号嵌进宿主 exe：桌面不再是空白图标，
# 程序属性里能读出产品与版本。版本沿用本脚本开头解析的 host pubspec 值。
$rceditPath = Get-RceditPath
$hostExecutablePath = Join-Path $stagingPath 'qiyu_windows_host.exe'
Invoke-Step 'Windows host icon and version info' {
  & $rceditPath $hostExecutablePath `
    --set-icon (Join-Path $repositoryRoot 'design\qiyu-icon\qiyu.ico') `
    --set-version-string 'ProductName' '栖语' `
    --set-version-string 'FileDescription' '栖语' `
    --set-file-version $packageVersion `
    --set-product-version $packageVersion
}
$embeddedVersionInfo = (Get-Item -LiteralPath $hostExecutablePath).VersionInfo
Write-Host (
  '==> 嵌入完成：ProductName={0}，ProductVersion={1}' -f `
    $embeddedVersionInfo.ProductName, $embeddedVersionInfo.ProductVersion
)

Copy-Item -LiteralPath $flutterWebPath `
  -Destination (Join-Path $stagingPath 'web') -Recurse
$personaConstitutionFileName = ([char]0x6816) + ([char]0x8BED) + `
  ([char]0x4EBA) + ([char]0x683C) + ([char]0x5BAA) + ([char]0x6CD5) + '.md'
Copy-Item -LiteralPath (Join-Path $repositoryRoot $personaConstitutionFileName) `
  -Destination (Join-Path $stagingPath 'persona-constitution.md')

$packageScriptPath = Join-Path $repositoryRoot 'scripts\windows-package'
foreach ($scriptName in @(
  'Install-Qiyu.ps1',
  'install.cmd',
  'Uninstall-Qiyu.ps1',
  'uninstall.cmd'
)) {
  Copy-Item -LiteralPath (Join-Path $packageScriptPath $scriptName) `
    -Destination $stagingPath
}

$licensesPath = Join-Path $stagingPath 'licenses'
New-Item -ItemType Directory -Path $licensesPath | Out-Null
$flutterCommand = Get-Command flutter -ErrorAction Stop
$flutterRoot = Split-Path -Parent (Split-Path -Parent $flutterCommand.Source)
$flutterLicense = Join-Path $flutterRoot 'LICENSE'
$dartLicense = Join-Path $flutterRoot 'bin\cache\dart-sdk\LICENSE'
foreach ($licenseFile in @($flutterLicense, $dartLicense)) {
  if (-not (Test-Path -LiteralPath $licenseFile -PathType Leaf)) {
    throw "Required SDK license is missing: $licenseFile"
  }
}
Copy-Item -LiteralPath $flutterLicense `
  -Destination (Join-Path $licensesPath 'Flutter-LICENSE.txt')
Copy-Item -LiteralPath $dartLicense `
  -Destination (Join-Path $licensesPath 'Dart-SDK-LICENSE.txt')

$packageConfigPath = Join-Path $hostPath '.dart_tool\package_config.json'
$packageConfig = Get-Content -Raw -Encoding UTF8 $packageConfigPath |
  ConvertFrom-Json
$licenseText = New-Object Text.StringBuilder
foreach ($package in $packageConfig.packages | Sort-Object name) {
  if (-not ([string]$package.rootUri).StartsWith('file:')) {
    continue
  }
  $packageRoot = ([Uri]$package.rootUri).LocalPath
  $packageLicenses = Get-ChildItem -LiteralPath $packageRoot -File |
    Where-Object Name -Match '^(LICENSE|COPYING|NOTICE)' |
    Sort-Object Name
  if (-not $packageLicenses) {
    throw "Package license is missing: $($package.name)"
  }
  [void]$licenseText.AppendLine("===== $($package.name) =====")
  foreach ($license in $packageLicenses) {
    [void]$licenseText.AppendLine("--- $($license.Name) ---")
    [void]$licenseText.AppendLine(
      (Get-Content -Raw -Encoding UTF8 $license.FullName).TrimEnd()
    )
  }
  [void]$licenseText.AppendLine()
}
[IO.File]::WriteAllText(
  (Join-Path $licensesPath 'Host-Packages-LICENSES.txt'),
  $licenseText.ToString(),
  [Text.UTF8Encoding]::new($false)
)

$manifestFiles = @(
  Get-ChildItem -LiteralPath $stagingPath -Recurse -File |
    Sort-Object FullName |
    ForEach-Object {
      @{
        path = $_.FullName.Substring($stagingPath.Length + 1).Replace('\', '/')
        size = $_.Length
        sha256 = Get-Sha256Hex -Path $_.FullName
      }
    }
)
$release = @{
  schemaVersion = 1
  product = 'Qiyu'
  version = $packageVersion
  architecture = 'x64'
  builtAt = [DateTime]::UtcNow.ToString('o')
  files = $manifestFiles
}
[IO.File]::WriteAllText(
  (Join-Path $stagingPath 'release.json'),
  ($release | ConvertTo-Json -Depth 4),
  [Text.UTF8Encoding]::new($false)
)

Publish-WindowsBundle `
  -StagingPath $stagingPath `
  -BundlePath $bundlePath `
  -ExpectedParent $hostBuildPath

if (Test-Path -LiteralPath $archivePath) {
  if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($archivePath)) -ne `
    [IO.Path]::GetFullPath($hostBuildPath)) {
    throw "Refusing to replace unexpected archive path: $archivePath"
  }
  Remove-Item -LiteralPath $archivePath -Force
}
# 发布 zip 顶层目录用产品名「栖语」，条目名按 UTF-8 写入并置标志位
# （见 Compress-BundleArchive），中文系统解压不会乱码。
Compress-BundleArchive `
  -BundlePath $bundlePath `
  -ArchivePath $archivePath `
  -RootDirectoryName '栖语'

Write-Host "==> Windows bundle ready: $bundlePath"
Write-Host "==> Windows release archive ready: $archivePath"
