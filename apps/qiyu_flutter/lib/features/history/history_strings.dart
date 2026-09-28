import 'package:flutter/widgets.dart';

import '../shell/qiyu_ui_locale.dart';

abstract class HistoryStrings {
  const HistoryStrings();

  static HistoryStrings of(BuildContext context) =>
      qiyuIsEn(context) ? const _HistoryStringsEn() : const _HistoryStringsZh();

  String get title;
  String get refresh;
  String get empty;
  String get unavailable;
  String get emptySession;
  String get resume;
  String get deleteAction;
  String get deleteTitle;
  String get cancel;
  String get delete;
  String get back;
  String get detail;
  String get emptyDetail;
  String get openError;
  String messageCount(int count);
  String deleteDescription(int count);
}

class _HistoryStringsZh extends HistoryStrings {
  const _HistoryStringsZh();

  @override
  String get title => '历史';
  @override
  String get refresh => '刷新历史';
  @override
  String get empty => '还没有历史记录';
  @override
  String get unavailable => '以下会话文件暂时无法读取';
  @override
  String get emptySession => '（空会话）';
  @override
  String get resume => '继续这段对话';
  @override
  String get deleteAction => '删除这段会话';
  @override
  String get deleteTitle => '删除这段会话？';
  @override
  String get cancel => '取消';
  @override
  String get delete => '删除';
  @override
  String get back => '返回历史';
  @override
  String get detail => '会话详情';
  @override
  String get emptyDetail => '这段会话还没有消息';
  @override
  String get openError => '无法打开这段会话，请返回后重试。';
  @override
  String messageCount(int count) => '$count 条消息';
  @override
  String deleteDescription(int count) => '删除后，这段会话的 $count 条消息无法恢复。';
}

class _HistoryStringsEn extends HistoryStrings {
  const _HistoryStringsEn();

  @override
  String get title => 'History';
  @override
  String get refresh => 'Refresh history';
  @override
  String get empty => 'No conversations yet';
  @override
  String get unavailable => 'Some conversation files could not be read';
  @override
  String get emptySession => '(Empty conversation)';
  @override
  String get resume => 'Continue';
  @override
  String get deleteAction => 'Delete this conversation';
  @override
  String get deleteTitle => 'Delete this conversation?';
  @override
  String get cancel => 'Cancel';
  @override
  String get delete => 'Delete';
  @override
  String get back => 'Back to history';
  @override
  String get detail => 'Conversation details';
  @override
  String get emptyDetail => 'No messages in this conversation yet';
  @override
  String get openError =>
      'Could not open this conversation. Go back and try again.';
  @override
  String messageCount(int count) =>
      '$count ${count == 1 ? 'message' : 'messages'}';
  @override
  String deleteDescription(int count) =>
      'The $count ${count == 1 ? 'message' : 'messages'} in this conversation cannot be recovered after deletion.';
}
