import 'dart:async';
import 'dart:convert';

import 'package:qiyu_local_host/qiyu_local_host.dart';

/// Omni 实时会话的可注入连接假件（T02）：客户端帧留痕并可选地按脚本
/// 应答；服务端事件经 [ScriptedOmniRealtimeConnection.server] 下发。
final class ScriptedOmniRealtimeConnection
    implements ProviderWebSocketConnection {
  final _incoming = StreamController<String>.broadcast();
  final sentFrames = <Map<String, Object?>>[];
  int connectCount = 0;
  bool closed = false;

  /// 客户端帧回调（测试据此做脚本应答）。
  void Function(Map<String, Object?> frame)? onClientFrame;

  @override
  Stream<List<int>> get messages => const Stream<List<int>>.empty();

  @override
  Stream<String> get textMessages => _incoming.stream;

  @override
  void send(List<int> bytes) {}

  @override
  void sendText(String text) {
    final frame = jsonDecode(text) as Map<String, Object?>;
    sentFrames.add(frame);
    onClientFrame?.call(frame);
  }

  @override
  Future<void> close() async {
    if (closed) {
      return;
    }
    closed = true;
    await _incoming.close();
  }

  void server(Map<String, Object?> event) {
    _incoming.add(jsonEncode(event));
  }

  List<Map<String, Object?>> framesOfType(String type) =>
      sentFrames.where((frame) => frame['type'] == type).toList();
}

final class ScriptedOmniRealtimeConnector
    implements ProviderWebSocketConnector {
  ScriptedOmniRealtimeConnector();

  final connection = ScriptedOmniRealtimeConnection();
  Uri? lastUri;
  Map<String, String>? lastHeaders;

  @override
  Future<ProviderWebSocketConnection> connect({
    required Uri uri,
    required Map<String, String> headers,
  }) async {
    lastUri = uri;
    lastHeaders = headers;
    connection.connectCount += 1;
    return connection;
  }
}

/// 固定脚本应答器：session.update 一律回 session.updated；首个
/// response.create 按脚本顺序下发服务端事件（脚本为空 = 对续答请求
/// 静默，覆盖服务端静默忽略的故障形态）。
void Function(Map<String, Object?> frame) scriptedOmniResponder(
  ScriptedOmniRealtimeConnection connection,
  List<Map<String, Object?>> replyScript,
) {
  var replied = false;
  return (frame) {
    if (frame['type'] == 'session.update') {
      connection.server({'type': 'session.updated', 'session': {}});
      return;
    }
    if (frame['type'] == 'response.create' && !replied) {
      replied = true;
      for (final event in replyScript) {
        connection.server(event);
      }
    }
  };
}
