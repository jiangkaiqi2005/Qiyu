import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_tokens.dart';
import '../chat/local_chat_client.dart';
import '../chat/local_chat_view_model.dart';
import '../chat/qiyu_chat_bubble.dart';
import '../navigation.dart';
import '../shell/qiyu_shell.dart';
import '../shell/qiyu_widgets.dart';
import '../time_format.dart';
import 'history_client.dart';
import 'history_view_model.dart';

class HistoryView extends StatelessWidget {
  const HistoryView({super.key});

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<HistoryViewModel>();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: QiyuLayout.pageReadingMaxWidth,
            ),
            child: Column(
              children: [
                Padding(
                  // 窄屏被壳包住时，三条杠浮在左上角：页头左内缩在自身 24 之外再让开
                  // 它的占位（差额由壳给出），标题才不会被压在它下面。会话详情页
                  // 不挂壳，用的是自己那一版固定内缩。
                  padding: EdgeInsets.fromLTRB(
                    24 + QiyuShellScope.headerLeftOverrun(context),
                    20,
                    24,
                    12,
                  ),
                  child: Row(
                    children: [
                      // 返回箭头何时让位给三条杠由壳判定（窄屏且被壳包住时
                      // 整块不出现），见 [QiyuPageHeaderBackButton]。
                      const QiyuPageHeaderBackButton(
                        buttonKey: Key('history-back'),
                      ),
                      Text(
                        '历史',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const Spacer(),
                      QiyuFocusRingScope(
                        borderRadius: QiyuRadii.circleBorder,
                        child: IconButton(
                          key: const Key('refresh-history'),
                          onPressed: viewModel.loading
                              ? null
                              : () => unawaited(viewModel.refresh()),
                          tooltip: '刷新历史',
                          icon: const Icon(QiyuIcons.refresh),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: _body(context, viewModel)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, HistoryViewModel viewModel) {
    if (viewModel.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (viewModel.errorMessage case final message?) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 12),
            QiyuFocusRingScope(
              borderRadius: QiyuRadii.circleBorder,
              child: TextButton(
                key: const Key('retry-history'),
                onPressed: () => unawaited(viewModel.refresh()),
                child: const Text('重试'),
              ),
            ),
          ],
        ),
      );
    }
    final listing = viewModel.listing;
    if (listing == null ||
        (listing.days.isEmpty && listing.unavailable.isEmpty)) {
      return const Center(child: Text('还没有历史记录'));
    }
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        for (final day in listing.days) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: Text(
              formatDayHeader(day.date),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final session in day.sessions)
            _SessionTile(
              key: Key('history-session-tile-${session.sessionId}'),
              session: session,
              isLatest: session.sessionId == listing.latestSessionId,
              viewModel: viewModel,
            ),
        ],
        if (listing.unavailable.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(top: 24, bottom: 8),
            child: Text('以下会话文件暂时无法读取'),
          ),
          for (final entry in listing.unavailable)
            Padding(
              key: Key('history-unavailable-${entry.name}'),
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${entry.name}：${entry.message}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ],
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    super.key,
    required this.session,
    required this.isLatest,
    required this.viewModel,
  });

  final HistorySessionSummary session;
  final bool isLatest;
  final HistoryViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final startedAt = session.startedAt.toLocal();
    return QiyuFocusRingScope(
      borderRadius: QiyuRadii.cardBorder,
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: InkWell(
          borderRadius: QiyuRadii.cardBorder,
          onTap: () => openInFront(context, '/history/${session.sessionId}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${twoDigits(startedAt.hour)}:${twoDigits(startedAt.minute)} · '
                        '${session.turnCount} 条消息',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        session.preview.isEmpty ? '（空会话）' : session.preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (isLatest)
                  QiyuFocusRingScope(
                    borderRadius: QiyuRadii.circleBorder,
                    child: TextButton(
                      key: const Key('resume-latest-session'),
                      onPressed: () => context.go('/chat'),
                      child: const Text('继续这段对话'),
                    ),
                  ),
                QiyuFocusRingScope(
                  borderRadius: QiyuRadii.circleBorder,
                  child: IconButton(
                    key: Key('delete-session-${session.sessionId}'),
                    onPressed: viewModel.deleting
                        ? null
                        : () => unawaited(_confirmDelete(context)),
                    tooltip: '删除这段会话',
                    icon: const Icon(QiyuIcons.delete),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这段会话？'),
        content: Text('删除后，这段会话的 ${session.turnCount} 条消息无法恢复。'),
        actions: [
          QiyuFocusRingScope(
            borderRadius: QiyuRadii.circleBorder,
            child: TextButton(
              key: const Key('cancel-delete'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
          ),
          QiyuFocusRingScope(
            borderRadius: QiyuRadii.circleBorder,
            child: TextButton(
              key: const Key('confirm-delete'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('删除'),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await viewModel.deleteSession(session.sessionId);
    }
  }
}

class HistorySessionView extends StatefulWidget {
  const HistorySessionView({super.key, required this.sessionId});

  final String sessionId;

  @override
  State<HistorySessionView> createState() => _HistorySessionViewState();
}

class _HistorySessionViewState extends State<HistorySessionView> {
  LocalChatSnapshot? _snapshot;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final viewModel = context.read<LocalChatViewModel>();
    unawaited(_load(viewModel));
  }

  Future<void> _load(LocalChatViewModel viewModel) async {
    try {
      final snapshot = await viewModel.readSession(widget.sessionId);
      if (!mounted) {
        return;
      }
      setState(() => _snapshot = snapshot);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = switch (error) {
          LocalChatGatewayException() => error.message,
          _ => '无法打开这段会话，请返回后重试。',
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: QiyuLayout.pageReadingMaxWidth,
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                  child: Row(
                    children: [
                      QiyuFocusRingScope(
                        borderRadius: QiyuRadii.circleBorder,
                        child: IconButton(
                          key: const Key('history-session-back'),
                          onPressed: () => backToPrevious(context),
                          tooltip: '返回历史',
                          icon: const Icon(QiyuIcons.arrow_back),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '会话详情',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: _body()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_errorMessage case final message?) {
      return Center(child: Text(message));
    }
    final snapshot = _snapshot;
    if (snapshot == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snapshot.messages.isEmpty) {
      return const Center(child: Text('这段会话还没有消息'));
    }
    // 只读回看页整页可选择：拖动即可跨气泡选中并复制文字；栖语回复
    // 的 Markdown 经 gpt_markdown 的 SelectableAdapter 参与同一选区。
    return SelectionArea(
      child: ListView.builder(
        key: const Key('history-session-messages'),
        padding: const EdgeInsets.all(24),
        itemCount: snapshot.messages.length,
        itemBuilder: (context, index) {
          final message = snapshot.messages[index];
          final fromUser = message.speaker == LocalChatSpeaker.user;
          // 与聊天页同口径：用户输入纯文本、栖语回复 Markdown，
          // 语义标签带说话人（ticket 24）。
          return QiyuChatBubble(text: message.text, fromUser: fromUser);
        },
      ),
    );
  }
}
