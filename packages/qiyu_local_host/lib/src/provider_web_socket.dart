import 'dart:async';
import 'dart:io';

/// Provider 出网 WebSocket 连接的抽象接缝（豆包流式语音识别等二进制
/// 协议使用，票三起 TTS 双向/Realtime 合成也用）：二进制帧与 JSON 文本
/// 帧是同一份连接的两个视图，测试注入内存管道 fake。
abstract interface class ProviderWebSocketConnection {
  /// 服务端发来的二进制帧流：连接正常关闭时结束，异常断开时抛错。
  Stream<List<int>> get messages;

  /// 服务端发来的 JSON 文本帧流（票三 千问 Realtime 合成协议用）：
  /// 与 [messages] 同源，文本帧不进二进制流、二进制帧不进本流。
  Stream<String> get textMessages;

  /// 发送一帧二进制数据（写入底层缓冲，不等待对端确认）。
  void send(List<int> bytes);

  /// 发送一帧 JSON 文本（写入底层缓冲，不等待对端确认）。
  void sendText(String text);

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

  /// 底层订阅的唯一入口：两个帧视图都从它派生。dart:io 的 WebSocket
  /// 流是单订阅的，直接各 map 一份会互相抢订阅；转成广播流后二进制
  /// 与文本两个视图可同时监听（最后一个监听者取消时底层订阅随之取消，
  /// 与既往单订阅行为一致）。
  late final Stream<dynamic> _frames = _socket.asBroadcastStream();

  @override
  Stream<List<int>> get messages =>
      _frames.where((data) => data is List<int>).cast<List<int>>();

  @override
  Stream<String> get textMessages =>
      _frames.where((data) => data is String).cast<String>();

  @override
  void send(List<int> bytes) {
    _socket.add(bytes);
  }

  @override
  void sendText(String text) {
    _socket.add(text);
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
