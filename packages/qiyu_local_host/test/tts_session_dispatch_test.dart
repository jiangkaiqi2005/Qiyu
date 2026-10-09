import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

/// 第三张分派表（开会话）的行为对拍测试（票 08，ADR 0021）。
///
/// 连续供给会话分派（票三/票 07）此前只有服务层的脚本网关用例，真正的
/// [TtsModelGateway].openSession 路由零测试——档位归口退化后由本文件闭
/// 合缺口：三个开会话形状各用最小握手脚本端到端开起来，按派生 URI 证
/// 明落到了哪个协议通道；五个不开会话组合（豆包 HTTP 分块、豆包双向
/// E1 压缩覆盖、千问现行 multimodal、OpenAI 兼容、自定义）返回 null 且
/// 一个连接都不发。「型号驱动先于地址判定」的优先级由 realtime 配 wss
/// 地址的用例锁定。
void main() {
  group('TtsModelGateway.openSession：开会话形状端到端对拍', () {
    test('豆包档 WebSocket 双向：开真实 WS 会话，HTTP 客户端零调用', () async {
      final connector = _HandshakeWsConnector();
      final gateway = TtsModelGateway(
        _ExplodingHttpClient(),
        webSocketConnector: connector,
      );

      final session = await gateway.openSession(
        config: _volcConfig(transport: TtsTransport.wsBidirection),
        apiKey: 'ark-test-key',
        sessionId: 'chat-1',
      );

      expect(session, isNotNull);
      expect(connector.connectCalls, 1);
      // 派生地址：host/port 保留，路径按协议写死（https→wss）。
      expect(
        connector.lastUri.toString(),
        'wss://openspeech.bytedance.com/api/v3/tts/bidirection',
      );
      session!.cancel();
    });

    test('豆包档 HTTP 分块：不开会话，WS 连接子零调用', () async {
      final connector = _HandshakeWsConnector();
      final gateway = TtsModelGateway(
        _ExplodingHttpClient(),
        webSocketConnector: connector,
      );

      final session = await gateway.openSession(
        config: _volcConfig(),
        apiKey: 'ark-test-key',
        sessionId: 'chat-1',
      );

      expect(session, isNull);
      expect(connector.connectCalls, isZero);
    });

    test('豆包双向档 E1 压缩覆盖：不开会话，WS 连接子零调用（票二回落分句）',
        () async {
      final connector = _HandshakeWsConnector();
      final gateway = TtsModelGateway(
        _ExplodingHttpClient(),
        webSocketConnector: connector,
      );

      // 用户经高级参数把 format 覆盖成 mp3：音频帧不能当裸 PCM 交付，
      // 会话在分派层就不开（网关层 E1 门控上收为分派行为用例）。
      final session = await gateway.openSession(
        config: const TtsConfig(
          provider: TtsProviderKind.volcTts,
          baseUrl: volcTtsDefaultEndpoint,
          model: volcTtsDefaultResourceId,
          transport: TtsTransport.wsBidirection,
          extraParams: {
            'audio_params': {'format': 'mp3'},
          },
        ),
        apiKey: 'ark-test-key',
        sessionId: 'chat-1',
      );

      expect(session, isNull);
      expect(connector.connectCalls, isZero);
    });

    test('千问 wss 推理地址配普通型号：经典 WS 推理会话，地址原样建连',
        () async {
      final connector = _HandshakeWsConnector();
      final gateway = TtsModelGateway(
        _ExplodingHttpClient(),
        webSocketConnector: connector,
      );

      final session = await gateway.openSession(
        config: TtsConfig(
          provider: TtsProviderKind.qwenTts,
          baseUrl: qwenTtsWsInferenceEndpoint,
          model: qwenTtsDefaultModel,
        ),
        apiKey: 'sk-dashscope-test',
        sessionId: 'chat-1',
      );

      expect(session, isNotNull);
      expect(connector.connectCalls, 1);
      // 地址即用户填的完整推理端点：原样建连（票 07）。
      expect(connector.lastUri.toString(), qwenTtsWsInferenceEndpoint);
      session!.cancel();
    });

    test('千问 HTTP Maas 地址配普通型号：不开会话（票二分句模式）',
        () async {
      final connector = _HandshakeWsConnector();
      final gateway = TtsModelGateway(
        _ExplodingHttpClient(),
        webSocketConnector: connector,
      );

      final session = await gateway.openSession(
        config: const TtsConfig(
          provider: TtsProviderKind.qwenTts,
          baseUrl:
              'https://ws-12345.cn-beijing.maas.aliyuncs.com'
              '/api/v1/services/audio/tts/SpeechSynthesizer',
          model: qwenTtsDefaultModel,
        ),
        apiKey: 'sk-dashscope-test',
        sessionId: 'chat-1',
      );

      expect(session, isNull);
      expect(connector.connectCalls, isZero);
    });

    test('OpenAI 兼容与自定义档：不开会话，网络零调用（票三前夜语义）',
        () async {
      final connector = _HandshakeWsConnector();
      final gateway = TtsModelGateway(
        _ExplodingHttpClient(),
        webSocketConnector: connector,
      );

      for (final provider in [
        TtsProviderKind.openAiCompatible,
        TtsProviderKind.custom,
      ]) {
        final session = await gateway.openSession(
          config: TtsConfig(
            provider: provider,
            baseUrl: 'https://tts.example.com/v1',
            model: 'tts-test',
          ),
          apiKey: 'tts-test-key',
          sessionId: 'chat-1',
        );
        expect(session, isNull, reason: provider.wireName);
      }
      expect(connector.connectCalls, isZero);
    });
  });

  group('句级流式回落的行为对拍（退化前两张分派表的既定语义）', () {
    test('豆包 WebSocket 双向档的句级流式落 HTTP 分块（E1 回落，不走 WS）',
        () async {
      final connector = _HandshakeWsConnector();
      final client = _EmptyResponseHttpClient();
      final gateway = TtsModelGateway(
        client,
        webSocketConnector: connector,
      );

      await expectLater(
        gateway
            .synthesizeStream(
              config: _volcConfig(transport: TtsTransport.wsBidirection),
              apiKey: 'ark-test-key',
              text: '晚安。',
            )
            .toList(),
        throwsA(isA<TtsGatewayException>()),
      );
      // 流式分派表不按传输分派：句级流式走 HTTP 分块端点，WS 一个连接
      // 都不开（E1 回落语义，与退化前逐字一致）。
      expect(client.postCalls, 1);
      expect(client.lastUri.toString(), volcTtsDefaultEndpoint);
      expect(connector.connectCalls, isZero);
    });
  });
}

TtsConfig _volcConfig({TtsTransport transport = TtsTransport.httpChunk}) =>
    TtsConfig(
      provider: TtsProviderKind.volcTts,
      baseUrl: volcTtsDefaultEndpoint,
      model: volcTtsDefaultResourceId,
      transport: transport,
    );

/// 脚本化 WS 连接器（最小握手回放）：记录建连 URI 与头，按各协议回放
/// 握手事件——豆包双向对 StartConnection/StartSession 回确认事件帧，
/// 千问 Realtime 建连即回 session.created，经典推理对 run-task 回
/// task-started。openSession 握手完成即够用，不回放音频。
final class _HandshakeWsConnector implements ProviderWebSocketConnector {
  _HandshakeWsConnector();

  int connectCalls = 0;
  Uri? lastUri;
  Map<String, String>? lastHeaders;

  @override
  Future<ProviderWebSocketConnection> connect({
    required Uri uri,
    required Map<String, String> headers,
  }) async {
    connectCalls += 1;
    lastUri = uri;
    lastHeaders = headers;
    return _HandshakeConnection();
  }
}

final class _HandshakeConnection implements ProviderWebSocketConnection {
  _HandshakeConnection();

  final _binary = StreamController<List<int>>();
  final _text = StreamController<String>();

  @override
  Stream<List<int>> get messages => _binary.stream;

  @override
  Stream<String> get textMessages => _text.stream;

  @override
  void send(List<int> bytes) {
    // 豆包双向握手：StartConnection → ConnectionStarted，StartSession
    // → SessionStarted（位域帧与实现同口径，见 ADR 0019）。
    final length = _readU32(bytes, 4);
    final event =
        jsonDecode(utf8.decode(bytes.sublist(8, 8 + length)))
            as Map<String, Object?>;
    switch (event['EventType']) {
      case 'StartConnection':
        _binary.add(
          _volcEventFrame({'EventType': 'ConnectionStarted'}),
        );
      case 'StartSession':
        _binary.add(
          _volcEventFrame({
            'EventType': 'SessionStarted',
            'SessionId': 'srv-session-1',
          }),
        );
      case 'CancelSession':
        _binary.add(_volcEventFrame({'EventType': 'SessionCanceled'}));
    }
  }

  @override
  void sendText(String text) {
    // 经典 WS 推理握手：run-task → task-started。
    final event = jsonDecode(text) as Map<String, Object?>;
    final header = event['header'];
    if (header is Map && header['action'] == 'run-task') {
      _text.add(
        jsonEncode({
          'header': {
            'task_id': 't-1',
            'event': 'task-started',
            'attributes': {},
          },
          'payload': <String, Object?>{},
        }),
      );
    }
  }

  @override
  Future<void> close() async {
    unawaited(_binary.close());
    unawaited(_text.close());
  }
}

/// 构造一帧豆包服务端 JSON 事件帧（位域与实现同口径）。
Uint8List _volcEventFrame(Map<String, Object?> payload) {
  final json = utf8.encode(jsonEncode(payload));
  final builder = BytesBuilder(copy: false)
    ..add([0x11, 0x90, 0x10, 0x00])
    ..add(_u32(json.length))
    ..add(json);
  return builder.takeBytes();
}

Uint8List _u32(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);

int _readU32(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

/// WS 路径绝不碰 HTTP：被调用即失败。
final class _ExplodingHttpClient implements ProviderBytesHttpClient {
  @override
  Future<ProviderBytesHttpResponse> postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) => throw StateError('会话路径不得走 HTTP 出网');

  @override
  Future<ProviderBytesHttpResponse> getBytes({
    required Uri uri,
    required Duration timeout,
  }) => throw StateError('会话路径不得走 HTTP 出网');
}

/// 记录型 HTTP 客户端：回空 200 响应，供「句级流式落到哪个端点」的路由
/// 断言用（空音频按解析失败告终，路由事实由 POST 留档证明）。
final class _EmptyResponseHttpClient implements ProviderBytesHttpClient {
  int postCalls = 0;
  Uri? lastUri;

  @override
  Future<ProviderBytesHttpResponse> postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) async {
    postCalls += 1;
    lastUri = uri;
    return ProviderBytesHttpResponse(
      statusCode: 200,
      body: Stream.empty(),
    );
  }

  @override
  Future<ProviderBytesHttpResponse> getBytes({
    required Uri uri,
    required Duration timeout,
  }) => throw StateError('unused');
}
