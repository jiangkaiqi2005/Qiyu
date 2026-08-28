import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/qiyu_tokens.dart';

/// 空状态首页的夜景背景（design-system §6、Spec Implementation Decisions
/// 第 6 条）：入库图保持原构图，虚化、亮度、饱和度与左右暗角**全部运行时
/// 施加**，调参不必重新出图。仅空状态渲染，进入聊天状态后由调用方淡出。
///
/// 值是规范定值：blur 5 / brightness 0.45 / saturate 0.55 + 左右深色渐变，
/// 全部走 [QiyuBackdrop] 与 [QiyuColors] token，这里不写色值字面量。
class QiyuHomeBackdrop extends StatelessWidget {
  const QiyuHomeBackdrop({super.key});

  /// 背景图资产（`scripts/prepare-visual-assets.ps1` 的一次性产物）。
  static const String asset = 'assets/images/home-night-backdrop.jpg';

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 虚化 + 调色：模糊会从边缘透出透明，故整幅放大一档盖住。
            Transform.scale(
              scale: QiyuBackdrop.scale,
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: QiyuBackdrop.blurSigma,
                  sigmaY: QiyuBackdrop.blurSigma,
                  tileMode: ui.TileMode.decal,
                ),
                child: ImageFiltered(
                  imageFilter: _dimmedNightFilter(),
                  child: Image.asset(
                    asset,
                    fit: BoxFit.cover,
                    alignment: QiyuBackdrop.alignment,
                    filterQuality: FilterQuality.medium,
                    gaplessPlayback: true,
                    // 解码失败退成纯夜色底：首页宁可素一点，也不能裂图。
                    errorBuilder: (context, error, stack) =>
                        const ColoredBox(color: QiyuColors.night),
                  ),
                ),
              ),
            ),
            // 左右深色渐变：暗角要足，中间留一档过渡。
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    QiyuColors.backdropVeilEdge,
                    QiyuColors.backdropVeilMid,
                    QiyuColors.backdropVeilMid,
                    QiyuColors.backdropVeilEdge,
                  ],
                  stops: [0, 0.3, 0.7, 1],
                ),
              ),
            ),
            // 中心渐晕：四角再压一档，问候与输入框才立得住。
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    QiyuColors.backdropVignetteInner,
                    QiyuColors.backdropVignetteOuter,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 亮度 × 饱和度合成一张 5×4 颜色矩阵（一次滤镜完成，不叠两层）。
///
/// 每通道：`out = brightness * (saturate*in + (1-saturate)*luminance)`，
/// 亮度系数直接乘在矩阵行上即可。alpha 原样透传。
ColorFilter _dimmedNightFilter() {
  final b = QiyuBackdrop.brightness;
  final s = QiyuBackdrop.saturation;
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final keep = 1 - s;
  return ColorFilter.matrix(<double>[
    (s + keep * lr) * b, keep * lg * b, keep * lb * b, 0, 0, //
    keep * lr * b, (s + keep * lg) * b, keep * lb * b, 0, 0, //
    keep * lr * b, keep * lg * b, (s + keep * lb) * b, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);
}
