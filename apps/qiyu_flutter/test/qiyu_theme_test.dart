import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

/// 设计 token 层契约测试（Spec Testing Decisions 第 2、3、7 条）。
///
/// 这是紫夜视觉改造的接缝：主题层是唯一色值来源，页面只准消费它。
/// 本文件锁住四件事——
/// 1. token 的字面值与 `docs/product/design-system.md` 第 2/3/8 节一字不差；
/// 2. `ColorScheme` 每个语义槽位取的都是 token，而不是第三处写死的色值；
/// 3. 三色纪律在**主题层**就成立：紫只准出现在「文字/图标强调」与「键盘焦点环」
///    两处（Spec User Story 9），任何被 M3 当填充/表面用的槽位与组件主题都不得
///    解析出 `accentBright`；
/// 4. 回归锁——旧种子色派生（`ColorScheme.fromSeed`、`0xFF8C86B8`、`0xFF15131A`、
///    黑体字族）已退场，`lib/features/**` 的裸 `Color(0x…)` 字面量不得超出棘轮
///    允许清单，且发布门禁脚本引用的资产名与 pubspec 一致。
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

/// 把单个控件装进本主题下渲染，用于读取**实际解析出来**的颜色。
Future<void> _pumpInTheme(
  WidgetTester tester,
  ThemeData theme,
  Widget child,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

/// M3 按钮把解析后的底色交给内部 `Material.color`，这就是页面上真正涂出来的填充色。
Color? _filledButtonFill(WidgetTester tester, Finder button) => tester
    .widget<Material>(
      find.descendant(of: button, matching: find.byType(Material)),
    )
    .color;

/// 按钮文字的实际前景色：`Material` 把 `resolvedForegroundColor` 放进 DefaultTextStyle，
/// 最终落在 `RichText` 的 TextSpan 上。
Color? _labelColor(WidgetTester tester, Finder button) {
  final richText = tester.widget<RichText>(
    find.descendant(of: button, matching: find.byType(RichText)),
  );
  final span = richText.text;
  return span is TextSpan ? span.style?.color : null;
}

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

    test('毛玻璃、tab 淡白下划线与 composer 聚焦描边取定案字面值', () {
      // 2026-08-28 裁定：毛玻璃基色不派生自 panel，取 rgba(19,18,23,0.72)。
      expect(QiyuColors.glass.toARGB32(), 0xB8131217);
      // 选中态 tab 的淡白下划线 rgba(255,255,255,0.30)，不是紫。
      expect(QiyuColors.indicatorNeutral.toARGB32(), 0x4DFFFFFF);
      // composer 聚焦描边紫度 0.13，只比无焦点略紫。
      expect(QiyuColors.composerFocusLine.a, closeTo(0.13, 0.005));
    });
  });

  group('ColorScheme 逐槽位消费 token', () {
    test('语义槽位全部等于对应 token', () {
      final scheme = theme.colorScheme;
      Color argb(Color color) => Color(color.toARGB32());

      // M3 把 primary 同时当作「填充色」和「图标/文字强调色」用（FilledButton 底、
      // Switch 轨道、Slider 轨道、进度条，以及页面里直接读 colorScheme.primary 的
      // 图标）。大面积填充由下面的组件主题逐个压到 bubbleUser 暗档，槽位本身取
      // 中性灰 muted：这样任何没被显式覆盖的派生点既不着紫、也不会暗到看不见。
      expect(argb(scheme.primary), argb(QiyuColors.muted));
      expect(argb(scheme.onPrimary), argb(QiyuColors.night));
      // F2：accent-glass 是「半透明渐变两端 + 背景模糊」的组合体，只属于发送按钮与
      // 主按钮，把渐变末色当单色容器槽位用是错映射。用户气泡面色定值是 bubble-user。
      expect(argb(scheme.primaryContainer), argb(QiyuColors.bubbleUser));
      expect(argb(scheme.onPrimaryContainer), argb(QiyuColors.ink));
      expect(argb(scheme.secondary), argb(QiyuColors.muted));
      expect(argb(scheme.onSecondary), argb(QiyuColors.night));
      expect(argb(scheme.secondaryContainer), argb(QiyuColors.panel));
      expect(argb(scheme.onSecondaryContainer), argb(QiyuColors.ink));
      expect(argb(scheme.tertiary), argb(QiyuColors.muted));
      expect(argb(scheme.onTertiary), argb(QiyuColors.night));
      expect(argb(scheme.tertiaryContainer), argb(QiyuColors.panel));
      expect(argb(scheme.onTertiaryContainer), argb(QiyuColors.ink));
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

    test('三色纪律：ColorScheme 没有任何槽位落在紫上', () {
      // 页面里的紫色越界绝大多数是「组件默认样式读槽位」派生出来的，所以槽位层
      // 必须一个紫都不留；accent-bright 只准以组件主题的文字/图标色与自绘焦点环
      // 的形式出现（design-system §1、§2、§9）。
      final scheme = theme.colorScheme;
      final slots = <String, Color>{
        'primary': scheme.primary,
        'onPrimary': scheme.onPrimary,
        'primaryContainer': scheme.primaryContainer,
        'onPrimaryContainer': scheme.onPrimaryContainer,
        'primaryFixed': scheme.primaryFixed,
        'primaryFixedDim': scheme.primaryFixedDim,
        'onPrimaryFixed': scheme.onPrimaryFixed,
        'onPrimaryFixedVariant': scheme.onPrimaryFixedVariant,
        'secondary': scheme.secondary,
        'onSecondary': scheme.onSecondary,
        'secondaryContainer': scheme.secondaryContainer,
        'onSecondaryContainer': scheme.onSecondaryContainer,
        'secondaryFixed': scheme.secondaryFixed,
        'secondaryFixedDim': scheme.secondaryFixedDim,
        'onSecondaryFixed': scheme.onSecondaryFixed,
        'onSecondaryFixedVariant': scheme.onSecondaryFixedVariant,
        'tertiary': scheme.tertiary,
        'onTertiary': scheme.onTertiary,
        'tertiaryContainer': scheme.tertiaryContainer,
        'onTertiaryContainer': scheme.onTertiaryContainer,
        'tertiaryFixed': scheme.tertiaryFixed,
        'tertiaryFixedDim': scheme.tertiaryFixedDim,
        'onTertiaryFixed': scheme.onTertiaryFixed,
        'onTertiaryFixedVariant': scheme.onTertiaryFixedVariant,
        'surface': scheme.surface,
        'surfaceBright': scheme.surfaceBright,
        'surfaceDim': scheme.surfaceDim,
        'surfaceContainer': scheme.surfaceContainer,
        'inversePrimary': scheme.inversePrimary,
        'outline': scheme.outline,
        'outlineVariant': scheme.outlineVariant,
        'shadow': scheme.shadow,
        'scrim': scheme.scrim,
        'surfaceTint': scheme.surfaceTint,
      };
      const purple = <int>{
        0xFF9D8FE0, // accent-bright
        0x9E4B4092, // accent-glass 渐变首色
        0x80332B61, // accent-glass 渐变末色
      };
      for (final entry in slots.entries) {
        expect(
          purple,
          isNot(contains(entry.value.toARGB32())),
          reason:
              '槽位 ${entry.key} 落紫：#${entry.value.toARGB32().toRadixString(16)}',
        );
      }
    });

    test('容器槽位与 elevation 叠加全部中性', () {
      final scheme = theme.colorScheme;
      // 未显式赋值的槽位会退到 Material 基线色，必须逐个压回中性。
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

    test('页面底色与焦点取 token（F4：焦点环留给自绘）', () {
      expect(
        theme.scaffoldBackgroundColor.toARGB32(),
        QiyuColors.night.toARGB32(),
      );
      expect(theme.canvasColor.toARGB32(), QiyuColors.night.toARGB32());
      expect(theme.cardColor.toARGB32(), QiyuColors.panel.toARGB32());
      // §9 要的 2px + offset 3px 焦点环画在控件表面之外，Material 的 focusColor
      // 只会贴在控件表面上，所以这里只能是中性淡底，不能是实心亮紫。
      expect(
        theme.focusColor.toARGB32(),
        QiyuColors.selectedNeutral.toARGB32(),
      );
      expect(theme.focusColor, isNot(QiyuColors.accentBright));
      expect(theme.focusColor.a, lessThan(0.2));
      expect(theme.useMaterial3, isTrue);
    });
  });

  group('三色纪律：被当填充用的组件在主题层压回中性（User Story 9）', () {
    testWidgets('FilledButton 实际渲染出的底色不是 accent-bright', (tester) async {
      await _pumpInTheme(
        tester,
        theme,
        FilledButton(onPressed: () {}, child: const Text('保存')),
      );
      final fill = _filledButtonFill(tester, find.byType(FilledButton));
      expect(fill, isNotNull, reason: '没读到按钮的实际填充色');
      expect(
        fill!.toARGB32(),
        isNot(QiyuColors.accentBright.toARGB32()),
        reason: 'FilledButton 拿亮紫当填充色，紫色越界',
      );
      // 中性暗底一档（design-system §2 中性色家族），文字取 ink。
      expect(fill.toARGB32(), QiyuColors.bubbleUser.toARGB32());
      expect(
        _labelColor(tester, find.byType(FilledButton))?.toARGB32(),
        QiyuColors.ink.toARGB32(),
      );
    });

    testWidgets('次按钮与文字按钮的 label 仍是 accent-bright', (tester) async {
      // 紫的两处用途之一：文字/图标强调（design-system §8 组件 2「次按钮 / 文字按钮
      // — 无底色，accent-bright 文字」）。primary 转中性后必须由主题层显式定住。
      await _pumpInTheme(
        tester,
        theme,
        Column(
          children: [
            TextButton(onPressed: () {}, child: const Text('取消')),
            OutlinedButton(onPressed: () {}, child: const Text('重试')),
          ],
        ),
      );
      expect(
        _labelColor(tester, find.byType(TextButton))?.toARGB32(),
        QiyuColors.accentBright.toARGB32(),
      );
      expect(
        _labelColor(tester, find.byType(OutlinedButton))?.toARGB32(),
        QiyuColors.accentBright.toARGB32(),
      );
    });

    testWidgets('Switch 与 Slider 的填充色在主题层显式取中性', (tester) async {
      Color? argb(Color? color) =>
          color == null ? null : Color(color.toARGB32());
      const selected = <WidgetState>{WidgetState.selected};
      const unselected = <WidgetState>{};

      expect(
        argb(theme.switchTheme.trackColor?.resolve(selected)),
        argb(QiyuColors.muted),
        reason: '选中轨道必须由主题层显式给定中性值',
      );
      expect(
        argb(theme.switchTheme.thumbColor?.resolve(selected)),
        argb(QiyuColors.night),
      );
      expect(
        argb(theme.switchTheme.trackColor?.resolve(unselected)),
        argb(QiyuColors.line),
      );
      expect(
        argb(theme.switchTheme.thumbColor?.resolve(unselected)),
        argb(QiyuColors.muted),
      );
      expect(argb(theme.sliderTheme.activeTrackColor), argb(QiyuColors.muted));
      expect(argb(theme.sliderTheme.inactiveTrackColor), argb(QiyuColors.line));
      expect(argb(theme.sliderTheme.thumbColor), argb(QiyuColors.ink));

      // 渲染出来的开关与滑块确实不是紫。
      await _pumpInTheme(
        tester,
        theme,
        Column(
          children: [
            Switch(value: true, onChanged: (_) {}),
            Slider(value: 0.6, onChanged: (_) {}),
          ],
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(Switch), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
    });

    test('所有显式压回的组件主题解析值都落在中性色集合内', () {
      const neutralArgb = <int>{
        0xFF0F0E14, // night
        0xFF181719, // panel
        0xFF232227, // line
        0xFF28272E, // bubble-user
        0xFF9A94A8, // muted
        0xFFECE9F2, // ink
        0xFFF5F3FA, // on-accent
        0x0AFFFFFF, // selected-neutral
        0x4DFFFFFF, // indicator-neutral
        0xB8131217, // glass
      };
      const selected = <WidgetState>{WidgetState.selected};
      const plain = <WidgetState>{};
      // 每一处都必须是主题层显式给定的值：null 意味着退回 M3 派生，正是这次要堵掉的。
      final fills = <String, Color?>{
        'filledButton.background': theme
            .filledButtonTheme
            .style
            ?.backgroundColor
            ?.resolve(plain),
        'filledButton.foreground': theme
            .filledButtonTheme
            .style
            ?.foregroundColor
            ?.resolve(plain),
        'switch.track.selected': theme.switchTheme.trackColor?.resolve(
          selected,
        ),
        'switch.track.unselected': theme.switchTheme.trackColor?.resolve(plain),
        'switch.thumb.selected': theme.switchTheme.thumbColor?.resolve(
          selected,
        ),
        'switch.thumb.unselected': theme.switchTheme.thumbColor?.resolve(plain),
        'slider.activeTrack': theme.sliderTheme.activeTrackColor,
        'slider.inactiveTrack': theme.sliderTheme.inactiveTrackColor,
        'slider.thumb': theme.sliderTheme.thumbColor,
        'progressIndicator': theme.progressIndicatorTheme.color,
        'checkbox.fill.selected': theme.checkboxTheme.fillColor?.resolve(
          selected,
        ),
        'checkbox.check.selected': theme.checkboxTheme.checkColor?.resolve(
          selected,
        ),
        'radio.fill.selected': theme.radioTheme.fillColor?.resolve(selected),
        'segmentedButton.background.selected': theme
            .segmentedButtonTheme
            .style
            ?.backgroundColor
            ?.resolve(selected),
        'segmentedButton.foreground.selected': theme
            .segmentedButtonTheme
            .style
            ?.foregroundColor
            ?.resolve(selected),
        'chip.selected': theme.chipTheme.color?.resolve(selected),
        'navigationBar.indicator': theme.navigationBarTheme.indicatorColor,
        'navigationRail.indicator': theme.navigationRailTheme.indicatorColor,
        'tabBar.label': theme.tabBarTheme.labelColor,
      };
      for (final entry in fills.entries) {
        final color = entry.value;
        expect(color, isNotNull, reason: '${entry.key} 没有由主题层显式压回中性，会退回 M3 派生');
        expect(
          neutralArgb,
          contains(color!.toARGB32()),
          reason:
              '${entry.key} 取到中性集合外的色：#${color.toARGB32().toRadixString(16)}',
        );
      }
    });

    test('记忆中心 tab：中性底上的选中文字取 ink，下划线走 token', () {
      // F3：on-accent 的语义是「强调底色上的文字」，tab 是中性底，选中态必须取 ink
      // （原型 .tab.active 亦为 var(--ink)，design-system §8 补充约定「选中态全站统一中性」）。
      expect(
        theme.tabBarTheme.labelColor?.toARGB32(),
        QiyuColors.ink.toARGB32(),
      );
      expect(
        theme.tabBarTheme.unselectedLabelColor?.toARGB32(),
        QiyuColors.muted.toARGB32(),
      );
      final indicator = theme.tabBarTheme.indicator;
      expect(indicator, isA<UnderlineTabIndicator>());
      final underline = indicator! as UnderlineTabIndicator;
      expect(underline.borderSide.width, QiyuLine.tabIndicator);
      expect(
        underline.borderSide.color.toARGB32(),
        QiyuColors.indicatorNeutral.toARGB32(),
      );
      // 原型 .tab 的下划线紧贴标签底部，没有内缩；原来的 6px 既无出处也不在 4px 网格上。
      expect(underline.insets, EdgeInsets.zero);
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

    test('栖语的话行高 1.9（书页式），UI 档不自造行高', () {
      expect(QiyuType.qiyuBodyLineHeight, 1.9);
      expect(QiyuTypography.qiyuMessage.height, 1.9);
      expect(QiyuTypography.qiyuMessage.fontSize, QiyuType.bodySize);
      // §3 只定了「栖语的话行高 1.9」，其余档位的 1.3/1.4/1.5/1.6 无出处：
      // 不自造值，退回随包字族的默认行高。
      expect(QiyuTypography.greeting.height, isNull);
      expect(QiyuTypography.title.height, isNull);
      expect(QiyuTypography.body.height, isNull);
      expect(QiyuTypography.secondary.height, isNull);
      expect(QiyuTypography.tiny.height, isNull);
      expect(theme.textTheme.bodySmall!.height, isNull);
    });

    test('问候档的字重与字距取自原型 .home-greet（视觉真相源）', () {
      // design-system §3 只定字号；字重与字距的出处是原型 index.html 的
      // `.home-greet { font-weight: 300; letter-spacing: 3px }`， Spec Further Notes 第 2 条。
      expect(QiyuTypography.greeting.fontWeight, FontWeight.w300);
      expect(QiyuTypography.greeting.letterSpacing, 3);
    });
  });

  group('几何 token', () {
    test('圆角档位 8 / 18 / 胶囊 999 / 气泡 20', () {
      expect(QiyuRadii.small, 8);
      expect(QiyuRadii.card, 18);
      expect(QiyuRadii.pill, 999);
      expect(QiyuRadii.bubble, 20);
      expect(QiyuRadii.cardBorder.topLeft.x, 18);
      expect(QiyuRadii.pillBorder.topLeft.x, 999);
    });

    test('圆形不用 radius 常量表达（§8 圆形与胶囊是两种形状）', () {
      // 旧 QiyuRadii.circle = 999 与 pill 同值，语义上区分不出「圆形（图标按钮、
      // 发送钮）」与「胶囊形（输入框）」。圆形由 ShapeBorder/BoxShape 语义承载。
      expect(QiyuShapes.circleBorder, isA<CircleBorder>());
      expect(QiyuRadii.pill, 999, reason: '胶囊仍然只有 pill 这一处 999');
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
    test('桌面断点、侧边栏宽度与抽屉比例精确相等', () {
      // 这些都是编译期常量，近似断言会白白放行 759–761 与 0.663–0.677。
      expect(QiyuLayout.desktopBreakpoint, 760);
      expect(QiyuLayout.sidebarWidth, 240);
      expect(QiyuLayout.drawerWidthFraction, 2 / 3);
      // 680 取自原型 `.chat-stream { max-width: 680px }`，非规范定稿值。
      expect(QiyuLayout.streamMaxWidth, 680);
      expect(QiyuLayout.composerPadding, 6);
      expect(QiyuLayout.composerIconButtonSize, 34);
    });

    test('毛玻璃模糊半径取定值，不拿验收区间当契约', () {
      expect(QiyuGlass.sendButtonBlur, 8);
      // §2 的 16–24 是「凭视觉验收微调」的区间，不该变成测试契约；
      // 定值出处是原型 `:root { --blur: blur(20px) }`。
      expect(QiyuGlass.panelBlur, 20);
    });

    test('线条宽度：发丝 1px、tab 下划线 2px', () {
      expect(QiyuLine.hairline, 1);
      expect(QiyuLine.tabIndicator, 2);
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

    test('棘轮：features 层的裸 Color(0x…) 不得超出允许清单', () {
      // Spec Testing Decisions 2 真正要防的是「实现时又散出新色值」。上面那条
      // 字面值黑名单只挡得住四个旧值，这里按文件逐个清点现存的裸色值。
      //
      // 允许清单 = 硬编码色值收口段（Spec Further Notes 3 最后一段）开工前的历史
      // 残留台账：后续每清掉一处，这里的条目必须同步缩短，收口完成时它必须降为
      // 空集——不要往回加条目，新写的色值一律进 token 层。
      const bareColorAllowList = <String>{
        'lib/features/memory/memory_view.dart :: Color(0xFF9C5C13)',
        'lib/features/memory/memory_view.dart :: Color(0xFFB3261E)',
        'lib/features/memory/memory_view.dart :: Color(0xFFFFFFFF)',
        'lib/features/settings/provider_settings_view.dart :: Color(0xFF91C7A7)',
      };
      final found = <String>{};
      for (final file in _dartFilesUnder('lib/features')) {
        final relative = file.path
            .replaceAll(r'\', '/')
            .replaceFirst('./', '')
            .replaceFirst(RegExp(r'^/'), '');
        for (final match in RegExp(
          r'Color\(0x[0-9A-Fa-f]{2,8}\)',
        ).allMatches(file.readAsStringSync())) {
          found.add('$relative :: ${match[0]}');
        }
      }
      expect(found.length, bareColorAllowList.length, reason: '$found');
      expect(found, bareColorAllowList);
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
