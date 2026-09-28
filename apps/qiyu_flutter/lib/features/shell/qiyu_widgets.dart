import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_tokens.dart';
import '../accessibility.dart';
import 'qiyu_ui_locale.dart';

/// 紫夜薄包装层（design-system §8 组件清单的 M3 底子 + token 换皮）：
/// 毛玻璃面板与自绘**键盘**焦点环。侧边栏、抽屉与 composer 的毛玻璃底共用
/// 同一份 [QiyuGlassPanel]，保证「材质同源」，页面不得再各自抄一遍
/// Blur + ColoredBox；发送钮的玻璃紫渐变是独立实现（自带 ClipOval +
/// BackdropFilter，见 `features/chat/qiyu_send_button.dart`），只从这里取焦点环。
///
/// 本文件另住着一件壳层共用件 [maybeProvider]：导航壳与连接状态都要读同一份
/// 可能缺席的 `LocalChatViewModel`，那份 try/catch 形状只留一处（read / watch
/// 的语义仍由各调用方的闭包决定）。
///
/// 焦点这一侧它也是唯一出处：来源判定（[QiyuFocusSource]）与两种挂法
/// （[QiyuFocusRing] 持节点、[QiyuFocusRingScope] 不持节点）都住在这里，绘制
/// 统一走私有的 [_QiyuRing]——页面只准套组件，不准自己判「该不该画环」。

/// 毛玻璃容器：玻璃基色 [QiyuColors.glass]（`rgba(19,18,23,0.72)`）+
/// `BackdropFilter`（design-system §2）。
///
/// **身下必须有东西**：`BackdropFilter` 糊的是它之下已经画好的像素，所以本容器
/// 只能作为半透明层叠在全幅页面背景之上（见 `QiyuShell` 的 Stack 分层）。把它
/// 平铺在一层同色 `ColoredBox` 上，糊出来的就是平涂，玻璃材质名存实亡。
/// 圆角与发丝描边由调用方给，模糊半径默认取面板档。
class QiyuGlassPanel extends StatelessWidget {
  const QiyuGlassPanel({
    super.key,
    required this.child,
    this.borderRadius = QiyuRadii.pillBorder,
    this.blurSigma = QiyuGlass.panelBlur,
    this.borderColor = QiyuColors.line,
    this.border,
    this.padding,
    this.duration = QiyuMotion.base,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double blurSigma;
  final Color borderColor;

  /// 需要单侧发丝线时由调用方给（侧边栏与抽屉只画右缘一条）；为空则整圈
  /// [borderColor] 1px。
  final BoxBorder? border;
  final EdgeInsetsGeometry? padding;

  /// 底色/描边变化的过渡时长（§9「动效一律 150–250ms 轻缓动」）。composer
  /// 的聚焦描边就从这里走：`line` ↔ `composerFocusLine` 是 200ms 过渡，不是
  /// 瞬时换色；reduced-motion 下由 [qiyuMotion] 压成 0。
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: AnimatedContainer(
          duration: qiyuMotion(context, duration),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: QiyuColors.glass,
            // 自定义边线（如侧边栏的单侧发丝线）不是均匀边，BoxDecoration
            // 此时不接受圆角；圆角已经由外层 ClipRRect 裁出，视觉一致。
            borderRadius: border == null ? borderRadius : null,
            border:
                border ??
                Border.all(width: QiyuLine.hairline, color: borderColor),
          ),
          child: Padding(
            padding: padding ?? EdgeInsets.zero,
            // 面板自带一层透明 Material 作为 ink 载体：导航壳在子页面
            // Scaffold 的**兄弟**位置，不能指望外层给 InkWell 提供 Material。
            child: Material(
              type: MaterialType.canvas,
              color: Colors.transparent,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 自绘**键盘**焦点环（design-system §9）：Material 3 的 `focusColor` 只能贴在
/// 控件表面，画不出「2px `accentBright` + offset 3px」的外环。
///
/// 表意分流（2026-08-30 第二轮评审后改判）：这一圈实紫**只服务键盘焦点**，
/// 判据是应用级自实现的 [QiyuFocusSource]——「最近一次**改变焦点**的输入来自
/// 键盘还是指针」。**不再读 `FocusManager.highlightMode`**：桌面 Web 上它初始
/// 就是 `traditional`，而 SDK 的指针处理里鼠标分支根本不改写模式，只有触摸与
/// 手写会改成 `touch`，所以鼠标导致的聚焦照样会画环；它只在「键盘 ↔ 触摸」这类
/// 跨输入方式切换时才可靠，挡不住这一条。输入框文本编辑态的 0.13 淡紫描边是
/// §8 组件 5 的另一件事，由 composer 自己的 `QiyuGlassPanel.borderColor` 给出，
/// 不走本组件。
///
/// 用法一（控件已有节点）：把调用方持有的 [focusNode] 同时交给环和它包住的
/// `InkWell`，Enter/Space 仍由 InkResponse 激活。
/// 用法二（`IconButton` 这类内部自建节点的控件）：用 [QiyuOwnFocusRing]，环自己
/// 持有节点并交给它的 `builder`，由子控件挂到树上；子控件不挂就永远不显环（宁可
/// 少显，也不画出与焦点无关的环）。
/// 用法三（页面里现成的 M3 控件，不想为套环再传节点）：[QiyuFocusRingScope]。
///
/// 环的留白常驻（未聚焦时透明），因此出现与消失都不会引起布局跳动。
class QiyuFocusRing extends StatefulWidget {
  const QiyuFocusRing({
    super.key,
    required this.focusNode,
    required this.child,
    this.borderRadius = QiyuRadii.smallBorder,
  });

  /// 调用方持有的节点（与内层 `InkWell` 共用）。节点归调用方创建与释放。
  final FocusNode focusNode;
  final Widget child;
  final BorderRadius borderRadius;

  @override
  State<QiyuFocusRing> createState() => _QiyuFocusRingState();
}

/// 焦点环的**画法**：三种挂法共用这一份，避免出现第二种环。
///
/// 留白常驻（未聚焦时只是描边透明），所以出现与消失都不引起布局跳动；
/// 宽度和 offset 只有 [QiyuLayout.focusRingWidth] / [QiyuLayout.focusRingOffset]
/// 一个出处（design-system §9「2px solid accent-bright，offset 3px」）。
class _QiyuRing extends StatelessWidget {
  const _QiyuRing({
    required this.show,
    required this.borderRadius,
    required this.child,
  });

  final bool show;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(QiyuLayout.focusRingOffset),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          border: Border.all(
            width: QiyuLayout.focusRingWidth,
            color: show ? QiyuColors.accentBright : Colors.transparent,
          ),
        ),
        child: child,
      ),
    );
  }
}

/// 用法二的包装：环**自持**焦点节点，把它交给 [builder]，由子控件挂进焦点树。
///
/// 单独一个组件是为了让「谁持有节点」这件事在类型上就说清楚：节点在这里
/// 一次创建、`dispose` 一次释放，不存在「换节点时旧节点没人管」的中间地带。
/// 绘制仍然委托 [QiyuFocusRing]，两种用法共用同一份环，不出现第二种画法。
class QiyuOwnFocusRing extends StatefulWidget {
  const QiyuOwnFocusRing({
    super.key,
    required this.builder,
    this.borderRadius = QiyuRadii.smallBorder,
  });

  final Widget Function(BuildContext context, FocusNode focusNode) builder;
  final BorderRadius borderRadius;

  @override
  State<QiyuOwnFocusRing> createState() => _QiyuOwnFocusRingState();
}

class _QiyuOwnFocusRingState extends State<QiyuOwnFocusRing> {
  /// 环自持的节点：字段初始化即创建，`dispose` 即释放。子控件不挂它就一直
  /// 不显环（宁可少显，也不画出与焦点无关的环）。
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return QiyuFocusRing(
      focusNode: _focusNode,
      borderRadius: widget.borderRadius,
      child: widget.builder(context, _focusNode),
    );
  }
}

class _QiyuFocusRingState extends State<QiyuFocusRing> {
  /// 环监听并据以判断画不画的节点：**永远**是调用方给的那一个（用法二由
  /// [QiyuOwnFocusRing] 自持节点后再传进来），环自己不建节点，因此也不存在
  /// 「环手里留着没人释放的节点」。
  FocusNode get _node => widget.focusNode;

  @override
  void initState() {
    super.initState();
    // 先绑定当前世代的 FocusManager 与按键监听，再谈画不画环（见 QiyuFocusSource）。
    QiyuFocusSource.instance.bind();
  }

  @override
  void didUpdateWidget(QiyuFocusRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 节点换了：旧节点归调用方释放，这里只负责改听新的那个并重画。
    if (oldWidget.focusNode != widget.focusNode) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // 两件事都得触发重画：来源换了（键盘 ↔ 指针）与节点自己得失焦。
      listenable: Listenable.merge([QiyuFocusSource.instance, _node]),
      builder: (context, child) => _QiyuRing(
        show: QiyuFocusSource.instance.keyboardDriven && _node.hasFocus,
        borderRadius: widget.borderRadius,
        child: child!,
      ),
      child: widget.child,
    );
  }
}

/// 最近一次**改变焦点**的输入来自哪里（design-system §9「来源如何判定」定案）。
enum QiyuFocusOrigin {
  /// 应用起来后还没有任何输入把焦点交出去过。此时**不画环**：宁少显，
  /// 也不给一个没被键盘走过的控件凭空描一圈紫。
  undetermined,

  /// 键盘：Tab / 方向键 / Enter / Space 这类按键把焦点移动到了控件上。
  keyboard,

  /// 指针：鼠标或触控板按下。
  pointer,

  /// 触摸：触摸设备上永远不画环。
  touch,
}

/// 应用级的焦点来源记录器——**全应用只有这一处**判「这次聚焦该不该画紫环」，
/// 三种挂法的环都只读它的结论，页面与控件一律不得自己猜（design-system §9）。
///
/// 为什么不用框架现成的 `FocusManager.highlightMode`：桌面 Web 上它初始即为
/// `traditional`，SDK 的指针分支里只有触摸/手写会把它改成 `touch`，鼠标**不写**
/// 这个字段，于是鼠标点出来的焦点一样满足「traditional 且持焦」，环会画错。
///
/// 三条守住的规矩（§9 定案）：
/// 1. **以焦点变更为边界**——按键与按下只记下「最近一次输入」，焦点真的落到
///    一个新节点上时才据此改判；没有新焦点就不改判（点空白处不改变结论）。
/// 2. **不下放**到各控件各自猜，判定全在这里。
/// 3. **触摸永不画环**——触摸按下记成 [QiyuFocusOrigin.touch]，不是 keyboard。
class QiyuFocusSource extends ChangeNotifier {
  QiyuFocusSource._() {
    // 指针侧一次登记即可：pointer router 的全局路由不会被重置。
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointerEvent);
  }

  /// 进程内单例：来源是**整机**的事实，不是某个页面或控件的状态。
  static final QiyuFocusSource instance = QiyuFocusSource._();

  QiyuFocusOrigin _origin = QiyuFocusOrigin.undetermined;
  QiyuFocusOrigin _lastInput = QiyuFocusOrigin.undetermined;

  /// 当前正在监听的那个 `FocusManager`。测试框架会在每个用例结束时换掉它
  /// （`buildOwner.focusManager = FocusManager()`）并把 `HardwareKeyboard` 的
  /// 全局处理器清空（`clearState()`），所以绑定**不能只在构造时做一次**：
  /// 每个环 initState 时走一遍 [_bind]，换代时重新登记。真实应用里 manager
  /// 全程是同一个，等于只登记一次。
  FocusManager? _bound;

  /// 环在 initState 里调用：确保按键与焦点监听挂在**当前世代**的 manager 上。
  void bind() => _bind(FocusManager.instance);

  void _bind(FocusManager manager) {
    if (identical(_bound, manager)) {
      return;
    }
    _bound?.removeListener(_onFocusChanged);
    _bound = manager..addListener(_onFocusChanged);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    // 换代即全新上下文：上一个用例留下的结论一律作废，退回「尚未判定」。
    _origin = QiyuFocusOrigin.undetermined;
    _lastInput = QiyuFocusOrigin.undetermined;
  }

  /// 环的唯一判据。只有键盘把焦点送到这里时才为 true（触摸与指针为 false）。
  bool get keyboardDriven {
    _bind(FocusManager.instance);
    return _origin == QiyuFocusOrigin.keyboard;
  }

  bool _onKeyEvent(KeyEvent event) {
    // 只认按下与重复：抬起同一次按键，不该改写判定。返回值 false = 不吞事件。
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _lastInput = QiyuFocusOrigin.keyboard;
    }
    return false;
  }

  void _onPointerEvent(PointerEvent event) {
    // 只认按下：悬停与移动不算「把焦点交给控件」。
    if (event is! PointerDownEvent) {
      return;
    }
    _lastInput = switch (event.kind) {
      PointerDeviceKind.touch => QiyuFocusOrigin.touch,
      PointerDeviceKind.stylus => QiyuFocusOrigin.touch,
      _ => QiyuFocusOrigin.pointer,
    };
  }

  void _onFocusChanged() {
    final manager = FocusManager.instance;
    final primary = manager.primaryFocus;
    // 焦点落到根 scope（等于没有新焦点）不改判：判定的边界是「焦点变更」。
    if (primary == null || primary.nearestScope == primary) {
      return;
    }
    if (_origin == _lastInput) {
      return;
    }
    _origin = _lastInput;
    notifyListeners();
  }

  /// 测试专用：把整机结论退回「尚未判定」，避免上一个用例的输入影响下一个。
  @visibleForTesting
  void resetForTests() {
    _origin = QiyuFocusOrigin.undetermined;
    _lastInput = QiyuFocusOrigin.undetermined;
    notifyListeners();
  }
}

/// 用法三：环**不持节点**，只看「当前持焦的控件是不是落在自己这棵子树里」。
///
/// 页面里的 `IconButton` / `TextButton` / 卡片 `InkWell` 的焦点节点是控件内部
/// 自建的（`InkResponse` 与 `ButtonStyleButton` 各自 `FocusNode()`），把它们逐个
/// 改成外部持有节点会牵动遍历顺序与释放责任；这里改为**只观察**：靠挂在子树上
/// 的 [_QiyuRingScope] 标记判断焦点是否在自己之内。不新增 `Focus`、不建焦点作用域，
/// 因此焦点遍历顺序、激活方式与 Key 一项都不动（Spec Implementation Decision 18）。
class QiyuFocusRingScope extends StatefulWidget {
  const QiyuFocusRingScope({
    super.key,
    required this.child,
    this.borderRadius = QiyuRadii.smallBorder,
  });

  final Widget child;
  final BorderRadius borderRadius;

  @override
  State<QiyuFocusRingScope> createState() => _QiyuFocusRingScopeState();
}

class _QiyuFocusRingScopeState extends State<QiyuFocusRingScope> {
  @override
  void initState() {
    super.initState();
    // 焦点换了人（可能进出本子树）就得重画；来源换了由 QiyuFocusSource 通知。
    QiyuFocusSource.instance.bind();
    FocusManager.instance.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  /// 当前持焦节点是否在自己这棵子树里：从持焦节点的 context 往上找最近的
  /// [_QiyuRingScope] 标记，认它的 owner 是不是自己。
  bool get _containsFocused {
    final focused = FocusManager.instance.primaryFocus;
    if (focused == null || !focused.hasPrimaryFocus) {
      return false;
    }
    final focusedContext = focused.context;
    if (focusedContext == null) {
      return false;
    }
    return _QiyuRingScope.maybeOwner(focusedContext) == this;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: QiyuFocusSource.instance,
      builder: (context, child) => _QiyuRing(
        show: QiyuFocusSource.instance.keyboardDriven && _containsFocused,
        borderRadius: widget.borderRadius,
        child: _QiyuRingScope(owner: this, child: child!),
      ),
      child: widget.child,
    );
  }
}

/// [QiyuFocusRingScope] 挂在子树上的标记：持焦控件沿祖先链找得到它，就说明
/// 焦点在这一层环的管辖之内。只做身份标记，不注册依赖。
class _QiyuRingScope extends InheritedWidget {
  const _QiyuRingScope({required this.owner, required super.child});

  final _QiyuFocusRingScopeState owner;

  static _QiyuFocusRingScopeState? maybeOwner(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_QiyuRingScope>()?.owner;

  @override
  bool updateShouldNotify(_QiyuRingScope oldWidget) => false;
}

/// 读一份**可能不存在**的 Provider：壳层（导航壳、连接状态）可以被脱离
/// `LocalChatViewModel` 单独 pump（旧测试、独立预览），拿不到不是错误，退化成
/// null 让调用方走中性呈现。这一处 try/catch 由 `qiyu_shell` 与
/// `qiyu_connection_status` 共用，两边不再各抄一份同形状的兜底。
///
/// `read` 与 `watch` 的差别由调用方传进来的闭包保留——`watch` 必须在 `build`
/// 里就地调用才挂得上依赖，所以这里只做同步调用。
T? maybeProvider<T>(T Function() lookup) {
  try {
    return lookup();
  } on ProviderNotFoundException {
    return null;
  }
}

/// 页面加载失败态的统一出口：错误文案 + 12px 间隔 + 带焦点环的重试钮。
/// 记忆中心列表页、记忆详情页与历史页共用这一份骨架，不再逐页复制。
/// 文案、文案键与文案样式由调用方给定：列表页文案着错误色但不带键、
/// 详情页文案带键但用默认字色——两处既有差异原样参数化，不在此合并。
/// 加载态没有共享组件：`Center(child: CircularProgressIndicator())`
/// 本就是最短表达。
class QiyuErrorRetryState extends StatelessWidget {
  const QiyuErrorRetryState({
    super.key,
    required this.message,
    this.messageKey,
    this.messageStyle,
    required this.retryKey,
    required this.onRetry,
  });

  final String message;
  final Key? messageKey;
  final TextStyle? messageStyle;
  final Key retryKey;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, key: messageKey, style: messageStyle),
          const SizedBox(height: 12),
          QiyuFocusRingScope(
            borderRadius: QiyuRadii.circleBorder,
            child: TextButton(
              key: retryKey,
              onPressed: onRetry,
              child: Text(qiyuStrings(context).retry),
            ),
          ),
        ],
      ),
    );
  }
}

/// 聊天域内容的水平居中约束：会话页的工具条、消息区与提示条，以及输入模块
/// （[QiyuLayout.streamMaxWidth] 的全部消费方）共用同一档流宽。约束组合
/// （Center > ConstrainedBox）收敛于此，页面不得再各自抄一遍。
class QiyuStreamWidthBox extends StatelessWidget {
  const QiyuStreamWidthBox({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: QiyuLayout.streamMaxWidth),
        child: child,
      ),
    );
  }
}
