import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import '../accessibility.dart';
import '../navigation.dart';
import '../settings/stt_settings_client.dart';
import '../shell/qiyu_shell.dart';
import '../shell/qiyu_widgets.dart';
import 'local_chat_client.dart';
import 'local_chat_view_model.dart';
import 'qiyu_chat_bubble.dart';
import 'qiyu_markdown.dart';
import 'qiyu_send_button.dart';
import 'voice_input_controller.dart';
import 'voice_output_controller.dart';
import 'voice_recorder_platform.dart';

/// 输入框里按 Enter 发送；Shift+Enter / Ctrl+Enter 插入软换行。
final class _SendChatIntent extends Intent {
  const _SendChatIntent();
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

final class _InsertLineBreakIntent extends Intent {
  const _InsertLineBreakIntent();
}

/// Esc 在语音输入各状态下的语义：录音中丢弃、转写中中止、可重试丢弃。
final class _VoiceEscapeIntent extends Intent {
  const _VoiceEscapeIntent();
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

class _LocalChatViewState extends State<LocalChatView> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  /// composer 焦点：聚焦态描边取 `composerFocusLine`（紫度 0.13），
  /// 失焦回落到 `line` 发丝线（design-system §8 组件 5）。
  final _inputFocusNode = FocusNode(debugLabel: 'chat-input');
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

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_trackStickToBottom);
    _inputFocusNode.addListener(_onInputFocusChange);
    final chatViewModel = _chatViewModel = context.read<LocalChatViewModel>();
    final sttSettingsGateway = _resolveSttSettingsGateway();
    _voiceInput = VoiceInputController(
      widget.voiceRecorderPlatform ?? createVoiceRecorderPlatform(),
      // 服务类型决定是否要浏览器端 WAV 转换（豆包要 16kHz 单声道 WAV）。
      () async {
        final settings = await sttSettingsGateway.read();
        return (
          configured: settings.configured,
          wantsWavAudio: settings.wantsWavAudio,
        );
      },
      chatViewModel.transcribeVoice,
      onTranscribed: (text) => unawaited(_sendTranscribed(chatViewModel, text)),
    );
    unawaited(_voiceInput.initialize());
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

  @override
  void dispose() {
    // 离开本页立刻闭嘴（ADR 0002）：**无条件**停播，包括还在队列里没开口的气泡。
    // 「只在 isReading 时才停」会让排队的 bubble 跨页继续读，不是可接受的取舍；
    // 卸载期不能同步通知监听者，这一点由 stopAllForLeavingPage 自己处理。
    _chatViewModel.voiceOutput.stopAllForLeavingPage();
    _voiceInput.dispose();
    _controller.dispose();
    _scrollController.dispose();
    _inputFocusNode
      ..removeListener(_onInputFocusChange)
      ..dispose();
    super.dispose();
  }

  /// 聚焦描边要跟着焦点重绘：`QiyuGlassPanel` 的装饰走 AnimatedContainer，
  /// `line` ↔ `composerFocusLine` 是 200ms 过渡（reduced-motion 下为 0）。
  void _onInputFocusChange() {
    if (mounted) setState(() {});
  }

  /// 聊天页工具条上的顶层目的地（历史 / 模型连接）：与侧边栏三项导航**同一个
  /// 语义出口** [openInFront]——目标已在返回栈里就回退到那一层，不在才 push。
  /// 统一前是侧边栏 `go` 换栈、工具条 `push` 叠栈，同一个目的地有时能返回、
  /// 有时不能；现在两边都「不叠加、返回键回到来的那一层」。页内详情（某一天
  /// 的会话、某条记忆）本来就走这条出口，语义没有变化。
  ///
  /// 换页前无条件停播（ADR 0002），与 [QiyuShell] 的导航动作同一口径。
  void _goToDestination(String location) {
    _chatViewModel.voiceOutput.stopAll();
    openInFront(context, location);
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

  Future<void> _send(LocalChatViewModel viewModel) async {
    final text = _controller.text;
    if (text.trim().isEmpty) {
      return;
    }
    _stickToBottom = true;
    final sending = viewModel.send(text);
    if (mounted && _controller.text == text) {
      _controller.clear();
    }
    final sent = await sending;
    if (!sent &&
        mounted &&
        _controller.text.isEmpty &&
        !viewModel.messages.any(
          (message) =>
              message.speaker == LocalChatSpeaker.user &&
              message.text == text.trim(),
        )) {
      _controller.text = text;
      _controller.selection = TextSelection.collapsed(offset: text.length);
    }
  }

  void _insertLineBreak() {
    final value = _controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final nextText = value.text.replaceRange(start, end, '\n');
    _controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  /// 语音转写出的文字直接发送：与手打共用同一条链路（requestId 幂等、
  /// 乐观插入、失败回填输入框）。栖语正在回复时排队，回复结束即发。
  Future<void> _sendTranscribed(
    LocalChatViewModel viewModel,
    String text,
  ) async {
    _stickToBottom = true;
    final sent = await viewModel.sendWhenIdle(text);
    if (!sent &&
        mounted &&
        _controller.text.isEmpty &&
        text.trim().isNotEmpty) {
      _controller.text = text;
      _controller.selection = TextSelection.collapsed(offset: text.length);
    }
  }

  Future<void> _showVoiceGuide() async {
    final voice = _voiceInput;
    // 置灰态先惰性重查一次：从设置页配好回来点麦克风直接开始说话。
    await voice.refreshConfigured();
    if (!mounted) {
      return;
    }
    if (voice.status == VoiceInputStatus.idle) {
      voice.handleMicTap();
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          voice.status == VoiceInputStatus.unsupported
              ? '当前浏览器不支持语音输入，请换 Chrome 或 Edge。'
              : '还没有配置语音服务，先去设置页填写地址、模型和 Key。',
        ),
        action: voice.status == VoiceInputStatus.unsupported
            ? null
            : SnackBarAction(
                label: '去设置',
                onPressed: () => _goToDestination('/settings'),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<LocalChatViewModel>();
    // 会话恢复、新消息与流式增量都跟在列表尾部：签名变化时下一帧滚到底。
    final transient = viewModel.waiting || viewModel.streamingText.isNotEmpty
        ? 1
        : 0;
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
    // 空态↔聊天态之间**只有夜景背景会淡出**：它由 [QiyuShell] 的全幅层用
    // `AnimatedSwitcher` 负责（时长走 `QiyuMotion`，reduced-motion 下归零）。
    // 问候随下面的分支切换立即出树，不参与淡出——它和 composer 是同一组垂直
    // 居中的内容，搬进全幅背景层就会压在被居中的 composer 之上，位置不再成立。
    // 桌面两段式（空态居中→落底）；手机全程底部（Decision 10、§5、Story 23）。
    final narrow =
        MediaQuery.sizeOf(context).width < QiyuLayout.desktopBreakpoint;
    return Scaffold(
      // 底色撤成透明：页面背景（夜色底 + 仅空态的夜景图）由 [QiyuShell] 铺成
      // **全幅底层**，侧边栏与抽屉作为半透明层叠在它之上。这里再铺一层不透明
      // night 会把底层整个盖住，毛玻璃就又退回平涂了。
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                _utilityStrip(context, viewModel),
                Expanded(
                  child: empty
                      ? _homeBody(context, viewModel, narrow: narrow)
                      : _chatBody(context, viewModel),
                ),
              ],
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
                      SizedBox(height: 8),
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

  /// 聊天态：消息流占满剩余高度，通知条与 composer 落底常驻。
  Widget _chatBody(BuildContext context, LocalChatViewModel viewModel) {
    return Column(
      children: [
        Expanded(child: _messageArea(viewModel)),
        _noticeBars(context, viewModel),
        _composer(context, viewModel),
        const SizedBox(height: QiyuSpacing.lg),
      ],
    );
  }

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
        // （ticket 24）。
        maxWidth: QiyuLayout.homeContentMaxWidth,
        padding: const EdgeInsets.all(QiyuSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _greeting(context),
            const SizedBox(height: QiyuSpacing.xl),
            _noticeBars(context, viewModel),
            _composer(context, viewModel),
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
            child: _greeting(context),
          ),
        ),
        _noticeBars(context, viewModel),
        _composer(context, viewModel),
        const SizedBox(height: QiyuSpacing.lg),
      ],
    );
  }

  /// 空状态问候：沿用时段分档的既有口径（`qiyuEmptyChatHint`），22 档字阶、
  /// 居中，压在虚化夜景上。
  Widget _greeting(BuildContext context) {
    return Text(
      qiyuEmptyChatHint(DateTime.now()),
      key: const Key('home-greeting'),
      textAlign: TextAlign.center,
      style: QiyuTypography.greeting.copyWith(color: QiyuColors.ink),
    );
  }

  /// 会话页自带的工具条：本地规则标识、朗读开关、历史与模型连接入口。
  /// 页面导航交给导航壳，这里只留会话自身的控件；两个入口与侧边栏去同一条
  /// 目的地，因此目的地与图标都从 [QiyuNavDestination] 取，返回栈语义也一致
  /// （`go`）。
  Widget _utilityStrip(BuildContext context, LocalChatViewModel viewModel) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: QiyuLayout.streamMaxWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            QiyuSpacing.md,
            QiyuSpacing.sm,
            QiyuSpacing.md,
            0,
          ),
          child: Row(
            children: [
              const Spacer(),
              if (viewModel.hasLocalFallback)
                const Flexible(
                  child: Text(
                    '本地规则回复',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: QiyuType.fontFamily,
                      fontSize: QiyuType.secondarySize,
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
                    _goToDestination(QiyuNavDestination.history.path),
              ),
              const SizedBox(width: QiyuSpacing.xs),
              _stripIconButton(
                key: const Key('open-provider-settings'),
                tooltip: '模型连接',
                icon: QiyuNavDestination.settings.icon,
                onPressed: () =>
                    _goToDestination(QiyuNavDestination.settings.path),
              ),
            ],
          ),
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
    return QiyuFocusRing.own(
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
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: QiyuLayout.streamMaxWidth),
        child: AnimatedBuilder(
          animation: viewModel.voiceOutput,
          builder: (context, _) => _messageList(viewModel),
        ),
      ),
    );
  }

  /// composer（design-system §8 组件 5）：毛玻璃胶囊、`line` 发丝描边、
  /// 内边距 6、聚焦描边压到紫度 0.13；占位字 `muted` 且靠 34px 行高居中。
  ///
  /// `home-go-chat` 沿用退役前首页「去聊天」入口卡的既有测试键：合一页
  /// 之后进入对话的动作就是这个输入容器，键位随职责搬过来。
  Widget _composer(BuildContext context, LocalChatViewModel viewModel) {
    final lineColor = _inputFocusNode.hasFocus
        ? QiyuColors.composerFocusLine
        : QiyuColors.line;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: QiyuSpacing.md),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: QiyuLayout.streamMaxWidth,
          ),
          child: QiyuGlassPanel(
            key: const Key('home-go-chat'),
            blurSigma: QiyuGlass.panelBlur,
            borderColor: lineColor,
            padding: const EdgeInsets.fromLTRB(
              QiyuSpacing.md,
              QiyuLayout.composerPadding,
              QiyuLayout.composerPadding,
              QiyuLayout.composerPadding,
            ),
            // 输入行本体：Enter 发送 / 软换行 / Esc 的快捷键作用域只包住它。
            child: Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.enter): _SendChatIntent(),
                SingleActivator(LogicalKeyboardKey.enter, shift: true):
                    _InsertLineBreakIntent(),
                SingleActivator(
                  LogicalKeyboardKey.enter,
                  control: true,
                ): _InsertLineBreakIntent(),
                SingleActivator(LogicalKeyboardKey.escape): _VoiceEscapeIntent(),
              },
              child: Actions(
                actions: {
                  _SendChatIntent: CallbackAction<_SendChatIntent>(
                    onInvoke: (intent) {
                      if (!viewModel.sending) {
                        unawaited(_send(viewModel));
                      }
                      return null;
                    },
                  ),
                  _InsertLineBreakIntent:
                      CallbackAction<_InsertLineBreakIntent>(
                        onInvoke: (intent) {
                          _insertLineBreak();
                          return null;
                        },
                      ),
                  _VoiceEscapeIntent: CallbackAction<_VoiceEscapeIntent>(
                    onInvoke: (intent) {
                      // 播放态下 Esc 等同停止按钮（ADR 0002 的打断规则）；
                      // 录音/转写语义不变。
                      viewModel.voiceOutput.stopAll();
                      _voiceInput.handleEscape();
                      return null;
                    },
                  ),
                },
                child: Row(
                  children: [
                    Expanded(child: _inputField()),
                    const SizedBox(width: QiyuSpacing.xs),
                    AnimatedBuilder(
                      animation: _voiceInput,
                      builder: (context, _) => _voiceMicButton(),
                    ),
                    const SizedBox(width: QiyuSpacing.xs),
                    QiyuSendButton(
                      sending: viewModel.sending,
                      onPressed: viewModel.sending
                          ? () => unawaited(viewModel.stop())
                          : () => unawaited(_send(viewModel)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 输入框本体：字色与占位字都来自 token；描边交给外层玻璃面板，
  /// 因此这里显式撤掉 TextField 自己的边框与填充。
  Widget _inputField() {
    return TextField(
      key: const Key('chat-input'),
      controller: _controller,
      focusNode: _inputFocusNode,
      autofocus: true,
      minLines: 1,
      maxLines: 5,
      textInputAction: TextInputAction.newline,
      style: QiyuTypography.body.copyWith(color: QiyuColors.ink),
      decoration: const InputDecoration(
        hintText: '想说点什么…',
        filled: false,
        isDense: true,
        contentPadding: EdgeInsets.zero,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        focusedErrorBorder: InputBorder.none,
      ),
    );
  }

  /// 语音输入状态行：录音计时 / 转写等待 / 可重试提示。作为 live region
  /// 播报给屏幕阅读器；idle 无事可报时不占位。
  Widget _voiceStatusBar(BuildContext context) {
    final voice = _voiceInput;
    final String? message;
    switch (voice.status) {
      case VoiceInputStatus.recording:
        final minutes = (voice.elapsedSeconds ~/ 60).toString().padLeft(2, '0');
        final seconds = (voice.elapsedSeconds % 60).toString().padLeft(2, '0');
        message = '正在录音 $minutes:$seconds，再点一次说完，按 Esc 取消';
      case VoiceInputStatus.transcribing:
        message = '正在转文字…（Esc 中止）';
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
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
                voice.status == VoiceInputStatus.retryable
                    ? Icons.error_outline
                    : Icons.graphic_eq,
                size: 16,
                color: voice.status == VoiceInputStatus.retryable
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                key: const Key('voice-status'),
                style: TextStyle(
                  color: voice.status == VoiceInputStatus.retryable
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

  /// 麦克风按钮：置灰态（不支持/未配置）点击只做引导，其余状态按
  /// 控制器状态机分派；转写中禁点（Esc 才是中止入口）。
  ///
  /// 五个状态共用 composer 的 34px 圆形图标按钮规格（design-system §8
  /// 组件 3），键名、tooltip 与状态机语义逐一对应原实现。
  Widget _voiceMicButton() {
    final voice = _voiceInput;
    final theme = Theme.of(context);
    final (key, tooltip, icon, color, onPressed) = switch (voice.status) {
      VoiceInputStatus.unsupported || VoiceInputStatus.notConfigured => (
        'voice-mic',
        '语音输入（当前不可用）',
        const Icon(Icons.mic_off_outlined),
        theme.disabledColor,
        _showVoiceGuide,
      ),
      VoiceInputStatus.idle => (
        'voice-mic',
        '语音输入',
        const Icon(Icons.mic_none),
        null,
        // 点麦克风她立刻闭嘴（ADR 0002 硬规则）：她的声音不能被录进
        // 转写变成用户在自言自语。
        () {
          final viewModel = context.read<LocalChatViewModel>();
          viewModel.voiceOutput.stopAll();
          // 60 秒自动收尾没有第二次点击，必须在开始录音
          // 的用户手势中先为稍后的回复朗读保留许可。
          if (viewModel.voiceOutputEnabled) {
            viewModel.voiceOutput.prepareForUserInitiatedPlayback();
          }
          voice.handleMicTap();
        },
      ),
      VoiceInputStatus.recording => (
        'voice-mic-stop',
        '说完，转成文字',
        const Icon(Icons.stop_circle_rounded),
        theme.colorScheme.error,
        // 转写和聊天都会跨越异步边界；说完的这次点击
        // 是语音闭环最后一个可用的浏览器用户手势。
        () {
          context.read<LocalChatViewModel>().voiceOutput
              .prepareForUserInitiatedPlayback();
          voice.handleMicTap();
        },
      ),
      VoiceInputStatus.transcribing => (
        'voice-mic-busy',
        '正在转文字',
        const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        null,
        null,
      ),
      VoiceInputStatus.retryable => (
        'voice-mic-retry',
        '重试转写',
        const Icon(Icons.mic_rounded),
        theme.colorScheme.error,
        // 与开始录音同规则：点麦克风即停播清队列。
        () {
          final voiceOutput = context.read<LocalChatViewModel>().voiceOutput;
          voiceOutput.stopAll();
          voiceOutput.prepareForUserInitiatedPlayback();
          voice.handleMicTap();
        },
      ),
    };
    return QiyuFocusRing.own(
      borderRadius: QiyuRadii.circleBorder,
      builder: (context, focusNode) => IconButton(
        key: Key(key),
        focusNode: focusNode,
        tooltip: tooltip,
        color: color,
        onPressed: onPressed,
        icon: icon,
        iconSize: QiyuIconSpec.size,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(
          width: QiyuLayout.composerIconButtonSize,
          height: QiyuLayout.composerIconButtonSize,
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
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      child: Semantics(
        liveRegion: true,
        child: Row(
          children: [
            if (voiceOutput.isReading) ...[
              const Icon(Icons.volume_up_outlined, size: 18),
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
                icon: const Icon(Icons.stop_rounded),
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
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ],
        ),
      ),
    );
  }

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
    final transientCount =
        viewModel.waiting || viewModel.streamingText.isNotEmpty ? 1 : 0;
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(QiyuSpacing.lg),
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
                            style: QiyuTypography.qiyuMessage.copyWith(
                              color: QiyuColors.muted,
                            ),
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
    );
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
              ? Icons.volume_off_rounded
              : (voiceOutput.volume < 0.5
                  ? Icons.volume_down_rounded
                  : Icons.volume_up_rounded);
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
  const _VolumePopupCard({
    required this.viewModel,
    required this.voiceOutput,
  });

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
          borderRadius: BorderRadius.circular(18),
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
            const SizedBox(height: 8),
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
              icon: Icon(
                isMuted
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
              ),
              onPressed: () => unawaited(viewModel.toggleVoiceOutput()),
            ),
          ],
        ),
      ),
    );
  }
}
