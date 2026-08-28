import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

/// 设计 token 层契约测试（Spec Testing Decisions 第 2、3、7 条）。
///
/// 这是紫夜视觉改造的接缝：主题层是唯一色值来源，页面只准消费它。
/// 本文件锁住四件事——
/// 1. token 的字面值与 `docs/product/design-system.md` 第 2/3/8 节一字不差，
///    含三个中性功能角色（强调位近白、填充位暗一档、强填充位灰档）；
/// 2. `ColorScheme` 每个语义槽位取的都是 token，而不是第三处写死的色值；强调槽位
///    （primary/secondary/tertiary）与拇指这类**强调位**取中性近白，绝不允许拿 §2 的
///    次要文字色 `muted` 或任何紫来当；
/// 3. 三色纪律在**主题层**就成立：紫只准出现在「文字/图标强调」与「键盘焦点环」
///    两处（Spec User Story 9），任何被 M3 当填充/表面用的槽位与组件主题都不得
///    解析出 `accentBright`；组件状态色全部由主题层那份共享中性状态表给出；
/// 4. 回归锁——旧种子色派生（`ColorScheme.fromSeed`、`0xFF8C86B8`、`0xFF15131A`、
///    黑体字族）已退场；整个 `lib/**`（只放行 `lib/theme/**`）的裸色值不得超出棘轮
///    允许清单；发布门禁脚本引用的资产名与 pubspec 一致（独立一条测试）。
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

/// 归一成 `lib/xxx/yyy.dart`：Windows 的反斜杠与 `./` 前缀都要抹掉，
/// 否则台账条目和放行目录判断会因路径写法不同而失效。
String _relativePath(File file) => file.path
    .replaceAll(r'\', '/')
    .replaceFirst('./', '')
    .replaceFirst(RegExp(r'^/'), '');

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

    test('中性功能角色只复用已有中性色值，不引入新色相', () {
      // 三个角色是 M3「强调位 / 填充位」的语义入口（见 QiyuColors 内的说明），
      // 取值必须逐个等于它复用的 §2 中性档：新增色相就等于绕过 §2 的色板。
      expect(QiyuColors.neutralEmphasis, QiyuColors.onAccent);
      expect(QiyuColors.neutralEmphasis.toARGB32(), 0xFFF5F3FA);
      expect(QiyuColors.neutralFill, QiyuColors.bubbleUser);
      expect(QiyuColors.neutralFill.toARGB32(), 0xFF28272E);
      expect(QiyuColors.neutralFillStrong, QiyuColors.muted);
      expect(QiyuColors.neutralFillStrong.toARGB32(), 0xFF9A94A8);
      // 中性角色不得是任何紫（三色纪律，design-system §1、§2）。
      expect(QiyuColors.neutralEmphasis, isNot(QiyuColors.accentBright));
      expect(QiyuColors.neutralFill, isNot(QiyuColors.accentGlassA));
      expect(QiyuColors.neutralFillStrong, isNot(QiyuColors.accentGlassB));
    });
  });

  group('ColorScheme 逐槽位消费 token', () {
    test('语义槽位全部等于对应 token', () {
      final scheme = theme.colorScheme;
      Color argb(Color color) => Color(color.toARGB32());

      // 三色纪律 + 档位纪律：M3 把 primary 同时当作「填充色」和「图标/文字强调色」
      // 用（FilledButton 底、Switch 轨道、Slider 轨道与拇指、进度条，以及页面里直接
      // 读 colorScheme.primary 的图标件），所以它必须是**中性近白的强调位**。拿 §2 的
      // 次要文字色 muted 填这里就是回归本身：名字骗人，而且所有直接读 primary 的
      // 图形件在暗底上糊成一片暗灰（音量滑块的拇指与轨道同色、设置页成功图标转灰）。
      expect(argb(scheme.primary), argb(QiyuColors.neutralEmphasis));
      expect(argb(scheme.secondary), argb(QiyuColors.neutralEmphasis));
      expect(argb(scheme.tertiary), argb(QiyuColors.neutralEmphasis));
      expect(
        scheme.primary.toARGB32(),
        isNot(QiyuColors.muted.toARGB32()),
        reason: 'primary 退回次要文字色 muted：直接读 colorScheme.primary 的图形件会变暗灰',
      );
      expect(
        scheme.secondary.toARGB32(),
        isNot(QiyuColors.muted.toARGB32()),
        reason: 'secondary 退回 muted，同上',
      );
      expect(
        scheme.tertiary.toARGB32(),
        isNot(QiyuColors.muted.toARGB32()),
        reason: 'tertiary 退回 muted，同上',
      );
      expect(argb(scheme.onPrimary), argb(QiyuColors.night));
      // accent-glass 是「半透明渐变两端 + 背景模糊」的组合体，只属于发送按钮与
      // 主按钮，把渐变末色当单色容器槽位用是错映射。通用中性填充取 neutralFill，
      // 不再拿文档用途只有「用户气泡」的 bubbleUser 兼职。
      expect(argb(scheme.primaryContainer), argb(QiyuColors.neutralFill));
      expect(argb(scheme.onPrimaryContainer), argb(QiyuColors.ink));
      expect(argb(scheme.onSecondary), argb(QiyuColors.night));
      expect(argb(scheme.secondaryContainer), argb(QiyuColors.panel));
      expect(argb(scheme.onSecondaryContainer), argb(QiyuColors.ink));
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
      expect(argb(scheme.surfaceBright), argb(QiyuColors.neutralFill));
      expect(argb(scheme.surfaceContainerHigh), argb(QiyuColors.neutralFill));
      expect(
        argb(scheme.surfaceContainerHighest),
        argb(QiyuColors.neutralFill),
      );
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
        // 原型历史命名 --accent-deep-a / --accent-deep-b：既不在 §2 的 token 表里，
        // 也不属于任何中性档（Spec Further Notes 第 2 条点名实现不得照抄）。
        0xFF55489C,
        0xFF463A85,
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

    test('页面底色与焦点取 token（焦点环留给自绘）', () {
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
      expect(fill.toARGB32(), QiyuColors.neutralFill.toARGB32());
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

    testWidgets('Switch 与 Slider：轨道取中性强填充，拇指取中性近白', (tester) async {
      Color? argb(Color? color) =>
          color == null ? null : Color(color.toARGB32());
      const selected = <WidgetState>{WidgetState.selected};
      const unselected = <WidgetState>{};

      // 轨道是「压在文字之下的可见中性填充」→ neutralFillStrong；描边档 line 留给
      // 未激活的一侧。两者都不是紫，也不再借用语义为次要文字的 muted 角色名。
      expect(
        argb(theme.switchTheme.trackColor?.resolve(selected)),
        argb(QiyuColors.neutralFillStrong),
        reason: '选中轨道必须由主题层显式给定中性强填充，不得退回 M3 派生',
      );
      expect(
        argb(theme.switchTheme.trackColor?.resolve(unselected)),
        argb(QiyuColors.line),
      );
      expect(
        argb(theme.sliderTheme.activeTrackColor),
        argb(QiyuColors.neutralFillStrong),
      );
      expect(argb(theme.sliderTheme.inactiveTrackColor), argb(QiyuColors.line));
      // 拇指属强调位：一律中性近白。它一旦跟着 primary 落到 muted，就会和轨道同色
      // 糊成一条（音量滑块就是这么坏的），所以逐位显式压回近白档并锁死不是灰档。
      expect(
        argb(theme.switchTheme.thumbColor?.resolve(selected)),
        argb(QiyuColors.neutralEmphasis),
      );
      expect(
        argb(theme.switchTheme.thumbColor?.resolve(unselected)),
        argb(QiyuColors.neutralEmphasis),
      );
      expect(
        argb(theme.sliderTheme.thumbColor),
        argb(QiyuColors.neutralEmphasis),
      );
      for (final entry in <String, Color?>{
        'slider.thumb': theme.sliderTheme.thumbColor,
        'switch.thumb.on': theme.switchTheme.thumbColor?.resolve(selected),
        'switch.thumb.off': theme.switchTheme.thumbColor?.resolve(unselected),
      }.entries) {
        expect(
          entry.value?.toARGB32(),
          isNot(QiyuColors.muted.toARGB32()),
          reason: '${entry.key} 退回 muted 灰档：拇指会和轨道糊成一条',
        );
        expect(
          entry.value?.toARGB32(),
          QiyuColors.neutralEmphasis.toARGB32(),
          reason: '${entry.key} 必须是中性近白强调位',
        );
      }

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

    test('每个组件状态位都显式压回中性，且逐位等于登记的中性角色', () {
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
      Color? argb(Color? color) =>
          color == null ? null : Color(color.toARGB32());
      // 每一处都必须是主题层显式给定的值：null 意味着退回 M3 派生，正是这次要堵掉的。
      final states = <String, Color?>{
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
        'checkbox.fill.unselected': theme.checkboxTheme.fillColor?.resolve(
          plain,
        ),
        'checkbox.check.selected': theme.checkboxTheme.checkColor?.resolve(
          selected,
        ),
        'radio.fill.selected': theme.radioTheme.fillColor?.resolve(selected),
        'radio.fill.unselected': theme.radioTheme.fillColor?.resolve(plain),
        'segmentedButton.background.selected': theme
            .segmentedButtonTheme
            .style
            ?.backgroundColor
            ?.resolve(selected),
        'segmentedButton.background.unselected': theme
            .segmentedButtonTheme
            .style
            ?.backgroundColor
            ?.resolve(plain),
        'segmentedButton.foreground.selected': theme
            .segmentedButtonTheme
            .style
            ?.foregroundColor
            ?.resolve(selected),
        'segmentedButton.foreground.unselected': theme
            .segmentedButtonTheme
            .style
            ?.foregroundColor
            ?.resolve(plain),
        'chip.selected': theme.chipTheme.color?.resolve(selected),
        'navigationBar.indicator': theme.navigationBarTheme.indicatorColor,
        'navigationRail.indicator': theme.navigationRailTheme.indicatorColor,
        'tabBar.label': theme.tabBarTheme.labelColor,
      };
      // 光「落在中性集合里」还不够——档位选错一样看不见：填充位取到灰档、拇指位
      // 取到暗档都是回归。逐位钉死它该取哪个中性角色，角色只有四类：
      // 实底填充 neutralFill / 可见强填充（轨道、进度）neutralFillStrong /
      // 强调件（拇指）neutralEmphasis / 前景文字与描边 ink、muted、line。
      final roleOf = <String, Color>{
        'filledButton.background': QiyuColors.neutralFill,
        'filledButton.foreground': QiyuColors.ink,
        'switch.track.selected': QiyuColors.neutralFillStrong,
        'switch.track.unselected': QiyuColors.line,
        'switch.thumb.selected': QiyuColors.neutralEmphasis,
        'switch.thumb.unselected': QiyuColors.neutralEmphasis,
        'slider.activeTrack': QiyuColors.neutralFillStrong,
        'slider.inactiveTrack': QiyuColors.line,
        'slider.thumb': QiyuColors.neutralEmphasis,
        'progressIndicator': QiyuColors.neutralFillStrong,
        'checkbox.fill.selected': QiyuColors.neutralFill,
        'checkbox.fill.unselected': QiyuColors.panel,
        'checkbox.check.selected': QiyuColors.ink,
        'radio.fill.selected': QiyuColors.neutralFill,
        'radio.fill.unselected': QiyuColors.panel,
        'segmentedButton.background.selected': QiyuColors.neutralFill,
        'segmentedButton.background.unselected': QiyuColors.panel,
        'segmentedButton.foreground.selected': QiyuColors.ink,
        'segmentedButton.foreground.unselected': QiyuColors.muted,
        'chip.selected': QiyuColors.neutralFill,
        'navigationBar.indicator': QiyuColors.neutralFill,
        'navigationRail.indicator': QiyuColors.neutralFill,
        'tabBar.label': QiyuColors.ink,
      };
      // 新登记了状态位却没写角色 → 红；角色表写了位子里没有 → 也红。
      expect(
        roleOf.keys.toSet(),
        states.keys.toSet(),
        reason: '组件状态位与中性角色登记表必须一一对应',
      );
      for (final entry in states.entries) {
        final color = entry.value;
        expect(color, isNotNull, reason: '${entry.key} 没有由主题层显式压回中性，会退回 M3 派生');
        expect(
          neutralArgb,
          contains(color!.toARGB32()),
          reason:
              '${entry.key} 取到中性集合外的色：#${color.toARGB32().toRadixString(16)}',
        );
        expect(
          argb(color),
          argb(roleOf[entry.key]),
          reason:
              '${entry.key} 档位不对，登记表要求 #'
              '${argb(roleOf[entry.key])?.toARGB32().toRadixString(16)}',
        );
      }
    });

    test('组件状态色共用一份中性状态表，不再各写 resolveWith', () {
      // 此前为十几个 M3 组件逐个复制了同形状的 `resolveWith`（选中? A : B），
      // 加一个组件就要再记一遍「槽位不得显紫」。现在这份知识只在
      // `qiyuNeutralStates` 里写一次，所以状态解析在主题层只准出现一处。
      final themeSource = _read('lib/theme/qiyu_theme.dart');
      expect(
        RegExp(
          r'WidgetStateProperty\.resolveWith',
        ).allMatches(themeSource).length,
        1,
        reason: '状态解析只允许写在共享 helper 里；组件主题请登记角色取值，不要再复制形状',
      );
    });

    test('主题层不再拿用户气泡面色兼职通用填充', () {
      // `bubbleUser` 在 §2 的文档用途只有「用户消息气泡」。主题层一旦再引用它，
      // 说明又有人拿气泡色当通用中性填充，档位语义会重新糊在一起。
      final themeSource = _read('lib/theme/qiyu_theme.dart');
      expect(
        RegExp(r'QiyuColors\.bubbleUser').allMatches(themeSource).length,
        0,
        reason: '通用中性填充请取 QiyuColors.neutralFill',
      );
    });

    test('记忆中心 tab：中性底上的选中文字取 ink，下划线走 token', () {
      // on-accent 的语义是「强调底色上的文字」，tab 是中性底，选中态必须取 ink
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
      // 指示器内缩是**基准对齐**：原型 `.tab` 的 border-bottom 贴在标签自身盒子
      // 底边，Flutter 的 UnderlineTabIndicator 画在整条 TabBar 底边，不内缩会把
      // 下划线推离标签。值收在 QiyuLine.tabIndicatorInset，刻意不进 §8 的 4px 间距体系。
      expect(
        underline.insets,
        const EdgeInsets.only(bottom: QiyuLine.tabIndicatorInset),
        reason: 'tab 下划线缺少基准对齐内缩，会贴到整条 TabBar 底边、离开标签',
      );
      expect(QiyuLine.tabIndicatorInset, 6);
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

    test('字重与字距只准有出处的档位写，其余退回默认', () {
      // design-system §3 只定字号与「栖语的话行高 1.9」，字重与字距一律不自造。
      // 唯一有出处的是问候档：原型 `.home-greet { font-weight: 300; letter-spacing: 3px }`
      // （Spec Further Notes 第 2 条把原型列为形态与观感的视觉真相源）。
      expect(QiyuTypography.greeting.fontWeight, FontWeight.w300);
      expect(QiyuTypography.greeting.letterSpacing, 3);
      // 标题档不自洽：原型 `.page-title` 是 400/2px、`.set-section h3` 是 500/2px，
      // 两个出处互相打架，§3 又没定，所以原来的 w500 + 1px 属自造值，去掉退回默认，
      // 等视觉验收段连同字阶一起定夺。
      expect(
        QiyuTypography.title.fontWeight,
        isNull,
        reason: '标题字重没有唯一出处，不许保留自造的 w500',
      );
      expect(
        QiyuTypography.title.letterSpacing,
        isNull,
        reason: '标题的 1px 字距在规范与原型里都查不到，去掉用默认',
      );
      for (final entry in <String, TextStyle>{
        'body': QiyuTypography.body,
        'secondary': QiyuTypography.secondary,
        'tiny': QiyuTypography.tiny,
        'qiyuMessage': QiyuTypography.qiyuMessage,
      }.entries) {
        expect(entry.value.fontWeight, isNull, reason: '${entry.key} 自造了字重');
        expect(entry.value.letterSpacing, isNull, reason: '${entry.key} 自造了字距');
      }
      // 装配到 Material 档位上之后同样不得漏出紫夜规范没定的字重/字距。
      expect(theme.textTheme.headlineSmall?.fontWeight, isNull);
      expect(theme.textTheme.headlineSmall?.letterSpacing, isNull);
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

    test('圆形不由 radius 档表达：999 只属于胶囊一个档位', () {
      // 旧写法是 QiyuRadii.circle = 999 与 pill 同值，代码里根本分不出
      // 「圆形（图标按钮、发送钮）」与「胶囊形（输入框）」两种形状。
      expect(QiyuRadii.pill, 999);
      final tokensSource = _read('lib/theme/qiyu_tokens.dart');
      expect(
        RegExp(
          r'static const double \w+ = 999\b',
        ).allMatches(tokensSource).length,
        1,
        reason: 'token 层出现第二个 999 档位：圆形又不拿 radius 凑胶囊了',
      );
      // 零消费的 QiyuShapes.circleBorder 已删除；第 2 段圆形图标按钮与发送钮真的
      // 需要共享轮廓时再加，不在这里摆一个没人读、测试又永真的常量。
      expect(
        tokensSource,
        isNot(contains('class QiyuShapes')),
        reason: 'QiyuShapes 重新出现但库内仍无消费方',
      );
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

    test('毛玻璃模糊半径：定值 20，且必须落在 §2 的 16–24 可微调区间内', () {
      expect(QiyuGlass.sendButtonBlur, 8);
      // 定值出处是原型 `:root { --blur: blur(20px) }`；区间 16–24 是 design-system
      // §2 的硬契约（「实现时凭视觉验收微调」指的是在区间内调），所以两头都锁：
      // 改定值要看得见，改成 4 或 60 这类越界值直接红。
      expect(QiyuGlass.panelBlur, 20);
      expect(
        QiyuGlass.panelBlur,
        inInclusiveRange(16, 24),
        reason: '§2 定的是 16–24px 可微调区间，越界即脱离规范',
      );
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

    test('棘轮：整个 lib 层的裸色值只准住在 theme 层，其余按台账清空', () {
      // Spec Testing Decisions 2 要防的是「实现时又散出新色值」。上面那条字面值
      // 黑名单只挡得住四个旧值，这里按文件逐个清点**全部**裸色值写法：
      // `Color(0x…)`、`Color.fromARGB(`、`Color.fromRGBO(`、`Colors.<常量>`。
      // 扫描范围是整个 `lib/**`（含 `lib/app.dart` 与未来的 `lib/widgets/`），
      // 唯一放行目录是 `lib/theme/**`——全应用只有这一层可以写死色值。
      //
      // 台账 = 硬编码色值收口段（Spec Further Notes 3 最后一段）开工前的历史残留：
      // 每清掉一处，这里的条目必须同步缩短，收口完成时它必须降为空集——不要往回加
      // 条目，新写的色值一律进 token 层。集合相等断言：新增会红，清掉了不改这里也红。
      const bareColorAllowList = <String>{
        'lib/features/memory/memory_view.dart :: Color(0xFF9C5C13)',
        // 注意：这是 **Material 3 基线红**，与 design-system §2 定稿的危险色
        // `danger #cc9999` 直接冲突。它留在台账里只是记账，不是合法值——第 4 段
        // （记忆中心换皮）必须换成 `QiyuColors.danger`，后续段不要照抄它。
        'lib/features/memory/memory_view.dart :: Color(0xFFB3261E)',
        'lib/features/memory/memory_view.dart :: Color(0xFFFFFFFF)',
        'lib/features/settings/provider_settings_view.dart :: Color(0xFF91C7A7)',
      };
      // 无色相、不承载任何设计语义的 Material 常量：允许在页面直接用（遮罩、
      // 渐变透明端这类）。放行项**逐个点名**写在这里，不用正则模糊掉——否则
      // `Colors.purple` 也会跟着溜过去。要新增成员必须在评审里说明为什么不走 token。
      const huelessMaterialConstants = <String>{
        'Colors.transparent',
        'Colors.white',
        'Colors.black',
      };
      final bareColor = RegExp(
        r'\bColor\(0x[0-9A-Fa-f]{2,8}\)'
        r'|\bColor\.fromARGB\('
        r'|\bColor\.fromRGBO\('
        r'|\bColors\.[a-zA-Z][a-zA-Z0-9_]*',
      );
      final found = <String>{};
      var themeLayerHits = 0;
      final scanned = <String>{};
      for (final file in _dartFilesUnder('lib')) {
        final relative = _relativePath(file);
        scanned.add(relative);
        final isThemeLayer = relative.startsWith('lib/theme/');
        for (final match in bareColor.allMatches(file.readAsStringSync())) {
          final literal = match[0]!;
          if (isThemeLayer) {
            themeLayerHits++;
          } else if (!huelessMaterialConstants.contains(literal)) {
            found.add('$relative :: $literal');
          }
        }
      }
      // 别让扫描静默空转：范围必须真的覆盖到 app.dart 与 theme 层自身。
      expect(scanned, contains('lib/app.dart'));
      expect(
        scanned.any((p) => p.startsWith('lib/theme/')),
        isTrue,
        reason: '没扫到 theme 层，放行目录的判断是空的',
      );
      expect(
        themeLayerHits,
        greaterThan(0),
        reason: 'theme 层自身一处裸色值都没有？扫描的形状不匹配了',
      );
      expect(found.length, bareColorAllowList.length, reason: '$found');
      expect(found, bareColorAllowList);
    });
  });

  group('发布门禁脚本与字体资产名保持同步', () {
    // 这条与「token 契约」不是一回事：它管的是 PowerShell 发布脚本里写死的资产
    // 文件名有没有跟着 pubspec 的字族改名一起改，独立成组免得混进颜色断言里。
    test('verify 脚本引用的字族资产名与 pubspec 一致', () {
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
