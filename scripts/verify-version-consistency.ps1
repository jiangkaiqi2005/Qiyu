param(
  # 缺省校验仓库内两份 pubspec；测试可注入临时文件，不必改动真源。
  [string]$HostPubspec,
  [string]$FlutterPubspec
)

$ErrorActionPreference = 'Stop'

# 双端发布物共用一个对外版本号：Windows 包取 qiyu_windows_host 的
# pubspec version，安卓 APK 取 qiyu_flutter 的 pubspec version（加号前
# 的 versionName，也是 APK 文件名里那一段）。两处不一致直接失败，
# 避免出现「Windows 是 0.1、安卓是 0.2」的分叉。版本只认 pubspec，
# 不引入第二版本源。

$repositoryRoot = Split-Path -Parent $PSScriptRoot
if (-not $HostPubspec) {
  $HostPubspec = Join-Path $repositoryRoot 'apps\qiyu_windows_host\pubspec.yaml'
}
if (-not $FlutterPubspec) {
  $FlutterPubspec = Join-Path $repositoryRoot 'apps\qiyu_flutter\pubspec.yaml'
}

function Get-PubspecVersion {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "找不到 $Label 的 pubspec：$Path"
  }
  $content = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
  if ($content -notmatch '(?m)^version:\s*([0-9A-Za-z.+-]+)\s*$') {
    throw "读不到 $Label 的 pubspec 里合法的 version 字段：$Path"
  }
  return $Matches[1]
}

$hostVersion = Get-PubspecVersion `
  -Path $HostPubspec -Label 'Windows 包（qiyu_windows_host）'
$flutterFullVersion = Get-PubspecVersion `
  -Path $FlutterPubspec -Label '安卓应用（qiyu_flutter）'

if ($flutterFullVersion -notmatch '^([0-9][0-9A-Za-z.]*)\+[0-9]+$') {
  throw "安卓 pubspec version 需为 versionName+versionCode 形式，当前：$flutterFullVersion"
}
$androidVersion = $Matches[1]

if ($hostVersion -ne $androidVersion) {
  throw (
    "Windows 包版本与 APK 版本不一致：qiyu_windows_host 是 $hostVersion，" +
    "qiyu_flutter 是 $androidVersion（完整 $flutterFullVersion）。" +
    '两份 pubspec 的版本号要一起改，改完重跑本检查。'
  )
}
Write-Host "==> 双端版本一致：$hostVersion（安卓完整 $flutterFullVersion）"
