import 'package:flutter/painting.dart';

/// 栖语「紫夜」设计 token —— 全应用视觉值的唯一来源。
///
/// 权威依据：`docs/product/design-system.md`（第 2、3、5、8、9 节）与
/// `docs/superpowers/specs/2026-08-28-qiyu-web-purple-night-visual-revamp.md`
/// Implementation Decisions 第 1、2、3、16 条。页面与组件**只准消费本层**，
/// 禁止在 widget 里直接写色值、圆角、字号或间距；`test/qiyu_theme_test.dart`
/// 锁住这里的每个字面值。
///
/// 三色纪律：紫只住强调位（文字/图标强调与键盘焦点环、玻璃紫的主按钮与发送钮），
/// 暗红只住危险位（破坏性操作），其余表面、线条、选中态一律中性暗夜色。
///
/// 本层除色值外还收着圆角（[QiyuRadii]）、形状（[QiyuShapes]）、线宽（[QiyuLine]）、
/// 间距、字族字阶、布局与玻璃常量。`lib/features/**` 现存的裸 `Color(0x…)` 字面量由
/// 测试里的棘轮允许清单逐段清空（见 `test/qiyu_theme_test.dart` 的「回归锁」组）。

/// 语义色板（design-system §2）。
abstract final class QiyuColors {
  /// 底色：页面背景（近黑）。
  static const Color night = Color(0xFF0F0E14);

  /// 面板：卡片、侧边栏与抽屉的基色（中性暗）。
  static const Color panel = Color(0xFF181719);

  /// 字色：正文（暖调象牙白偏紫）。
  static const Color ink = Color(0xFFECE9F2);

  /// 次要字：次要文字、占位符。
  static const Color muted = Color(0xFF9A94A8);

  /// 强调-交互起点：玻璃紫渐变首色 `rgba(75,64,146,.62)`。
  ///
  /// `accent-glass` 是「两端渐变 + 背景模糊」的**组合体**（design-system §2、§8 组件
  /// 1/4），只出现在发送按钮与主按钮上，且必须成对使用；单独取其中一端当 `ColorScheme`
  /// 的单色槽位（例如 primaryContainer）是错映射——那会把 α0.5 的渐变末色当实色铺底。
  static const Color accentGlassA = Color(0x9E4B4092);

  /// 强调-交互终点：玻璃紫渐变末色 `rgba(51,43,97,.5)`。见 [accentGlassA] 的使用边界。
  static const Color accentGlassB = Color(0x80332B61);

  /// 强调-状态：焦点描边、键盘导航（唯一允许出现在非玻璃组件上的紫）。
  ///
  /// 全紫只有两处用途（design-system §1 三色纪律、§8 组件 2、§9；Spec User Story 9
  /// 「界面里除了发送按钮和键盘焦点外没有任何紫色」）：
  /// 1. **文字/图标强调**——次按钮与文字按钮的 label、文字链接；
  /// 2. **键盘焦点环**——由 `QiyuFocusRing` 自绘的 2px + offset 3px 外环。
  ///
  /// 禁止把它写进任何会被 M3 当**填充/表面**用的 `ColorScheme` 槽位
  /// （primary/secondary/tertiary 及其容器、onPrimary 等）——M3 会顺着这些槽位把亮紫
  /// 铺到 FilledButton、Switch、Slider、Checkbox、进度条上。`test/qiyu_theme_test.dart`
  /// 的槽位清扫与组件填充断言就是用来抓这个回退的。
  static const Color accentBright = Color(0xFF9D8FE0);

  /// 图标近白：强调底色上的图标与文字。
  ///
  /// 语义限定在「紫/暗红这类强调底色之上」（design-system §2）。中性底上的文字——
  /// 包括记忆中心 tab 的选中态、导航项选中态——一律取 [ink]，不要顺手用本常量。
  static const Color onAccent = Color(0xFFF5F3FA);

  /// 用户气泡面色：中性暗、无描边，靠面色与背景拉开层次。
  static const Color bubbleUser = Color(0xFF28272E);

  /// 描边：发丝线（中性暗）。
  static const Color line = Color(0xFF232227);

  /// 危险：降饱和暗红，**仅破坏性操作**。唯一例外是 Host 健康探测失败时
  /// 的连接状态文案（它表达的是危险态，不是破坏性操作）。
  static const Color danger = Color(0xFFCC9999);

  /// 选中态：中性暗底 `rgba(255,255,255,0.04)`，不用紫色底。
  static const Color selectedNeutral = Color(0x0AFFFFFF);

  /// 毛玻璃基色 `rgba(19,18,23,0.72)`：比 [panel] 暗一档，不从 panel 拼透明度
  /// 得出，目的是不把背景紫透出来。依据 design-system §2 与决策日志「原型迭代
  /// 定案」（2026-08-28 裁定取此值）。
  static const Color glass = Color(0xB8131217);

  /// 记忆中心 tab 的淡白下划线 `rgba(255,255,255,0.30)`：选中态中性化后
  /// 用来替代原来的种子紫下划线（决策日志第二轮 3）。
  static const Color indicatorNeutral = Color(0x4DFFFFFF);

  /// composer 聚焦描边：`accent-bright` 压到透明度 0.13，只比无焦点略紫
  /// （design-system §8 组件 5；不要与键盘焦点环的 2px 实紫混用）。
  static const Color composerFocusLine = Color(0x219D8FE0);

  ///  elevation 色调叠加：本设计不靠 M3 的 tint 提亮（会把紫铺满抬升面），
  /// 抬升层次改用中性面板色阶。
  static const Color elevationTint = Color(0x00000000);
}

/// 几何 token：圆角（design-system §8）。
///
/// §8 的圆角是**三种**形状：小圆角 8、卡片 18、胶囊（输入框）；「圆形」（图标按钮、
/// 发送钮）不在这里——用一个 999 的 radius 表达圆形会和胶囊撞值，语义上分不出两种
/// 形状，所以圆形走 [QiyuShapes.circleBorder] / `BoxShape.circle` 的形状语义。
abstract final class QiyuRadii {
  /// 小元素。
  static const double small = 8;

  /// 卡片与列表项；12px 及以下的方正小圆角已验证偏 AI 感，不再使用。
  static const double card = 18;

  /// 胶囊形：composer。
  static const double pill = 999;

  /// 气泡主体圆角。
  static const double bubble = 20;

  /// 气泡指向角：柔和不尖锐。
  static const double bubbleTail = 6;

  static const BorderRadius smallBorder = BorderRadius.all(
    Radius.circular(small),
  );
  static const BorderRadius cardBorder = BorderRadius.all(
    Radius.circular(card),
  );
  static const BorderRadius pillBorder = BorderRadius.all(
    Radius.circular(pill),
  );

  /// 用户气泡：右对齐水滴形，指向角落在右下（20/20/6/20）。
  static const BorderRadius bubbleBorder = BorderRadius.only(
    topLeft: Radius.circular(bubble),
    topRight: Radius.circular(bubble),
    bottomRight: Radius.circular(bubbleTail),
    bottomLeft: Radius.circular(bubble),
  );
}

/// 形状 token：圆形（design-system §8 组件 3「圆形图标按钮」、组件 4「发送按钮」）。
///
/// 圆形不要拿 [QiyuRadii.pill] 的 999 当「够大的圆角」凑——那会让胶囊和圆形在代码里
/// 长得一样。实心底用 `BoxShape.circle`，带描边/可点击的用本常量。
abstract final class QiyuShapes {
  /// 圆形轮廓：图标按钮、发送钮、状态圆点。
  static const CircleBorder circleBorder = CircleBorder();
}

/// 线条宽度 token：规范里只有两种线。
///
/// 发丝线 1px（design-system §2 `line`、§8 组件 5「`line` 发丝描边」）与焦点/tab
/// 这类状态线 2px（§9 焦点环 2px；原型 `.tab.active` 的 `border-bottom: 2px`）。
/// 别的宽度不要现编。
abstract final class QiyuLine {
  /// 发丝描边。
  static const double hairline = 1;

  /// 状态线：tab 下划线（焦点环的 2px 同值，见 §9）。
  static const double tabIndicator = 2;
}

/// 间距 token：4px 基础网格（design-system §8）。
abstract final class QiyuSpacing {
  /// 基础网格，所有档位都是它的整数倍。
  static const double grid = 4;

  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
}

/// 排版 token：字族与字阶（design-system §3）。精美优先，宁小勿大。
abstract final class QiyuType {
  /// 全局唯一字族：思源宋体。pubspec 里的 `Roboto` 别名同样指向这份子集，
  /// 用来防止未随包字族触发远程回退（2026-08 修「字体回退卡死」的结论）。
  static const String fontFamily = 'Noto Serif SC';

  /// 空状态首页问候。
  static const double greetingSize = 22;

  /// 页面标题。
  static const double titleSize = 18;

  /// 消息与正文。
  static const double bodySize = 15;

  /// 时间戳、说明文字。
  static const double secondarySize = 13;

  /// 徽标、脚注。
  static const double tinySize = 12;

  /// 栖语的话：书页式行高。
  static const double qiyuBodyLineHeight = 1.9;
}

/// 布局与玻璃 token（design-system §5、§8）：第 2 段起的导航壳与 composer
/// 直接取这里的常量，避免值散落到各页面。
abstract final class QiyuLayout {
  /// 宽屏（常驻侧边栏）与窄屏（汉堡抽屉）的断点。
  static const double desktopBreakpoint = 760;

  /// 桌面常驻侧边栏宽度。
  static const double sidebarWidth = 240;

  /// 窄屏抽屉宽度约占视口 2/3。
  static const double drawerWidthFraction = 2 / 3;

  /// 消息流最大宽度。
  ///
  /// 注意：680 取自原型 `.chat-stream { max-width: 680px }`，design-system 与 Spec
  /// 都没有定稿这个值（只在 `.scratch` 原型里存在）。视觉验收要调就直接改这里并同步
  /// 原型，不要把它当规范定值拒绝调整。
  static const double streamMaxWidth = 680;

  /// composer 内边距与图标按钮高度（占位字靠它垂直居中）。
  /// 6px 是 §8 组件 5 的「矮一档」定值，不是 4px 网格档位。
  static const double composerPadding = 6;
  static const double composerIconButtonSize = 34;

  /// 键盘焦点环（design-system §9）：2px 实线 accent-bright、offset 3px。
  ///
  /// Material 的 `ThemeData.focusColor` 只能贴在控件表面上，画不出带 offset 的
  /// 外环，所以真正的焦点环由 `QiyuFocusRing` 自绘（第 2 段落地），这里只定值。
  static const double focusRingWidth = 2;
  static const double focusRingOffset = 3;
}

/// 毛玻璃模糊半径（design-system §2、§8）。
///
/// §2 的 16–24 是「凭视觉验收微调」的区间，不是契约，所以这里只留**一个定值**：
/// 面板/侧边栏/抽屉取原型 `:root { --blur: blur(20px) }` 的 20，验收不通过时直接改
/// 这一个值（改完同步原型），不要再拆成 min/max 让测试去锁区间。
abstract final class QiyuGlass {
  /// 发送按钮的模糊半径（§8 组件 4）。
  static const double sendButtonBlur = 8;

  /// 面板、侧边栏与抽屉的模糊半径。
  static const double panelBlur = 20;
}
