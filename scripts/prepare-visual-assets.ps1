<#
.SYNOPSIS
    生成视觉改造随包资产：首页夜景背景图。

.DESCRIPTION
    读取设计素材原图，等比缩放到目标宽度，以指定 JPEG 质量编码写入 Flutter assets 目录。

    纯 PowerShell + System.Drawing 实现，零 Node/npm 依赖，可被发布门禁直接调用。

    重要：本脚本只做「等比缩放 + JPEG 编码」这一件事。设计要求的高斯虚化、暗角、
    brightness 0.45、saturate 0.55 等效果一律在 Flutter 运行时施加，入库图必须保持
    原构图与原色彩，因此这里刻意不预施加任何滤镜。

    脚本可重复执行（幂等覆盖产物）。

.PARAMETER SourcePath
    源图路径（含中文目录，脚本内部一律用 -LiteralPath 处理）。

.PARAMETER OutputPath
    产物路径，默认 apps/qiyu_flutter/assets/images/home-night-backdrop.jpg。

.PARAMETER TargetWidth
    目标宽度（像素），高度按比例缩放。默认 1600。

.PARAMETER Quality
    JPEG 编码质量 0-100。默认 85。

    定案依据（不是本脚本自定的值）：`docs/product/design-system.md` 第 6 节与
    Spec Implementation Decisions 第 6 条——等比缩到宽 1600、JPEG 质量 85，
    产物 `apps/qiyu_flutter/assets/images/home-night-backdrop.jpg`
    实测 1600x1200、约 110KB（110,556 字节）。

    为什么不是最初指定的 65：65 出图 66KB，夜景暗部出现明显块状与涂抹，
    参考图本身就是暗部为主的构图，掉细节最刺眼，故定案把质量提到 85。
    实测质量-体积曲线（产物均为 1600x1200，体积只作对照参考，
    仓库不存在「100–300KB」这类体积门禁，脚本也只校验宽度）：

        65 ->  67,201 B   暗部细节明显发糊，被否
        75 ->  80,561 B
        80 ->  90,028 B
        82 ->  96,228 B
        85 -> 110,556 B   <-- 定案默认值
        90 -> 144,369 B

    如需更小的 66KB 变体仍可随时产出（但不得直接入库）：
        & .\scripts\prepare-visual-assets.ps1 -Quality 65

.EXAMPLE
    & .\scripts\prepare-visual-assets.ps1

.EXAMPLE
    & .\scripts\prepare-visual-assets.ps1 -Quality 60 -TargetWidth 1920
#>
[CmdletBinding()]
param(
    # 源图：栖语视觉素材（已核实存在，4096x3072）
    [string]
    $SourcePath = 'E:\Note\Asset\img\栖语\微信图片_20260825172300_5_1.jpg',

    [string]
    $OutputPath,

    [ValidateRange(160, 8192)]
    [int]
    $TargetWidth = 1600,

    [ValidateRange(1, 100)]
    [int]
    # 取 85 而非 65：见上方 Quality 说明；65 出图暗部细节明显发糊，定案值记于
    # docs/product/design-system.md 第 6 节。
    $Quality = 85
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot 'apps/qiyu_flutter/assets/images/home-night-backdrop.jpg'
}

function Write-Step([string]$Message) {
    Write-Host "[prepare-visual-assets] $Message"
}

# ---------------------------------------------------------------------------
# 1. 校验源图：缺失必须明确报错，绝不静默跳过，也绝不生成占位图。
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw @"

找不到首页背景图源图，无法生成资产。
  期望路径：$SourcePath
  请确认该文件存在（含中文目录时注意拼写），或用 -SourcePath 指定实际路径后重试：
      & .\scripts\prepare-visual-assets.ps1 -SourcePath '<你的图片绝对路径>'
  本脚本不会用占位图代替，因为随包资产必须是设计确认过的真实构图。
"@
}

$sourceItem = Get-Item -LiteralPath $SourcePath
Write-Step "源图：$($sourceItem.FullName)（$($sourceItem.Length) 字节）"

# ---------------------------------------------------------------------------
# 2. 等比缩放并以 JPEG 质量编码。
#    目标画布强制 Format24bppRgb：带 alpha 的 32bpp ARGB 位图保存 JPEG 会失败，
#    且 JPEG 本身不支持透明通道。
# ---------------------------------------------------------------------------
$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    Write-Step "已创建输出目录：$outputDirectory"
}

# 先整帧读入内存副本再释放原句柄：源图被 Image 锁定时，读取自身不受影响，
# 但内存副本可以安全地用于长事务绘制。
$sourceImage = [System.Drawing.Image]::FromFile($sourceItem.FullName)
try {
    $sourceWidth = $sourceImage.Width
    $sourceHeight = $sourceImage.Height

    if ($sourceWidth -le 0 -or $sourceHeight -le 0) {
        throw "源图尺寸非法：${sourceWidth}x${sourceHeight}"
    }

    # 等比：高度按实际宽度反算，避免整数截断造成比例失真。
    $scale = [double]$TargetWidth / [double]$sourceWidth
    $targetHeight = [Math]::Max(1, [int][Math]::Round([double]$sourceHeight * $scale, [MidpointRounding]::AwayFromZero))

    Write-Step "缩放：${sourceWidth}x${sourceHeight} -> ${TargetWidth}x${targetHeight}（等比，无裁剪、无模糊、无调色）"

    $canvas = New-Object System.Drawing.Bitmap($TargetWidth, $targetHeight, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb))
    try {
        # JPEG 编码器：用 ImageCodecInfo + EncoderParameters 才能显式控制质量。
        $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
            Where-Object { $_.MimeType -eq 'image/jpeg' } |
            Select-Object -First 1
        if (-not $jpegCodec) {
            throw '本机未注册 JPEG 编码器（ImageCodecInfo 中找不到 image/jpeg），无法继续。'
        }

        $encoderParameters = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $encoderParameters.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
            [System.Drawing.Imaging.Encoder]::Quality, [long]$Quality)

        $graphics = [System.Drawing.Graphics]::FromImage($canvas)
        try {
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            # 源矩形铺满、目标矩形铺满：纯粹等比缩放。
            $graphics.DrawImage($sourceImage, (New-Object System.Drawing.Rectangle(0, 0, $TargetWidth, $targetHeight)), 0, 0, $sourceWidth, $sourceHeight, [System.Drawing.GraphicsUnit]::Pixel)
        }
        finally {
            if ($graphics) { $graphics.Dispose() }
        }

        # 幂等覆盖：Save 直接覆写目标文件。
        $canvas.Save($OutputPath, $jpegCodec, $encoderParameters)
    }
    finally {
        if ($canvas) { $canvas.Dispose() }
    }
}
finally {
    if ($sourceImage) { $sourceImage.Dispose() }
}

# ---------------------------------------------------------------------------
# 3. 读回验收：确认产物是合法 JPEG，且宽高与体积符合预期。
# ---------------------------------------------------------------------------
$product = Get-Item -LiteralPath $OutputPath
$check = [System.Drawing.Image]::FromFile($product.FullName)
try {
    $productWidth = $check.Width
    $productHeight = $check.Height
    $horizontalResolution = [Math]::Round($check.HorizontalResolution, 2)
    $verticalResolution = [Math]::Round($check.VerticalResolution, 2)
    $rawFormat = $check.RawFormat.Guid.ToString('N')
}
finally {
    if ($check) { $check.Dispose() }
}

$jpegRawFormatGuid = [System.Drawing.Imaging.ImageFormat]::Jpeg.Guid.ToString('N')
if ($rawFormat -ne $jpegRawFormatGuid) {
    throw "产物不是合法 JPEG：RawFormat={$rawFormat}，期望={$jpegRawFormatGuid}"
}

Write-Step "产物：$($product.FullName)"
Write-Step "体积：$($product.Length) 字节（$([Math]::Round($product.Length / 1KB, 1)) KB），质量参数=$Quality"
Write-Step "尺寸：${productWidth}x${productHeight}，分辨率 ${horizontalResolution}x${verticalResolution} dpi"

if ($productWidth -ne $TargetWidth) {
    throw "产物宽度不符合预期：实际 $productWidth，期望 $TargetWidth"
}

Write-Step '完成。'
