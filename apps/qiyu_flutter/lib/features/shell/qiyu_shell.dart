import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import '../accessibility.dart';
import 'qiyu_connection_status.dart';
import 'qiyu_widgets.dart';

/// 毛玻璃导航壳（design-system §5、Spec Implementation Decisions 第 7 条）。
///
/// - 桌面（宽度 ≥ [QiyuLayout.desktopBreakpoint]）：左侧常驻 240px 毛玻璃
///   侧边栏，自上而下是品牌图标槽 → 三项导航 → 底部连接状态；无三条杠、
///   无底部导航。
/// - 窄屏：左上角三条杠打开约视口 2/3 宽的毛玻璃抽屉，内容与桌面**同源**
///   （同一个 [_NavPanel]），点遮罩或再点三条杠收回。
/// - 侧边栏与抽屉渲染同一批导航文案，因此三项导航、品牌槽、连接状态全部
///   带 [Key]；widget 测试按 Key 定位，不用 `find.text`（Spec Testing
///   Decisions 第 8 条）。
class QiyuShell extends StatefulWidget {
  const QiyuShell({super.key, required this.child});

  /// 被壳包住的页面内容（合一页里就是 `LocalChatView`）。
  final Widget child;

  @override
  State<QiyuShell> createState() => _QiyuShellState();
}

class _QiyuShellState extends State<QiyuShell>
    with SingleTickerProviderStateMixin {
  bool _drawerOpen = false;

  /// 抽屉开合动画。必须在 initState 里建好：惰性字段初始化会在 dispose
  /// 首次访问时于「正在卸载」的树上创建 ticker，直接炸断言。
  late final AnimationController _drawerController;

  final _menuFocusNode = FocusNode(debugLabel: 'nav-menu-button');

  @override
  void initState() {
    super.initState();
    _drawerController = AnimationController(
      vsync: this,
      duration: QiyuMotion.drawer,
      reverseDuration: QiyuMotion.drawer,
    )..addStatusListener(_onDrawerStatus);
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
    } else {
      await _drawerController.reverse();
    }
  }

  /// 抽屉只在「开着」或「正在滑出去」时留在树里：收到底后不再占用焦点与
  /// 语义树，窄屏也不会被误当成常驻导航。
  bool get _drawerMounted =>
      _drawerOpen || _drawerController.status != AnimationStatus.dismissed;

  /// 导航动作与退役前的首页入口保持一致：`go` 到目标页，返回键仍回合一页。
  void _goTo(String location) {
    context.go(location);
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final desktop = viewport.width >= QiyuLayout.desktopBreakpoint;

    if (desktop) {
      return ColoredBox(
        color: QiyuColors.night,
        child: Row(
          children: [
            SizedBox(
              width: QiyuLayout.sidebarWidth,
              child: _NavPanel(onNavigate: _goTo),
            ),
            Expanded(child: widget.child),
          ],
        ),
      );
    }

    final drawerWidth = viewport.width * QiyuLayout.drawerWidthFraction;
    final slide = Tween<Offset>(begin: const Offset(-1.02, 0), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _drawerController,
            curve: Curves.easeOut,
            reverseCurve: Curves.easeIn,
          ),
        );

    return ColoredBox(
      color: QiyuColors.night,
      child: Stack(
        children: [
          widget.child,
          if (_drawerMounted)
            // 遮罩：点它就收回抽屉。
            Positioned.fill(
              child: GestureDetector(
                key: const Key('nav-scrim'),
                behavior: HitTestBehavior.opaque,
                onTap: () => unawaited(_setDrawer(false)),
                child: const ColoredBox(color: QiyuColors.scrimSoft),
              ),
            ),
          if (_drawerMounted)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              width: drawerWidth,
              child: SlideTransition(
                position: slide,
                child: _NavPanel(
                  onNavigate: (location) {
                    unawaited(_setDrawer(false));
                    _goTo(location);
                  },
                ),
              ),
            ),
          // 三条杠：圆形图标按钮，玻璃底 + 发丝描边，细描边图形。
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
                        child: Center(
                          child: Icon(
                            _drawerOpen
                                ? Icons.close_rounded
                                : Icons.menu_outlined,
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
      ),
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

/// 侧边栏与抽屉共用的面板内容：品牌槽 → 三项导航 → 底部连接状态。
/// 小窗或字号放大时整块可滚动，绝不溢出（ticket 24 的同一口径）。
class _NavPanel extends StatelessWidget {
  const _NavPanel({required this.onNavigate});

  final void Function(String location) onNavigate;

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
        // 面板内容固定且短（品牌槽 + 三项导航 + 一枚连接状态），字号放大后
        // 仍远在视口之内；这里不能用无界高度的滚动容器——连接状态靠
        // Spacer 压到底，需要面板给出有界高度。
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BrandSlot(onTap: () => onNavigate('/')),
            const SizedBox(height: QiyuSpacing.lg),
            _NavItem(
              key: const Key('nav-history'),
              tapKey: const Key('home-go-history'),
              icon: Icons.hourglass_empty_outlined,
              label: '历史',
              selected: current == '/history',
              onTap: () => onNavigate('/history'),
            ),
            _NavItem(
              key: const Key('nav-memory'),
              tapKey: const Key('home-go-memory'),
              icon: Icons.menu_book_outlined,
              label: '记忆中心',
              selected: current == '/memory',
              onTap: () => onNavigate('/memory'),
            ),
            _NavItem(
              key: const Key('nav-settings'),
              tapKey: const Key('home-go-settings'),
              icon: Icons.tune_outlined,
              label: '设置',
              selected: current == '/settings',
              onTap: () => onNavigate('/settings'),
            ),
            const Spacer(),
            const QiyuConnectionStatus(),
          ],
        ),
      ),
    );
  }
}

/// 品牌图标槽（Spec Implementation Decisions 第 9 条）：本轮**不做图形设计**，
/// 只落一个中性几何占位——不着紫、无渐变、无发光，点击回空状态首页。
/// 原型里那个「紫色渐变圆 + 自造波纹」按定案不得沿用。
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
        // `go-home` 是既有测试键：合一页后「回首页」的入口就是品牌槽，
        // 键位随职责一起搬过来，不改名也不放宽断言。
        key: const Key('go-home'),
        focusNode: _focusNode,
        borderRadius: QiyuRadii.smallBorder,
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: QiyuLayout.navItemPaddingHorizontal,
            vertical: QiyuSpacing.xs,
          ),
          child: Row(
            children: [
              Container(
                key: const Key('nav-brand'),
                width: QiyuLayout.brandMarkSize,
                height: QiyuLayout.brandMarkSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    width: QiyuLine.hairline,
                    color: QiyuColors.line,
                  ),
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
              ),
              const SizedBox(width: QiyuLayout.navItemIconGap),
              Text(
                '栖语',
                style: QiyuTypography.title.copyWith(
                  color: QiyuColors.ink,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 导航项（design-system §8 组件 6）：图标 + 文字，选中态用中性暗底 +
/// 近白文字，**不得用紫**。
class _NavItem extends StatefulWidget {
  const _NavItem({
    super.key,
    required this.tapKey,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  /// 外层（含焦点环）定位键：`nav-history` / `nav-memory` / `nav-settings`。
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
    final labelColor = selected
        ? QiyuColors.neutralEmphasis
        : QiyuColors.muted;
    return QiyuFocusRing(
      focusNode: _focusNode,
      child: InkWell(
        // 内层点击键沿用退役前首页入口卡片的既有测试键（home-go-*）。
        key: widget.tapKey,
        focusNode: _focusNode,
        borderRadius: QiyuRadii.smallBorder,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: qiyuMotion(context, QiyuMotion.fast),
          decoration: BoxDecoration(
            borderRadius: QiyuRadii.smallBorder,
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
