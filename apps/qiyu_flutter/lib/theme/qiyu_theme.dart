import 'package:flutter/material.dart';

import 'qiyu_tokens.dart';

/// 栖语「紫夜」主题层：把 `QiyuColors` / `QiyuType` / `QiyuRadii` 装配成
/// Material 3 主题，替换早期由单一种子色派生整份色板的写法。
///
/// 色值一律来自 token 层，这里不写任何新的颜色字面值；页面也不该绕过
/// `Theme.of(context)` 直接取色。契约测试见 `test/qiyu_theme_test.dart`。

/// 紫夜五档字阶的具体样式（design-system §3）。
///
/// §3 只定了字号（22/18/15/13/12）与「栖语的话行高 1.9」，其余档位**不自造行高**，
/// 退回随包宋体的默认行高；字重与字距只在有出处时才写，出处一律注明。
abstract final class QiyuTypography {
  /// 空状态问候：22，字重轻、留字距。
  ///
  /// w300 + 3px 字距的出处是原型 `.home-greet { font-weight: 300; letter-spacing: 3px }`
  /// （视觉真相源，见 Spec Further Notes 第 2 条），不是现编值。
  static const TextStyle greeting = TextStyle(
    fontFamily: QiyuType.fontFamily,
    fontSize: QiyuType.greetingSize,
    fontWeight: FontWeight.w300,
    letterSpacing: 3,
  );

  /// 页面标题：18。
  ///
  /// 字重与字距规范未定稿（§3 只给字号，原型 `.page-title` 为 400/2px、
  /// `.set-section h3` 为 500/2px），这里沿用现值 500/1px 待视觉验收段一并定夺，
  /// 不当定论用。行高不自造，取字族默认。
  static const TextStyle title = TextStyle(
    fontFamily: QiyuType.fontFamily,
    fontSize: QiyuType.titleSize,
    fontWeight: FontWeight.w500,
    letterSpacing: 1,
  );

  /// 正文：15。UI 常规行高不另定值，书页式的 1.9 只用于栖语的话。
  static const TextStyle body = TextStyle(
    fontFamily: QiyuType.fontFamily,
    fontSize: QiyuType.bodySize,
  );

  /// 次要：13，时间戳与说明文字。
  static const TextStyle secondary = TextStyle(
    fontFamily: QiyuType.fontFamily,
    fontSize: QiyuType.secondarySize,
  );

  /// 极小：12，徽标与脚注。
  static const TextStyle tiny = TextStyle(
    fontFamily: QiyuType.fontFamily,
    fontSize: QiyuType.tinySize,
  );

  /// 栖语的话：宋体正文、行高 1.9，无气泡书页式（design-system §7）。
  static const TextStyle qiyuMessage = TextStyle(
    fontFamily: QiyuType.fontFamily,
    fontSize: QiyuType.bodySize,
    height: QiyuType.qiyuBodyLineHeight,
  );
}

/// 紫夜字阶表：五档字阶落到 Material 的语义档位上。
TextTheme qiyuTextTheme() {
  return const TextTheme(
    displaySmall: QiyuTypography.greeting,
    headlineSmall: QiyuTypography.title,
    titleMedium: QiyuTypography.title,
    bodyLarge: QiyuTypography.body,
    bodyMedium: QiyuTypography.body,
    bodySmall: QiyuTypography.secondary,
    labelLarge: QiyuTypography.body,
    labelMedium: QiyuTypography.tiny,
    labelSmall: QiyuTypography.tiny,
  );
}

/// 深色「紫夜」主题。全应用唯一的 ThemeData 来源。
ThemeData qiyuDarkTheme() {
  const colorScheme = ColorScheme.dark(
    // 三色纪律（design-system §1、§2；Spec User Story 9）：**没有任何槽位是紫**。
    // M3 会顺着 primary/secondary/tertiary 把颜色铺进 FilledButton 底、Switch 选中
    // 轨道、Slider 轨道、Checkbox 填充、进度条、SegmentedButton、Chip 选中态……
    // 一旦这些槽位取 accent-bright，紫色就从主题层漫出去（本轮修的就是这个）。
    //
    // primary 在 M3 里身兼两职：既当「填充色」也当「图标/文字强调色」。取
    // panel/bubbleUser 那种暗档会让直接读它的图标与滑块在暗底上看不见，所以槽位
    // 本身取中性灰 muted；大面积实底（filled button、选中容器）由下面的组件主题
    // 逐个显式压回 bubbleUser 暗档，文字与图标取 ink / onAccent。
    primary: QiyuColors.muted,
    onPrimary: QiyuColors.night,
    primaryContainer: QiyuColors.bubbleUser,
    onPrimaryContainer: QiyuColors.ink,
    secondary: QiyuColors.muted,
    onSecondary: QiyuColors.night,
    secondaryContainer: QiyuColors.panel,
    onSecondaryContainer: QiyuColors.ink,
    tertiary: QiyuColors.muted,
    onTertiary: QiyuColors.night,
    tertiaryContainer: QiyuColors.panel,
    onTertiaryContainer: QiyuColors.ink,
    // 暗红只住破坏性操作。
    error: QiyuColors.danger,
    onError: QiyuColors.night,
    errorContainer: QiyuColors.danger,
    onErrorContainer: QiyuColors.night,
    // 表面全部中性：底色 night、面板 panel，抬升层次靠 bubbleUser，不靠紫色调。
    surface: QiyuColors.panel,
    onSurface: QiyuColors.ink,
    surfaceDim: QiyuColors.night,
    surfaceBright: QiyuColors.bubbleUser,
    surfaceContainerLowest: QiyuColors.night,
    surfaceContainerLow: QiyuColors.panel,
    surfaceContainer: QiyuColors.panel,
    surfaceContainerHigh: QiyuColors.bubbleUser,
    surfaceContainerHighest: QiyuColors.bubbleUser,
    onSurfaceVariant: QiyuColors.muted,
    outline: QiyuColors.line,
    outlineVariant: QiyuColors.line,
    shadow: QiyuColors.night,
    scrim: QiyuColors.night,
    inverseSurface: QiyuColors.ink,
    onInverseSurface: QiyuColors.night,
    // inversePrimary 出现在 light 版气泡/SnackBar 这类反色面上（底色是 ink），
    // 要的是「反色面上的主色」，取中性 panel；不是紫，也不是 accent-glass 渐变端色。
    inversePrimary: QiyuColors.panel,
    surfaceTint: QiyuColors.elevationTint,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    fontFamily: QiyuType.fontFamily,
    scaffoldBackgroundColor: QiyuColors.night,
    canvasColor: QiyuColors.night,
    cardColor: QiyuColors.panel,
    // 键盘焦点：真正的焦点环是 2px 实线 accent-bright + 3px offset，画在控件表面
    // **之外**，由 `QiyuFocusRing` 自绘（design-system §9，值见
    // QiyuLayout.focusRingWidth / focusRingOffset，第 2 段落地）。M3 的 focusColor
    // 只能贴在控件表面上铺一层，所以这里取中性淡底 selectedNeutral，绝不落实心紫。
    focusColor: QiyuColors.selectedNeutral,
    textTheme: qiyuTextTheme(),
    iconTheme: const IconThemeData(color: QiyuColors.muted, size: 24),
    dividerTheme: const DividerThemeData(color: QiyuColors.line, thickness: 1),
    cardTheme: const CardThemeData(
      color: QiyuColors.panel,
      surfaceTintColor: QiyuColors.elevationTint,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: QiyuRadii.cardBorder,
        side: BorderSide.none,
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: QiyuColors.panel,
      surfaceTintColor: QiyuColors.elevationTint,
      titleTextStyle: QiyuTypography.title,
      contentTextStyle: QiyuTypography.body,
      shape: RoundedRectangleBorder(borderRadius: QiyuRadii.cardBorder),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: QiyuColors.panel,
      contentTextStyle: TextStyle(
        fontFamily: QiyuType.fontFamily,
        fontSize: QiyuType.secondarySize,
        color: QiyuColors.ink,
      ),
      shape: RoundedRectangleBorder(borderRadius: QiyuRadii.smallBorder),
    ),
    // ── 会被 M3 当「填充/表面」用的组件：主题层逐个显式压回中性 ──────────────
    // 只把 ColorScheme 槽位改中性是不够的：这些组件的默认样式读的就是槽位，
    // 下次谁再动槽位又会把紫（或暗到看不见的档）漏进实底。显式定值 + 契约测试
    // （test/qiyu_theme_test.dart「被当填充用的组件在主题层压回中性」）一起守住。
    filledButtonTheme: const FilledButtonThemeData(
      // 实底按钮：中性暗底一档 bubbleUser + ink 文字/图标。accent-glass 玻璃紫
      // 只属于 §8 组件 1/4 的主按钮与发送钮，由页面按 token 直接画，不走这里。
      style: ButtonStyle(
        backgroundColor: WidgetStatePropertyAll<Color>(QiyuColors.bubbleUser),
        foregroundColor: WidgetStatePropertyAll<Color>(QiyuColors.ink),
      ),
    ),
    textButtonTheme: const TextButtonThemeData(
      // §8 组件 2：次按钮 / 文字按钮无底色，label 取 accent-bright
      // ——这是紫被允许的两处用途之一（另一处是键盘焦点环）。
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll<Color>(QiyuColors.accentBright),
      ),
    ),
    outlinedButtonTheme: const OutlinedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll<Color>(QiyuColors.accentBright),
      ),
    ),
    switchTheme: SwitchThemeData(
      // off 态取原型 `.toggle`（轨道 line、拇指 muted）；on 态原型原本是紫渐变
      // 实底，按三色纪律压回中性：muted 轨道 + night 拇指（M3 的 primary/onPrimary
      // 配对语义），两态靠「深拇指在灰轨 / 灰拇指在深轨」区分，不靠紫。
      trackColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.selected)
            ? QiyuColors.muted
            : QiyuColors.line,
      ),
      thumbColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.selected)
            ? QiyuColors.night
            : QiyuColors.muted,
      ),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: QiyuColors.muted,
      inactiveTrackColor: QiyuColors.line,
      // 轨道是灰的，M3 默认拇指色（primary）会与轨道同色糊成一团，拇指显式取 ink。
      thumbColor: QiyuColors.ink,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: QiyuColors.muted,
    ),
    checkboxTheme: CheckboxThemeData(
      // 勾选态实底中性暗档，勾取 ink；未勾选是 panel 底 + line 描边。
      fillColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.selected)
            ? QiyuColors.bubbleUser
            : QiyuColors.panel,
      ),
      checkColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.selected)
            ? QiyuColors.ink
            : QiyuColors.muted,
      ),
      side: const BorderSide(width: QiyuLine.hairline, color: QiyuColors.line),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.selected)
            ? QiyuColors.bubbleUser
            : QiyuColors.panel,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith<Color?>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? QiyuColors.bubbleUser
              : QiyuColors.panel,
        ),
        foregroundColor: WidgetStateProperty.resolveWith<Color?>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? QiyuColors.ink
              : QiyuColors.muted,
        ),
      ),
    ),
    chipTheme: const ChipThemeData(
      // 选中态中性暗底（§8 补充约定「选中态全站统一中性」），不用紫底。
      color: WidgetStatePropertyAll<Color>(QiyuColors.bubbleUser),
      backgroundColor: QiyuColors.panel,
    ),
    navigationBarTheme: const NavigationBarThemeData(
      indicatorColor: QiyuColors.bubbleUser,
      backgroundColor: QiyuColors.panel,
    ),
    navigationRailTheme: const NavigationRailThemeData(
      indicatorColor: QiyuColors.bubbleUser,
      backgroundColor: QiyuColors.panel,
    ),
    // 记忆中心四区 tab：选中态中性——ink 文字 + 淡白下划线，不用种子紫。
    // on-accent 的语义是「强调底色上的文字」，tab 是中性底，所以取 ink
    // （原型 `.tab.active` 亦为 var(--ink)）。
    tabBarTheme: const TabBarThemeData(
      labelColor: QiyuColors.ink,
      unselectedLabelColor: QiyuColors.muted,
      labelStyle: QiyuTypography.body,
      unselectedLabelStyle: QiyuTypography.body,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: QiyuColors.line,
      indicator: UnderlineTabIndicator(
        borderRadius: QiyuRadii.smallBorder,
        borderSide: BorderSide(
          width: QiyuLine.tabIndicator,
          color: QiyuColors.indicatorNeutral,
        ),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: QiyuColors.muted,
      textColor: QiyuColors.ink,
      titleTextStyle: QiyuTypography.body,
      subtitleTextStyle: QiyuTypography.secondary,
      selectedTileColor: QiyuColors.selectedNeutral,
      shape: RoundedRectangleBorder(borderRadius: QiyuRadii.cardBorder),
    ),
    // composer：毛玻璃、胶囊全圆角、发丝描边、内边距 6、占位字 muted。
    // 页面接线留给第 2 段，值先在这里定死。
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: QiyuColors.glass,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: QiyuSpacing.md,
        vertical: QiyuLayout.composerPadding,
      ),
      hintStyle: const TextStyle(
        fontFamily: QiyuType.fontFamily,
        fontSize: QiyuType.bodySize,
        color: QiyuColors.muted,
        // 行高 = 图标按钮高度（§8 组件 5「占位字垂直居中，行高对齐按钮高度 34px」），
        // 由 token 相除得出，不写死裸比值。
        height: QiyuLayout.composerIconButtonSize / QiyuType.bodySize,
      ),
      border: _composerBorder(QiyuColors.line),
      enabledBorder: _composerBorder(QiyuColors.line),
      focusedBorder: _composerBorder(QiyuColors.composerFocusLine),
      errorBorder: _composerBorder(QiyuColors.danger),
      focusedErrorBorder: _composerBorder(QiyuColors.danger),
    ),
  );
}

/// composer 描边：胶囊上的 1px 发丝线。
OutlineInputBorder _composerBorder(Color color) => OutlineInputBorder(
  borderRadius: QiyuRadii.pillBorder,
  borderSide: BorderSide(width: QiyuLine.hairline, color: color),
);
