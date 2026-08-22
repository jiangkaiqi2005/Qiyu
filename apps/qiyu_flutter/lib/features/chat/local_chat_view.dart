import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../accessibility.dart';
import 'local_chat_client.dart';
import 'local_chat_view_model.dart';
import 'qiyu_chat_bubble.dart';
import 'qiyu_markdown.dart';

/// 输入框里按 Enter 发送；Shift+Enter / Ctrl+Enter 插入软换行。
final class _SendChatIntent extends Intent {
  const _SendChatIntent();
}

final class _InsertLineBreakIntent extends Intent {
  const _InsertLineBreakIntent();
}

class LocalChatView extends StatefulWidget {
  const LocalChatView({super.key});

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

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_trackStickToBottom);
  }

  @override
  void dispose() {
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
                    Expanded(child: _messageList(viewModel)),
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
        return QiyuChatBubble(
          text: message.text,
          fromUser: message.speaker == LocalChatSpeaker.user,
        );
      },
    );
  }
}
