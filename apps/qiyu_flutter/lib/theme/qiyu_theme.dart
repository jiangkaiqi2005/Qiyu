import 'package:flutter/material.dart';

import 'qiyu_tokens.dart';

/// 栖语「紫夜」主题层：把 `QiyuColors` / `QiyuType` / `QiyuRadii` 装配成
/// Material 3 主题，替换早期由单一种子色派生整份色板的写法。
///
/// 色值一律来自 token 层，这里不写任何新的颜色字面值；页面也不该绕过
/// `Theme.of(context)` 直接取色。
///
/// 取档纪律：M3 的槽位与组件状态按**功能角色**取，不按「哪个颜色长得像」取——
/// 强调位（primary/secondary/tertiary、拇指、直接读 `colorScheme.primary` 的图标）
/// 用 `neutralEmphasis`，实底填充用 `neutralFill`，看得见的轨道与进度用
/// `neutralFillStrong`，文字与描边用 `ink` / `muted` / `line`。组件状态解析只走
/// [qiyuNeutralStates] 一处。契约测试见 `test/qiyu_theme_test.dart`。

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
  /// §3 只定字号；字重与字距**没有一致出处**——原型 `.page-title` 是 400/2px、
  /// `.set-section h3` 是 500/2px、`.settings-flat .set-section h3` 是 400/3px，
  /// 三处互相打架。原来的 w500 + 1px 两个值都查不到来源，一律去掉退回字族默认，
  /// 等视觉验收段随字阶一起定夺；不要为了保留而编出处。
  static const TextStyle title = TextStyle(
    fontFamily: QiyuType.fontFamily,
    fontSize: QiyuType.titleSize,
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

/// 中性状态表：M3 组件「未选中 / 选中 / 悬停 / 禁用」这些态的取值**只在这里
/// 解析一次**。
///
/// 此前每个被当填充用的组件都各写一份同形状的 `resolveWith`（数到七份），加一个
/// 组件就得再记一遍「这里不得显紫、不得取到看不见的档位」——典型的 Shotgun
/// Surgery。现在这份知识收敛到一个 helper 加一张角色登记表：组件主题只登记
/// 「哪一态取哪个中性角色」，状态解析逻辑全主题层只有这一处。
///
/// [hovered] 与 [disabled] 都是**按需登记**的角色位，不传就退回未选中值：
/// - [hovered]：§8 组件 7「悬停轻提亮」——指针上来只提**前景**，悬停底一律中性，
///   原型的 `rgba(157,143,224,.08)` 淡紫底按 Spec Further Notes 2 压掉；
/// - [disabled]：§2 没有第三档中性，禁用一律靠**透明度降档**表达而不是新色值；
///   不登记就沿用未选中值，避免冒出规范外的新档。
WidgetStateProperty<Color?> qiyuNeutralStates({
  required Color unselected,
  Color? selected,
  Color? hovered,
  Color? disabled,
}) => WidgetStateProperty.resolveWith<Color?>((Set<WidgetState> states) {
  final resting = states.contains(WidgetState.selected)
      ? (selected ?? unselected)
      : unselected;
  if (states.contains(WidgetState.disabled)) {
    // 没登记 disabled 角色就沿用静置值：透明度降档由控件自己表达。
    return disabled ?? resting;
  }
  if (states.contains(WidgetState.hovered)) {
    return hovered ?? resting;
  }
  return resting;
});

/// 中性「底」登记表：选中抬到 [QiyuColors.neutralFill]，未选中压回 panel。
/// Checkbox 填充、Radio 填充、SegmentedButton 底色共用（三处此前各写一份）。
WidgetStateProperty<Color?> qiyuNeutralFillStates() => qiyuNeutralStates(
  unselected: QiyuColors.panel,
  selected: QiyuColors.neutralFill,
);

/// 中性「前景」登记表：选中 ink，未选中 muted（文字位，取 §2 的次要字档）。
/// Checkbox 勾色、SegmentedButton 文字共用。
WidgetStateProperty<Color?> qiyuNeutralContentStates() =>
    qiyuNeutralStates(unselected: QiyuColors.muted, selected: QiyuColors.ink);

/// 「常驻但安静」的图标按钮前景档：design-system §8 补充约定「操作按钮常驻…
/// 次要色、悬停提亮」与 Spec Implementation Decision 14 的唯一取值处。
///
/// 放在主题层而不是页面里，理由同 [qiyuNeutralStates]：这条「静置压成次要字、
/// 指针上来才提亮」的状态知识会被多组常驻图标按钮重复消费，写进页面就会各抄
/// 一份解析器。这里**只登记角色**，解析仍在 [qiyuNeutralStates] 那一处。
///
/// - 静置 [QiyuColors.muted]：§2 的次要字档，按钮在场但不抢读；
/// - 悬停 [QiyuColors.ink]：§8 组件 7 的「提亮」提的是**前景**；悬停底不在这里
///   另写，沿用 M3 图标按钮的中性淡底（本主题 `onSurfaceVariant` 即 muted），
///   与历史页那只常驻删除按钮同一份质感，原型那层淡紫悬停底按 Spec Further
///   Notes 2 一律不取；
/// - 禁用：照 [qiyuNeutralStates] 的纪律不另造色档，只把同一档 muted 按 M3
///   图标按钮 disabled 前景的 0.38 透明度降档。
ButtonStyle qiyuQuietIconButtonStyle() => ButtonStyle(
  foregroundColor: qiyuNeutralStates(
    unselected: QiyuColors.muted,
    hovered: QiyuColors.ink,
    disabled: QiyuColors.muted.withValues(alpha: 0.38),
  ),
);

/// 横向滚动容器不画滚动条：design-system §8 补充约定「横向滚动容器隐藏原生
/// 滚动条，不留浏览器滚动控件」。
///
/// 做法是**换掉绘制层**而不是裁容器：`buildScrollbar` 直接返回 child，滚动、
/// 惯性、指针手势与命中区域一律照旧，只是不再套一层 `Scrollbar`。也不取
/// 「`thumbVisibility: false` + 透明拇指」那条路——滚条虽然画不出来，却会在容器
/// 边缘留下一块看不见但吃命中的拖拽热区。
///
/// 必须**按容器作用域**用（`ScrollConfiguration` 只包住横向滚动的那个容器）：
/// 纵向滚动条不在规范要求去掉之列，整页套上去就把两样一起摘了。
class QiyuNoScrollbarBehavior extends ScrollBehavior {
  const QiyuNoScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

/// 深色「紫夜」主题。全应用唯一的 ThemeData 来源。
///
/// [reduceMotion] 对应系统的「减少动态效果」（design-system §9：开启后关闭
/// **全部**过渡与渐显）。页面自写的动效走 `qiyuMotion()`，但路由页切换与
/// Material ink ripple 是框架自带的、长在 ThemeData 上，只有这里能把它们关掉；
/// 由 `lib/app.dart` 在能读到 MediaQuery 的那一层按系统读数重建主题传入。
ThemeData qiyuDarkTheme({bool reduceMotion = false}) {
  const colorScheme = ColorScheme.dark(
    // 三色纪律（design-system §1、§2；Spec User Story 9）：**没有任何槽位是紫**。
    // M3 会顺着 primary/secondary/tertiary 把颜色铺进 FilledButton 底、Switch 选中
    // 轨道、Slider 轨道、Checkbox 填充、进度条、SegmentedButton、Chip 选中态……
    //
    // 槽位取档按**功能角色**分三类（见 QiyuColors 的「中性功能角色」段）：
    // - 强调槽位 primary/secondary/tertiary → [QiyuColors.neutralEmphasis]（中性近白）。
    //   primary 在 M3 里身兼「填充色」与「图标/文字强调色」两职，而页面有直接读
    //   `colorScheme.primary` 的图形件（音量滑块的拇指与轨道、设置页状态图标）；
    //   拿 §2 的次要文字色 muted 填这里，这些件会在暗底上糊成一片暗灰——名字骗人、
    //   档位也选错。大面积实底另由下面的组件主题显式压到 neutralFill。
    // - 容器/填充槽位 → [QiyuColors.neutralFill]（中性暗一档）或 panel。
    // - 前景槽位 → ink / night，按 on-X 配对。
    primary: QiyuColors.neutralEmphasis,
    onPrimary: QiyuColors.night,
    primaryContainer: QiyuColors.neutralFill,
    onPrimaryContainer: QiyuColors.ink,
    secondary: QiyuColors.neutralEmphasis,
    onSecondary: QiyuColors.night,
    secondaryContainer: QiyuColors.panel,
    onSecondaryContainer: QiyuColors.ink,
    tertiary: QiyuColors.neutralEmphasis,
    onTertiary: QiyuColors.night,
    tertiaryContainer: QiyuColors.panel,
    onTertiaryContainer: QiyuColors.ink,
    // 暗红只住破坏性操作。
    error: QiyuColors.danger,
    onError: QiyuColors.night,
    errorContainer: QiyuColors.danger,
    onErrorContainer: QiyuColors.night,
    // 表面全部中性：底色 night、面板 panel，抬升层次靠 neutralFill，不靠紫色调。
    surface: QiyuColors.panel,
    onSurface: QiyuColors.ink,
    surfaceDim: QiyuColors.night,
    surfaceBright: QiyuColors.neutralFill,
    surfaceContainerLowest: QiyuColors.night,
    surfaceContainerLow: QiyuColors.panel,
    surfaceContainer: QiyuColors.panel,
    surfaceContainerHigh: QiyuColors.neutralFill,
    surfaceContainerHighest: QiyuColors.neutralFill,
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
    // ── reduced-motion（design-system §9）────────────────────────────────
    // 页面自写的过渡已在 `qiyuMotion()` 一处压零；剩下两件是框架自带的、
    // 只能从这里关：路由页切换动画与 Material ink ripple。
    pageTransitionsTheme: reduceMotion
        ? const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: _NoMotionPageTransitionsBuilder(),
              TargetPlatform.fuchsia: _NoMotionPageTransitionsBuilder(),
              TargetPlatform.iOS: _NoMotionPageTransitionsBuilder(),
              TargetPlatform.linux: _NoMotionPageTransitionsBuilder(),
              TargetPlatform.macOS: _NoMotionPageTransitionsBuilder(),
              TargetPlatform.windows: _NoMotionPageTransitionsBuilder(),
            },
          )
        : null,
    splashFactory: reduceMotion ? NoSplash.splashFactory : null,
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
    // ── 会被 M3 当「填充/表面」用的组件：状态色全部从共享中性表取 ────────────
    // 只把 ColorScheme 槽位改中性是不够的：这些组件的默认样式读的就是槽位，
    // 下次谁再动槽位又会把紫（或暗到看不见的档）漏进实底。所以这里逐件登记
    // 「哪一态取哪个中性角色」，解析只在 qiyuNeutralStates 一处；
    // 契约见 test/qiyu_theme_test.dart「被当填充用的组件在主题层压回中性」。
    filledButtonTheme: const FilledButtonThemeData(
      // 实底按钮：中性暗底一档 neutralFill + ink 文字/图标。accent-glass 玻璃紫
      // 只属于 §8 组件 1/4 的主按钮与发送钮，由页面按 token 直接画，不走这里。
      style: ButtonStyle(
        backgroundColor: WidgetStatePropertyAll<Color>(QiyuColors.neutralFill),
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
      // off 态照原型 `.toggle`（轨道 line）；on 态原型原本是紫渐变实底，按三色
      // 纪律压回中性强填充 neutralFillStrong。拇指**两态同色**恒取中性近白
      // neutralEmphasis：拇指是强调位，一旦跟着 primary 落到灰档就会和轨道糊成
      // 一条；两态靠「轨道深浅 + 拇指位置」区分，不靠紫、也不靠把拇指涂黑。
      trackColor: qiyuNeutralStates(
        unselected: QiyuColors.line,
        selected: QiyuColors.neutralFillStrong,
      ),
      thumbColor: const WidgetStatePropertyAll<Color>(
        QiyuColors.neutralEmphasis,
      ),
    ),
    sliderTheme: const SliderThemeData(
      // 活动轨道是「压在文字之下的可见填充」→ neutralFillStrong，未激活一侧取
      // 描边档 line；拇指是强调位 → neutralEmphasis（恒比轨道亮一档，永远分得开）。
      activeTrackColor: QiyuColors.neutralFillStrong,
      inactiveTrackColor: QiyuColors.line,
      thumbColor: QiyuColors.neutralEmphasis,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: QiyuColors.neutralFillStrong,
    ),
    checkboxTheme: CheckboxThemeData(
      // 勾选态实底 neutralFill、勾取 ink；未勾选是 panel 底 + line 描边。
      fillColor: qiyuNeutralFillStates(),
      checkColor: qiyuNeutralContentStates(),
      side: const BorderSide(width: QiyuLine.hairline, color: QiyuColors.line),
    ),
    radioTheme: RadioThemeData(fillColor: qiyuNeutralFillStates()),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: qiyuNeutralFillStates(),
        foregroundColor: qiyuNeutralContentStates(),
      ),
    ),
    chipTheme: const ChipThemeData(
      // 选中态中性暗底（§8 补充约定「选中态全站统一中性」），不用紫底。
      color: WidgetStatePropertyAll<Color>(QiyuColors.neutralFill),
      backgroundColor: QiyuColors.panel,
    ),
    navigationBarTheme: const NavigationBarThemeData(
      indicatorColor: QiyuColors.neutralFill,
      backgroundColor: QiyuColors.panel,
    ),
    navigationRailTheme: const NavigationRailThemeData(
      indicatorColor: QiyuColors.neutralFill,
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
        // 基准对齐：Flutter 把指示器画在整条 TabBar 的底边，原型的 2px 边框贴在
        // 标签自身底边上；不内缩下划线就会离开标签。值见 QiyuLine.tabIndicatorInset
        // （几何修正，不属于 §8 的 4px 间距体系）。
        insets: EdgeInsets.only(bottom: QiyuLine.tabIndicatorInset),
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

/// reduced-motion 下的路由过渡：**不做任何动画**，正向与反向时长都是 0。
///
/// design-system §9 要求开启减少动态效果后关掉全部过渡——路由页切换是框架
/// 自带的那一类，页面里压零 `qiyuMotion()` 管不到它，只能在主题层的
/// `pageTransitionsTheme` 上换掉。这里不自造新的动效档位，只是把动画摘掉。
class _NoMotionPageTransitionsBuilder extends PageTransitionsBuilder {
  const _NoMotionPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => Duration.zero;
}
