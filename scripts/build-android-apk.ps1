$ErrorActionPreference = 'Stop'

function Invoke-Step {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Command,
    [switch]$CollectOutput
  )

  Write-Host "==> $Name"
  $global:LASTEXITCODE = 0
  # Windows PowerShell 5.1 在 EAP=Stop 下会把 flutter/gradle 写到 stderr 的
  # 进度与诊断输出误判为致命错误；步骤内临时降级为 Continue，
  # 真实失败仍由下方 LASTEXITCODE 兜底。
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($CollectOutput) {
      $collected = @(& $Command 2>&1 | ForEach-Object { "$_" })
    } else {
      # 不收集输出：flutter 与 gradle 的进度要实时可见。
      & $Command
      $collected = @()
    }
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($LASTEXITCODE -ne 0) {
    if ($CollectOutput) {
      $collectedText = $collected -join "`n"
      throw "$Name 失败（exit code $LASTEXITCODE）`n$collectedText"
    }
    throw "$Name 失败（exit code $LASTEXITCODE）"
  }
  return $collected
}

function Get-KeyPropertyValue {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$Keys
  )

  $values = @{}
  foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
    $text = $line.Trim()
    if ($text -eq '' -or $text.StartsWith('#')) {
      continue
    }
    $separator = $text.IndexOf('=')
    if ($separator -lt 1) {
      continue
    }
    $key = $text.Substring(0, $separator).Trim()
    if ($Keys -contains $key) {
      $values[$key] = $text.Substring($separator + 1).Trim()
    }
  }
  return $values
}

function Find-ApkSigner {
  param(
    [Parameter(Mandatory = $true)][string[]]$SdkRoots
  )

  # 逐个 SDK 根试到底：某个根的 build-tools 里没有 apksigner.bat 时还要试下一个根。
  foreach ($root in $SdkRoots) {
    $buildToolsRoot = Join-Path $root 'build-tools'
    if (-not (Test-Path -LiteralPath $buildToolsRoot -PathType Container)) {
      continue
    }
    $buildTools = @(
      Get-ChildItem -LiteralPath $buildToolsRoot -Directory |
        ForEach-Object {
          $versionMatch = [regex]::Match($_.Name, '^(\d+(?:\.\d+)*)')
          if ($versionMatch.Success) {
            [pscustomobject]@{
              Directory = $_.FullName
              Version = [version] $versionMatch.Groups[1].Value
            }
          }
        } | Sort-Object Version -Descending
    )
    foreach ($candidate in $buildTools) {
      $candidatePath = Join-Path $candidate.Directory 'apksigner.bat'
      if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
        return $candidatePath
      }
    }
  }
  return $null
}

function Write-SigningGuidance {
  param(
    [Parameter(Mandatory = $true)][string]$Reason,
    [Parameter(Mandatory = $true)][string]$KeyPropertiesPath,
    [Parameter(Mandatory = $true)][string]$KeyPropertiesExamplePath
  )

  Write-Host "release 构建中止：$Reason" -ForegroundColor Red
  Write-Host ''
  Write-Host '签名身份一旦换过，覆盖安装就会被系统拒绝，只能卸载重装；'
  Write-Host '而会话与记忆全在 App 私有目录里，卸载即清空且不可逆。'
  Write-Host '所以这里宁可不构建，也绝不静默用调试钥匙签一个「看着像 release」的包。'
  Write-Host ''
  Write-Host '补齐步骤（完整版见仓库根 docs/engineering/android-release-build.md）：'
  Write-Host '  1. 自建终身签名身份，一整行直接粘贴执行（别名与口令定了就别再改）：'
  Write-Host '     keytool -genkeypair -v -keystore qiyu-release.keystore -alias qiyu -keyalg RSA -keysize 4096 -validity 10950'
  Write-Host "  2. 复制 $KeyPropertiesExamplePath 为 $KeyPropertiesPath，"
  Write-Host '     填入 storeFile / storePassword / keyAlias / keyPassword'
  Write-Host '     （key.properties 与 keystore 都已被 gitignore，口令不得入库或写进文档）。'
  Write-Host '     缺省生成的 PKCS12 不支持条目独立口令：keyPassword 要与 storePassword 同值，'
  Write-Host '     否则要到打包那一步才报 "final block not properly padded"；要用两个不同口令请加 -storetype JKS。'
  Write-Host '  3. keystore 本体在本机之外另存一份（网盘也算，介质不限），但口令不与它同处一处；'
  Write-Host '     没有自建 keystore、没记下证书指纹、没做到这一条之前，不要产出任何分发包。'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$flutterPath = Join-Path $repositoryRoot 'apps\qiyu_flutter'
$androidPath = Join-Path $flutterPath 'android'
$keyPropertiesPath = Join-Path $androidPath 'key.properties'
$keyPropertiesExamplePath = Join-Path $androidPath 'key.properties.example'
$signingKeys = @('storeFile', 'storePassword', 'keyAlias', 'keyPassword')
$sdkRoots = @(
  $env:ANDROID_HOME,
  $env:ANDROID_SDK_ROOT,
  $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Android\Sdk' })
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) }

if (-not (Test-Path -LiteralPath $keyPropertiesPath -PathType Leaf)) {
  Write-SigningGuidance `
    -Reason "缺少 $keyPropertiesPath" `
    -KeyPropertiesPath $keyPropertiesPath `
    -KeyPropertiesExamplePath $keyPropertiesExamplePath
  exit 1
}

$keyValues = Get-KeyPropertyValue -Path $keyPropertiesPath -Keys $signingKeys
$missingKeys = @($signingKeys | Where-Object { -not $keyValues[$_] })
if ($missingKeys.Count -gt 0) {
  Write-SigningGuidance `
    -Reason "$keyPropertiesPath 缺少字段：$($missingKeys -join '、')" `
    -KeyPropertiesPath $keyPropertiesPath `
    -KeyPropertiesExamplePath $keyPropertiesExamplePath
  exit 1
}

$storeFilePath = $keyValues['storeFile']
if (-not [IO.Path]::IsPathRooted($storeFilePath)) {
  # 相对路径按 android/ 解析，与 gradle 侧 rootProject.file(...) 保持一致。
  $storeFilePath = [IO.Path]::GetFullPath(
    (Join-Path $androidPath $storeFilePath)
  )
}
if (-not (Test-Path -LiteralPath $storeFilePath -PathType Leaf)) {
  Write-SigningGuidance `
    -Reason "key.properties 的 storeFile 指向的 keystore 不存在：$storeFilePath" `
    -KeyPropertiesPath $keyPropertiesPath `
    -KeyPropertiesExamplePath $keyPropertiesExamplePath
  exit 1
}

Push-Location $flutterPath
try {
  # 版本一致性：Windows 包与本次要出的 APK 共用一个对外版本号，
  # 两份 pubspec 不一致就直接失败，避免双端发布物版本分叉。
  Invoke-Step 'Version consistency across Windows and Android packages' {
    & (Join-Path $repositoryRoot 'scripts\verify-version-consistency.ps1')
  }
  Invoke-Step 'Flutter Android release APK (split per ABI)' {
    flutter build apk --release --split-per-abi
  }
} finally {
  Pop-Location
}

$flutterApkDir = Join-Path $flutterPath 'build\app\outputs\flutter-apk'
$pubspec = Get-Content -Raw -Encoding UTF8 (Join-Path $flutterPath 'pubspec.yaml')
if ($pubspec -notmatch '(?m)^version:\s*([0-9A-Za-z.+-]+)\s*$') {
  throw '读不到 apps/qiyu_flutter/pubspec.yaml 里合法的 version 字段（需为 versionName+versionCode 形式）。'
}
$pubspecVersion = $Matches[1]
if ($pubspecVersion -notmatch '^([0-9][0-9A-Za-z.]*)\+([0-9]+)$') {
  throw "pubspec.yaml version 需为 versionName+versionCode 形式，当前：$pubspecVersion"
}
$versionName = $Matches[1]
$versionCode = $Matches[2]

# --split-per-abi 按架构各出一个 APK，单个包体积小得多；产物改名成
# 「qiyu-<版本>-<ABI>-release.apk」，不会装错旧包。项目未配置 abiFilters，
# 工具链按 Flutter 缺省支持面出三种架构；调整支持面时同步改这份清单。
$expectedAbis = @('arm64-v8a', 'armeabi-v7a', 'x86_64')
# 先清掉上一轮带版本名的产物，再逐个改名，目录里留下的就是且只是本次版本的包。
Get-ChildItem -LiteralPath $flutterApkDir -File -Filter 'qiyu-*-release.apk' |
  Remove-Item -Force
$releaseApks = @()
foreach ($expectedAbi in $expectedAbis) {
  $abiApkPath = Join-Path $flutterApkDir "app-$expectedAbi-release.apk"
  if (-not (Test-Path -LiteralPath $abiApkPath -PathType Leaf)) {
    throw "构建已结束但找不到 $expectedAbi 的拆分 APK：$abiApkPath"
  }
  $versionedApkPath = Join-Path $flutterApkDir `
    "qiyu-$pubspecVersion-$expectedAbi-release.apk"
  Move-Item -LiteralPath $abiApkPath -Destination $versionedApkPath -Force
  $releaseApks += Get-Item -LiteralPath $versionedApkPath
}

foreach ($apk in $releaseApks) {
  Write-Host ('==> release APK: {0}（{1:N2} MB）' -f `
    $apk.FullName, ($apk.Length / 1MB))
}
Write-Host ('==> 版本 {0}({1})' -f $versionName, $versionCode)

$apksignerPath = Find-ApkSigner -SdkRoots $sdkRoots
if (-not $apksignerPath) {
  Write-Host '==> 未在 Android SDK build-tools 中找到 apksigner，跳过签名指纹打印。' `
    -ForegroundColor Yellow
  Write-Host '    请改用 Android Studio 的 APK Analyzer，或按文档用 keytool 直接读 keystore 核对证书指纹。'
  return
}

# 每个 ABI 的拆分包各自过一遍签名证书，指纹应完全一致（同一把 keystore）。
foreach ($apk in $releaseApks) {
  $apkPath = $apk.FullName
  # -CollectOutput：要解析指纹行，同时复用 Invoke-Step 那段 EAP 降级与退出码兜底。
  $signerOutput = Invoke-Step `
    -Name "签名证书指纹（$($apk.Name)，apksigner $apksignerPath）" `
    -Command { & $apksignerPath verify --print-certs $apkPath } `
    -CollectOutput
  $digestLines = @($signerOutput | Where-Object { $_ -match 'SHA-256 digest' })
  if ($digestLines.Count -eq 0) {
    Write-Host '==> apksigner 未报出 SHA-256 指纹，请人工核对下列原始输出：' -ForegroundColor Yellow
    Write-Host ($signerOutput -join "`n")
    return
  }
  foreach ($digestLine in $digestLines) {
    Write-Host ('    ' + $digestLine.Trim())
  }
}
Write-Host '==> 把这个指纹记进 docs/engineering/android-release-build.md 的指纹表，分发前逐项比对：'
Write-Host '    签名身份换过就装不上旧设备上的数据，只能卸载重装，而卸载会把记忆全清。'
