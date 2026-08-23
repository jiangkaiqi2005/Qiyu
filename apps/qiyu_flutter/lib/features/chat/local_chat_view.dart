import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../accessibility.dart';
import '../settings/stt_settings_client.dart';
import 'local_chat_client.dart';
import 'local_chat_view_model.dart';
import 'qiyu_chat_bubble.dart';
import 'qiyu_markdown.dart';
import 'voice_input_controller.dart';
import 'voice_output_controller.dart';
import 'voice_recorder_platform.dart';

/// 输入框里按 Enter 发送；Shift+Enter / Ctrl+Enter 插入软换行。
final class _SendChatIntent extends Intent {
  const _SendChatIntent();
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
  String _lastListSignature = '';

  // 会话恢复与发送后默认跟到底部；只有用户主动上滑才离开，
  // 避免流式增量把正在回读历史的用户拉回底部。
  bool _stickToBottom = true;
  double _lastPixels = 0;

  late final VoiceInputController _voiceInput;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_trackStickToBottom);
    final chatViewModel = context.read<LocalChatViewModel>();
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
    _voiceInput.dispose();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
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
                onPressed: () => context.push('/settings'),
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
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                      child: Row(
                        children: [
                          IconButton(
                            key: const Key('go-home'),
                            onPressed: () => context.go('/'),
                            tooltip: '首页',
                            icon: const Icon(Icons.arrow_back),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '栖语',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const Spacer(),
                          if (viewModel.hasLocalFallback)
                            const Flexible(
                              child: Text(
                                '本地规则回复',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          const SizedBox(width: 12),
                          if (viewModel.voiceOutputConfigured)
                            // 朗读一键开关：写 Host 的 tts.autoSpeak，刷新、
                            // 重启都记住；关掉后纯文字（状态变化经
                            // viewModel 通知重建）。
                            IconButton(
                              key: Key(
                                viewModel.voiceOutputEnabled
                                    ? 'voice-output-toggle-on'
                                    : 'voice-output-toggle-off',
                              ),
                              onPressed: () =>
                                  unawaited(viewModel.toggleVoiceOutput()),
                              tooltip: viewModel.voiceOutputEnabled
                                  ? '语音朗读开着，点击安静'
                                  : '语音朗读关着，点击开启',
                              icon: Icon(
                                viewModel.voiceOutputEnabled
                                    ? Icons.volume_up_rounded
                                    : Icons.volume_off_rounded,
                              ),
                            ),
                          IconButton(
                            key: const Key('open-history'),
                            onPressed: () => context.push('/history'),
                            tooltip: '历史',
                            icon: const Icon(Icons.history),
                          ),
                          IconButton(
                            key: const Key('open-provider-settings'),
                            onPressed: () => context.push('/settings'),
                            tooltip: '模型连接',
                            icon: const Icon(Icons.tune),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: AnimatedBuilder(
                        animation: viewModel.voiceOutput,
                        builder: (context, _) => _messageList(viewModel),
                      ),
                    ),
                    if (viewModel.errorMessage case final message?)
                      // 错误就近出现在输入区上方，并作为 live region
                      // 播报给屏幕阅读器（ticket 24 错误关联）。
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            message,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ),
                    AnimatedBuilder(
                      animation: _voiceInput,
                      builder: (context, _) => _voiceStatusBar(context),
                    ),
                    AnimatedBuilder(
                      animation: Listenable.merge([
                        viewModel,
                        viewModel.voiceOutput,
                      ]),
                      builder: (context, _) =>
                          _voiceOutputBar(context, viewModel),
                    ),
                    Shortcuts(
                      shortcuts: const {
                        SingleActivator(LogicalKeyboardKey.enter):
                            _SendChatIntent(),
                        SingleActivator(LogicalKeyboardKey.enter, shift: true):
                            _InsertLineBreakIntent(),
                        SingleActivator(
                          LogicalKeyboardKey.enter,
                          control: true,
                        ): _InsertLineBreakIntent(),
                        SingleActivator(LogicalKeyboardKey.escape):
                            _VoiceEscapeIntent(),
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
                          _VoiceEscapeIntent:
                              CallbackAction<_VoiceEscapeIntent>(
                                onInvoke: (intent) {
                                  // 播放态下 Esc 等同停止按钮（ADR 0002
                                  // 的打断规则）；录音/转写语义不变。
                                  viewModel.voiceOutput.stopAll();
                                  _voiceInput.handleEscape();
                                  return null;
                                },
                              ),
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                child: TextField(
                                  key: const Key('chat-input'),
                                  controller: _controller,
                                  autofocus: true,
                                  minLines: 1,
                                  maxLines: 5,
                                  textInputAction: TextInputAction.newline,
                                  decoration: const InputDecoration(
                                    hintText: '想说点什么…',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              AnimatedBuilder(
                                animation: _voiceInput,
                                builder: (context, _) => _voiceMicButton(),
                              ),
                              const SizedBox(width: 12),
                              IconButton.filled(
                                key: Key(
                                  viewModel.sending ? 'chat-stop' : 'chat-send',
                                ),
                                onPressed: viewModel.sending
                                    ? () => unawaited(viewModel.stop())
                                    : () => unawaited(_send(viewModel)),
                                tooltip: viewModel.sending ? '停止回复' : '发送',
                                icon: viewModel.sending
                                    ? const Icon(Icons.stop_rounded)
                                    : const Icon(Icons.arrow_upward),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
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
  Widget _voiceMicButton() {
    final voice = _voiceInput;
    switch (voice.status) {
      case VoiceInputStatus.unsupported:
      case VoiceInputStatus.notConfigured:
        return IconButton(
          key: const Key('voice-mic'),
          tooltip: '语音输入（当前不可用）',
          color: Theme.of(context).disabledColor,
          onPressed: _showVoiceGuide,
          icon: const Icon(Icons.mic_off_outlined),
        );
      case VoiceInputStatus.idle:
        return IconButton(
          key: const Key('voice-mic'),
          tooltip: '语音输入',
          // 点麦克风她立刻闭嘴（ADR 0002 硬规则）：她的声音不能被录进
          // 转写变成用户在自言自语。
          onPressed: () {
            context.read<LocalChatViewModel>().voiceOutput.stopAll();
            voice.handleMicTap();
          },
          icon: const Icon(Icons.mic_none),
        );
      case VoiceInputStatus.recording:
        return IconButton(
          key: const Key('voice-mic-stop'),
          tooltip: '说完，转成文字',
          color: Theme.of(context).colorScheme.error,
          onPressed: () => voice.handleMicTap(),
          icon: const Icon(Icons.stop_circle_rounded),
        );
      case VoiceInputStatus.transcribing:
        return IconButton(
          key: const Key('voice-mic-busy'),
          tooltip: '正在转文字',
          onPressed: null,
          icon: const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case VoiceInputStatus.retryable:
        return IconButton(
          key: const Key('voice-mic-retry'),
          tooltip: '重试转写',
          color: Theme.of(context).colorScheme.error,
          // 与开始录音同规则：点麦克风即停播清队列。
          onPressed: () {
            context.read<LocalChatViewModel>().voiceOutput.stopAll();
            voice.handleMicTap();
          },
          icon: const Icon(Icons.mic_rounded),
        );
    }
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
    if (viewModel.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (viewModel.messages.isEmpty &&
        !viewModel.waiting &&
        viewModel.streamingText.isEmpty) {
      return const Center(child: Text('今晚想说点什么？'));
    }
    final transientCount =
        viewModel.waiting || viewModel.streamingText.isNotEmpty ? 1 : 0;
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(24),
      itemCount: viewModel.messages.length + transientCount,
      itemBuilder: (context, index) {
        if (index == viewModel.messages.length) {
          return Align(
            alignment: Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              constraints: const BoxConstraints(maxWidth: 520),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(18),
                border: Border.fromBorderSide(highContrastSide(context)),
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
                        ? const Text('栖语在想…')
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
          text: message.text,
          fromUser: !isQiyu,
          deliveryIndex: deliveryIndex,
          isSpeaking:
              nowReading != null &&
              message.requestId == nowReading.requestId &&
              deliveryIndex == nowReading.deliveryIndex,
          // 栖语气泡的重听小喇叭：点一下立即重读这句（重听=重新合成）。
          onReplay: isQiyu && deliveryIndex != null
              ? () => viewModel.voiceOutput.playNow(
                  VoiceOutputRequest(
                    requestId: message.requestId,
                    deliveryIndex: deliveryIndex,
                    sessionId: null,
                  ),
                )
              : null,
        );
      },
    );
  }
}
