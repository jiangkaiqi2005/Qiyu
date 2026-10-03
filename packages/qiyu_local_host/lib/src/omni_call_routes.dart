import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_http.dart';
import 'markdown_memory_repository.dart';
import 'omni_call_service.dart';

/// Omni 双工通话的 Host 传输路由（T03）：`GET api/omni/call` 经现有
/// Host 会话/Origin 检查后升级为 WebSocket。前端不直接拿 Key 连接
/// Provider——上行只有采集音频与控制帧，下行只有通话状态与文字/
/// 音频事件；Provider 凭据全部留在 Host 内。
///
/// 线协议（JSON 文本帧）：
/// - 上行：`{"type":"start","sessionId":…}`（首帧，开始通话）、
///   `{"type":"audio","pcm":"<base64 PCM16 16k>"}`、
///   `{"type":"text","requestId":…,"text":…}`（通话中打字）、
///   `{"type":"mute","muted":bool}`、`{"type":"end"}`（挂断）。
/// - 下行：`{"type":"state","phase":…[,"reason":…]}`、
///   `{"type":"speechStarted"|"speechStopped"}`、
///   `{"type":"inputTranscript","turnId":…,"text":…}`、
///   `{"type":"replyDelta","turnId":…,"text":…}`、
///   `{"type":"replyDone","turnId":…,"status":…,"incomplete":bool}`、
///   `{"type":"audio","turnId":…,"pcm":"<base64 PCM16 24k>"}`。
final class OmniCallRoutes implements ApiRoutes {
  OmniCallRoutes({required this.callService});

  final OmniRealtimeCallService callService;

  late final Handler _webSocketHandler = webSocketHandler(
    (WebSocketChannel channel, String? subprotocol) {
      unawaited(_serve(channel));
    },
  );

  @override
  Future<Response?> handle(Request request) async {
    final method = request.method;
    final path = request.url.path;
    if (method == 'GET' && path == 'api/omni/call') {
      // 非法升级请求由 shelf_web_socket 回 404/400；合法升级在其内部
      // 完成 Hijack，响应不再走常规返回路径。
      return _webSocketHandler(request);
    }
    return null;
  }

  Future<void> _serve(WebSocketChannel channel) async {
    var started = false;
    try {
      await for (final message in channel.stream) {
        if (message is! String) {
          continue;
        }
        final Map<String, Object?> frame;
        try {
          final decoded = jsonDecode(message);
          if (decoded is! Map<String, Object?>) {
            throw const FormatException('frame must be an object');
          }
          frame = decoded;
        } on FormatException {
          stderrDiagnostics('omni call socket dropped malformed frame');
          continue;
        }
        if (!started) {
          if (frame['type'] != 'start') {
            stderrDiagnostics('omni call socket ignored frame before start');
            continue;
          }
          started = true;
          final sessionId = frame['sessionId'];
          await callService.startCall(
            send: (event) {
              try {
                channel.sink.add(jsonEncode(event));
              } on Object {
                // 连接已断：事件丢弃，socket 收尾分支会结束通话。
              }
            },
            sessionId: sessionId is String ? sessionId : null,
          );
          continue;
        }
        await callService.handleFrontFrame(frame);
      }
    } on Object catch (error) {
      stderrDiagnostics('omni call socket error [$error]');
    } finally {
      // 前端连接断开即结束通话：无界面的连接不做无声续聊，T04 的
      // 通话条/重连表现建立在该诚实边界上。
      await callService.stopCall();
    }
  }
}
