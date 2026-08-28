import 'package:flutter/material.dart';

import 'qiyu_tokens.dart';

/// 栖语「紫夜」主题层：把 `QiyuColors` / `QiyuType` / `QiyuRadii` 装配成
/// Material 3 主题，替换早期由单一种子色派生整份色板的写法。
///
/// 色值一律来自 token 层，这里不写任何新的颜色字面值；页面也不该绕过
/// `Theme.of(context)` 直接取色。契约测试见 `test/qiyu_theme_test.dart`。

/// 紫夜五档字阶的具体样式（design-system §3）。
abstract final class QiyuTypography {
  /// 空状态问候：22，字重轻、留字距。
  static const TextStyle greeting = TextStyle(
    fontFamily: QiyuType.fontFamily,
    fontSize: QiyuType.greetingSize,
    fontWeight: FontWeight.w300,
    letterSpacing: 3,
    height: 1.3,
  );

  /// 页面标题：18。
  static const TextStyle title = TextStyle(
    fontFamily: QiyuType.fontFamily,
    fontSize: QiyuType.titleSize,
    fontWeight: FontWeight.w500,
    letterSpacing: 1,
    height: 1.3,
  );

  /// 正文：15。UI 常规行高，书页式的 1.9 只用于栖语的话。
  static const TextStyle body = TextStyle(
    fontFamily: QiyuType.fontFamily,
    fontSize: QiyuType.bodySize,
    height: 1.6,
  );

  /// 次要：13，时间戳与说明文字。
  static const TextStyle secondary = TextStyle(
    fontFamily: QiyuType.fontFamily,
    fontSize: QiyuType.secondarySize,
    height: 1.5,
  );

  /// 极小：12，徽标与脚注。
  static const TextStyle tiny = TextStyle(
    fontFamily: QiyuType.fontFamily,
    fontSize: QiyuType.tinySize,
    height: 1.4,
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
    // 紫只住强调位：primary/secondary/tertiary 与它们之上的图标色。
    primary: QiyuColors.accentBright,
    onPrimary: QiyuColors.onAccent,
    primaryContainer: QiyuColors.accentGlassB,
    onPrimaryContainer: QiyuColors.onAccent,
    secondary: QiyuColors.accentBright,
    onSecondary: QiyuColors.onAccent,
    secondaryContainer: QiyuColors.panel,
    onSecondaryContainer: QiyuColors.ink,
    tertiary: QiyuColors.accentBright,
    onTertiary: QiyuColors.onAccent,
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
    inversePrimary: QiyuColors.accentGlassB,
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
    // 键盘焦点高亮在深色底上必须清晰可见，对比度留足余量（ticket 24）；
    // 带 offset 的外环焦点环自绘，见 design-system §9，本段先定主题值。
    focusColor: QiyuColors.accentBright,
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
    // 记忆中心四区 tab：选中态中性——近白文字 + 淡白下划线，不用种子紫。
    tabBarTheme: const TabBarThemeData(
      labelColor: QiyuColors.onAccent,
      unselectedLabelColor: QiyuColors.muted,
      labelStyle: QiyuTypography.body,
      unselectedLabelStyle: QiyuTypography.body,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: QiyuColors.line,
      indicator: UnderlineTabIndicator(
        borderRadius: QiyuRadii.smallBorder,
        borderSide: BorderSide(width: 2, color: QiyuColors.indicatorNeutral),
        insets: EdgeInsets.only(bottom: 6),
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
        height: 34 / 15, // 行高对齐按钮高度，占位字垂直居中
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
  borderSide: BorderSide(width: 1, color: color),
);
