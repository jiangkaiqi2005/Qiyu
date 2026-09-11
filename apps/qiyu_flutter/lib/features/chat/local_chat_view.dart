import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import '../accessibility.dart';
import '../settings/stt_settings_client.dart';
import '../shell/qiyu_shell.dart';
import '../shell/qiyu_widgets.dart';
import 'api_error_dialog.dart';
import 'local_chat_client.dart';
import 'local_chat_view_model.dart';
import 'qiyu_chat_bubble.dart';
import 'qiyu_composer.dart';
import 'qiyu_markdown.dart';
import 'qiyu_hover_gate.dart';
import 'voice_input_controller.dart';
import 'voice_output_controller.dart';
import 'voice_recorder_platform.dart';

final class _ApiErrorNotice {
  const _ApiErrorNotice({
    required this.message,
    this.showSettingsLink = true,
  });

  final String message;
  final bool showSettingsLink;
}

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
  StreamSubscription<void>? _recordingInterruptions;
  GoRouter? _router;
  String? _chatLocation;
  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  final _scrollController = ScrollController();

  /// 输入模块的身份与操作键：状态与生命周期都在 [QiyuComposer] 内部，
  /// 页面只经由它调用「恢复输入焦点」与「转写文本发送」两个操作；同一枚
  /// 键传给 widget，空态↔聊天态换布局时 State 原位保留，输入连续。
  final _composerKey = GlobalKey<QiyuComposerState>(debugLabel: 'chat-composer');

  String _lastListSignature = '';

  // 会话恢复与发送后默认跟到底部；只有用户主动上滑才离开，
  // 避免流式增量把正在回读历史的用户拉回底部。
  bool _stickToBottom = true;
  double _lastPixels = 0;

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
  final Set<ApiErrorCategory> _alertedErrorCategories = {};
  _ApiErrorNotice? _apiErrorNotice;
  bool _isShowingApiErrorDialog = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_trackStickToBottom);
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
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      chatViewModel.voiceOutput.isMicrophoneInUse = _isMicrophoneInUse;
      WidgetsBinding.instance.addObserver(this);
      if (recorder is InterruptibleVoiceRecorderPlatform) {
        _recordingInterruptions =
            (recorder as InterruptibleVoiceRecorderPlatform).interruptions
                .listen((_) {
                  _cancelUnsubmittedVoice();
                });
      }
    }
    unawaited(_voiceInput.initialize());
  }

  bool _isMicrophoneInUse() => _voiceInput.isMicrophoneInUse;

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
      _cancelUnsubmittedVoice();
      _chatViewModel.voiceOutput.stopAllForLeavingPage();
    }
  }

  void _cancelUnsubmittedVoice() =>
      _composerKey.currentState?.cancelUnsubmittedVoice();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _cancelUnsubmittedVoice();
      _chatViewModel.voiceOutput.interruptOutput();
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
      _alertedErrorCategories.clear();
      if (_apiErrorNotice != null && mounted) {
        setState(() => _apiErrorNotice = null);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router?.routerDelegate.removeListener(_onRouteChanged);
    unawaited(_recordingInterruptions?.cancel());
    _chatViewModel.removeListener(_onChatViewModelChanged);
    // 离开本页立刻闭嘴（ADR 0002）：**无条件**停播，包括还在队列里没开口的气泡。
    // 「只在 isReading 时才停」会让排队的 bubble 跨页继续读，不是可接受的取舍；
    // 卸载期不能同步通知监听者，这一点由 stopAllForLeavingPage 自己处理。
    _chatViewModel.voiceOutput.stopAllForLeavingPage();
    if (_chatViewModel.voiceOutput.onApiError == _handleVoiceApiError) {
      _chatViewModel.voiceOutput.onApiError = null;
    }
    if (_chatViewModel.voiceOutput.isMicrophoneInUse == _isMicrophoneInUse) {
      _chatViewModel.voiceOutput.isMicrophoneInUse = null;
    }
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

  /// composer 的发送起点回调（手打与转写共用）：发一条消息都视为用户要
  /// 回到底部，与迁移前两条发送路径开头的 `_stickToBottom = true` 同口径。
  void _onComposerSendStarted() {
    _stickToBottom = true;
  }

  // pixels 减少只可能来自用户上滑（程序跳转与内容增长不会减少），
  // 以此判定离开底部；滑回底部附近则重新粘滞。
  void _trackStickToBottom() {
    final position = _scrollController.position;
    if (position.pixels < _lastPixels) {
      _stickToBottom = position.pixels >= position.maxScrollExtent - 120;
    } else if (position.pixels >= position.maxScrollExtent - 120) {
      _stickToBottom = true;
    }
    _lastPixels = position.pixels;
  }

  ApiErrorCategory? _categorizeFallbackReason(
    FallbackReason? reason, {
    String? detail,
  }) {
    if (reason == null) {
      return null;
    }
    return switch (reason) {
      FallbackReason.modelRateLimited => ApiErrorCategory.rateLimited,
      FallbackReason.modelAuthentication => ApiErrorCategory.authentication,
      FallbackReason.modelNotFound => ApiErrorCategory.modelNotFound,
      FallbackReason.modelProvider when _isClient4xxError(detail) =>
        ApiErrorCategory.otherClientError,
      _ => null,
    };
  }

  static bool _isClient4xxError(String? detail) {
    if (detail == null || detail.isEmpty) {
      return false;
    }
    final lower = detail.toLowerCase();
    // 纯 5xx 或内部错误不归为客户端错误
    if (lower.contains('500') ||
        lower.contains('502') ||
        lower.contains('503') ||
        lower.contains('504') ||
        lower.contains('internal_server_error')) {
      return false;
    }
    return lower.contains('400') ||
        lower.contains('422') ||
        lower.contains('bad_request') ||
        lower.contains('unprocessable') ||
        lower.contains('invalid_request') ||
        lower.contains('client_error');
  }

  /// 统一的异常分发与会话级频控判断逻辑：供文本聊天与语音链路共用。
  Future<void> _dispatchApiError(
    ApiErrorCategory category, {
    bool delay = false,
  }) async {
    if (!mounted) {
      return;
    }
    // 会话级频控去重：同会话内仅第 1 次弹窗；第 2 次及后续展示状态条轻提示
    if (_alertedErrorCategories.contains(category)) {
      setState(() {
        _apiErrorNotice = _ApiErrorNotice(
          message: category.noticeText,
          showSettingsLink: true,
        );
      });
    } else {
      _alertedErrorCategories.add(category);
      await _triggerApiErrorDialog(category, delay: delay);
    }
  }

  Future<void> _handleTurnApiErrors(LocalChatViewModel viewModel) async {
    final reason = viewModel.latestFallbackReason;
    if (reason == null) {
      if (_apiErrorNotice != null) {
        setState(() => _apiErrorNotice = null);
      }
      return;
    }

    // 严格排除设计内降级：安全拦截与未配置模型绝对不弹窗
    if (reason == FallbackReason.safety ||
        reason == FallbackReason.noLlmConfig) {
      if (_apiErrorNotice != null) {
        setState(() => _apiErrorNotice = null);
      }
      return;
    }

    // 网络瞬态（超时/网络/DNS/TLS）：维持就地轻提示，绝不弹出模态配置修复窗
    if (reason == FallbackReason.modelTimeout) {
      setState(() {
        _apiErrorNotice = const _ApiErrorNotice(
          message: '⚠️ 网络连接超时，当前保持本地基础回复',
          showSettingsLink: false,
        );
      });
      return;
    }
    if (reason == FallbackReason.modelNetwork ||
        reason == FallbackReason.modelDns ||
        reason == FallbackReason.modelTls) {
      setState(() {
        _apiErrorNotice = const _ApiErrorNotice(
          message: '⚠️ 网络连接异常，当前保持本地基础回复',
          showSettingsLink: false,
        );
      });
      return;
    }

    final category = _categorizeFallbackReason(
      reason,
      detail: viewModel.latestFallbackDetail,
    );
    if (category == null) {
      return;
    }

    // 流式落定后约 300ms 缓冲
    await _dispatchApiError(category, delay: true);
  }

  Future<void> _triggerApiErrorDialog(
    ApiErrorCategory category, {
    bool delay = false,
  }) async {
    if (_isShowingApiErrorDialog || !mounted) {
      return;
    }
    _isShowingApiErrorDialog = true;
    try {
      if (delay) {
        // 流式落定后约 300ms 缓冲：与原型一致，留出视觉落定呼吸时间（Spec §2）
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!mounted) {
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
    unawaited(_dispatchApiError(category, delay: false));
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<LocalChatViewModel>();
    // 会话恢复、新消息与流式增量都跟在列表尾部：签名变化时下一帧滚到底。
    final transient = _transientCount(viewModel);
    final signature =
        '${viewModel.messages.length}|$transient|${viewModel.streamingText.length}';
    if (signature != _lastListSignature) {
      _lastListSignature = signature;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_stickToBottom) {
          return;
        }
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
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
    return Scaffold(
      // 底色撤成透明：页面背景（夜色底 + 仅空态的夜景图）由 [QiyuShell] 铺成
      // **全幅底层**，侧边栏与抽屉作为半透明层叠在它之上。这里再铺一层不透明
      // night 会把底层整个盖住，毛玻璃就又退回平涂了。
      backgroundColor: Colors.transparent,
      body: Stack(
        key: _bodyStackKey,
        children: [
          SafeArea(
            child: Column(
              children: [
                _utilityStrip(context, viewModel),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap:
                        !kIsWeb &&
                            defaultTargetPlatform == TargetPlatform.android
                        ? () => _composerKey.currentState?.dismissKeyboard()
                        : null,
                    child: empty
                        ? _homeBody(context, viewModel, narrow: narrow)
                        : _chatBody(context, viewModel),
                  ),
                ),
              ],
            ),
          ),
          // 聊天态才出现的问候淡出层：不接手势，也不参与命中测试。
          if (fadingGreeting case final rect?)
            Positioned.fromRect(
              rect: rect,
              child: IgnorePointer(
                child: _GreetingFadeOut(
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
                      Text('本机程序已停止'),
                      SizedBox(height: QiyuSpacing.xs),
                      Text('请重新启动栖语本机程序。'),
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
  Widget _chatBody(BuildContext context, LocalChatViewModel viewModel) {
    return Stack(
      children: [
        Positioned.fill(child: _messageArea(viewModel)),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _noticeBars(context, viewModel),
              _composer(viewModel),
              const SizedBox(height: QiyuSpacing.lg),
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
              _VoiceOutputHeaderControl(viewModel: viewModel),
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
        focusNode: focusNode,
        onPressed: onPressed,
        tooltip: tooltip,
        color: QiyuColors.muted,
        iconSize: QiyuIconSpec.size,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(
          width: QiyuLayout.composerIconButtonSize,
          height: QiyuLayout.composerIconButtonSize,
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
  /// 收在模块内部；页面只接发送起点、轮次收尾（服务异常分类/频控/弹窗
  /// 仍在页面协调）与导航三个页面侧回调，不管理输入内部状态。
  Widget _composer(LocalChatViewModel viewModel) {
    return QiyuComposer(
      key: _composerKey,
      viewModel: viewModel,
      voiceInput: _voiceInput,
      onSendStarted: _onComposerSendStarted,
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
        message = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
            ? '正在录音 $minutes:$seconds，最长 60 秒'
            : '正在录音 $minutes:$seconds，再点一次说完，按 Esc 取消';
      case VoiceInputStatus.transcribing:
        message = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
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
    // 行进抑制门控（design-system §10 第 11 条）：滚轮滚动让消息滑到
    // 静止光标下时 MouseTracker 会派发 onEnter，指针快速扫过时每颗气泡
    // 也会闪时刻——门控在列表层收住（滚动通知只向上冒泡经过祖先，放出
    // 气泡收不到）。
    return QiyuHoverGate(
      child: ListView.builder(
        controller: _scrollController,
        keyboardDismissBehavior:
            !kIsWeb && defaultTargetPlatform == TargetPlatform.android
            ? ScrollViewKeyboardDismissBehavior.onDrag
            : ScrollViewKeyboardDismissBehavior.manual,
        padding: const EdgeInsets.fromLTRB(
          QiyuSpacing.lg,
          QiyuSpacing.lg,
          QiyuSpacing.lg,
          // 覆盖层静息占位常量：推导与取舍见 [_chatListBottomInset]。
          _chatListBottomInset,
        ),
        itemCount: viewModel.messages.length + transientCount,
        itemBuilder: (context, index) {
          if (index == viewModel.messages.length) {
            // 栖语的话无气泡（design-system §7）：流式增量同样直接以书页式
            // 正文靠左呈现，只保留语义上的 live region。
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
                    label: viewModel.streamingText.isEmpty ? '栖语在想' : '栖语正在回复',
                    child: ExcludeSemantics(
                      child: viewModel.streamingText.isEmpty
                          ? Text(
                              '栖语在想…',
                              style: QiyuTypography.of(
                                context,
                              ).qiyuMessage.copyWith(color: QiyuColors.muted),
                            )
                          : QiyuMarkdown(text: viewModel.streamingText),
                    ),
                  ),
                ),
              ),
            );
          }
          final message = viewModel.messages[index];
          final nowReading = viewModel.voiceOutput.nowReading;
          final isQiyu = message.speaker == LocalChatSpeaker.qiyu;
          final deliveryIndex = message.deliveryIndex;
          return QiyuChatBubble(
            key: Key('chat-message-$index'),
            text: message.text,
            fromUser: !isQiyu,
            deliveryIndex: deliveryIndex,
            at: message.at,
            isSpeaking:
                nowReading != null &&
                message.requestId == nowReading.requestId &&
                deliveryIndex == nowReading.deliveryIndex,
            // 栖语气泡的重听小喇叭：点一下立即重读这句（重听=重新合成）。
            onReplay: isQiyu && deliveryIndex != null
                ? () => viewModel.replayVoiceOutput(message)
                : null,
          );
        },
      ),
    );
  }
}

/// 空态→聊天态时问候的**淡出层**：从完全不透明淡到透明，淡完通知父级把自己
/// 摘掉（Spec User Story 2「发出第一句后背景与问候淡出」）。
///
/// 时长由调用方给（`qiyuMotion(context, QiyuMotion.base)`，reduced-motion 下是
/// [Duration.zero]，第一帧就到位、等于没有动效）。它在父级重建时**必须保持同一个
/// 键**：`_chatBody` 每次 notify 都重建，键一变这个 State 就重造、动画从头再来，
/// 淡出永远走不完——所以父级只把它当固定的一层挂在那里，不拿内容当 key。
class _GreetingFadeOut extends StatefulWidget {
  const _GreetingFadeOut({
    super.key,
    required this.duration,
    required this.onFinished,
    required this.child,
  });

  final Duration duration;
  final VoidCallback onFinished;
  final Widget child;

  @override
  State<_GreetingFadeOut> createState() => _GreetingFadeOutState();
}

class _GreetingFadeOutState extends State<_GreetingFadeOut>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1.0,
  );

  @override
  void initState() {
    super.initState();
    // 听 TickerFuture，不听状态监听：以 value 1.0 构造出来的控制器「上次上报的
    // 状态」还是 dismissed，零时长（reduced-motion）下直接跳到 dismissed 不算
    // 状态变化，监听器一次都不会触发，这一层就永远挂在树上。
    _controller.reverse().whenComplete(_notifyFinished);
  }

  void _notifyFinished() {
    // 再等这一帧画完才通知父级：whenComplete 的回调可能落在本帧 build 之后立刻
    // 执行，那时 setState 会撞上「build 期间不得标脏」的限制。
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onFinished());
  }

  @override
  void dispose() {
    // 父级提前摘掉这一层（例如又回到空态）时动画可能还在跑：先 stop，
    // 不留活跃 ticker。
    _controller
      ..stop()
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _controller, child: widget.child);
  }
}

class _VoiceOutputHeaderControl extends StatefulWidget {
  const _VoiceOutputHeaderControl({required this.viewModel});

  final LocalChatViewModel viewModel;

  @override
  State<_VoiceOutputHeaderControl> createState() =>
      _VoiceOutputHeaderControlState();
}

class _VoiceOutputHeaderControlState extends State<_VoiceOutputHeaderControl> {
  final _overlayController = OverlayPortalController();
  final _link = LayerLink();

  /// 焦点节点由本页持有并释放，同时交给自绘键盘焦点环与 IconButton
  /// （§9：工具条上的图标按钮也要有带 offset 的实线外环，且只响应键盘态）。
  final _focusNode = FocusNode(debugLabel: 'voice-output-toggle');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final viewModel = widget.viewModel;
    final voiceOutput = viewModel.voiceOutput;
    return CompositedTransformTarget(
      link: _link,
      child: ListenableBuilder(
        listenable: voiceOutput,
        builder: (context, _) {
          final isMuted =
              !viewModel.voiceOutputEnabled || voiceOutput.volume == 0;
          final icon = isMuted
              ? QiyuIcons.volume_off
              : (voiceOutput.volume < 0.5
                    ? QiyuIcons.volume_down
                    : QiyuIcons.volume_up);
          return OverlayPortal(
            controller: _overlayController,
            overlayChildBuilder: (context) {
              return Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _overlayController.hide(),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  CompositedTransformFollower(
                    link: _link,
                    targetAnchor: Alignment.bottomCenter,
                    followerAnchor: Alignment.topCenter,
                    offset: const Offset(0, 6),
                    child: _VolumePopupCard(
                      viewModel: viewModel,
                      voiceOutput: voiceOutput,
                    ),
                  ),
                ],
              );
            },
            child: QiyuFocusRing(
              focusNode: _focusNode,
              borderRadius: QiyuRadii.circleBorder,
              child: IconButton(
                key: Key(
                  viewModel.voiceOutputEnabled
                      ? 'voice-output-toggle-on'
                      : 'voice-output-toggle-off',
                ),
                focusNode: _focusNode,
                color: isMuted ? theme.colorScheme.onSurfaceVariant : null,
                tooltip: viewModel.voiceOutputEnabled
                    ? '朗读音量与静音调节'
                    : '语音朗读已关闭，点击开启与调节',
                icon: Icon(icon),
                onPressed: () {
                  _overlayController.toggle();
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class _VolumePopupCard extends StatelessWidget {
  const _VolumePopupCard({required this.viewModel, required this.voiceOutput});

  final LocalChatViewModel viewModel;
  final VoiceOutputController voiceOutput;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMuted = !viewModel.voiceOutputEnabled || voiceOutput.volume == 0;
    final percent = isMuted ? 0 : (voiceOutput.volume * 100).round();

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 72,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: QiyuRadii.cardBorder,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          boxShadow: [
            BoxShadow(
              color: theme.shadowColor.withValues(alpha: 0.25),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              height: 120,
              width: 32,
              child: RotatedBox(
                quarterTurns: 3,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 6,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 8,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                    activeTrackColor: theme.colorScheme.primary,
                    thumbColor: theme.colorScheme.primary,
                    inactiveTrackColor: theme.colorScheme.surfaceContainer,
                  ),
                  child: Slider(
                    key: const Key('voice-output-volume-slider'),
                    value: isMuted ? 0.0 : voiceOutput.volume,
                    min: 0.0,
                    max: 1.0,
                    onChanged: (val) {
                      voiceOutput.setVolume(val);
                      if (!viewModel.voiceOutputEnabled && val > 0) {
                        unawaited(viewModel.toggleVoiceOutput());
                      }
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: QiyuSpacing.xs),
            Text(
              '$percent%',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 6),
            const Divider(height: 1),
            const SizedBox(height: 2),
            IconButton(
              key: const Key('voice-output-popover-mute-button'),
              iconSize: 22,
              visualDensity: VisualDensity.compact,
              tooltip: isMuted ? '解除静音' : '静音',
              color: isMuted ? theme.colorScheme.onSurfaceVariant : null,
              icon: Icon(isMuted ? QiyuIcons.volume_off : QiyuIcons.volume_up),
              onPressed: () => unawaited(viewModel.toggleVoiceOutput()),
            ),
          ],
        ),
      ),
    );
  }
}
