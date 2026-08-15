import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'local_chat_client.dart';
import 'local_chat_view_model.dart';
import 'qiyu_markdown.dart';

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
    final sent = await viewModel.send(text);
    if (sent && mounted && _controller.text == text) {
      _controller.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<LocalChatViewModel>();
    // 会话恢复、新消息与流式增量都跟在列表尾部：签名变化时下一帧滚到底。
    final transient =
        viewModel.waiting || viewModel.streamingText.isNotEmpty ? 1 : 0;
    final signature =
        '${viewModel.messages.length}|$transient|${viewModel.streamingText.length}';
    if (signature != _lastListSignature) {
      _lastListSignature = signature;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_stickToBottom) {
          return;
        }
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(
            _scrollController.position.maxScrollExtent,
          );
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
                          if (viewModel.hasLocalFallback) const Text('本地规则回复'),
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
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          message,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('chat-input'),
                              controller: _controller,
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
              key: const Key('chat-streaming-reply'),
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              constraints: const BoxConstraints(maxWidth: 520),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(18),
              ),
              child: viewModel.streamingText.isEmpty
                  ? const Text('栖语在想…')
                  : QiyuMarkdown(text: viewModel.streamingText),
            ),
          );
        }
        final message = viewModel.messages[index];
        final fromUser = message.speaker == LocalChatSpeaker.user;
        return Align(
          alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            constraints: const BoxConstraints(maxWidth: 520),
            decoration: BoxDecoration(
              color: fromUser
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(18),
            ),
            // 用户输入按纯文本展示；栖语回复来自模型，按 Markdown 渲染。
            child: fromUser
                ? Text(message.text)
                : QiyuMarkdown(text: message.text),
          ),
        );
      },
    );
  }
}
