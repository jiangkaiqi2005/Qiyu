import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

/// 设计 token 层契约测试（Spec Testing Decisions 第 2、3、7 条）。
///
/// 这是紫夜视觉改造的接缝：主题层是唯一色值来源，页面只准消费它。
/// 本文件锁住三件事——
/// 1. token 的字面值与 `docs/product/design-system.md` 第 2/3/8 节一字不差；
/// 2. `ColorScheme` 每个语义槽位取的都是 token，而不是第三处写死的色值；
/// 3. 旧种子色派生（`ColorScheme.fromSeed`、`0xFF8C86B8`、`0xFF15131A`、
///    黑体字族）已从源码退场，且发布门禁脚本引用的资产名与 pubspec 一致。
///
/// 扫描一律读源码文件，不依赖任何构建产物。

const _packageRoot = '.';

String _read(String relativePath) =>
    File('$_packageRoot/$relativePath').readAsStringSync();

Iterable<File> _dartFilesUnder(String relativeDir) =>
    Directory('$_packageRoot/$relativeDir')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

void main() {
  final theme = qiyuDarkTheme();

  group('色板 token 与设计规范对齐', () {
    test('紫夜语义色值一字不差（design-system §2）', () {
      expect(QiyuColors.night.toARGB32(), 0xFF0F0E14);
      expect(QiyuColors.panel.toARGB32(), 0xFF181719);
      expect(QiyuColors.ink.toARGB32(), 0xFFECE9F2);
      expect(QiyuColors.muted.toARGB32(), 0xFF9A94A8);
      // accent-glass：rgba(75,64,146,.62) → rgba(51,43,97,.5)
      expect(QiyuColors.accentGlassA.toARGB32(), 0x9E4B4092);
      expect(QiyuColors.accentGlassB.toARGB32(), 0x80332B61);
      expect(QiyuColors.accentBright.toARGB32(), 0xFF9D8FE0);
      expect(QiyuColors.onAccent.toARGB32(), 0xFFF5F3FA);
      expect(QiyuColors.bubbleUser.toARGB32(), 0xFF28272E);
      expect(QiyuColors.line.toARGB32(), 0xFF232227);
      expect(QiyuColors.danger.toARGB32(), 0xFFCC9999);
      // 选中态中性 rgba(255,255,255,0.04)，不用紫底。
      expect(QiyuColors.selectedNeutral.toARGB32(), 0x0AFFFFFF);
    });

    test('玻璃面板由 panel 派生高透明度，不引入新色相', () {
      expect(QiyuColors.glass.a, lessThan(1.0));
      expect(QiyuColors.glass.a, greaterThan(0.0));
      expect(QiyuColors.glass.toARGB32() & 0x00FFFFFF, 0x00181719);
    });
  });

  group('ColorScheme 逐槽位消费 token', () {
    test('语义槽位全部等于对应 token', () {
      final scheme = theme.colorScheme;
      Color argb(Color color) => Color(color.toARGB32());

      expect(argb(scheme.primary), argb(QiyuColors.accentBright));
      expect(argb(scheme.onPrimary), argb(QiyuColors.onAccent));
      expect(argb(scheme.primaryContainer), argb(QiyuColors.accentGlassB));
      expect(argb(scheme.onPrimaryContainer), argb(QiyuColors.onAccent));
      // 次按钮/文字按钮：无底色，accent-bright 文字。
      expect(argb(scheme.secondary), argb(QiyuColors.accentBright));
      expect(argb(scheme.onSecondary), argb(QiyuColors.onAccent));
      expect(argb(scheme.tertiary), argb(QiyuColors.accentBright));
      // 暗红只住危险。
      expect(argb(scheme.error), argb(QiyuColors.danger));
      expect(argb(scheme.onError), argb(QiyuColors.night));
      expect(argb(scheme.surface), argb(QiyuColors.panel));
      expect(argb(scheme.onSurface), argb(QiyuColors.ink));
      expect(argb(scheme.onSurfaceVariant), argb(QiyuColors.muted));
      expect(argb(scheme.outline), argb(QiyuColors.line));
      expect(argb(scheme.outlineVariant), argb(QiyuColors.line));
      expect(argb(scheme.surfaceContainerLowest), argb(QiyuColors.night));
      expect(argb(scheme.surfaceContainerLow), argb(QiyuColors.panel));
      expect(argb(scheme.surfaceContainer), argb(QiyuColors.panel));
      expect(argb(scheme.surfaceContainerHigh), argb(QiyuColors.bubbleUser));
      expect(argb(scheme.surfaceContainerHighest), argb(QiyuColors.bubbleUser));
      expect(argb(scheme.inverseSurface), argb(QiyuColors.ink));
      expect(argb(scheme.onInverseSurface), argb(QiyuColors.night));
      expect(argb(scheme.shadow), argb(QiyuColors.night));
      expect(argb(scheme.scrim), argb(QiyuColors.night));
    });

    test('三色纪律：容器槽位不得落紫，紫只住 primary/secondary/tertiary', () {
      final scheme = theme.colorScheme;
      // 未显式赋值的容器槽位会退到 Material 默认淡紫，必须逐个压回中性。
      expect(scheme.secondaryContainer.toARGB32(), QiyuColors.panel.toARGB32());
      expect(scheme.tertiaryContainer.toARGB32(), QiyuColors.panel.toARGB32());
      expect(scheme.errorContainer.toARGB32(), QiyuColors.danger.toARGB32());
      //  elevation 色调叠加关掉：提亮靠中性面板色阶，不靠紫。
      expect(QiyuColors.elevationTint.toARGB32(), 0x00000000);
      expect(
        scheme.surfaceTint.toARGB32(),
        QiyuColors.elevationTint.toARGB32(),
      );
    });

    test('页面底色与焦点取 token（ticket 24：深色底焦点必须清晰）', () {
      expect(
        theme.scaffoldBackgroundColor.toARGB32(),
        QiyuColors.night.toARGB32(),
      );
      expect(theme.canvasColor.toARGB32(), QiyuColors.night.toARGB32());
      expect(theme.cardColor.toARGB32(), QiyuColors.panel.toARGB32());
      expect(theme.focusColor.toARGB32(), QiyuColors.accentBright.toARGB32());
      expect(theme.useMaterial3, isTrue);
    });
  });

  group('字族与字阶', () {
    test('全局唯一字族为思源宋体', () {
      expect(QiyuType.fontFamily, 'Noto Serif SC');
      expect(theme.textTheme.bodyMedium!.fontFamily, 'Noto Serif SC');
      for (final style in <TextStyle?>[
        theme.textTheme.displaySmall,
        theme.textTheme.headlineSmall,
        theme.textTheme.titleMedium,
        theme.textTheme.bodyLarge,
        theme.textTheme.bodyMedium,
        theme.textTheme.bodySmall,
        theme.textTheme.labelLarge,
        theme.textTheme.labelMedium,
        theme.textTheme.labelSmall,
      ]) {
        expect(style, isNotNull);
        expect(style!.fontFamily, 'Noto Serif SC');
      }
    });

    test('五档字阶：22/18/15/13/12，宁小勿大', () {
      expect(QiyuType.greetingSize, 22);
      expect(QiyuType.titleSize, 18);
      expect(QiyuType.bodySize, 15);
      expect(QiyuType.secondarySize, 13);
      expect(QiyuType.tinySize, 12);
      expect(QiyuTypography.greeting.fontSize, QiyuType.greetingSize);
      expect(QiyuTypography.title.fontSize, QiyuType.titleSize);
      expect(QiyuTypography.body.fontSize, QiyuType.bodySize);
      expect(QiyuTypography.secondary.fontSize, QiyuType.secondarySize);
      expect(QiyuTypography.tiny.fontSize, QiyuType.tinySize);
      expect(theme.textTheme.displaySmall!.fontSize, QiyuType.greetingSize);
      expect(theme.textTheme.headlineSmall!.fontSize, QiyuType.titleSize);
      expect(theme.textTheme.bodyMedium!.fontSize, QiyuType.bodySize);
      expect(theme.textTheme.bodySmall!.fontSize, QiyuType.secondarySize);
      expect(theme.textTheme.labelSmall!.fontSize, QiyuType.tinySize);
    });

    test('栖语的话行高 1.9（书页式），UI 次要文字不跟着放大', () {
      expect(QiyuType.qiyuBodyLineHeight, 1.9);
      expect(QiyuTypography.qiyuMessage.height, 1.9);
      expect(QiyuTypography.qiyuMessage.fontSize, QiyuType.bodySize);
      expect(theme.textTheme.bodySmall!.height, lessThan(1.9));
    });
  });

  group('几何 token', () {
    test('圆角档位 8 / 18 / 999 / 20', () {
      expect(QiyuRadii.small, 8);
      expect(QiyuRadii.card, 18);
      expect(QiyuRadii.pill, 999);
      expect(QiyuRadii.circle, 999);
      expect(QiyuRadii.bubble, 20);
      expect(QiyuRadii.cardBorder.topLeft.x, 18);
      expect(QiyuRadii.pillBorder.topLeft.x, 999);
    });

    test('气泡为水滴形 20/20/6/20，指向角在右下', () {
      final bubble = QiyuRadii.bubbleBorder;
      expect(bubble.topLeft.x, 20);
      expect(bubble.topRight.x, 20);
      expect(bubble.bottomRight.x, 6);
      expect(bubble.bottomLeft.x, 20);
      expect(QiyuRadii.bubbleTail, 6);
    });

    test('间距：4px 基础网格 + 8/12/16/24/32', () {
      const spacing = <double>[
        QiyuSpacing.grid,
        QiyuSpacing.xs,
        QiyuSpacing.sm,
        QiyuSpacing.md,
        QiyuSpacing.lg,
        QiyuSpacing.xl,
      ];
      expect(spacing, <double>[4, 8, 12, 16, 24, 32]);
      for (final value in spacing) {
        expect(value % QiyuSpacing.grid, 0, reason: '$value 不在 4px 网格上');
      }
    });
  });

  group('布局与玻璃常量（第 2 段起消费，值不得散落）', () {
    test('桌面断点与侧边栏宽度、毛玻璃模糊半径', () {
      expect(QiyuLayout.desktopBreakpoint, closeTo(760, 1));
      expect(QiyuLayout.sidebarWidth, 240);
      expect(QiyuLayout.drawerWidthFraction, closeTo(2 / 3, 0.01));
      expect(QiyuGlass.sendButtonBlur, 8);
      expect(QiyuGlass.panelBlur, inInclusiveRange(16, 24));
      expect(QiyuGlass.panelBlurMin, 16);
      expect(QiyuGlass.panelBlurMax, 24);
    });
  });

  group('字体与背景资产入库', () {
    test('宋体子集、OFL 与夜景背景图随包存在', () {
      for (final path in <String>[
        'assets/fonts/NotoSerifSC-QiyuSubset.ttf',
        'assets/fonts/OFL-NotoSerifSC.txt',
        'assets/images/home-night-backdrop.jpg',
      ]) {
        expect(File('$_packageRoot/$path').existsSync(), isTrue, reason: path);
      }
    });

    test('旧 Sans 基线字族与其 OFL 已删除（决策日志第四轮 8）', () {
      expect(
        File(
          '$_packageRoot/assets/fonts/NotoSansSC-QiyuBaseline.ttf',
        ).existsSync(),
        isFalse,
      );
      expect(
        File('$_packageRoot/assets/fonts/OFL-NotoSansSC.txt').existsSync(),
        isFalse,
      );
    });

    test('pubspec 字族声明指向新子集，Roboto 别名保留', () {
      final pubspec = _read('pubspec.yaml');
      expect(pubspec, contains('family: Noto Serif SC'));
      expect(pubspec, contains('family: Roboto'));
      expect(
        RegExp('NotoSerifSC-QiyuSubset\\.ttf').allMatches(pubspec).length,
        2,
        reason: '宋体主字族与 Roboto 别名都要指向随包子集',
      );
      expect(
        pubspec,
        contains('asset: assets/fonts/NotoSerifSC-QiyuSubset.ttf'),
      );
      expect(pubspec, contains('- assets/images/home-night-backdrop.jpg'));
      expect(pubspec, contains('assets/fonts/OFL-NotoSerifSC.txt'));
      expect(pubspec, isNot(contains('NotoSansSC')));
    });
  });

  group('回归锁：旧视觉值不得回到源码', () {
    test('lib 下不再有种子色派生与黑体字族', () {
      final forbidden = <String>[
        '0xFF8C86B8',
        '0xFF15131A',
        "'Noto Sans SC'",
        'ColorScheme.fromSeed',
      ];
      for (final file in _dartFilesUnder('lib')) {
        final source = file.readAsStringSync();
        for (final needle in forbidden) {
          expect(
            source,
            isNot(contains(needle)),
            reason: '${file.path} 仍写着 $needle',
          );
        }
      }
    });

    test('发布门禁脚本引用的资产名与 pubspec 同步', () {
      for (final script in <String>[
        '../../scripts/verify-release-baseline.ps1',
        '../../scripts/verify-windows-package.ps1',
      ]) {
        final source = _read(script);
        expect(source, isNot(contains('NotoSansSC')), reason: script);
        expect(source, contains('NotoSerifSC-QiyuSubset.ttf'), reason: script);
        expect(source, contains('OFL-NotoSerifSC.txt'), reason: script);
      }
    });
  });
}
