import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import '../accessibility.dart';
import '../chat/local_chat_view_model.dart';
import '../navigation.dart';
import 'qiyu_connection_status.dart';
import 'qiyu_home_backdrop.dart';
import 'qiyu_widgets.dart';

/// 三项导航的**唯一**出处：目的地、文案与图标（design-system §4 定案选型：
/// 沙漏 / 翻开的书 / 圆形旋钮滑杆，§5 桌面侧边栏）。
///
/// 桌面侧边栏与窄屏抽屉遍历同一张表渲染（材质与文案同源）；聊天页工具条上的
/// 「历史」「模型连接」入口也取这里的图标，不再各抄一份三元组。
///
/// 键位约定：外层（含焦点环）用 `nav-<name>`，内层点击沿用退役前首页入口卡片的
/// 既有测试键 `home-go-<name>`——侧边栏与抽屉会同时渲染同一批文案，测试一律按
/// Key 定位（Spec Testing Decisions 第 8 条）。
enum QiyuNavDestination {
  history('/history', '历史', QiyuIcons.hourglass_empty),
  memory('/memory', '记忆中心', QiyuIcons.menu_book),
  settings('/settings', '设置', QiyuIcons.tune);

  const QiyuNavDestination(this.path, this.label, this.icon);

  final String path;
  final String label;
  final IconData icon;

  Key get outerKey => Key('nav-$name');
  Key get tapKey => Key('home-go-$name');
}

/// 毛玻璃导航壳（design-system §5、Spec Implementation Decisions 第 7 条）。
///
/// **分层**（这是毛玻璃成立的前提）：壳不再把页面背景与侧边栏并排摆（那样
/// `BackdropFilter` 身后是同一层平涂夜色，糊不出任何东西），而是
/// `Stack`：底层 = 全幅页面背景（夜色底 + 仅合一页空态的夜景图，横贯整个
/// 视口，不被 240px 栏切掉）→ 上层 = 壳与内容，侧边栏与抽屉作为半透明层
/// 叠在背景之上。被壳包住的页面因此必须把自己的 `Scaffold` 底色撤成透明。
///
/// - 桌面（宽度 ≥ [QiyuLayout.desktopBreakpoint]）：左侧 240px 毛玻璃侧边栏，
///   自上而下是三项导航 → 底部连接状态；无三条杠、无底部导航。合一页与三个
///   功能页都挂着它（User Story 5「桌面端始终看到侧边栏」）。侧边栏**可收起**
///   （2026-08-31 用户二次裁定：收不回去的问题）：左上角的品牌图标是**常驻的
///   纯开合开关**——点击切换收起/展开，不带任何导航语义；图标不在随动画进出
///   的面板里，开/关两态停在同一位置，全程不重影、不残留，**桌面没有任何
///   「回合一页」入口**。收起状态**不持久化**，刷新/重启回到默认展开。
/// - 窄屏：左上角三条杠打开约视口 2/3 宽的毛玻璃抽屉，内容与桌面**同源**
///   （同一个 [_NavPanel]），点遮罩或按 Esc 收回。抽屉开着时三条杠整块让位
///   （它的命中盒正压在抽屉品牌槽上），抽屉里的品牌槽保持「点击回合一页」
///   语义（键 `go-home` 只留在这里）。
class QiyuShell extends StatefulWidget {
  const QiyuShell({
    super.key,
    this.showHomeBackdrop = false,
    required this.child,
  });

  /// 被壳包住的页面内容（合一页里就是 `LocalChatView`）。
  final Widget child;

  /// 是否由壳负责渲染**合一页空态**的夜景背景：只有合一页（`/` 与 `/chat`）
  /// 为 true，功能页不带背景图（§6「仅空状态出现」）。
  final bool showHomeBackdrop;

  @override
  State<QiyuShell> createState() => _QiyuShellState();
}

class _QiyuShellState extends State<QiyuShell>
    with SingleTickerProviderStateMixin {
  bool _drawerOpen = false;

  /// 桌面侧边栏收起态（2026-08-31 用户裁定）：**不持久化**——刷新/重启回到
  /// 默认展开；只在桌面分支消费，窄屏抽屉不读它。
  bool _sidebarCollapsed = false;

  /// 面板是否在树里：收起动画到底（[_onSidebarAnimationEnd]）才摘出；展开时
  /// 与宽度增长同帧挂回。默认展开即挂载。
  bool _sidebarPanelMounted = true;

  /// 抽屉开合动画。必须在 initState 里建好：惰性字段初始化会在 dispose
  /// 首次访问时于「正在卸载」的树上创建 ticker，直接炸断言。
  late final AnimationController _drawerController;

  /// 抽屉平移曲线：**在 state 里建一次并 dispose**。放在 `build()` 里每次
  /// 重建都会在 [_drawerController] 上留一个状态监听，壳每重绘一次就多一个。
  late final Animation<Offset> _drawerSlide;

  final _menuFocusNode = FocusNode(debugLabel: 'nav-menu-button');

  /// 遮罩的焦点节点：抽屉开着时它接管键盘，Esc 收回抽屉（§9 无障碍）。
  final _scrimFocusNode = FocusNode(debugLabel: 'nav-scrim');

  @override
  void initState() {
    super.initState();
    _drawerController = AnimationController(
      vsync: this,
      duration: QiyuMotion.drawer,
      reverseDuration: QiyuMotion.drawer,
    )..addStatusListener(_onDrawerStatus);
    _drawerSlide =
        Tween<Offset>(begin: const Offset(-1.02, 0), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _drawerController,
            curve: Curves.easeOut,
            reverseCurve: Curves.easeIn,
          ),
        );
  }

  void _onDrawerStatus(AnimationStatus status) {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _drawerController
      ..removeStatusListener(_onDrawerStatus)
      ..dispose();
    _menuFocusNode.dispose();
    _scrimFocusNode.dispose();
    super.dispose();
  }

  /// 开关抽屉。reduced-motion 下时长压成 0：抽屉直接到位，不做平移
  /// （design-system §9）。
  Future<void> _setDrawer(bool open) async {
    final duration = qiyuMotion(context, QiyuMotion.drawer);
    _drawerController.duration = duration;
    _drawerController.reverseDuration = duration;
    setState(() => _drawerOpen = open);
    if (open) {
      await _drawerController.forward();
      // 遮罩**显式**接管键盘：`Focus(autofocus: true)` 只在焦点作用域里还没有
      // 人持焦时才生效，而合一页的 composer 是自动获焦的——只靠 autofocus 的话
      // 焦点留在输入框，Esc 落不进遮罩、抽屉收不回来，所以开抽屉时要把焦点真的
      // 交给遮罩（§9 键盘可关闭）。
      if (mounted) {
        _scrimFocusNode.requestFocus();
      }
    } else {
      await _drawerController.reverse();
      // 焦点交还三条杠：抽屉开着时焦点在遮罩上（它才接得住 Esc），而遮罩随
      // 收回一起被摘出焦点树，不主动给回去的话键盘用户关掉抽屉就丢了位置
      // （design-system §9）。放在 reverse 之后，是为了让环在抽屉真正合上、
      // 遮罩节点已经不在焦点链上时才亮起。
      if (mounted) {
        _menuFocusNode.requestFocus();
      }
    }
  }

  /// 抽屉只在「开着」或「正在滑出去」时留在树里：收到底后不再占用焦点与
  /// 语义树，窄屏也不会被误当成常驻导航。
  bool get _drawerMounted =>
      _drawerOpen || _drawerController.status != AnimationStatus.dismissed;

  /// 三项导航的目的地动作：**换栈**到目的地（`go`），与退役前首页入口卡片的
  /// `_HomeEntry` 完全同一语义（用户裁定：本轮纯视觉换皮，路由与返回栈一项不动）。
  /// 侧边栏是常驻顶层导航，不是「往前翻一层」的内容跳转，所以它重置当前位置，
  /// 页内的「返回上一页」在直接进这一页时退回落地的合一页。
  ///
  /// 换页前无条件停播（ADR 0002：离开这一段话的语境就闭嘴，排队的 bubble 不得
  /// 跨页继续读）：退役前的 `_goHome` 就是这个语义，这里照搬。
  void _goTo(String location) {
    _chatViewModel(context)?.voiceOutput.stopAll();
    context.go(location);
  }

  /// **回合一页**。目的地固定为 `/`（不是「回来时那页」），语义与退役前的
  /// `_goHome` 一致，同样先无条件停播。合一页是首页与对话页的同一个页面，所以
  /// 本次会话已有消息时落回的仍是消息流——不借这个动作新建会话（用户裁定，见
  /// 决策日志第五轮 #8 与 Spec Story 6 的 2026-08-30 收口；要做到字面上的「回
  /// 空状态首页」只能引入新建会话，那是行为改动，越出换皮范围）。
  ///
  /// 消费方（2026-08-31 二次裁定起）：**只剩窄屏抽屉的品牌槽**。桌面不设任何
  /// 「回合一页」入口——品牌图标是侧边栏的常驻纯开合开关，点击不导航。
  void _goHome() {
    _chatViewModel(context)?.voiceOutput.stopAll();
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final desktop = viewport.width >= QiyuLayout.desktopBreakpoint;
    final homeBackdrop =
        widget.showHomeBackdrop &&
        context.select<LocalChatViewModel, bool>(
          (viewModel) => viewModel.isHomeState,
        );

    return QiyuShellScope(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── 底层：全幅页面背景（横贯视口，不被侧边栏切断）───────────────
          const Positioned.fill(child: ColoredBox(color: QiyuColors.night)),
          // 仅合一页空态渲染夜景图；AnimatedSwitcher 淡出后把子树整块摘掉，
          // 聊天态不再为全屏模糊买单（CanvasKit 掉帧时按规范改预烘焙资产）。
          // 必须 Positioned.fill：这张图是整幅 ImageFiltered，拿不到确定尺寸就
          // 合成不出栅格。
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: qiyuMotion(context, QiyuMotion.base),
              child: homeBackdrop
                  ? const QiyuHomeBackdrop(key: Key('home-backdrop'))
                  : const SizedBox.shrink(key: Key('home-backdrop-gone')),
            ),
          ),
          // ── 上层：壳与内容（侧边栏/抽屉是叠在背景上的半透明层）──────────
          if (desktop)
            Row(
              children: [
                // 收起/展开的宽度过渡。用 AnimatedContainer 这类隐式动画，生命
                // 周期由框架自管，不另引入需要 dispose 的 AnimationController
                // （见 _drawerController 处的纪律注释）。
                //
                // 两段编排：收起时宽度 240→0，面板先保持挂载、收到底（onEnd）才
                // 离场，不占焦点与语义树（同抽屉 `_drawerMounted` 的口径）；展开
                // 时面板挂回、宽度 0→240 长回来。全程面板都在 OverflowBox 里按
                // 定宽 240 布局，不在过渡途中被压到小宽度重排（列表项里的固定
                // 图标才不会挤爆），越出盒宽的部分由容器裁掉。
                //
                // 面板里**没有品牌槽**（2026-08-31 二次裁定）：品牌图标是常驻
                // 开合开关 [_sidebarBrandToggle]，叠在面板左上角原品牌槽位置；
                // 面板顶部用等高空位给它让位，过渡期间只有面板在动。
                AnimatedContainer(
                  key: const Key('nav-sidebar-size'),
                  duration: qiyuMotion(context, QiyuMotion.drawer),
                  curve: Curves.easeOut,
                  width: _sidebarCollapsed ? 0 : QiyuLayout.sidebarWidth,
                  // Container 只在带 decoration 时才接受非 none 的裁剪；空装饰
                  // 只为放行这一条。
                  decoration: const BoxDecoration(),
                  clipBehavior: Clip.hardEdge,
                  onEnd: _onSidebarAnimationEnd,
                  child: _sidebarPanelMounted
                      ? OverflowBox(
                          alignment: Alignment.centerLeft,
                          minWidth: QiyuLayout.sidebarWidth,
                          maxWidth: QiyuLayout.sidebarWidth,
                          child: SizedBox(
                            width: QiyuLayout.sidebarWidth,
                            child: _NavPanel(
                              shape: _NavPanelShape.sidebar,
                              onNavigate: _goTo,
                            ),
                          ),
                        )
                      : null,
                ),
                Expanded(child: widget.child),
              ],
            )
          else
            _narrowLayer(viewport),
          // 常驻品牌开合开关：不随收起进出树、不参与淡入淡出，开/关两态停在
          // 同一位置（裁定第 3、4 条）。只有桌面分支渲染它；窄屏的品牌图标在
          // 抽屉品牌槽里，语义是回合一页。
          if (desktop) _sidebarBrandToggle(),
        ],
      ),
    );
  }

  /// 收起动画到底后才把面板摘出树：宽度过渡期间它还在（内容跟着塌），塌到 0
  /// 再离场；展开不需要这一步（挂载与宽度增长同帧开始）。仍在收起态才摘，是
  /// 为了收/展在半途互相打断时不把还该在树里的面板误摘。
  ///
  /// setState 延到帧后：reduced-motion 下时长为 0，onEnd 会在 build 途中同步
  /// 回调，当场 setState 直接撞「build 期间标脏」断言。
  void _onSidebarAnimationEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _sidebarCollapsed && _sidebarPanelMounted) {
        setState(() => _sidebarPanelMounted = false);
      }
    });
  }

  /// 品牌开合开关的点击：只翻转 [_sidebarCollapsed]，不做任何导航（2026-08-31
  /// 二次裁定第 1 条）。展开时面板挂回与宽度增长同帧发生；收起时面板等宽度
  /// 动画到底才离场（[_onSidebarAnimationEnd]）。
  void _toggleSidebar() {
    setState(() {
      _sidebarCollapsed = !_sidebarCollapsed;
      if (!_sidebarCollapsed) {
        _sidebarPanelMounted = true;
      }
    });
  }

  /// 常驻品牌开合开关（2026-08-31 二次裁定第 3、4 条）：**一枚**固定定位的
  /// 毛玻璃圆钮，叠在展开面板左上角原品牌槽的坐标上；收起/展开都只是它旁边
  /// 的面板在动，它自己逐帧不挪位、不进出树、不淡入淡出，因此两态位置天然
  /// 恒定、无重影无残留。键盘可达（自持焦点环）、带 tooltip 与显式语义标签，
  /// 两态分别说清「收起侧边栏」「展开侧边栏」（无字图标按钮的读屏名必须显式
  /// 给，决策日志第五轮 #17）。
  Widget _sidebarBrandToggle() {
    final label = _sidebarCollapsed ? '展开侧边栏' : '收起侧边栏';
    return Positioned(
      top: 0,
      left: 0,
      child: SafeArea(
        // 落位对齐品牌图标在展开面板里的坐标：面板上/左内边距 + 品牌槽自身
        // 那档内缩；再减去焦点环的**常驻**留白，图形本体才正好压在原位上。
        child: Padding(
          padding: const EdgeInsets.only(
            top:
                QiyuLayout.sidebarPaddingVertical +
                QiyuSpacing.xs -
                QiyuLayout.focusRingOffset,
            left:
                QiyuLayout.sidebarPaddingHorizontal +
                QiyuLayout.navItemPaddingHorizontal -
                QiyuLayout.focusRingOffset,
          ),
          child: QiyuOwnFocusRing(
            borderRadius: QiyuRadii.circleBorder,
            builder: (context, focusNode) => QiyuGlassPanel(
              borderRadius: QiyuRadii.circleBorder,
              child: Semantics(
                button: true,
                label: label,
                child: Tooltip(
                  message: label,
                  // 语义标签由外层 Semantics 单点给出，不在语义树里重复一份。
                  excludeFromSemantics: true,
                  child: InkWell(
                    key: const Key('nav-sidebar-toggle'),
                    focusNode: focusNode,
                    customBorder: const CircleBorder(),
                    onTap: _toggleSidebar,
                    child: SizedBox.square(
                      dimension: QiyuLayout.brandMarkSize,
                      child: const Center(
                        child: _BrandMark(key: Key('nav-brand')),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 窄屏：内容铺满视口（背景在它身下），抽屉与遮罩叠在其上。
  Widget _narrowLayer(Size viewport) {
    final drawerWidth = viewport.width * QiyuLayout.drawerWidthFraction;
    return Stack(
      children: [
        widget.child,
        if (_drawerMounted)
          // 遮罩：点它就收回抽屉；键盘下 Esc 同样收回；语义上是按钮，读屏
          // 用户点得到也听得懂（§9）。抽屉开着时焦点归它，Esc 才进得来。
          Positioned.fill(
            child: Focus(
              focusNode: _scrimFocusNode,
              canRequestFocus: true,
              autofocus: true,
              onKeyEvent: _onScrimKeyEvent,
              child: Semantics(
                button: true,
                label: '关闭导航抽屉',
                onTap: () => unawaited(_setDrawer(false)),
                child: GestureDetector(
                  key: const Key('nav-scrim'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => unawaited(_setDrawer(false)),
                  child: const ColoredBox(color: QiyuColors.scrimSoft),
                ),
              ),
            ),
          ),
        if (_drawerMounted)
          Positioned(
            // 抽屉本体定位键：宽度与停靠位置只能按键量，文案在侧边栏
            // 与抽屉里是同一批。
            key: const Key('nav-drawer'),
            top: 0,
            bottom: 0,
            left: 0,
            width: drawerWidth,
            child: SlideTransition(
              position: _drawerSlide,
              child: _NavPanel(
                shape: _NavPanelShape.drawer,
                onNavigate: (location) {
                  unawaited(_setDrawer(false));
                  _goTo(location);
                },
                onHome: () {
                  unawaited(_setDrawer(false));
                  _goHome();
                },
              ),
            ),
          ),
        // 三条杠：圆形图标按钮，玻璃底 + 发丝描边，细描边图形。抽屉开着时
        // 不在树里（点收回的当帧就随抽屉外滑回到树里）：它的命中盒正压在
        // 抽屉品牌槽的栖语图标上，抽屉开着还挂着就会挡住「回合一页」的点击；
        // 关闭由此移交遮罩（点按/Esc）与抽屉内导航项，键盘焦点仍由
        // [_setDrawer] 在收回后交还这枚按钮。
        if (!_drawerOpen)
          Positioned(
            top: 0,
            left: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(QiyuSpacing.md),
                child: QiyuFocusRing(
                  focusNode: _menuFocusNode,
                  borderRadius: QiyuRadii.circleBorder,
                  child: QiyuGlassPanel(
                    borderRadius: QiyuRadii.circleBorder,
                    child: InkWell(
                      key: const Key('nav-menu-button'),
                      focusNode: _menuFocusNode,
                      customBorder: const CircleBorder(),
                      onTap: () => unawaited(_setDrawer(!_drawerOpen)),
                      child: SizedBox.square(
                        dimension: QiyuLayout.menuButtonSize,
                        child: const Center(
                          child: Icon(
                            QiyuIcons.menu,
                            size: QiyuIconSpec.size,
                            color: QiyuColors.ink,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  KeyEventResult _onScrimKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    unawaited(_setDrawer(false));
    return KeyEventResult.handled;
  }
}

/// 壳存在性标记：被 [QiyuShell] 包住的页面据此判断**前导航按钮归谁**。
/// 页面保留自己的 `Scaffold`（信息架构不动），只在壳真的占用同一个角时把
/// 前导航这一件事让给壳。
class QiyuShellScope extends InheritedWidget {
  const QiyuShellScope({super.key, required super.child});

  static bool isPresent(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<QiyuShellScope>() != null;

  /// 页面该不该撤掉自己的返回箭头：**只在窄屏**。
  ///
  /// 窄屏的三条杠浮在左上角，与页内返回箭头叠在同一个位置，这时导航交给
  /// 抽屉。桌面不撤：侧边栏在内容列之外的另一栏，两者不相交，而「回到打开
  /// 这一页的那一层」这条语义只有页内箭头给得出（壳的抽屉品牌槽回的是合一页，
  /// 不必然是空状态；桌面品牌图标只是开合开关，根本没有返回语义）。
  static bool coversFrontNavigation(BuildContext context) {
    if (!isPresent(context)) {
      return false;
    }
    return MediaQuery.sizeOf(context).width < QiyuLayout.desktopBreakpoint;
  }

  /// 页头左侧要为三条杠**再补**的内缩：被壳包住（窄屏）时是它的横向占位，
  /// 其余情况是 0。
  ///
  /// 三条杠是浮在内容之上的层（见 `_narrowLayer`），而功能页的页头自带一档
  /// 左留白，所以这里给的是「占位减去那档已有留白」的差额，页面把它加在
  /// 自己的左内缩之上就够了，不必各自量一遍浮层的三层几何。
  static double headerLeftOverrun(BuildContext context) =>
      coversFrontNavigation(context) ? QiyuLayout.narrowHeaderLeftOverrun : 0;

  @override
  bool updateShouldNotify(QiyuShellScope oldWidget) => false;
}

/// 功能页页头 Row 的**左侧前缀**：桌面与「没被壳包住」时是自己的返回箭头，
/// 窄屏且被壳包住时整块不出现（那个左上角归三条杠，导航交给抽屉）。
///
/// 历史 / 记忆中心 / 设置三页过去各抄一份逐字相同的 `if (!coversFrontNavigation)
/// ...[IconButton, SizedBox]`，连撤箭头的理由都抄三遍；判定口径必须与
/// [QiyuShellScope.coversFrontNavigation] 严格一致，否则页头会与三条杠打架，
/// 所以收成这一处。各页仍传自己的按钮 Key，行为（[backToPrevious]）与位置不变。
class QiyuPageHeaderBackButton extends StatelessWidget {
  const QiyuPageHeaderBackButton({super.key, required this.buttonKey});

  /// 页面自己的返回键（`history-back` / `memory-back` / `settings-back`）。
  final Key buttonKey;

  @override
  Widget build(BuildContext context) {
    if (QiyuShellScope.coversFrontNavigation(context)) {
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: buttonKey,
          onPressed: () => backToPrevious(context),
          tooltip: '返回上一页',
          icon: const Icon(QiyuIcons.arrow_back),
        ),
        const SizedBox(width: QiyuSpacing.xs),
      ],
    );
  }
}

/// 当前路径：用于导航项选中态。go_router 17 的 `GoRouterState` 没有
/// `maybeOf`，走 `GoRouter.maybeOf` 读代理的当前匹配；脱离路由单独 pump
/// 本页时退化成空串（谁都不选中，不报错）。
String _currentLocation(BuildContext context) {
  final router = GoRouter.maybeOf(context);
  if (router == null) {
    return '';
  }
  return router.routerDelegate.currentConfiguration.uri.path;
}

/// 合一页与功能页共用的聊天 view model：`QiyuConnectionStatus` 与壳都要读它，
/// 但本页可以被脱离 Provider 树单独 pump（旧测试），拿不到就退化成中性呈现，
/// 不报错也不谎报。兜底形状与连接状态共用 `qiyu_widgets.dart` 的 [maybeProvider]。
LocalChatViewModel? _chatViewModel(BuildContext context) =>
    maybeProvider(() => context.read<LocalChatViewModel>());

/// 面板的两种形态（2026-08-31 二次裁定）：形态由**显式参数**给出，不拿
/// 回调是否为空兼作判别（上一轮评审报过的味道）。
enum _NavPanelShape {
  /// 桌面侧边栏：不渲染品牌槽——品牌图标是壳上的常驻开合开关，叠在面板
  /// 左上角；面板也没有任何「回合一页」入口。
  sidebar,

  /// 窄屏抽屉：保留品牌槽，点击回合一页（键 `go-home` 只在这里）。
  drawer,
}

/// 侧边栏与抽屉共用的面板内容：三项导航 → 底部连接状态；抽屉形态顶部另有
/// 品牌槽（桌面形态的品牌图标住在面板外的常驻开合开关里）。
///
/// 整块**可滚动**：连接状态仍压在底部，但小窗或字号放大（ticket 24 的口径，
/// §8 的列表项在 2.0 字阶下 240px 宽装不下）时整块能滚，绝不溢出。
class _NavPanel extends StatelessWidget {
  const _NavPanel({required this.shape, required this.onNavigate, this.onHome})
    : assert(
        (shape == _NavPanelShape.drawer) == (onHome != null),
        '抽屉形态必须给 onHome（品牌槽回合一页）；桌面侧边栏形态不得给',
      );

  final _NavPanelShape shape;
  final void Function(String location) onNavigate;

  /// 仅抽屉形态传入：品牌槽「回合一页」。
  final VoidCallback? onHome;

  /// 桌面形态顶部给常驻开合开关让位的空位高度：与抽屉品牌槽的占位等高
  /// （品牌槽那档上下内缩 + 图形直径），两种形态的第一项导航落位因此一致。
  static const double _brandRowExtent =
      QiyuLayout.brandMarkSize + QiyuSpacing.xs * 2;

  @override
  Widget build(BuildContext context) {
    final current = _currentLocation(context);
    return QiyuGlassPanel(
      borderRadius: BorderRadius.zero,
      // 原型 `.sidebar` 只有 border-right：抽屉与侧边栏同理，左缘贴屏幕边。
      border: const BorderDirectional(
        end: BorderSide(width: QiyuLine.hairline, color: QiyuColors.line),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: QiyuLayout.sidebarPaddingHorizontal,
        vertical: QiyuLayout.sidebarPaddingVertical,
      ),
      child: SafeArea(
        // 连接状态靠底部留白压到面板底；这份留白由 SliverFillRemaining 给，
        // 放不下时它会缩成 0、整块转滚动，而不是把 RenderFlex 撑爆。
        // `nav-scroll`：这块滚动容器与页面内容里的列表同为纵向，且排在页面
        // 之前，测试取「页面自己的滚动区」时按这个键把它摘出去。
        child: CustomScrollView(
          key: const Key('nav-scroll'),
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (shape == _NavPanelShape.drawer)
                    // 窄屏抽屉：品牌槽点击回合一页（键 `go-home` 只留在这里，
                    // 2026-08-31 二次裁定）。
                    _BrandSlot(onTap: onHome!)
                  else
                    // 桌面：品牌图标住在面板**外**的常驻开合开关里，这里留
                    // 等高空位，导航项整体下移给图标行让位，视觉节奏与抽屉
                    // 一致。
                    const SizedBox(height: _brandRowExtent),
                  const SizedBox(height: QiyuSpacing.lg),
                  for (final destination in QiyuNavDestination.values)
                    _NavItem(
                      key: destination.outerKey,
                      tapKey: destination.tapKey,
                      icon: destination.icon,
                      label: destination.label,
                      selected: current == destination.path,
                      onTap: () => onNavigate(destination.path),
                    ),
                ],
              ),
            ),
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: QiyuConnectionStatus(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 品牌图标槽（Spec Implementation Decisions 第 9 条、决策日志第一轮第 8 条）：
/// **只放图形占位，不带「栖语」字标**——字标在第一轮就被列为被拒项。本轮不做
/// 图形设计，落一个中性几何占位：不着紫、无渐变、无发光。
///
/// 只被**窄屏抽屉**渲染，点击回合一页（键 `go-home` 只留在这里）。桌面没有
/// 品牌槽：品牌图标是壳上的常驻开合开关（[_QiyuShellState._sidebarBrandToggle]），
/// 点击只收起/展开，不导航（2026-08-31 二次裁定）。
class _BrandSlot extends StatefulWidget {
  const _BrandSlot({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_BrandSlot> createState() => _BrandSlotState();
}

class _BrandSlotState extends State<_BrandSlot> {
  final _focusNode = FocusNode(debugLabel: 'nav-brand');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return QiyuFocusRing(
      focusNode: _focusNode,
      child: InkWell(
        key: const Key('go-home'),
        focusNode: _focusNode,
        borderRadius: QiyuRadii.cardBorder,
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: QiyuLayout.navItemPaddingHorizontal,
            vertical: QiyuSpacing.xs,
          ),
          child: const Align(
            alignment: Alignment.centerLeft,
            child: _BrandMark(key: Key('nav-brand')),
          ),
        ),
      ),
    );
  }
}

/// 品牌图形本体：中性几何占位（发丝描边外圈 + 居中实心小圆点）。窄屏抽屉的
/// 品牌槽与桌面常驻开合开关共用这同一份图形与尺寸，键 `nav-brand` 始终跟着
/// 品牌图标走（任一时刻树上只有一枚）。
class _BrandMark extends StatelessWidget {
  const _BrandMark({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: QiyuLayout.brandMarkSize,
      height: QiyuLayout.brandMarkSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(width: QiyuLine.hairline, color: QiyuColors.line),
        color: QiyuColors.neutralFill,
      ),
      child: const Center(
        child: SizedBox.square(
          dimension: 12,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: QiyuColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}

/// 导航项（design-system §8 组件 6，圆角按用户裁定归入组件 7 的 18px 列表项档）：
/// 图标 + 文字，选中态用中性暗底 + 近白文字，**不得用紫**。
class _NavItem extends StatefulWidget {
  const _NavItem({
    super.key,
    required this.tapKey,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  /// 内层点击键沿用退役前首页入口卡片的既有测试键（home-go-*）。
  final Key tapKey;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final labelColor = selected ? QiyuColors.neutralEmphasis : QiyuColors.muted;
    return QiyuFocusRing(
      focusNode: _focusNode,
      borderRadius: QiyuRadii.cardBorder,
      child: InkWell(
        key: widget.tapKey,
        focusNode: _focusNode,
        borderRadius: QiyuRadii.cardBorder,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: qiyuMotion(context, QiyuMotion.fast),
          decoration: BoxDecoration(
            borderRadius: QiyuRadii.cardBorder,
            // 选中态中性暗底 rgba(255,255,255,0.04)，绝不用紫底。
            color: selected ? QiyuColors.selectedNeutral : Colors.transparent,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: QiyuLayout.navItemPaddingHorizontal,
            vertical: QiyuLayout.navItemPaddingVertical,
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: QiyuIconSpec.size,
                color: selected ? QiyuColors.ink : QiyuColors.muted,
              ),
              const SizedBox(width: QiyuLayout.navItemIconGap),
              Expanded(
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  style: QiyuTypography.body.copyWith(color: labelColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
