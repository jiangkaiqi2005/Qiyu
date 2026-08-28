import 'package:flutter/painting.dart';

/// 栖语「紫夜」设计 token —— 全应用视觉值的唯一来源。
///
/// 权威依据：`docs/product/design-system.md`（第 2、3、5、8、9 节）与
/// `docs/superpowers/specs/2026-08-28-qiyu-web-purple-night-visual-revamp.md`
/// Implementation Decisions 第 1、2、3、16 条。页面与组件**只准消费本层**，
/// 禁止在 widget 里直接写色值、圆角、字号或间距；`test/qiyu_theme_test.dart`
/// 锁住这里的每个字面值。
///
/// 三色纪律：紫只住强调位（发送按钮、键盘焦点），暗红只住危险位（破坏性
/// 操作），其余表面、线条、选中态一律中性暗夜色。

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
  static const Color accentGlassA = Color(0x9E4B4092);

  /// 强调-交互终点：玻璃紫渐变末色 `rgba(51,43,97,.5)`。
  static const Color accentGlassB = Color(0x80332B61);

  /// 强调-状态：焦点描边、键盘导航（唯一允许出现在非玻璃组件上的紫）。
  static const Color accentBright = Color(0xFF9D8FE0);

  /// 图标近白：强调底色上的图标与文字。
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

  /// 毛玻璃基色：`panel` 的高透明度版本（design-system §2「毛玻璃 = panel
  /// 高透明度 + 背景模糊」），透明度沿用原型定值 0.72。
  static const Color glass = Color(0xB8181719);

  /// 记忆中心 tab 的淡白下划线 `rgba(255,255,255,0.30)`：选中态中性化后
  /// 用来替代原来的种子紫下划线（决策日志第二轮 3）。
  static const Color indicatorNeutral = Color(0x4DFFFFFF);

  /// composer 聚焦描边：`accent-bright` 压到透明度 0.13，只比无焦点略紫
  /// （design-system §8 组件 5；不要与键盘焦点环的 2px 实紫混用）。
  static const Color composerFocusLine = Color(0x219D8FE0);

  ///  elevation 色调叠加：本设计不靠 M3 的 tint 提亮（会把紫铺满抬升面），
  /// 抬升层次改用中性面板色阶。
  static const Color elevationTint = Color(0x00000000);

  /// 窄屏抽屉遮罩：底色压深到 0.55（design-system §5 窄屏；原型 `.scrim` 定值
  /// `rgba(10,9,14,.55)`）。中性夜色，不着紫。
  static const Color scrimSoft = Color(0x8C0A090E);

  /// 首页背景左右两端暗角 `rgba(15,14,20,.92)`（design-system §6「暗角要足」）。
  static const Color backdropVeilEdge = Color(0xEB0F0E14);

  /// 首页背景中部过渡 `rgba(15,14,20,.25)`。
  static const Color backdropVeilMid = Color(0x400F0E14);

  /// 中心渐晕内圈 `rgba(15,14,20,.15)`。
  static const Color backdropVignetteInner = Color(0x260F0E14);

  /// 中心渐晕外圈 `rgba(15,14,20,.78)`。
  static const Color backdropVignetteOuter = Color(0xC70F0E14);

  /// 发送钮光晕：`rgba(70,60,125,.30)`——规范 §8 组件 4 只允许「极淡紫色光晕」，
  /// 无描边、无白色高光。
  static const Color sendGlow = Color(0x4D463C7D);
}

/// 几何 token：圆角（design-system §8）。
abstract final class QiyuRadii {
  /// 小元素。
  static const double small = 8;

  /// 卡片与列表项；12px 及以下的方正小圆角已验证偏 AI 感，不再使用。
  static const double card = 18;

  /// 胶囊形：composer。
  static const double pill = 999;

  /// 圆形：图标按钮与发送钮。
  static const double circle = 999;

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
  static const BorderRadius circleBorder = BorderRadius.all(
    Radius.circular(circle),
  );

  /// 用户气泡：右对齐水滴形，指向角落在右下（20/20/6/20）。
  static const BorderRadius bubbleBorder = BorderRadius.only(
    topLeft: Radius.circular(bubble),
    topRight: Radius.circular(bubble),
    bottomRight: Radius.circular(bubbleTail),
    bottomLeft: Radius.circular(bubble),
  );
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
  static const double streamMaxWidth = 680;

  /// composer 内边距与图标按钮高度（占位字靠它垂直居中）。
  static const double composerPadding = 6;
  static const double composerIconButtonSize = 34;

  /// 侧边栏内边距：上下 24、左右 16（原型 `.sidebar` padding 定值）。
  static const double sidebarPaddingVertical = QiyuSpacing.lg;
  static const double sidebarPaddingHorizontal = QiyuSpacing.md;

  /// 导航项内边距：上下 10、左右 12，图标与文字间距 12。
  static const double navItemPaddingVertical = 10;
  static const double navItemPaddingHorizontal = QiyuSpacing.sm;
  static const double navItemIconGap = QiyuSpacing.sm;

  /// 品牌槽的几何占位尺寸：与 composer 图标按钮同档（34）。
  static const double brandMarkSize = composerIconButtonSize;

  /// 窄屏三条杠圆钮直径（原型 `.menu-btn` 定值 40）。
  static const double menuButtonSize = 40;

  /// 空状态首页内容宽度：min(560, 86vw)（原型 `.home-content`）。
  static const double homeContentMaxWidth = 560;
  static const double homeContentWidthFraction = 0.86;

  /// 连接状态小圆点直径（design-system §5：6px）。
  static const double connectionDotSize = 6;
}

/// 首页背景图的运行时滤镜定值（design-system §6）：入库图保持原构图，
/// 虚化、亮度、饱和度全部运行时施加，调参不必重新出图。
abstract final class QiyuBackdrop {
  /// 模糊半径 5px（原型 `.home-bg` filter: blur(5px)）。
  static const double blurSigma = 5;

  /// 整体偏暗：亮度 0.45。
  static const double brightness = 0.45;

  /// 饱和度 0.55。
  static const double saturation = 0.55;

  /// 模糊会把边缘透出透明，放大 1.03 盖住（原型 transform: scale(1.03)）。
  static const double scale = 1.03;

  /// 构图焦点偏上（原型 `center 40%`）。
  static const Alignment alignment = Alignment(0, -0.2);
}

/// 动效档位（design-system §9）：一律 150–250ms 轻缓动。reduced-motion
/// 下由 `qiyuMotion()` 统一压成 `Duration.zero`，页面不得自写时长。
abstract final class QiyuMotion {
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration base = Duration(milliseconds: 200);
  static const Duration drawer = Duration(milliseconds: 220);
}

/// 自绘键盘焦点环几何（design-system §9）：Material 的 `focusColor` 只能
/// 贴在控件表面，画不出带 offset 的外环。
abstract final class QiyuFocus {
  /// 环宽 2px，取 `accentBright`。
  static const double ringWidth = 2;

  /// 环与控件之间留 3px。
  static const double ringOffset = 3;
}

/// 图标尺寸（design-system §4）：统一 24px、outlined、细描边风格。
abstract final class QiyuIconSpec {
  static const double size = 24;

  /// 发送钮里的上箭头图形：圆形 34 直径下收一档。
  static const double sendGlyph = 18;
}

/// 毛玻璃模糊半径（design-system §2、§8；16–24 为验收区间，凭视觉微调）。
abstract final class QiyuGlass {
  /// 发送按钮的模糊半径。
  static const double sendButtonBlur = 8;

  /// 面板、侧边栏与抽屉的模糊半径默认值。
  static const double panelBlur = 20;

  static const double panelBlurMin = 16;
  static const double panelBlurMax = 24;
}
