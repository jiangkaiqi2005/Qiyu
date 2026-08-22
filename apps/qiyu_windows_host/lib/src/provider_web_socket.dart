import 'dart:async';
import 'dart:io';

/// Provider 出网 WebSocket 连接的抽象接缝（豆包流式语音识别等二进制
/// 协议使用）：只暴露二进制收/发与关闭，测试注入内存管道 fake。
abstract interface class ProviderWebSocketConnection {
  /// 服务端发来的二进制帧流：连接正常关闭时结束，异常断开时抛错。
  Stream<List<int>> get messages;

  /// 发送一帧二进制数据（写入底层缓冲，不等待对端确认）。
  void send(List<int> bytes);

  /// 主动关闭连接；重复调用安全。
  Future<void> close();
}

/// WebSocket 建连接口：连接失败、TLS 握手失败的异常原样抛出，由网关
/// 统一分类（与 HTTP 出网同律）。
abstract interface class ProviderWebSocketConnector {
  Future<ProviderWebSocketConnection> connect({
    required Uri uri,
    required Map<String, String> headers,
  });
}

final class DartIoProviderWebSocketConnector
    implements ProviderWebSocketConnector {
  const DartIoProviderWebSocketConnector();

  @override
  Future<ProviderWebSocketConnection> connect({
    required Uri uri,
    required Map<String, String> headers,
  }) async {
    final socket = await WebSocket.connect(
      uri.toString(),
      headers: headers,
    );
    return _DartIoProviderWebSocketConnection(socket);
  }
}

final class _DartIoProviderWebSocketConnection
    implements ProviderWebSocketConnection {
  _DartIoProviderWebSocketConnection(this._socket);

  final WebSocket _socket;
  bool _closed = false;

  @override
  Stream<List<int>> get messages =>
      _socket.map((dynamic data) => data as List<int>);

  @override
  void send(List<int> bytes) {
    _socket.add(bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _socket.close();
  }
}
