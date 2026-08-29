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
/// 本层除色值外还收着圆角（[QiyuRadii]）、线宽与指示器几何（[QiyuLine]）、间距、
/// 字族字阶、布局与玻璃常量。全应用**只有本层可以出现裸色值**：`test/qiyu_theme_test.dart`
/// 的棘轮扫描覆盖整个 `lib/**`（含 `lib/app.dart` 与未来的 `lib/widgets/`），
/// 只放行 `lib/theme/**`，现存的历史残留逐段清空。

/// 语义色板（design-system §2）。
abstract final class QiyuColors {
  /// 底色：页面背景（近黑）。
  static const Color night = Color(0xFF0F0E14);

  /// 面板：卡片、侧边栏与抽屉的基色（中性暗）。
  static const Color panel = Color(0xFF181719);

  /// 字色：正文（暖调象牙白偏紫）。
  static const Color ink = Color(0xFFECE9F2);

  /// 次要字：次要文字、占位符。
  ///
  /// 只服务**文字位**。要一个看得见、压在文字之下的中性**填充**（活动轨道、
  /// 进度条、开关选中轨道），请取 [neutralFillStrong]，不要直接拿本常量去填。
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
  /// 的槽位清扫与组件填充断言就是用来抓这个回退的。需要「中性强调」时用
  /// [neutralEmphasis]，它才是 M3 强调槽位与拇指的正确档位。
  static const Color accentBright = Color(0xFF9D8FE0);

  /// 图标近白：强调底色上的图标与文字。
  ///
  /// 语义限定在「紫/暗红这类强调底色之上」（design-system §2）。中性底上的文字——
  /// 包括记忆中心 tab 的选中态、导航项选中态——一律取 [ink]，不要顺手用本常量。
  static const Color onAccent = Color(0xFFF5F3FA);

  /// 用户气泡面色：中性暗、无描边，靠面色与背景拉开层次。
  ///
  /// 文档用途**只有**「用户消息气泡」（design-system §2、§7）。它一度被主题层
  /// 当通用中性填充到处兼职，那件事现在由 [neutralFill] 接管；本常量不要再被
  /// 拿去填按钮、chip、导航指示器或 surface 色阶。
  static const Color bubbleUser = Color(0xFF28272E);

  // ── 中性功能角色 ───────────────────────────────────────────────────────────
  // §2 的 token 表是按「文字 / 气泡 / 描边」这些**用途**命名的，而 M3 的
  // ColorScheme 槽位与组件状态要的是「强调位 / 填充位」这类**功能**角色。直接
  // 拿文字角色去填功能位会同时犯两个错：名字骗人，以及档位选错（例如拿次要字
  // 色 muted 当 primary，所有直接读 colorScheme.primary 的图形件立刻变成暗灰，
  // 音量滑块的拇指与轨道同色糊成一条）。下面三个角色只复用上面已有的中性色值，
  // **不引入任何新的色相**，取值由契约测试逐个锁死。

  /// 中性强调位：M3 的 primary/secondary/tertiary 槽位、滑块与开关的拇指、
  /// 以及页面里直接读 `colorScheme.primary` 的图标。
  ///
  /// 与 [onAccent] 同值（中性近白），但语义不同：[onAccent] 专指「紫/暗红这类
  /// 强调底色之上的文字与图标」，本角色指「中性底之上的强调件」。
  static const Color neutralEmphasis = onAccent;

  /// 通用中性填充位：实底按钮、选中容器、chip、导航指示器、抬升 surface 色阶。
  ///
  /// 与 [bubbleUser] 同值（中性暗一档），语义是「填充」而不是「用户气泡」。
  static const Color neutralFill = bubbleUser;

  /// 中性强填充位：活动轨道、开关选中轨道、进度条这类**要看得见、但压在文字
  /// 之下**的填充件。
  ///
  /// 与 [muted] 同值（中性灰档），但 [muted] 在 §2 的语义是次要文字与占位符；
  /// 填充位取本角色，文字位取 [muted]，两者靠契约测试保持同值。
  static const Color neutralFillStrong = muted;

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
///
/// §8 的圆角是**三种**形状：小圆角 8、卡片 18、胶囊（输入框）；「圆形」（图标按钮、
/// 发送钮）不在这里——用一个 999 的 radius 表达圆形会和胶囊撞值，语义上分不出两种
/// 形状，所以圆形由 `BoxShape.circle` / `CircleBorder` 的**形状语义**承载。主题层
/// 当前没有任何圆形消费方，因此不再预登记 ShapeBorder 常量（零消费即删）；等第 2 段
/// 圆形图标按钮与发送钮落地、真的需要共享轮廓时再加。
abstract final class QiyuRadii {
  /// 小元素。
  static const double small = 8;

  /// 卡片与列表项；12px 及以下的方正小圆角已验证偏 AI 感，不再使用。
  ///
  /// 侧边栏/抽屉的**导航项**也归这一档（§8 组件 6「导航项」与组件 7「列表项」同为
  /// 列表项形态，2026-08-29 裁定取 18，不取实现里残留的 small 档）。
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

  /// 圆形轮廓：第 2 段落地的三条杠图标按钮与发送钮共享。
  ///
  /// 它**不是**第二个 999 档位——由 [pill] 派生，且只服务 `QiyuFocusRing` /
  /// `QiyuGlassPanel` 这类必须拿 `BorderRadius` 的裁剪与描边；触摸与 ink 扩散
  /// 的圆形语义仍由调用方的 `BoxShape.circle` / `CircleBorder` 承载（见上面
  /// 的类注释：圆形靠形状语义，不靠 radius）。
  static const BorderRadius circleBorder = pillBorder;

  /// 用户气泡：右对齐水滴形，指向角落在右下（20/20/6/20）。
  static const BorderRadius bubbleBorder = BorderRadius.only(
    topLeft: Radius.circular(bubble),
    topRight: Radius.circular(bubble),
    bottomRight: Radius.circular(bubbleTail),
    bottomLeft: Radius.circular(bubble),
  );
}

/// 线条宽度与状态线几何。
///
/// 发丝线 1px（design-system §2 `line`、§8 组件 5「`line` 发丝描边」）与焦点/tab
/// 这类状态线 2px（§9 焦点环 2px；原型 `.tab.active` 的 `border-bottom: 2px`）。
/// 别的宽度不要现编。
abstract final class QiyuLine {
  /// 发丝描边。
  static const double hairline = 1;

  /// 状态线：tab 下划线（焦点环的 2px 同值，见 §9）。
  static const double tabIndicator = 2;

  /// tab 指示器的下内缩：**几何修正值，不是间距档**。
  ///
  /// 两种基准不一样：原型 `.tab` 的 `border-bottom: 2px`（配 `padding: 10px 16px`
  /// 与 `margin-bottom: -1px`）贴在**标签自身盒子**的底边上，而 Flutter 的
  /// `UnderlineTabIndicator` 画在**整条 TabBar 的底边**，label 之下的留白会让线
  /// 落得比原型低一档。去掉内缩就是把下划线推离标签、贴到栏框上去。6px 是为对齐
  /// 这两种基准留下的实现期修正值（非规范定值，记忆中心接线时随原型复验），因此
  /// 刻意不收进 §8 的 4px 间距体系——那套体系管的是 padding 与 gap，别把它当档位
  /// 拿去复用作间距。
  static const double tabIndicatorInset = 6;
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

  /// 消息流所在整列的最大宽度。
  ///
  /// 注意：680 取自原型 `.chat-stream { max-width: 680px }`，design-system 与 Spec
  /// 都没有定稿这个值（只在 `.scratch` 原型里存在）。视觉验收要调就直接改这里并同步
  /// 原型，不要把它当规范定值拒绝调整。
  static const double streamMaxWidth = 680;

  /// 单条消息正文（用户水滴气泡、栖语的无气泡正文、流式增量）的最大宽度。
  ///
  /// 与 [streamMaxWidth] 是**两件事**：680 管整列消息流容器，520 管一条消息自身
  /// 的行长——后者是紫夜改造之前的既有实现值（改造只是把三处裸写的 520 收进
  /// 本 token），不是规范定值，视觉验收要调就改这里。以前它在
  /// `qiyu_chat_bubble.dart` 两处与 `local_chat_view.dart` 流式回复一处各写一遍，
  /// 改一处漏两处。
  static const double messageMaxWidth = 520;

  /// composer 内边距与图标按钮高度（占位字靠它垂直居中）。
  /// 6px 是 §8 组件 5 的「矮一档」定值，不是 4px 网格档位。
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

  /// 键盘焦点环（design-system §9）：2px 实线 accent-bright、offset 3px。
  ///
  /// Material 的 `ThemeData.focusColor` 只能贴在控件表面上，画不出带 offset 的
  /// 外环。**唯一消费方**是 `QiyuFocusRing`——全站自绘焦点环组件，导航壳与
  /// composer 都走它；不要在页面里另写一份 2/3。
  static const double focusRingWidth = 2;
  static const double focusRingOffset = 3;
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

/// 图标尺寸（design-system §4）：统一 24px、outlined、细描边风格。
abstract final class QiyuIconSpec {
  static const double size = 24;

  /// 发送钮里的上箭头图形：圆形 34 直径下收一档。
  static const double sendGlyph = 18;
}

/// 毛玻璃模糊半径（design-system §2、§8）。
///
/// §2 定的是**区间**：16–24px，「实现时凭视觉验收微调」。区间本身是契约，由
/// `test/qiyu_theme_test.dart` 的 `inInclusiveRange(16, 24)` 范围锁守住（防止有人
/// 微调时改成 4 或 60 这类越界值）；区间内取哪一个值不是契约，所以这里只留**一个
/// 可微调定值**：面板/侧边栏/抽屉取原型 `:root { --blur: blur(20px) }` 的 20，
/// 验收不通过时直接改这一个值并同步原型，不要再拆成 min/max 两个常量。
abstract final class QiyuGlass {
  /// 发送按钮的模糊半径（§8 组件 4）。
  static const double sendButtonBlur = 8;

  /// 面板、侧边栏与抽屉的模糊半径。
  static const double panelBlur = 20;
}
