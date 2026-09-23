import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

enum ChatDeliveryEnd { closed, cancelled, failed }

enum _SegmentPhase { ready, collecting, message, state }

/// 已收到 message/state/done 的一个落盘段。页面展示与便捷发送共用它。
final class CompletedChatDelivery {
  const CompletedChatDelivery({
    required this.messages,
    required this.source,
    this.fallbackReason,
    this.serviceError,
    this.incomplete = false,
  });

  final List<String> messages;
  final ReplySource source;
  final FallbackReason? fallbackReason;
  final ServiceErrorCategory? serviceError;

  /// 协议失败留下的半句（票一）：该轮最终回复没有正常说完。内容如实，
  /// 页面据此显示「未完成」标记，不补全不伪装。
  final bool incomplete;
}

/// 一条请求流的协议状态。done 只完成一段，取消、失败或 EOF 才结束流。
/// 不拥有页面生命周期、草稿、消息集合或朗读副作用。
final class ChatDeliveryAssembly {
  ChatDeliveryAssembly({required this.requestId, bool accepted = false})
    // ignore: prefer_initializing_formals
    : _accepted = accepted;

  final String requestId;
  bool _accepted;
  String? _sessionId;
  ChatDeliveryEnd? _end;
  final List<CompletedChatDelivery> _completed = [];
  _SegmentPhase _phase = _SegmentPhase.ready;
  List<String>? _messages;
  ReplySource? _source;
  FallbackReason? _fallbackReason;
  ServiceErrorCategory? _serviceError;
  bool _incomplete = false;

  bool get accepted => _accepted;
  String? get sessionId => _sessionId;
  ChatDeliveryEnd? get end => _end;
  List<CompletedChatDelivery> get completed => List.unmodifiable(_completed);
  bool get hasCompleted => _completed.isNotEmpty;
  bool get hasIncompleteSegment => _phase != _SegmentPhase.ready;

  /// 每个合法 done 恰好返回一次完整段；终态后的事件不再接纳。
  CompletedChatDelivery? add(ChatDeliveryEvent event) {
    if (end != null) return null;
    if (event.requestId != requestId ||
        (sessionId != null &&
            event.sessionId != null &&
            event.sessionId != sessionId)) {
      _invalid();
    }
    _sessionId = event.sessionId ?? sessionId;
    switch (event.kind) {
      case ChatDeliveryEventKind.accepted:
        if (_phase != _SegmentPhase.ready || hasCompleted) _invalid();
        _accepted = true;
      case ChatDeliveryEventKind.waiting:
      case ChatDeliveryEventKind.delta:
      case ChatDeliveryEventKind.fallback:
        if (_phase == _SegmentPhase.message || _phase == _SegmentPhase.state) {
          _invalid();
        }
        _phase = _SegmentPhase.collecting;
        if (event.kind == ChatDeliveryEventKind.fallback) {
          _fallbackReason = event.fallbackReason;
          _serviceError = event.serviceError;
        }
      case ChatDeliveryEventKind.message:
        if (_phase == _SegmentPhase.message ||
            _phase == _SegmentPhase.state ||
            event.messages!.isEmpty) {
          _invalid();
        }
        _messages = event.messages!;
        _incomplete = event.incomplete == true;
        _phase = _SegmentPhase.message;
      case ChatDeliveryEventKind.state:
        if (_phase != _SegmentPhase.message) _invalid();
        _source = event.source!;
        _fallbackReason = event.fallbackReason;
        _serviceError = event.serviceError;
        _phase = _SegmentPhase.state;
      case ChatDeliveryEventKind.done:
        if (_phase != _SegmentPhase.state || sessionId == null) _invalid();
        final delivery = CompletedChatDelivery(
          messages: List.unmodifiable(_messages!),
          source: _source!,
          fallbackReason: _fallbackReason,
          serviceError: _serviceError,
          incomplete: _incomplete,
        );
        _completed.add(delivery);
        _messages = null;
        _source = null;
        _fallbackReason = null;
        _serviceError = null;
        _incomplete = false;
        _phase = _SegmentPhase.ready;
        return delivery;
      case ChatDeliveryEventKind.cancelled:
        _end = ChatDeliveryEnd.cancelled;
      case ChatDeliveryEventKind.error:
        _end = ChatDeliveryEnd.failed;
    }
    return null;
  }

  void close() => _end ??= ChatDeliveryEnd.closed;
  void fail() => _end ??= ChatDeliveryEnd.failed;

  Never _invalid() {
    fail();
    throw const FormatException('Invalid chat delivery sequence');
  }
}
