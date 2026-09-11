import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  const config = SttConfig(
    provider: SttProviderKind.volcSeedAsr,
    baseUrl: 'wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream',
    model: 'volc.seedasr.sauc.duration',
  );

  Uint8List wav(int length) => Uint8List.fromList(
    List<int>.generate(length, (index) => index % 251),
  );

  test('建连头与帧序列：full request 带序号、音频分片递增、末片取负', () async {
    final connector = _FakeWebSocketConnector();
    final connection = connector.connection!;
    final gateway = VolcSeedAsrGateway(connector);

    final audio = wav(20000); // 4 片：6400×3 + 800，末片即末包。
    final future = gateway.transcribe(
      config: config,
      apiKey: ' ark-test-key ',
      audio: audio,
      mimeType: 'audio/wav',
    );
    // full request 发出后网关等服务端确认，先回 ack 再继续。
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 1);
    connection.serverSends(_responseFrame(flags: 0x91, payload: {}));
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 5);
    connection.serverSends(
      _responseFrame(flags: 0x93, payload: {'result': {'text': '今天有点累'}}),
    );
    expect(await future, '今天有点累');

    // 建连头：Key 去空格、Resource-Id 用模型名、Request-Id/Connect-Id 是
    // 同值 UUID，官方鉴权规范的固定序号头也在。
    expect(connector.lastUri.toString(), config.baseUrl);
    expect(connector.lastHeaders!['X-Api-Key'], 'ark-test-key');
    expect(connector.lastHeaders!['X-Api-Resource-Id'], 'volc.seedasr.sauc.duration');
    expect(connector.lastHeaders!['X-Api-Sequence'], '-1');
    expect(
      connector.lastHeaders!['X-Api-Connect-Id'],
      connector.lastHeaders!['X-Api-Request-Id'],
    );
    expect(
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      ).hasMatch(connector.lastHeaders!['X-Api-Request-Id']!),
      isTrue,
    );

    // ① full client request：头字节 11 11 11 00 + 大端 i32 序号 1。
    final frames = connection.sentFrames;
    expect(frames, hasLength(5));
    final fullRequest = frames[0];
    expect(fullRequest.sublist(0, 4), [0x11, 0x11, 0x11, 0x00]);
    expect(_readInt32(fullRequest, 4), 1);
    final requestJson =
        jsonDecode(utf8.decode(_payloadAt(fullRequest, 8)))
            as Map<String, Object?>;
    expect(requestJson, {
      'user': {'uid': 'qiyu'},
      'audio': {
        'format': 'wav',
        'codec': 'raw',
        'rate': 16000,
        'bits': 16,
        'channel': 1,
      },
      'request': {
        'model_name': 'bigmodel',
        'result_type': 'full',
        'enable_itn': true,
        'enable_punc': true,
        'enable_ddc': true,
        'show_utterances': true,
        'enable_nonstream': false,
      },
    });

    // ② audio only：正包头 11 21 01 00 + 递增正序号；末片 11 23 01 00 取负。
    final sequences = <int>[];
    for (final frame in frames.sublist(1)) {
      sequences.add(_readInt32(frame, 4));
    }
    expect(sequences, [2, 3, 4, -5]);
    for (final frame in frames.sublist(1, 4)) {
      expect(frame.sublist(0, 4), [0x11, 0x21, 0x01, 0x00]);
    }
    expect(frames[4].sublist(0, 4), [0x11, 0x23, 0x01, 0x00]);

    // 分片还原：全部音频帧（含末片）解压拼接等于整段原始字节。
    final rejoined = BytesBuilder(copy: false);
    for (final frame in frames.sublist(1)) {
      rejoined.add(_payloadAt(frame, 8));
    }
    expect(rejoined.takeBytes(), audio);
    expect(connection.closed, isTrue);
  });

  test('空音频只发一个负序号空末包', () async {
    final connector = _FakeWebSocketConnector();
    final connection = connector.connection!;
    final gateway = VolcSeedAsrGateway(connector);

    final future = gateway.transcribe(
      config: config,
      apiKey: 'ark-test-key',
      audio: const [],
      mimeType: 'audio/wav',
    );
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 1);
    connection.serverSends(_responseFrame(flags: 0x91, payload: {}));
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 2);
    connection.serverSends(_responseFrame(flags: 0x93, payload: {'result': {'text': ''}}));
    expect(await future, '');

    expect(connection.sentFrames, hasLength(2));
    expect(connection.sentFrames[1].sublist(0, 4), [0x11, 0x23, 0x01, 0x00]);
    expect(_readInt32(connection.sentFrames[1], 4), -2);
    expect(_payloadAt(connection.sentFrames[1], 8), isEmpty);
  });

  test('多响应 full 快照替换：累计文本只返回一次', () async {
    final connector = _FakeWebSocketConnector();
    final connection = connector.connection!;
    final gateway = VolcSeedAsrGateway(connector);

    final future = gateway.transcribe(
      config: config,
      apiKey: 'ark-test-key',
      audio: wav(100),
      mimeType: 'audio/wav',
    );
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 1);
    connection.serverSends(_responseFrame(flags: 0x91, payload: {}));
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 2);
    connection.serverSends(
      _responseFrame(flags: 0x91, sequence: 1, payload: {
        'result': {'text': '今晚'},
      }),
    );
    connection.serverSends(
      _responseFrame(flags: 0x91, sequence: 2, payload: {
        'result': {'text': '今晚有点'},
      }),
    );
    connection.serverSends(
      _responseFrame(flags: 0x93, sequence: 3, payload: {
        'result': {'text': '今晚有点累。'},
      }),
    );
    expect(await future, '今晚有点累。');
  });

  test('空中间帧不抹去快照，无结果的终止帧返回最后快照', () async {
    final connector = _FakeWebSocketConnector();
    final connection = connector.connection!;
    final future = VolcSeedAsrGateway(connector).transcribe(
      config: config, apiKey: 'ark-test-key', audio: wav(100), mimeType: 'audio/wav');
    var completed = false;
    unawaited(future.then((_) => completed = true));
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 1);
    connection.serverSends(_responseFrame(flags: 0x91, payload: {}));
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 2);
    connection.serverSends(_responseFrame(flags: 0x91, payload: {
      'result': {'text': '明天见。'},
    }));
    connection.serverSends(_responseFrame(flags: 0x91, payload: {
      'result': {'text': ''},
    }));
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    connection.serverSends(_responseFrame(flags: 0x93, payload: {}));
    expect(await future, '明天见。');
    expect(connection.closed, isTrue);
  });

  for (final finalText in ['明天见。', '再见，再见。', '']) {
    test('最终 full 快照保留修订与原有重复：$finalText', () async {
      final connector = _FakeWebSocketConnector();
      final connection = connector.connection!;
      final future = VolcSeedAsrGateway(connector).transcribe(
        config: config, apiKey: 'ark-test-key', audio: wav(100), mimeType: 'audio/wav');
      await _pumpUntil(connection, (_) => connection.sentFrames.length == 1);
      connection.serverSends(_responseFrame(flags: 0x91, payload: {}));
      await _pumpUntil(connection, (_) => connection.sentFrames.length == 2);
      connection.serverSends(_responseFrame(flags: 0x91, payload: {
        'result': {'text': '今天见。'},
      }));
      connection.serverSends(_responseFrame(flags: 0x91, payload: {
        'result': {'text': finalText},
      }));
      connection.serverSends(_responseFrame(flags: 0x93, payload: {
        'result': {'text': finalText},
      }));
      expect(await future, finalText);
    });
  }

  test('已有 full 中间文本但没有最终标志就断开仍判失败', () async {
    final connector = _FakeWebSocketConnector();
    final connection = connector.connection!;
    final future = VolcSeedAsrGateway(connector).transcribe(
      config: config, apiKey: 'ark-test-key', audio: wav(100), mimeType: 'audio/wav');
    final check = expectLater(future, throwsA(isA<SttGatewayException>()
      .having((error) => error.kind, 'kind', ModelFailureKind.network)));
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 1);
    connection.serverSends(_responseFrame(flags: 0x91, payload: {}));
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 2);
    connection.serverSends(_responseFrame(flags: 0x91, payload: {
      'result': {'text': '未完成的结果'},
    }));
    await connection.drop();
    await check;
  });

  test('result 为列表形态时逐项拼接（官方字段表与示例两种形态都兼容）', () async {
    final connector = _FakeWebSocketConnector();
    final connection = connector.connection!;
    final gateway = VolcSeedAsrGateway(connector);

    final future = gateway.transcribe(
      config: config,
      apiKey: 'ark-test-key',
      audio: wav(100),
      mimeType: 'audio/wav',
    );
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 1);
    connection.serverSends(_responseFrame(flags: 0x91, payload: {}));
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 2);
    connection.serverSends(_responseFrame(flags: 0x91, payload: {
      'result': [
        {'text': '睡吧'},
      ],
    }));
    connection.serverSends(_responseFrame(flags: 0x93, payload: {
      'result': [
        {'text': '睡吧'},
        {'text': '，明天再聊。'},
      ],
    }));
    expect(await future, '睡吧，明天再聊。');
  });

  test('响应帧带 event 字段（flags 0x04）时按动态偏移跳过', () async {
    final connector = _FakeWebSocketConnector();
    final connection = connector.connection!;
    final gateway = VolcSeedAsrGateway(connector);

    final future = gateway.transcribe(
      config: config,
      apiKey: 'ark-test-key',
      audio: wav(100),
      mimeType: 'audio/wav',
    );
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 1);
    // flags = seq(0x01) | event(0x04) | last(0x02) = 0x07。
    connection.serverSends(_responseFrame(flags: 0x07, payload: {
      'result': {'text': '带事件的最终包'},
    }));
    expect(await future, '带事件的最终包');
  });

  test('error 帧按允许列表映射：空音频语义、音频不可读、限流与其余拒绝', () async {
    // 45000002：空音频，与 OpenAI 空文本同一分支，返回空串不抛。
    expect(await _transcribeWithServerError(45000002, 'raw secret detail'), isEmpty);
    final scenarios = [
      (code: 45000001, kind: ModelFailureKind.contentParsing, message: '语音服务无法读取这段音频。'),
      (code: 45000151, kind: ModelFailureKind.contentParsing, message: '语音服务无法读取这段音频。'),
      (code: 55000031, kind: ModelFailureKind.rateLimited, message: '语音服务繁忙，请稍后再试。'),
      (code: 45000003, kind: ModelFailureKind.provider, message: '语音服务拒绝了这次请求。'),
    ];
    for (final scenario in scenarios) {
      final outcome = await _captureOutcome(
        _transcribeWithServerError(scenario.code, 'quota secret detail'),
      );
      expect(outcome, isA<SttGatewayException>(), reason: scenario.code.toString());
      final sttError = outcome as SttGatewayException;
      expect(sttError.kind, scenario.kind, reason: scenario.code.toString());
      expect(sttError.message, scenario.message, reason: scenario.code.toString());
      expect(sttError.toString(), isNot(contains('secret')));
    }
  });

  test('full request 的确认帧是 error 时直接按错误映射终止', () async {
    final connector = _FakeWebSocketConnector();
    final connection = connector.connection!;
    final gateway = VolcSeedAsrGateway(connector);

    final future = gateway.transcribe(
      config: config,
      apiKey: 'ark-test-key',
      audio: wav(100),
      mimeType: 'audio/wav',
    );
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 1);
    connection.serverSends(_errorFrame(45000151, 'format secret detail'));
    await expectLater(
      future,
      throwsA(
        isA<SttGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.contentParsing),
      ),
    );
  });

  test('响应帧解不开按解析失败处理，不透出原始字节', () async {
    final connector = _FakeWebSocketConnector();
    final connection = connector.connection!;
    final gateway = VolcSeedAsrGateway(connector);

    final future = gateway.transcribe(
      config: config,
      apiKey: 'ark-test-key',
      audio: wav(100),
      mimeType: 'audio/wav',
    );
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 1);
    connection.serverSends([0x11, 0x93, 0x11, 0x00, 0x00]);
    await expectLater(
      future,
      throwsA(
        isA<SttGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.contentParsing),
      ),
    );
  });

  test('无压缩响应帧（真机确认帧实测形态：compression=0 明文 JSON）', () async {
    final connector = _FakeWebSocketConnector();
    final connection = connector.connection!;
    final gateway = VolcSeedAsrGateway(connector);

    final future = gateway.transcribe(
      config: config,
      apiKey: 'ark-test-key',
      audio: wav(100),
      mimeType: 'audio/wav',
    );
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 1);
    // 真机抓包形态：byte2=0x10（JSON + 无压缩），payload 是明文 JSON。
    connection.serverSends(_plainResponseFrame(0x91, {
      'audio_info': {'duration': 0.0},
      'result': {'text': ''},
    }));
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 2);
    connection.serverSends(_plainResponseFrame(0x93, {
      'audio_info': {'duration': 0.06},
      'result': {'text': '静音也要能读出来'},
    }));
    expect(await future, '静音也要能读出来');
  });

  test('连接失败按 SocketException 消息分 dns/network，TLS 单独分类', () async {
    final scenarios = [
      (
        error: const SocketException(
          'Failed host lookup',
          osError: OSError('host not found', 11001),
        ),
        kind: ModelFailureKind.dns,
        message: '找不到语音服务域名。',
      ),
      (
        error: const SocketException('offline'),
        kind: ModelFailureKind.network,
        message: '无法连接语音服务。',
      ),
      (
        error: HandshakeException('bad tls'),
        kind: ModelFailureKind.tls,
        message: '语音服务的 TLS 安全连接失败。',
      ),
    ];
    for (final scenario in scenarios) {
      final connector = _FakeWebSocketConnector(connectError: scenario.error);
      await expectLater(
        VolcSeedAsrGateway(connector).transcribe(
          config: config,
          apiKey: 'ark-test-key',
          audio: wav(10),
          mimeType: 'audio/wav',
        ),
        throwsA(
          isA<SttGatewayException>()
              .having((error) => error.kind, 'kind', scenario.kind)
              .having((error) => error.message, 'message', scenario.message),
        ),
        reason: scenario.kind.name,
      );
    }
  });

  test('总超时（含建连与确认等待）沿用 sttRequestTimeout 语义并归为 timeout', () async {
    final connector = _HangingWebSocketConnector();
    final gateway = VolcSeedAsrGateway(
      connector,
      timeout: const Duration(milliseconds: 30),
    );

    await expectLater(
      gateway.transcribe(
        config: config,
        apiKey: 'ark-test-key',
        audio: wav(10),
        mimeType: 'audio/wav',
      ),
      throwsA(
        isA<SttGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.timeout)
            .having((error) => error.message, 'message', '连接语音服务超时。'),
      ),
    );
  });

  test('服务端不发确认帧直接断开按网络中断处理', () async {
    final connector = _FakeWebSocketConnector();
    final connection = connector.connection!;
    final gateway = VolcSeedAsrGateway(connector);

    final future = gateway.transcribe(
      config: config,
      apiKey: 'ark-test-key',
      audio: wav(100),
      mimeType: 'audio/wav',
    );
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 1);
    await connection.drop();
    await expectLater(
      future,
      throwsA(
        isA<SttGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.network)
            .having((error) => error.message, 'message', '语音服务连接中断。'),
      ),
    );
  });

  test('SSRF 拒绝：内网与保留地址在出网前抛错，连接器未被调用', () async {
    final targets = [
      'ws://localhost:9000/api',
      'wss://127.0.0.1/api',
      'wss://127.0.0.10/api',
      'wss://10.0.0.1/api',
      'wss://172.16.0.1/api',
      'wss://172.31.255.255/api',
      'wss://192.168.1.5/api',
      'wss://169.254.169.254/api',
      'wss://0.0.0.0/api',
      'wss://100.64.0.1/api',
      'wss://[::1]/api',
      'wss://[fe80::1]/api',
      'wss://[fc00::1]/api',
      'wss://[::ffff:127.0.0.1]/api',
    ];
    for (final baseUrl in targets) {
      final connector = _FakeWebSocketConnector();
      await expectLater(
        VolcSeedAsrGateway(connector).transcribe(
          config: SttConfig(
            provider: SttProviderKind.volcSeedAsr,
            baseUrl: baseUrl,
            model: 'volc.seedasr.sauc.duration',
          ),
          apiKey: 'ark-test-key',
          audio: wav(10),
          mimeType: 'audio/wav',
        ),
        throwsA(
          isA<SttGatewayException>()
              .having((error) => error.kind, 'kind', ModelFailureKind.provider)
              .having(
                (error) => error.message,
                'message',
                '语音服务地址不允许指向本机或内网。',
              ),
        ),
        reason: baseUrl,
      );
      expect(connector.connectCalls, 0, reason: baseUrl);
    }
  });

  test('缺 Key 按鉴权失败拒绝，不出网', () async {
    final connector = _FakeWebSocketConnector();
    await expectLater(
      VolcSeedAsrGateway(connector).transcribe(
        config: config,
        apiKey: '  ',
        audio: wav(10),
        mimeType: 'audio/wav',
      ),
      throwsA(
        isA<SttGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.authentication),
      ),
    );
    expect(connector.connectCalls, 0);
  });

  test('Key 带零宽空格按粘贴事故拒绝，不出网', () async {
    final connector = _FakeWebSocketConnector();
    await expectLater(
      VolcSeedAsrGateway(connector).transcribe(
        config: config,
        apiKey: 'ark-test-key\u200B',
        audio: wav(10),
        mimeType: 'audio/wav',
      ),
      throwsA(
        isA<SttGatewayException>()
            .having((error) => error.kind, 'kind', ModelFailureKind.provider)
            .having(
              (error) => error.message,
              'message',
              'API Key 里混入了中文或看不见的字符，请重新复制粘贴。',
            ),
      ),
    );
    expect(connector.connectCalls, 0);
  });
}

/// 等待 [connection] 的发送侧出现满足条件的帧（fake 侧同步分发）。
Future<void> _pumpUntil(
  _FakeWebSocketConnection connection,
  bool Function(_FakeWebSocketConnection) condition,
) async {
  while (!condition(connection)) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 把转写结果或异常都收成值，便于逐场景断言映射。
Future<Object?> _captureOutcome(Future<String?> future) async {
  try {
    return await future;
  } on Object catch (error) {
    return error;
  }
}

Future<String?> _transcribeWithServerError(int code, String message) {
  final connector = _FakeWebSocketConnector();
  final connection = connector.connection!;
  final gateway = VolcSeedAsrGateway(connector);
  final future = gateway.transcribe(
    config: const SttConfig(
      provider: SttProviderKind.volcSeedAsr,
      baseUrl: 'wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream',
      model: 'volc.seedasr.sauc.duration',
    ),
    apiKey: 'ark-test-key',
    audio: Uint8List.fromList(List<int>.generate(100, (index) => index)),
    mimeType: 'audio/wav',
  );
  return (() async {
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 1);
    connection.serverSends(_responseFrame(flags: 0x91, payload: {}));
    await _pumpUntil(connection, (_) => connection.sentFrames.length == 2);
    connection.serverSends(_errorFrame(code, message));
    return future;
  })();
}

/// 服务端响应帧：头 + 大端 u32 sequence +（flags 声明 event 时）大端
/// u32 event + 大端 u32 payload 长度 + gzip(JSON)，与网关动态偏移对齐。
Uint8List _responseFrame({
  required int flags,
  int sequence = 0,
  required Map<String, Object?> payload,
}) => _buildResponseFrame(
      flags,
      sequence,
      0x11, // serialization JSON + compression gzip
      gzip.encode(utf8.encode(jsonEncode(payload))),
    );

/// 无压缩响应帧（真机确认帧实测形态）：payload 是明文 JSON。
Uint8List _plainResponseFrame(int flags, Map<String, Object?> payload) =>
    _buildResponseFrame(
      flags,
      1,
      0x10, // serialization JSON + 无压缩
      utf8.encode(jsonEncode(payload)),
    );

Uint8List _buildResponseFrame(
  int flags,
  int sequence,
  int serializationCompression,
  List<int> encoded,
) {
  final builder = BytesBuilder(copy: false)
    ..add([0x11, 0x90 | flags, serializationCompression, 0x00])
    ..add(_u32(sequence));
  if (flags & 0x04 != 0) {
    builder.add(_u32(1));
  }
  builder
    ..add(_u32(encoded.length))
    ..add(encoded);
  return builder.takeBytes();
}

/// 服务端 error 帧：头 + 大端 u32 code + 大端 u32 消息长度 + UTF-8 消息。
Uint8List _errorFrame(int code, String message) {
  final bytes = utf8.encode(message);
  return (BytesBuilder(copy: false)
        ..add([0x11, 0xF0, 0x11, 0x00])
        ..add(_u32(code))
        ..add(_u32(bytes.length))
        ..add(bytes))
      .takeBytes();
}

Uint8List _u32(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);

int _readInt32(List<int> bytes, int offset) {
  final raw =
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
  return raw >= 0x80000000 ? raw - 0x100000000 : raw;
}

/// 解压带序列号帧（头 + i32 seq + u32 长度 + payload）在 [offset] 处的
/// gzip payload。
List<int> _payloadAt(List<int> frame, int offset) {
  final length =
      (frame[offset] << 24) |
      (frame[offset + 1] << 16) |
      (frame[offset + 2] << 8) |
      frame[offset + 3];
  expect(frame.length, offset + 4 + length);
  return gzip.decode(frame.sublist(offset + 4));
}

final class _FakeWebSocketConnector implements ProviderWebSocketConnector {
  _FakeWebSocketConnector({this.connectError});

  final Object? connectError;
  int connectCalls = 0;
  Uri? lastUri;
  Map<String, String>? lastHeaders;
  _FakeWebSocketConnection? _connection;

  _FakeWebSocketConnection? get connection {
    _connection ??= _FakeWebSocketConnection();
    return _connection;
  }

  @override
  Future<ProviderWebSocketConnection> connect({
    required Uri uri,
    required Map<String, String> headers,
  }) async {
    connectCalls += 1;
    if (connectError case final error?) {
      throw error;
    }
    lastUri = uri;
    lastHeaders = headers;
    return connection!;
  }
}

final class _FakeWebSocketConnection implements ProviderWebSocketConnection {
  final _incoming = StreamController<List<int>>();
  final sentFrames = <List<int>>[];
  bool closed = false;

  @override
  Stream<List<int>> get messages => _incoming.stream;

  @override
  void send(List<int> bytes) {
    sentFrames.add(bytes);
  }

  @override
  Future<void> close() async {
    closed = true;
    await _incoming.close();
  }

  /// 服务端主动断开（不经过 close 的正常关闭路径）。
  Future<void> drop() async {
    await _incoming.close();
  }

  void serverSends(List<int> frame) {
    _incoming.add(frame);
  }
}

final class _HangingWebSocketConnector implements ProviderWebSocketConnector {
  @override
  Future<ProviderWebSocketConnection> connect({
    required Uri uri,
    required Map<String, String> headers,
  }) =>
      Completer<ProviderWebSocketConnection>().future;
}
