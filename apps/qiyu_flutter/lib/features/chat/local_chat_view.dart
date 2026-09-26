import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import '../accessibility.dart';
import '../baseline/host_stopped_gate.dart';
import '../settings/stt_settings_client.dart';
import '../shell/qiyu_shell.dart';
import '../shell/qiyu_widgets.dart';
import 'api_error_dialog.dart';
import 'api_error_policy.dart';
import 'chat_stick_to_bottom.dart';
import 'chat_voice_coordinator.dart';
import 'local_chat_client.dart';
import 'local_chat_view_model.dart';
import 'qiyu_chat_bubble.dart';
import 'qiyu_composer.dart';
import 'qiyu_greeting_fade_out.dart';
import 'qiyu_markdown.dart';
import 'qiyu_hover_gate.dart';
import 'qiyu_voice_output_control.dart';
import 'voice_input_controller.dart';
import 'voice_output_controller.dart';
import 'voice_recorder_platform.dart';

/// 空会话占位按当前时段分流。产品定位是夜间陪伴，但白天打开也该
/// 贴合当下时段；凌晨到清晨都归入「今晚」，守住睡前陪伴的基调。
String qiyuEmptyChatHint(DateTime now) {
  final hour = now.hour;
  if (hour >= 5 && hour < 11) return '早上想说点什么？';
  if (hour >= 11 && hour < 13) return '中午想说点什么？';
  if (hour >= 13 && hour < 18) return '下午想说点什么？';
  return '今晚想说点什么？';
}

class LocalChatView extends StatefulWidget {
  const LocalChatView({
    super.key,
    this.voiceRecorderPlatform,
    this.sttSettingsGateway,
  });

  /// 语音输入接缝：缺省走条件导出的平台实现（Web 真录音、测试 stub）；
  /// widget 测试注入 fake。
  final VoiceRecorderPlatform? voiceRecorderPlatform;

  /// 语音服务配置读取：缺省复用 app Provider 树里的共享网关实例
  /// （与设置页同一实例，CSRF 不重复换）；widget 测试注入 fake。
  final SttSettingsGateway? sttSettingsGateway;

  @override
  State<LocalChatView> createState() => _LocalChatViewState();
}

class _LocalChatViewState extends State<LocalChatView>
    with WidgetsBindingObserver {
  late final ChatVoiceCoordinator _voiceCoordinator;
  GoRouter? _router;
  String? _chatLocation;
  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  final _scrollController = ScrollController();

  /// 输入模块的身份与操作键：状态与生命周期都在 [QiyuComposer] 内部，
  /// 页面只经由它调用「恢复输入焦点」与「转写文本发送」两个操作；同一枚
  /// 键传给 widget，空态↔聊天态换布局时 State 原位保留，输入连续。
  final _composerKey = GlobalKey<QiyuComposerState>(debugLabel: 'chat-composer');

  /// 贴底收敛状态机：会话恢复、新消息、流式增量与键盘压缩视口都跟在列表
  /// 尾部，判定与调度收在 [ChatStickToBottomController]，页面只在 build
  /// 与通知接线处喂数据。
  late final ChatStickToBottomController _stick =
      ChatStickToBottomController(
        scrollController: _scrollController,
        android: _android,
        isMounted: () => mounted,
      );
  late final LocalChatViewModel _chatViewModel;
  late final VoiceInputController _voiceInput;

  /// 聊天 VM 与朗读控制器的合并监听：**只建一次**复用。每次 build 现造
  /// `Listenable.merge` 会把这个临时合并对象挂到 voiceOutput 上且没人摘，
  /// 空态↔聊天态切换几次就攒出几个僵尸监听，卸载期 dispose 里的 stopAll()
  /// 会通知到已失效的 AnimatedBuilder（tree locked 断言）。
  late final Listenable _chatAndVoiceTick = Listenable.merge([
    _chatViewModel,
    _chatViewModel.voiceOutput,
  ]);

  /// 页面 body 那一层 Stack：问候的淡出层挂在它上面，量到的矩形也要换算到它的
  /// 本地坐标，所以留一个键。
  final _bodyStackKey = GlobalKey(debugLabel: 'chat-body-stack');

  /// 空态最后一帧里问候**实际占到的矩形**（[_bodyStackKey] 的本地坐标）。
  /// 空态→聊天态时整列布局换掉，淡出层照着这块矩形原地画问候，用户看到的
  /// 就是它在自己位置上淡掉，而不是跳一处再消失（Spec User Story 2）。
  Rect? _greetingRect;

  String? _lastTrackedSessionId;

  /// 轮末异常的分类、会话级弹窗频控与轻提示文案全部在 [ApiErrorPolicy]
  /// 策略表内；页面只执行判定（setState、弹窗、导航与焦点返还）。
  final ApiErrorPolicy _errorPolicy = ApiErrorPolicy();
  ApiErrorNotice? _apiErrorNotice;
  bool _isShowingApiErrorDialog = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_stick.trackScroll);
    final chatViewModel = _chatViewModel = context.read<LocalChatViewModel>();
    chatViewModel.addListener(_onChatViewModelChanged);
    _lastTrackedSessionId = chatViewModel.sessionId;
    final sttSettingsGateway = _resolveSttSettingsGateway();
    final recorder =
        widget.voiceRecorderPlatform ?? createVoiceRecorderPlatform();
    _voiceInput = VoiceInputController(
      recorder,
      // 服务类型决定是否要浏览器端 WAV 转换（豆包要 16kHz 单声道 WAV）。
      () async {
        final settings = await sttSettingsGateway.read();
        return (
          configured: settings.configured,
          wantsWavAudio: settings.wantsWavAudio,
        );
      },
      chatViewModel.transcribeVoice,
      // 转写文本交给输入模块的发送协调：清空、失败回填与页面收尾钩子
      // 都在模块内部按既有口径执行。
      onTranscribed: (text) =>
          unawaited(_composerKey.currentState?.sendTranscribed(text)),
      onApiError: _handleVoiceApiError,
    );
    chatViewModel.voiceOutput.onApiError = _handleVoiceApiError;
    _voiceCoordinator = ChatVoiceCoordinator(
      viewModel: chatViewModel,
      input: _voiceInput,
      android: _android,
      hasComposer: () => _composerKey.currentState != null,
      recorder: recorder,
    );
    if (_android) WidgetsBinding.instance.addObserver(this);
    unawaited(_voiceInput.initialize());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_android) return;
    final router = GoRouter.maybeOf(context);
    if (router == _router) return;
    _router?.routerDelegate.removeListener(_onRouteChanged);
    _router = router;
    _chatLocation =
        router?.routerDelegate.currentConfiguration.last.matchedLocation;
    router?.routerDelegate.addListener(_onRouteChanged);
  }

  void _onRouteChanged() {
    final location =
        _router?.routerDelegate.currentConfiguration.last.matchedLocation;
    if (location != _chatLocation) {
      _voiceCoordinator.leaveRoute();
    }
  }

  void _cancelUnsubmittedVoice() =>
      _voiceCoordinator.cancelForPage();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _voiceCoordinator.enterBackground();
    }
  }

  /// 语音设置网关解析：注入优先；其次复用 app Provider 树的共享实例
  /// （与设置页同一实例，CSRF 不重复换取）；只有脱离 app 树单独 pump
  /// 本页的测试才回退自建——widget 测试里平台是 stub，不会真正发请求。
  SttSettingsGateway _resolveSttSettingsGateway() {
    final injected = widget.sttSettingsGateway;
    if (injected != null) {
      return injected;
    }
    try {
      return context.read<SttSettingsGateway>();
    } on ProviderNotFoundException {
      return HttpSttSettingsGateway();
    }
  }

  void _onChatViewModelChanged() {
    final currentSessionId = _chatViewModel.sessionId;
    if (_lastTrackedSessionId != currentSessionId) {
      _lastTrackedSessionId = currentSessionId;
      _errorPolicy.resetSession();
      if (_apiErrorNotice != null && mounted) {
        setState(() => _apiErrorNotice = null);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router?.routerDelegate.removeListener(_onRouteChanged);
    _voiceCoordinator.unsubscribe();
    _chatViewModel.removeListener(_onChatViewModelChanged);
    // 离开本页立刻闭嘴（ADR 0002）：**无条件**停播，包括还在队列里没开口的气泡。
    // 「只在 isReading 时才停」会让排队的 bubble 跨页继续读，不是可接受的取舍；
    // 卸载期不能同步通知监听者，这一点由 stopAllForLeavingPage 自己处理。
    _chatViewModel.voiceOutput.stopAllForLeavingPage();
    if (_chatViewModel.voiceOutput.onApiError == _handleVoiceApiError) {
      _chatViewModel.voiceOutput.onApiError = null;
    }
    _voiceCoordinator.dispose();
    _voiceInput.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 聊天页工具条上的顶层目的地（历史 / 模型连接）：**叠在当前位置之上**，
  /// 因此页内的「返回上一页」回到的就是刚离开的那一页。换页前无条件停播
  /// （ADR 0002），这一步与 [QiyuShell] 的导航动作同一口径。
  void _pushAwayFromChat(String location) {
    if (_android) _cancelUnsubmittedVoice();
    _composerKey.currentState?.dismissKeyboard();
    _chatViewModel.voiceOutput.stopAll();
    context.push(location);
  }

  /// 统一的异常分发执行点：策略表给出判定，页面只负责 setState 与弹窗接线。
  Future<void> _executeApiErrorDecision(ApiErrorTurnDecision decision) async {
    switch (decision) {
      case ClearApiErrorNotice():
        if (_apiErrorNotice != null) {
          setState(() => _apiErrorNotice = null);
        }
      case ShowApiErrorNotice(:final notice):
        setState(() => _apiErrorNotice = notice);
      case DispatchApiErrorDialog(:final category, :final delay):
        await _triggerApiErrorDialog(category, delay: delay);
    }
  }

  /// composer 的轮次收尾回调：兜底原因与服务错误元数据交给 [_errorPolicy]
  /// 查表，分类/频控/弹窗节奏都不在页面。
  Future<void> _handleTurnApiErrors(LocalChatViewModel viewModel) async {
    await _executeApiErrorDecision(
      _errorPolicy.decideTurn(
        reason: viewModel.latestFallbackReason,
        serviceError: viewModel.latestServiceError,
      ),
    );
  }

  Future<void> _triggerApiErrorDialog(
    ApiErrorCategory category, {
    bool delay = false,
  }) async {
    if (_isShowingApiErrorDialog || !mounted) {
      return;
    }
    final sessionId = _chatViewModel.sessionId;
    _isShowingApiErrorDialog = true;
    try {
      if (delay) {
        // 流式落定后约 300ms 缓冲：与原型一致，留出视觉落定呼吸时间（Spec §2）
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!mounted || _chatViewModel.sessionId != sessionId) {
          return;
        }
      }
      _composerKey.currentState?.dismissKeyboard();
      final goToSettings = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => QiyuApiErrorDialog(
          category: category,
          onDismiss: () => Navigator.of(dialogContext).pop(false),
          onGoToSettings: () => Navigator.of(dialogContext).pop(true),
        ),
      );
      if (!mounted) {
        return;
      }
      if (goToSettings == true) {
        _chatViewModel.voiceOutput.stopAll();
        context.push('/settings');
      } else {
        _composerKey.currentState?.restoreFocus();
      }
    } finally {
      _isShowingApiErrorDialog = false;
    }
  }

  void _handleVoiceApiError(ApiErrorCategory category) {
    unawaited(_executeApiErrorDecision(_errorPolicy.decideCategory(category)));
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<LocalChatViewModel>();
    // 会话恢复、新消息与流式增量都跟在列表尾部：签名变化时下一帧滚到底。
    _stick.onListContent(
      messageCount: viewModel.messages.length,
      transientCount: _transientCount(viewModel),
      streamingLength: viewModel.streamingText.length,
    );
    // 合一页（design-system §5）：还没发出消息就是空状态首页——问候 +
    // composer；发出第一句后消息流生长。没有「首页→对话页」的跳转，两条路由
    // 渲染同一个视图。判定只有一处出处：`isHomeState`（含「会话恢复中不算
    // 空态」，所以打开应用不会先闪一帧首页）。
    final empty = viewModel.isHomeState;
    // 空态↔聊天态的淡出分两处，走同一套时长（`QiyuMotion.base`，reduced-motion
    // 下归零）：夜景背景由 [QiyuShell] 的全幅层淡出；问候留在本页——空态那一列
    // 里它和 composer 同组垂直居中，聊天态换成消息流，所以淡出层照着
    // [_greetingRect]（空态最后一帧量到的位置）在原位画它，淡到底即出树。
    // 桌面两段式（空态居中→落底）；手机全程底部（Decision 10、§5、Story 23）。
    final narrow =
        MediaQuery.sizeOf(context).width < QiyuLayout.desktopBreakpoint;
    // 淡出层的落点：只在聊天态取，空态下问候由 `_homeBody` 自己画。
    final fadingGreeting = empty ? null : _greetingRect;
    // 键盘弹起把视口压矮，贴底态要重新贴底——否则列表停在半空，最新消息沉到
    // 键盘之下（内容签名不含 inset，没有这一跳就没人扣扳机）。
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    _stick.onKeyboardInset(keyboardInset);
    final keyboardVisible = keyboardInset > 0;
    return Scaffold(
      // 底色撤成透明：页面背景（夜色底 + 仅空态的夜景图）由 [QiyuShell] 铺成
      // **全幅底层**，侧边栏与抽屉作为半透明层叠在它之上。这里再铺一层不透明
      // night 会把底层整个盖住，毛玻璃就又退回平涂了。
      backgroundColor: Colors.transparent,
      body: Stack(
        key: _bodyStackKey,
        children: [
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 软键盘留下不足 200px 时优先保全编辑区；键盘收起即恢复工具栏。
                // 用安全区内实际高度判布局，不把横屏或窗口宽度当作平台判断。
                final compactKeyboard =
                    qiyuAndroidTouch &&
                    keyboardVisible &&
                    constraints.maxHeight < 200;
                return Column(
                  children: [
                    if (!compactKeyboard) _utilityStrip(context, viewModel),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _android
                            ? () => _composerKey.currentState?.dismissKeyboard()
                            : null,
                        child: empty && !compactKeyboard
                            ? _homeBody(context, viewModel, narrow: narrow)
                            : _chatBody(
                                context,
                                viewModel,
                                editorHeight: compactKeyboard
                                    ? constraints.maxHeight
                                    : null,
                              ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          // 聊天态才出现的问候淡出层：不接手势，也不参与命中测试。
          if (fadingGreeting case final rect?)
            Positioned.fromRect(
              rect: rect,
              child: IgnorePointer(
                child: QiyuGreetingFadeOut(
                  key: const Key('home-greeting-fade'),
                  duration: qiyuMotion(context, QiyuMotion.base),
                  onFinished: _dropGreetingOverlay,
                  child: _greeting(context),
                ),
              ),
            ),
          if (viewModel.hostStopped)
            Positioned.fill(
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(hostStoppedGateSituation),
                      SizedBox(height: QiyuSpacing.xs),
                      Text(hostStoppedGateGuidance),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 聊天态消息列表的 bottom padding：composer 覆盖层的**静息占位**（单行输入、
  /// 通知条收起时，覆盖层从列表底缘算起占掉的高度）。取常量、不跟随 composer
  /// 实际高度联动——联动会让列表随打字移动，违背「会话不动」；composer 长高时
  /// 覆盖层向上生长盖住更早的消息，「滚到底」时最后一条消息完整落在覆盖层之上。
  ///
  /// 数值推导（自下而上）：
  /// - [QiyuSpacing.lg]：面板之下原有的出屏留白（原 Column 底部的 SizedBox）；
  /// - composer 静息面板：Row（[QiyuComposer.restingRowHeight]，实测 46）+
  ///   上下内边距 2×[QiyuLayout.composerPadding] + 上下发丝边框 2×[QiyuLine.hairline]；
  /// - [QiyuSpacing.lg]：一条通知条的近似余量（通知条 = 顶距 8 + 正文行盒约 21）。
  ///   通知条出现时覆盖层向上吃掉这份余量，最多再侵入最后一条消息的底部边缘，
  ///   属「会话不动」优先的既定取舍；这份 24 也接替了改造前列表自身的 bottom
  ///   padding，静息外观与改造前一致（最后一条消息距面板顶 24px）。
  static const double _chatListBottomInset =
      QiyuSpacing.lg +
      QiyuComposer.restingRowHeight +
      2 * QiyuLayout.composerPadding +
      2 * QiyuLine.hairline +
      QiyuSpacing.lg;

  /// 聊天态：消息流铺满整幅作底层，通知条与 composer 作为**覆盖层**落底常驻。
  /// composer 随输入内容长高时只向上生长、盖住更早的消息，列表视口纹丝不动
  /// （原 Column 结构里 `Expanded` 的列表视口会被精确压缩对应行高）。列表底部
  /// 为覆盖层让位的 padding 常量见 [_chatListBottomInset]。
  Widget _chatBody(
    BuildContext context,
    LocalChatViewModel viewModel, {
    double? editorHeight,
  }) {
    return Stack(
      children: [
        // 收键盘走 Listener 的 down 事件而不是手势：每条消息自己带一个轻点
        // 显隐时刻的手势，竞技场里内层先胜，页面级的 onTap 点消息时永远轮不上
        // （框架的 tap-outside 失焦又明确排除移动端触摸）。down 事件不进竞技场，
        // 点任何位置都先到达，气泡的轻点与重听按钮照常工作。
        Positioned.fill(
          child: _android
              ? Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) =>
                      _composerKey.currentState?.dismissKeyboard(),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _stick.onUserDrag,
                    child: NotificationListener<ScrollMetricsNotification>(
                      onNotification: _stick.onScrollMetrics,
                      child: _messageArea(viewModel),
                    ),
                  ),
                )
              : _messageArea(viewModel),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: editorHeight == null ? null : 0,
          bottom: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (editorHeight == null) ...[
                _noticeBars(context, viewModel),
                _composer(viewModel),
                const SizedBox(height: QiyuSpacing.lg),
              ] else ...[
                Flexible(
                  child: SingleChildScrollView(
                    reverse: true,
                    child: _noticeBars(context, viewModel),
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: editorHeight),
                  child: _composer(viewModel),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 空态首页底部垫高：居中会把 padding 对半分到上下，所以垫 2 倍、实际把
  /// 内容上移 56——浏览器上边栏（标签页/地址栏/收藏栏）把窗口的视觉中心压到
  /// 视口几何中心之上，居中内容在 maximized 窗口里看起来坠在下半（2026-09-04
  /// 用户反馈「看起来很靠下」）。走 padding 而非 Transform：短窗滚动时垫高
  /// 只是滚出界的尾巴，不破坏 ticket 24 的「绝不溢出」。
  static const double _homeHeroRisePadding = 112;

  /// 空状态首页：桌面把问候与 composer 一起垂直居中（首页仪式感），窄屏问候
  /// 居中、composer **全程落底**。两种布局都保持「小窗与字号放大可滚动不溢出」。
  Widget _homeBody(
    BuildContext context,
    LocalChatViewModel viewModel, {
    required bool narrow,
  }) {
    if (!narrow) {
      return QiyuCenteredScrollable(
        // 首页仍是「小窗与字号放大时整体可滚动、绝不溢出」的那一类非列表页
        // （ticket 24）。底部垫高见 [_homeHeroRisePadding]。
        maxWidth: QiyuLayout.homeContentMaxWidth,
        padding: const EdgeInsets.fromLTRB(
          QiyuSpacing.lg,
          QiyuSpacing.lg,
          QiyuSpacing.lg,
          QiyuSpacing.lg + _homeHeroRisePadding,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _homeGreeting(context),
            const SizedBox(height: QiyuSpacing.xl),
            _noticeBars(context, viewModel),
            _composer(viewModel),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 问候仍居中且可滚，composer 不参与居中、钉在视口底部。
        Expanded(
          child: QiyuCenteredScrollable(
            maxWidth: QiyuLayout.homeContentMaxWidth,
            padding: const EdgeInsets.all(QiyuSpacing.lg),
            child: _homeGreeting(context),
          ),
        ),
        _noticeBars(context, viewModel),
        _composer(viewModel),
        const SizedBox(height: QiyuSpacing.lg),
      ],
    );
  }

  /// 空态那一列里的问候：除了绘制，还把这一帧实际占到的矩形记给聊天态的淡出层。
  ///
  /// 只记字段、不 setState——空态下问候本来就画在这里，重绘它没有任何意义；
  /// 翻页那一帧读到的是上一帧的落点，正好是用户看到的位置。
  Widget _homeGreeting(BuildContext context) {
    return Builder(
      builder: (context) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _captureGreetingRect(context),
        );
        return _greeting(context);
      },
    );
  }

  void _captureGreetingRect(BuildContext greetingContext) {
    if (!mounted || !greetingContext.mounted) {
      return;
    }
    final greeting = greetingContext.findRenderObject();
    final stack = _bodyStackKey.currentContext?.findRenderObject();
    if (greeting is! RenderBox ||
        stack is! RenderBox ||
        !greeting.attached ||
        !greeting.hasSize) {
      return;
    }
    _greetingRect =
        (stack.globalToLocal(greeting.localToGlobal(Offset.zero))) &
        greeting.size;
  }

  /// 淡到底了：把落点清空，淡出层随之出树。
  void _dropGreetingOverlay() {
    if (!mounted || _greetingRect == null) {
      return;
    }
    setState(() => _greetingRect = null);
  }

  /// 空状态问候：沿用时段分档的既有口径（`qiyuEmptyChatHint`），22 档字阶、
  /// 居中，压在虚化夜景上。
  Widget _greeting(BuildContext context) {
    return Text(
      qiyuEmptyChatHint(DateTime.now()),
      key: const Key('home-greeting'),
      textAlign: TextAlign.center,
      style: QiyuTypography.of(
        context,
      ).greeting.copyWith(color: QiyuColors.ink),
    );
  }

  /// 会话页自带的工具条：本地规则标识、朗读开关、历史与模型连接入口。
  /// 页面导航交给导航壳，这里只留会话自身的控件；两个入口与侧边栏去同一条
  /// 目的地，因此目的地与图标都从 [QiyuNavDestination] 取。返回栈语义**两边
  /// 不同**（改造前就是这样，本轮纯视觉换皮不动它）：工具条 [_pushAwayFromChat]
  /// 叠栈，页内「返回上一页」回到来的那一页；侧边栏是常驻顶层导航，走 `go` 换栈。
  Widget _utilityStrip(BuildContext context, LocalChatViewModel viewModel) {
    return QiyuStreamWidthBox(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          QiyuSpacing.md,
          QiyuSpacing.sm,
          QiyuSpacing.md,
          0,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (viewModel.hasLocalFallback)
              Flexible(
                child: Text(
                  '本地规则回复',
                  overflow: TextOverflow.ellipsis,
                  // 字号随档取次要档（散点数值直读走 QiyuTypography.of 的
                  // 数值入口，不回 QiyuType 直读——那里只有桌面档）。
                  style: TextStyle(
                    fontFamily: QiyuType.fontFamily,
                    fontSize: QiyuTypography.of(context).secondarySize,
                    color: QiyuColors.muted,
                  ),
                ),
              ),
            if (viewModel.voiceOutputConfigured) ...[
              const SizedBox(width: QiyuSpacing.xs),
              QiyuVoiceOutputControl(viewModel: viewModel),
            ],
            const SizedBox(width: QiyuSpacing.xs),
            _stripIconButton(
              key: const Key('open-history'),
              tooltip: QiyuNavDestination.history.label,
              icon: QiyuNavDestination.history.icon,
              onPressed: () =>
                  _pushAwayFromChat(QiyuNavDestination.history.path),
            ),
            const SizedBox(width: QiyuSpacing.xs),
            _stripIconButton(
              key: const Key('open-provider-settings'),
              tooltip: '模型连接',
              icon: QiyuNavDestination.settings.icon,
              onPressed: () =>
                  _pushAwayFromChat(QiyuNavDestination.settings.path),
            ),
          ],
        ),
      ),
    );
  }

  /// 工具条上的圆形图标按钮：34 档、muted 细图形，不着紫不带描边。
  /// 外面套自绘**键盘**焦点环（§9）：IconButton 自己会画 M3 的表面 focusColor
  /// 淡底，但给不出带 offset 的实线外环，节点由环自持并交给 IconButton。
  Widget _stripIconButton({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return QiyuOwnFocusRing(
      borderRadius: QiyuRadii.circleBorder,
      builder: (context, focusNode) => IconButton(
        key: key,
        style: qiyuAndroidTouchStyle,
        focusNode: focusNode,
        onPressed: onPressed,
        tooltip: tooltip,
        color: QiyuColors.muted,
        iconSize: QiyuIconSpec.size,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: BoxConstraints.tightFor(
          width: qiyuAndroidTouch ? 48 : QiyuLayout.composerIconButtonSize,
          height: qiyuAndroidTouch ? 48 : QiyuLayout.composerIconButtonSize,
        ),
        icon: Icon(icon),
      ),
    );
  }

  /// 错误与语音状态条：就近出现在 composer 上方，并作为 live region
  /// 播报给屏幕阅读器（ticket 24 错误关联）。两种状态共用。
  Widget _noticeBars(BuildContext context, LocalChatViewModel viewModel) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (viewModel.errorMessage case final message?)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: QiyuSpacing.md),
            child: Semantics(
              liveRegion: true,
              child: Text(
                message,
                style: QiyuTypography.of(context).secondary.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          ),
        if (_apiErrorNotice case final notice?)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              QiyuSpacing.md,
              QiyuSpacing.xs,
              QiyuSpacing.md,
              QiyuSpacing.xs,
            ),
            child: QiyuStreamWidthBox(
              child: Container(
                key: const Key('api-error-notice-banner'),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .errorContainer
                      .withValues(alpha: 0.12),
                  borderRadius: QiyuRadii.smallBorder,
                  border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .error
                        .withValues(alpha: 0.3),
                    width: QiyuLine.hairline,
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: QiyuSpacing.md,
                  vertical: QiyuSpacing.sm,
                ),
                child: Semantics(
                  liveRegion: true,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          notice.message,
                          key: const Key('api-error-notice-text'),
                          style: QiyuTypography.of(context).secondary.copyWith(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                      if (notice.showSettingsLink) ...[
                        const SizedBox(width: QiyuSpacing.xs),
                        InkWell(
                          key: const Key('api-error-notice-settings'),
                          onTap: () => _pushAwayFromChat('/settings'),
                          child: Text(
                            '去设置检查',
                            style: QiyuTypography.of(context).secondary.copyWith(
                              color: QiyuColors.accentBright,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        AnimatedBuilder(
          animation: _voiceInput,
          builder: (context, _) => _voiceStatusBar(context),
        ),
        AnimatedBuilder(
          animation: _chatAndVoiceTick,
          builder: (context, _) => _voiceOutputBar(context, viewModel),
        ),
      ],
    );
  }

  Widget _messageArea(LocalChatViewModel viewModel) {
    return QiyuStreamWidthBox(
      child: AnimatedBuilder(
        animation: viewModel.voiceOutput,
        builder: (context, _) => _messageList(viewModel),
      ),
    );
  }

  /// 输入行：合一页与输入模块（[QiyuComposer]）的唯一接缝。输入的文本、
  /// 选区、焦点、测量键、展开状态、文字度量、快捷键与监听生命周期全部
  /// 收在模块内部；页面只接发送起点、轮次收尾（异常分类与频控已收进
  /// [ApiErrorPolicy] 策略表，这里只执行判定）与导航三个页面侧回调，
  /// 不管理输入内部状态。
  Widget _composer(LocalChatViewModel viewModel) {
    return QiyuComposer(
      key: _composerKey,
      viewModel: viewModel,
      voiceInput: _voiceInput,
      voiceCoordinator: _voiceCoordinator,
      onSendStarted: _stick.requestFollow,
      // 回调无参：本轮视图模型就是模块持有的这一个，分类/频控/弹窗仍走
      // [_handleTurnApiErrors]，页面侧闭包自取 viewModel。
      onTurnCompleted: () => _handleTurnApiErrors(viewModel),
      pushAwayFromChat: _pushAwayFromChat,
    );
  }

  /// 语音输入状态行：录音计时 / 转写等待 / 可重试提示。作为 live region
  /// 播报给屏幕阅读器；idle 无事可报时不占位。
  Widget _voiceStatusBar(BuildContext context) {
    final voice = _voiceInput;
    final String? message;
    switch (voice.status) {
      case VoiceInputStatus.preparing:
        message = '正在准备麦克风…';
      case VoiceInputStatus.recording:
        final minutes = (voice.elapsedSeconds ~/ 60).toString().padLeft(2, '0');
        final seconds = (voice.elapsedSeconds % 60).toString().padLeft(2, '0');
        message = _android
            ? '正在录音 $minutes:$seconds，最长 60 秒'
            : '正在录音 $minutes:$seconds，再点一次说完，按 Esc 取消';
      case VoiceInputStatus.transcribing:
        message = _android
            ? '正在转文字…'
            : '正在转文字…（Esc 中止）';
      case VoiceInputStatus.retryable:
        message = voice.errorMessage ?? '转写没有成功，点麦克风重试，Esc 丢弃。';
      case VoiceInputStatus.idle:
        message = voice.errorMessage; // 麦克风授权失败等就近平铺。
      case VoiceInputStatus.unsupported:
      case VoiceInputStatus.notConfigured:
        message = null;
    }
    if (message == null) {
      return const SizedBox.shrink();
    }
    final isRetryable = voice.status == VoiceInputStatus.retryable;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        QiyuSpacing.lg,
        QiyuSpacing.xs,
        QiyuSpacing.lg,
        0,
      ),
      child: Semantics(
        liveRegion: true,
        child: Row(
          children: [
            if (voice.status == VoiceInputStatus.transcribing)
              const SizedBox.square(
                key: Key('voice-transcribing-spinner'),
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                isRetryable ? QiyuIcons.error : QiyuIcons.graphic_eq,
                size: 16,
                color: isRetryable
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            const SizedBox(width: QiyuSpacing.xs),
            Expanded(
              child: Text(
                message,
                key: const Key('voice-status'),
                style: TextStyle(
                  color: isRetryable
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 语音朗读状态行：正在朗读时提示并给出停止按钮；读不出来时同一
  /// 会话只提示一次（ADR 0002 的首提示后续静默）。作为 live region
  /// 播报给屏幕阅读器；空闲时收起。
  Widget _voiceOutputBar(BuildContext context, LocalChatViewModel viewModel) {
    final voiceOutput = viewModel.voiceOutput;
    final failure = voiceOutput.failureNotice;
    if (!voiceOutput.isReading && failure == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        QiyuSpacing.lg,
        QiyuSpacing.xs,
        QiyuSpacing.lg,
        0,
      ),
      child: Semantics(
        liveRegion: true,
        child: Row(
          children: [
            if (voiceOutput.isReading) ...[
              const Icon(QiyuIcons.volume_up, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  voiceOutput.phase == VoiceOutputPhase.synthesizing
                      ? '栖语准备读…'
                      : '栖语正在读',
                  key: const Key('voice-output-status'),
                ),
              ),
              IconButton(
                key: const Key('voice-output-stop'),
                tooltip: '停止朗读',
                onPressed: () => voiceOutput.stopAll(),
                icon: const Icon(QiyuIcons.stop),
              ),
            ] else if (failure != null) ...[
              Expanded(
                child: Text(
                  failure,
                  key: const Key('voice-output-failure'),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: '知道了',
                onPressed: () => voiceOutput.consumeFailureNotice(),
                icon: const Icon(QiyuIcons.close),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 等待或流式期间消息列表尾部多出的那一行（瞬时回复位）：build 里算
  /// 滚动签名与 [_messageList] 里算 itemCount 共用同一口径。
  static int _transientCount(LocalChatViewModel viewModel) =>
      viewModel.waiting || viewModel.streamingText.isNotEmpty ? 1 : 0;

  Widget _messageList(LocalChatViewModel viewModel) {
    // 会话恢复中：这里给出等待位。合一页的空态判定（`isHomeState`）已经把
    // loading 排除在外，所以恢复旧会话不会先闪一帧首页再回到消息流。
    if (viewModel.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (viewModel.isHomeState) {
      // 空列表的可见占位交给合一页的问候位，这里不再另画一份。
      return const SizedBox.shrink();
    }
    final transientCount = _transientCount(viewModel);
    // 流式期间已完结的行：按最终消息的同一装配先行渲染（见 itemBuilder），
    // done 换届时除尾段转正外零重排。
    final completedLines = viewModel.streamingCompletedLines;
    // 行进抑制门控（design-system §10 第 11 条）：滚轮滚动让消息滑到
    // 静止光标下时 MouseTracker 会派发 onEnter，指针快速扫过时每颗气泡
    // 也会闪时刻——门控在列表层收住（滚动通知只向上冒泡经过祖先，放出
    // 气泡收不到）。
    //
    // 聊天页划选（design-system §10 第 12 条）：选择区在最外、门控在
    // 内、消息列表在最内——与历史回看页同款同位置同口径。选区内容 =
    // 两边消息正文、消息时刻行小字与流式增量文本（整条列表包住即自然
    // 覆盖）；输入框与问候层不进选区（输入框有自带选区，包进去只会打
    // 架）。鼠标左键拖动列表即划选——滚动器的竖向拖动识别器不认鼠标
    // （`ScrollBehavior.dragDevices` 默认不含 mouse），划选无竞争者；
    // 滚动靠滚轮、滚动条与触屏竖向拖动（触屏路径选择区只注册横向拖动
    // 与长按）。触屏长按归划选（气泡侧不设长按手势，一个手势只对应一
    // 件事）；横向/斜向触屏拖动会起选（选择区固有行为，登记为小边
    // 界）。工具条、Ctrl+C 与网页右键复制出口全用原生默认，焦点行为
    // 也全盘接受原生（起选聚焦、点选区外解散、滚动跟随）。
    return SelectionArea(
      child: QiyuHoverGate(
        child: ListView.builder(
          controller: _scrollController,
          keyboardDismissBehavior: _android
              ? ScrollViewKeyboardDismissBehavior.onDrag
              : ScrollViewKeyboardDismissBehavior.manual,
          padding: const EdgeInsets.fromLTRB(
            QiyuSpacing.lg,
            QiyuSpacing.lg,
            QiyuSpacing.lg,
            // 覆盖层静息占位常量：推导与取舍见 [_chatListBottomInset]。
            _chatListBottomInset,
          ),
          itemCount:
              viewModel.messages.length +
              completedLines.length +
              transientCount,
          itemBuilder: (context, index) {
            final messagesEnd = viewModel.messages.length;
            if (index < messagesEnd) {
              final message = viewModel.messages[index];
              final nowReading = viewModel.voiceOutput.nowReading;
              final isQiyu = message.speaker == LocalChatSpeaker.qiyu;
              final deliveryIndex = message.deliveryIndex;
              return QiyuChatBubble(
                key: Key('chat-message-$index'),
                text: message.text,
                fromUser: !isQiyu,
                deliveryIndex: deliveryIndex,
                incomplete: message.incomplete,
                at: message.at,
                isSpeaking:
                    nowReading != null &&
                    message.requestId == nowReading.requestId &&
                    deliveryIndex == nowReading.deliveryIndex,
                // 栖语气泡的重听小喇叭：点一下立即重读这句（重听=重新合成）。
                onReplay: isQiyu && deliveryIndex != null
                    ? () => viewModel.replayVoiceOutput(message)
                    : null,
                // 一键复制：流式中断后不必凭记忆重打全文，栖语的金句也想
                // 存就走它。入口按指针分两路——桌面鼠标与时刻同一悬停显隐
                // （复制钮落在时刻行里），触屏/手写笔走选择区长按起选；历
                // 史回看页（整页可选中复制）不给。
                enableCopy: true,
              );
            }
            final completedEnd = messagesEnd + completedLines.length;
            if (index < completedEnd) {
              // 流式期间已完结的行：与最终消息**同一装配**（同宽度约束、
              // 同块底距、同时刻槽位常驻预留），done 换届时几何等值接管、
              // 布局零位移。但本行根件是 ExcludeSemantics、终局消息根件
              // 是 QiyuChatBubble，槽位级 canUpdate 类型失配——done 时
              // 子树重建、悬停态瞬态复位后自愈：几何等值成立，元素不跨
              // done 复用。deliveryIndex 尚不存在：不给重听键与朗读态，
              // 重听行位置留同位同高空带；复制与时刻显隐同最终气泡同参
              // 数。正文语义暂时排除——live region 不逐行重复播报，交付
              // 完成后由历史消息语义接管（ticket 24 口径）。零位移仅对
              // 完整交付且不立即朗读成立：半句交付每行长出「未完成」小
              // 字、立即朗读时重听行被「正在读」行替换，done 后仍有一
              // 次形变，已知取舍（design-system §10 条 13）。
              return ExcludeSemantics(
                child: QiyuChatBubble(
                  key: Key('chat-message-$index'),
                  text: completedLines[index - messagesEnd],
                  fromUser: false,
                  at: viewModel.previewMoment,
                  enableCopy: true,
                  // 重听键不给，但由 reserveReplayRow 留同位同高的重听
                  // 行空带（隐藏真实按钮承载，随平台档自动成立）。
                  reserveReplayRow: true,
                ),
              );
            }
            // 正在增长的尾段留在临时行：栖语的话无气泡（design-system §7），
            // 流式增量同样直接以书页式正文靠左呈现，只保留语义上的 live
            // region；完结行已在上面按最终装配先行渲染。
            return Padding(
              padding: const EdgeInsets.only(bottom: QiyuSpacing.xs),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: QiyuLayout.messageMaxWidth,
                ),
                // live region 只承载状态标签：流式期间正文不进语义树，
                // 避免每个 delta 都重读全文；交付完成后正文以历史消息
                // 的说话人语义呈现（ticket 24）。
                child: Semantics(
                  key: const Key('chat-streaming-reply'),
                  container: true,
                  child: Semantics(
                    liveRegion: true,
                    label: viewModel.streamingText.isEmpty
                        ? '栖语在想'
                        : '栖语正在回复',
                    child: ExcludeSemantics(
                      child: viewModel.streamingText.isEmpty
                          ? Text(
                              '栖语在想…',
                              style: QiyuTypography.of(
                                context,
                              ).qiyuMessage.copyWith(color: QiyuColors.muted),
                            )
                          : QiyuMarkdown(text: viewModel.streamingTailSegment),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
