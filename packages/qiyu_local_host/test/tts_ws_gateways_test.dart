import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

/// 连续喂文本的 WS 合成网关用例（票三）：脚本化连接器按官方示例时序
/// 回放（豆包双向 StartConnection→ConnectionStarted→StartSession→
/// SessionStarted→TaskRequest→TTSResponse→FinishSession→SessionFinished；
/// 千问 Realtime 同构），断言音频块顺序、上行帧形状、派生端点与鉴权头、
/// SSRF 建连前拒绝、取消后不再收块、中途断流与错误帧的允许列表分类，
/// 以及帧构造/解析的位域往返。只测外部可观察行为，不测内部缓冲。

const _volcConfig = TtsConfig(
  provider: TtsProviderKind.volcTts,
  baseUrl:
      'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
  model: 'seed-tts-2.0',
  apiKey: 'ark-test-key',
  transport: TtsTransport.wsBidirection,
);

const _qwenConfig = TtsConfig(
  provider: TtsProviderKind.qwenTts,
  baseUrl: 'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
  model: 'qwen3-tts-flash-realtime',
  apiKey: 'sk-dashscope-test',
);

void main() {
  group('豆包双向 WS 帧编解码', () {
    test('客户端事件帧的位域构造：4 字节头 + 大端长度 + JSON 载荷', () {
      final frame = volcTtsJsonClientFrame(
        jsonEncode({'EventType': 'StartConnection'}),
      );

      // 推断位域（ADR 0019）：version 1 + 头长 1、客户端请求类型、
      // JSON 序列化 + 无压缩、保留位 0。
      expect(frame[0], 0x11);
      expect(frame[1], 0x10);
      expect(frame[2], 0x10);
      expect(frame[3], 0x00);
      final payload = utf8.encode(jsonEncode({'EventType': 'StartConnection'}));
      expect(_readU32(frame, 4), payload.length);
      expect(
        jsonDecode(utf8.decode(frame.sublist(8))),
        {'EventType': 'StartConnection'},
      );
      expect(frame.length, 8 + payload.length);
    });

    test('服务端事件帧解析：载荷 EventType 字符串优先', () {
      final frame = _serverEventFrame({
        'EventType': 'SessionStarted',
        'SessionId': 'srv-1',
      });

      final action = parseVolcTtsServerFrame(frame);
      expect(action, isA<WsEventAction>());
      expect((action as WsEventAction).name, 'SessionStarted');
    });

    test('服务端事件帧解析：载荷缺 EventType 时回退推断的 event 号', () {
      final frame = _serverEventFrame({'SessionId': 'srv-1'}, headerEvent: 152);

      final action = parseVolcTtsServerFrame(frame) as WsEventAction;
      expect(action.name, volcTtsEventSessionFinished);
    });

    test('服务端音频帧解析：裸 PCM 字节原样取出', () {
      final frame = _serverAudioFrame([1, 2, 3, 4]);

      final action = parseVolcTtsServerFrame(frame) as WsAudioAction;
      expect(action.bytes, [1, 2, 3, 4]);
    });

    test('带序列号与 event 字段的帧按 flags 跳偏移后解析正确', () {
      final frame = _serverEventFrame({
        'EventType': 'ConnectionStarted',
      }, sequence: 7, headerEvent: 50);

      final action = parseVolcTtsServerFrame(frame) as WsEventAction;
      expect(action.name, volcTtsEventConnectionStarted);
    });

    test('错误帧按错误码映射允许列表文案，不透第三方原文', () {
      final limited = parseVolcTtsServerFrame(_serverErrorFrame(55000031))
          as WsErrorAction;
      expect(limited.failure.kind, ModelFailureKind.rateLimited);
      expect(limited.failure.message, '语音合成服务请求过于频繁。');

      final refused = parseVolcTtsServerFrame(
        _serverErrorFrame(45000001),
      ) as WsErrorAction;
      expect(refused.failure.kind, ModelFailureKind.provider);
      expect(refused.failure.message, '语音合成服务拒绝了这次请求。');
    });

    test('畸形帧按解析失败拒绝，不透出原始字节', () {
      for (final frame in <List<int>>[
        [0x11],
        [0x11, 0x90, 0x10, 0x00, 0x00, 0x00], // 载荷长度越界
        [0x11, 0x70, 0x10, 0x00, 0x00, 0x00, 0x00, 0x01, 0x41], // 未知消息类型
        [0x11, 0x90, 0x10, 0x00, 0x00, 0x00, 0x00, 0x03, 0x7B, 0x7B], // 非 JSON
        // 音频帧长度越界同样拒绝：静默截断会让半截 PCM 播成噪音。
        [0x11, 0xB0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x01, 0x02],
      ]) {
        expect(
          () => parseVolcTtsServerFrame(frame),
          throwsA(
            isA<TtsGatewayException>()
                .having((e) => e.kind, 'kind', ModelFailureKind.contentParsing)
                .having(
                  (e) => e.message,
                  'message',
                  '语音合成服务返回的内容无法解析。',
                ),
          ),
        );
      }
    });
  });

  group('豆包双向 WS 合成会话', () {
    test('官方示例时序：逐段发文本、音频按到达序转块、收尾后结束', () async {
      final connector = _ScriptedTtsWsConnector(
        onBinarySend: (frame, connection) =>
            _volcScript.respond(_decodeClientEvent(frame), connection),
      );

      final session = await VolcBidirectionTtsGateway(
        connector,
        _ExplodingBytesHttpClient(),
        ).openSession(
        config: _volcConfig,
        apiKey: 'ark-test-key',
        sessionId: 'chat-1',
      );
      expect(session, isNotNull);

      final chunks = <VoiceAudioChunk>[];
      final done = Completer<void>();
      session!.chunks.listen(
        chunks.add,
        onError: (Object error) => fail('不应失败：$error'),
        onDone: done.complete,
      );

      session.appendText('我在');
      await _settle();
      session.appendText('。刚忙完。');
      await _settle();
      await session.close();
      await done.future.timeout(const Duration(seconds: 5));

      // 每次 TaskRequest 回一段音频：块按到达序交付，采样率随块上行。
      expect(chunks.map((chunk) => chunk.bytes), [
        [1, 2],
        [3],
        [1, 2],
        [3],
      ]);
      expect(chunks.every((chunk) => chunk.sampleRate == 24000), isTrue);
    });

    test('上行帧形状：事件名、session_id、req_params 与 section_id 稳定', () async {
      final connector = _ScriptedTtsWsConnector(
        onBinarySend: (frame, connection) =>
            _volcScript.respond(_decodeClientEvent(frame), connection),
      );
      // 同一网关实例：section_id 按聊天会话的进程内映射才可观测。
      final gateway = VolcBidirectionTtsGateway(
        connector,
        _ExplodingBytesHttpClient(),
        );

      final session = await gateway.openSession(
        config: _volcConfig,
        apiKey: 'ark-test-key',
        sessionId: 'chat-1',
      );
      session!.appendText('我在');
      await _settle();
      await session.close();
      await _settle();

      final events = connector
          .connections
          .first
          .sentBinary
          .map(_decodeClientEvent);
      final byType = {
        for (final event in events) event['EventType']! as String: event,
      };
      expect(byType.keys, {
        'StartConnection',
        'StartSession',
        'TaskRequest',
        'FinishSession',
        'FinishConnection',
      });

      // StartSession：session_id 客户端生成、req_params 带音色/音频参数/
      // section_id（多轮合成上下文）。
      final startSession = byType['StartSession']!;
      final sessionId = startSession['session_id']! as String;
      expect(_uuidPattern.hasMatch(sessionId), isTrue);
      final reqParams = startSession['req_params']! as Map<String, Object?>;
      expect(reqParams['speaker'], 'zh_female_vv_uranus_bigtts');
      expect(reqParams['audio_params'], {
        'format': 'pcm',
        'sample_rate': 24000,
      });
      final sectionId = reqParams['section_id']! as String;
      expect(_uuidPattern.hasMatch(sectionId), isTrue);

      // TaskRequest：text 逐段追加，session_id 与 StartSession 一致。
      final taskRequest = byType['TaskRequest']!;
      expect(taskRequest['session_id'], sessionId);
      expect(taskRequest['text'], '我在');

      // 同一聊天会话再开一轮：section_id 保持（多轮上下文延续）；
      // 换聊天会话即新值。（每轮一条新连接，上行帧按连接累计。）
      List<Map<String, Object?>> sentEvents() => connector.connections
          .expand((connection) => connection.sentBinary)
          .map(_decodeClientEvent)
          .toList();
      final second = await gateway.openSession(
        config: _volcConfig,
        apiKey: 'ark-test-key',
        sessionId: 'chat-1',
      );
      final secondReqParams =
          (sentEvents().lastWhere(
                (event) => event['EventType'] == 'StartSession',
              ))['req_params']!
              as Map<String, Object?>;
      expect(secondReqParams['section_id'], sectionId);
      await second!.close();

      final other = await gateway.openSession(
        config: _volcConfig,
        apiKey: 'ark-test-key',
        sessionId: 'chat-2',
      );
      final otherReqParams =
          (sentEvents().lastWhere(
                (event) => event['EventType'] == 'StartSession',
              ))['req_params']!
              as Map<String, Object?>;
      expect(otherReqParams['section_id'], isNot(sectionId));
      await other!.close();
    });

    test('派生端点与鉴权头：host/port 保留，路径按协议写死', () async {
      final connector = _ScriptedTtsWsConnector(
        onBinarySend: (frame, connection) =>
            _volcScript.respond(_decodeClientEvent(frame), connection),
      );

      await VolcBidirectionTtsGateway(
        connector,
        _ExplodingBytesHttpClient(),
        ).openSession(
        config: _volcConfig,
        apiKey: 'ark-test-key',
        sessionId: 'chat-1',
      );

      expect(
        connector.lastUri.toString(),
        'wss://openspeech.bytedance.com/api/v3/tts/bidirection',
      );
      expect(connector.lastHeaders!['X-Api-Key'], 'ark-test-key');
      expect(connector.lastHeaders!['X-Api-Resource-Id'], 'seed-tts-2.0');
      expect(
        connector.lastHeaders!['X-Control-Require-Usage-Tokens-Return'],
        '*',
      );
      expect(
        _uuidPattern.hasMatch(connector.lastHeaders!['X-Api-Connect-Id']!),
        isTrue,
      );
    });

    test('派生地址保留配置端点的主机与端口', () async {
      final connector = _ScriptedTtsWsConnector(
        onBinarySend: (frame, connection) =>
            _volcScript.respond(_decodeClientEvent(frame), connection),
      );

      await VolcBidirectionTtsGateway(
        connector,
        _ExplodingBytesHttpClient(),
        ).openSession(
        config: const TtsConfig(
          provider: TtsProviderKind.volcTts,
          baseUrl: 'https://openspeech.example.com:8443/api/v3/plan/tts/unidirectional',
          model: 'seed-tts-2.0',
          apiKey: 'ark-test-key',
          transport: TtsTransport.wsBidirection,
        ),
        apiKey: 'ark-test-key',
        sessionId: 'chat-1',
      );

      expect(
        connector.lastUri.toString(),
        'wss://openspeech.example.com:8443/api/v3/tts/bidirection',
      );
    });

    test('建连前 SSRF 拒绝：环回/私有/本机地址一个都不连', () async {
      for (final baseUrl in [
        'http://localhost:8080/api/v3/plan/tts/unidirectional',
        'http://127.0.0.1/api/v3/plan/tts/unidirectional',
        'https://10.1.2.3/api/v3/plan/tts/unidirectional',
        'https://192.168.1.10/api/v3/plan/tts/unidirectional',
        'https://[::1]/api/v3/plan/tts/unidirectional',
      ]) {
        final connector = _ScriptedTtsWsConnector(
          onBinarySend: (frame, connection) =>
              _volcScript.respond(_decodeClientEvent(frame), connection),
        );
        await expectLater(
          VolcBidirectionTtsGateway(
        connector,
        _ExplodingBytesHttpClient(),
        ).openSession(
            config: TtsConfig(
              provider: TtsProviderKind.volcTts,
              baseUrl: baseUrl,
              model: 'seed-tts-2.0',
              apiKey: 'ark-test-key',
              transport: TtsTransport.wsBidirection,
            ),
            apiKey: 'ark-test-key',
            sessionId: 'chat-1',
          ),
          throwsA(
            isA<TtsGatewayException>()
                .having((e) => e.kind, 'kind', ModelFailureKind.provider)
                .having(
                  (e) => e.message,
                  'message',
                  '语音服务地址不允许指向本机或内网。',
                ),
          ),
          reason: baseUrl,
        );
        expect(connector.connectCalls, isZero, reason: baseUrl);
      }
    });

    test('非 HTTP scheme 的配置地址在出网前被配置校验拒绝', () async {
      final connector = _ScriptedTtsWsConnector(
        onBinarySend: (frame, connection) =>
            _volcScript.respond(_decodeClientEvent(frame), connection),
      );
      // 地址栏只允许 http/https（WS 地址由 Host 派生，不经过配置校验）：
      // 别的 scheme 在保存/加载的配置校验就被拒，出网路径一个字节都不发。
      await expectLater(
        VolcBidirectionTtsGateway(
        connector,
        _ExplodingBytesHttpClient(),
        ).openSession(
          config: const TtsConfig(
            provider: TtsProviderKind.volcTts,
            baseUrl: 'ftp://openspeech.bytedance.com/api/v3/tts/bidirection',
            model: 'seed-tts-2.0',
            apiKey: 'ark-test-key',
            transport: TtsTransport.wsBidirection,
          ),
          apiKey: 'ark-test-key',
          sessionId: 'chat-1',
        ),
        throwsA(
          isA<ProviderConfigException>().having(
            (e) => e.message,
            'message',
            '语音合成服务地址必须是有效的 HTTP 地址。',
          ),
        ),
      );
      expect(connector.connectCalls, isZero);
    });

    test('取消后不再收块：CancelSession 上行，迟到的音频整体丢弃', () async {
      final connector = _ScriptedTtsWsConnector(
        onBinarySend: (frame, connection) =>
            _volcScript.respond(_decodeClientEvent(frame), connection),
      );

      final session = await VolcBidirectionTtsGateway(
        connector,
        _ExplodingBytesHttpClient(),
        ).openSession(
        config: _volcConfig,
        apiKey: 'ark-test-key',
        sessionId: 'chat-1',
      );
      final chunks = <VoiceAudioChunk>[];
      final done = Completer<void>();
      session!.chunks.listen(
        chunks.add,
        onError: (Object error) => fail('取消不是失败：$error'),
        onDone: done.complete,
      );

      session.appendText('我在');
      await _settle();
      expect(chunks, hasLength(2));

      session.cancel();
      await done.future.timeout(const Duration(seconds: 5));
      // 取消后的追加不再产生请求，已收到的块也不增加。
      session.appendText('。刚忙完。');
      await _settle();
      expect(chunks, hasLength(2));
      expect(
        connector.connections
            .expand((connection) => connection.sentBinary)
            .map(_decodeClientEvent)
            .map((event) => event['EventType'])
            .contains('CancelSession'),
        isTrue,
      );
    });

    test('中途断流：没等到 SessionFinished 按音频不完整失败', () async {
      final connector = _ScriptedTtsWsConnector(
        onBinarySend: (frame, connection) =>
            _volcScript.respond(
              _decodeClientEvent(frame),
              connection,
              dropOnFinish: true,
            ),
      );

      final session = await VolcBidirectionTtsGateway(
        connector,
        _ExplodingBytesHttpClient(),
        ).openSession(
        config: _volcConfig,
        apiKey: 'ark-test-key',
        sessionId: 'chat-1',
      );
      final failure = Completer<Object>();
      session!.chunks.listen(
        (_) {},
        onError: failure.complete,
      );

      session.appendText('我在');
      await _settle();
      await session.close();

      await expectLater(
        failure.future.timeout(const Duration(seconds: 5)),
        completion(
          isA<TtsGatewayException>()
              .having((e) => e.kind, 'kind', ModelFailureKind.contentParsing)
              .having((e) => e.message, 'message', '语音合成服务返回的音频不完整。'),
        ),
      );
    });

    test('错误帧与服务端失败事件按允许列表分类', () async {
      final limited = _ScriptedTtsWsConnector(
        onBinarySend: (frame, connection) =>
            _volcScript.respond(
              _decodeClientEvent(frame),
              connection,
              errorCodeOnTask: 55000031,
            ),
      );
      final limitedSession = await VolcBidirectionTtsGateway(
        limited,
        _ExplodingBytesHttpClient(),
      ).openSession(config: _volcConfig, apiKey: 'ark-test-key', sessionId: 'c');
      final limitedFailure = Completer<Object>();
      limitedSession!.chunks.listen((_) {}, onError: limitedFailure.complete);
      limitedSession.appendText('我在');
      await expectLater(
        limitedFailure.future.timeout(const Duration(seconds: 5)),
        completion(
          isA<TtsGatewayException>().having(
            (e) => e.kind,
            'kind',
            ModelFailureKind.rateLimited,
          ),
        ),
      );

      final failed = _ScriptedTtsWsConnector(
        onBinarySend: (frame, connection) =>
            _volcScript.respond(
              _decodeClientEvent(frame),
              connection,
              failedEvent: volcTtsEventSessionFailed,
            ),
      );
      await expectLater(
        VolcBidirectionTtsGateway(
          failed,
          _ExplodingBytesHttpClient(),
        ).openSession(
          config: _volcConfig,
          apiKey: 'ark-test-key',
          sessionId: 'c',
        ),
        throwsA(
          isA<TtsGatewayException>()
              .having((e) => e.kind, 'kind', ModelFailureKind.provider)
              .having((e) => e.message, 'message', '语音合成服务拒绝了这次请求。'),
        ),
      );
    });

    test('握手超时按超时失败，连接被断开', () async {
      final connector = _ScriptedTtsWsConnector();
      await expectLater(
        VolcBidirectionTtsGateway(
        connector,
        _ExplodingBytesHttpClient(),
        timeout: const Duration(milliseconds: 50),
        ).openSession(
          config: _volcConfig,
          apiKey: 'ark-test-key',
          sessionId: 'chat-1',
        ),
        throwsA(
          isA<TtsGatewayException>()
              .having((e) => e.kind, 'kind', ModelFailureKind.timeout)
              .having((e) => e.message, 'message', '连接语音合成服务超时。'),
        ),
      );
      expect(connector.connection?.closed, isTrue);
    });

    test('缺 Key 在出网前按未保存鉴权拒绝', () async {
      final connector = _ScriptedTtsWsConnector();
      await expectLater(
        VolcBidirectionTtsGateway(
        connector,
        _ExplodingBytesHttpClient(),
        ).openSession(
          config: _volcConfig,
          apiKey: null,
          sessionId: 'chat-1',
        ),
        throwsA(
          isA<TtsGatewayException>()
              .having((e) => e.kind, 'kind', ModelFailureKind.authentication)
              .having(
                (e) => e.message,
                'message',
                '还没有保存语音合成服务的 API Key。',
              ),
        ),
      );
      expect(connector.connectCalls, isZero);
    });

    test('E1：压缩格式覆盖不开 WS 会话（分句层回落票二分句 + 句子级整段）', () async {
      final connector = _ScriptedTtsWsConnector(
        onBinarySend: (frame, connection) =>
            _volcScript.respond(_decodeClientEvent(frame), connection),
      );
      // 用户经高级参数把 format 覆盖成 mp3：音频帧不能当裸 PCM 交付。
      expect(
        await VolcBidirectionTtsGateway(
          connector,
          _ExplodingBytesHttpClient(),
        ).openSession(
          config: const TtsConfig(
            provider: TtsProviderKind.volcTts,
            baseUrl:
                'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
            model: 'seed-tts-2.0',
            apiKey: 'ark-test-key',
            transport: TtsTransport.wsBidirection,
            extraParams: {
              'audio_params': {'format': 'mp3'},
            },
          ),
          apiKey: 'ark-test-key',
          sessionId: 'chat-1',
        ),
        isNull,
      );
      expect(connector.connectCalls, isZero);
    });

    test('正常收尾后不再发取消帧（连接已断，发出去只是诊断噪音）', () async {
      final connector = _ScriptedTtsWsConnector(
        onBinarySend: (frame, connection) =>
            _volcScript.respond(_decodeClientEvent(frame), connection),
      );

      final session = await VolcBidirectionTtsGateway(
        connector,
        _ExplodingBytesHttpClient(),
      ).openSession(config: _volcConfig, apiKey: 'ark-test-key', sessionId: 'c');
      final done = Completer<void>();
      session!.chunks.listen((_) {}, onDone: done.complete);
      session.appendText('我在');
      await _settle();
      await session.close();
      await done.future.timeout(const Duration(seconds: 5));
      // 交付收尾（finally）还会 cancel 一次：已结束的会话不得再发帧。
      session.cancel();

      final sent = connector.connections
          .expand((connection) => connection.sentBinary)
          .map(_decodeClientEvent)
          .map((event) => event['EventType'])
          .toList();
      expect(sent, contains('FinishSession'));
      expect(sent, isNot(contains('CancelSession')));
    });

    test('建连失败按允许列表分类：连接/TLS/Socket/未分类', () async {
      // WebSocket 异常（连接中断）按网络失败：与豆包 ASR 网关同律——本 SDK 的 WebSocketException.httpStatusCode 恒为 null，状态码分支与 ASR 侧同款保留但不触发。
      final dropped = _ScriptedTtsWsConnector(
        connectError: const WebSocketException('connection reset'),
      );
      await expectLater(
        VolcBidirectionTtsGateway(
          dropped,
          _ExplodingBytesHttpClient(),
        ).openSession(config: _volcConfig, apiKey: 'ark-test-key', sessionId: 'c'),
        throwsA(
          isA<TtsGatewayException>()
              .having((e) => e.kind, 'kind', ModelFailureKind.network)
              .having((e) => e.message, 'message', '无法连接语音合成服务。'),
        ),
      );

      // TLS 握手失败。
      final tls = _ScriptedTtsWsConnector(
        connectError: const HandshakeException('tls broken'),
      );
      await expectLater(
        VolcBidirectionTtsGateway(
          tls,
          _ExplodingBytesHttpClient(),
        ).openSession(config: _volcConfig, apiKey: 'ark-test-key', sessionId: 'c'),
        throwsA(
          isA<TtsGatewayException>()
              .having((e) => e.kind, 'kind', ModelFailureKind.tls)
              .having((e) => e.message, 'message', '语音合成服务的 TLS 安全连接失败。'),
        ),
      );

      // Socket 失败（域名解析不了）：按 DNS 分类说话。
      final socket = _ScriptedTtsWsConnector(
        connectError: const SocketException('no route to host'),
      );
      await expectLater(
        VolcBidirectionTtsGateway(
          socket,
          _ExplodingBytesHttpClient(),
        ).openSession(config: _volcConfig, apiKey: 'ark-test-key', sessionId: 'c'),
        throwsA(
          isA<TtsGatewayException>().having(
            (e) => e.kind,
            'kind',
            anyOf(ModelFailureKind.dns, ModelFailureKind.network),
          ),
        ),
      );

      // 未分类异常：内部错误，且只打类型不打消息。
      final weird = _ScriptedTtsWsConnector(
        connectError: StateError('leaks secret upstream detail'),
      );
      await expectLater(
        VolcBidirectionTtsGateway(
          weird,
          _ExplodingBytesHttpClient(),
        ).openSession(config: _volcConfig, apiKey: 'ark-test-key', sessionId: 'c'),
        throwsA(
          isA<TtsGatewayException>()
              .having((e) => e.kind, 'kind', ModelFailureKind.internal)
              .having((e) => e.message, 'message', '本机程序内部出错。'),
        ),
      );
    });

    test('读循环空闲超时：握手后音频静默按响应超时失败', () async {
      // 脚本只回握手与首块，之后不再发帧——空闲计时器（握手完成后才
      // 武装）到点按响应超时失败。
      final connector = _ScriptedTtsWsConnector(
        onBinarySend: (frame, connection) {
          final event = _decodeClientEvent(frame);
          if (event['EventType'] == 'StartConnection') {
            connection.serverBinary(
              _serverEventFrame({'EventType': 'ConnectionStarted'}),
            );
          } else if (event['EventType'] == 'StartSession') {
            connection.serverBinary(
              _serverEventFrame({'EventType': 'SessionStarted'}),
            );
          } else if (event['EventType'] == 'TaskRequest') {
            connection.serverBinary(_serverAudioFrame([1, 2]));
          }
        },
      );

      final session = await VolcBidirectionTtsGateway(
        connector,
        _ExplodingBytesHttpClient(),
        timeout: const Duration(milliseconds: 50),
      ).openSession(config: _volcConfig, apiKey: 'ark-test-key', sessionId: 'c');
      final failure = Completer<Object>();
      session!.chunks.listen((_) {}, onError: failure.complete);
      session.appendText('我在');
      await expectLater(
        failure.future.timeout(const Duration(seconds: 5)),
        completion(
          isA<TtsGatewayException>()
              .having((e) => e.kind, 'kind', ModelFailureKind.timeout)
              .having((e) => e.message, 'message', '语音合成服务响应超时。'),
        ),
      );
    });

    test('握手阶段静默按连接超时失败（握手帧不武装空闲计时器）', () async {
      // 只回 ConnectionStarted，之后不再发帧：SessionStarted 永不来。
      // 握手等待自带预算——到点必须是「连接超时」而不是被读循环空闲
      // 计时器抢先误报成的「响应超时」。
      final connector = _ScriptedTtsWsConnector(
        onBinarySend: (frame, connection) {
          final event = _decodeClientEvent(frame);
          if (event['EventType'] == 'StartConnection') {
            connection.serverBinary(
              _serverEventFrame({'EventType': 'ConnectionStarted'}),
            );
          }
        },
      );

      await expectLater(
        VolcBidirectionTtsGateway(
          connector,
          _ExplodingBytesHttpClient(),
          timeout: const Duration(milliseconds: 50),
        ).openSession(config: _volcConfig, apiKey: 'ark-test-key', sessionId: 'c'),
        throwsA(
          isA<TtsGatewayException>()
              .having((e) => e.kind, 'kind', ModelFailureKind.timeout)
              .having((e) => e.message, 'message', '连接语音合成服务超时。'),
        ),
      );
    });

    test('整段路径（试听/重听/连接测试）：一次性会话收完整 PCM 包 WAV 头', () async {
      final connector = _ScriptedTtsWsConnector(
        onBinarySend: (frame, connection) =>
            _volcScript.respond(_decodeClientEvent(frame), connection),
      );

      final audio = await VolcBidirectionTtsGateway(
        connector,
        _ExplodingBytesHttpClient(),
      ).synthesize(
        config: _volcConfig,
        apiKey: 'ark-test-key',
        text: '你好，我是栖语。',
      );
      final wav = Uint8List.fromList(audio);

      expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
      expect(ascii.decode(wav.sublist(8, 12)), 'WAVE');
      expect(
        ByteData.sublistView(wav, 24, 28).getUint32(0, Endian.little),
        24000,
      );
      expect(wav.sublist(44), [1, 2, 3]);
    });

    test('绝对截止：持续涓流帧但永无终态事件，到点按 D1 失败', () async {
      // 服务端每 20ms 来一帧（音频/句子事件）却永不发 SessionFinished：
      // 空闲计时器被每帧重置，只有绝对截止（空闲预算 ×10）能收口——该轮
      // done 不被涓流会话无限期拖住。注入小 timeout：20ms × 10 = 200ms。
      final connector = _ScriptedTtsWsConnector(
        onBinarySend: (frame, connection) {
          final event = _decodeClientEvent(frame);
          switch (event['EventType']) {
            case 'StartConnection':
              connection.serverBinary(
                _serverEventFrame({'EventType': 'ConnectionStarted'}),
              );
            case 'StartSession':
              connection.serverBinary(
                _serverEventFrame({'EventType': 'SessionStarted'}),
              );
            case 'TaskRequest':
              // 涓流：音频帧 + 句子事件交替，永不停发。
              Timer.periodic(const Duration(milliseconds: 10), (timer) {
                if (connection.closed) {
                  timer.cancel();
                  return;
                }
                connection.serverBinary(_serverAudioFrame([1]));
                connection.serverBinary(
                  _serverEventFrame({'EventType': 'TTSSentenceStart'}),
                );
              });
          }
        },
      );

      final session = await VolcBidirectionTtsGateway(
        connector,
        _ExplodingBytesHttpClient(),
        timeout: const Duration(milliseconds: 50),
      ).openSession(config: _volcConfig, apiKey: 'ark-test-key', sessionId: 'c');
      final failure = Completer<Object>();
      session!.chunks.listen((_) {}, onError: failure.complete);
      session.appendText('我在');
      // 汇流（10ms/帧）快于空闲预算（50ms）——空闲计时器永不到点，到点的只能是绝对截止（50ms ×10 = 500ms）。
      final started = DateTime.now();
      await expectLater(
        failure.future.timeout(const Duration(seconds: 5)),
        completion(
          isA<TtsGatewayException>()
              .having((e) => e.kind, 'kind', ModelFailureKind.timeout)
              .having((e) => e.message, 'message', '语音合成服务响应超时。'),
        ),
      );
      final elapsed = DateTime.now().difference(started);
      // 到点时间落在绝对截止（500ms）附近，而非空闲预算（50ms）——锁定“空闲不能收口时绝对截止收口”。
      expect(
        elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 300)),
        reason: '空闲计时器提早收口了：$elapsed',
      );
    });
  });

  group('千问 Realtime WS 合成会话', () {
    test('流式追加文本：PCM delta 转块，session.finish 收尾', () async {
      final connector = _ScriptedTtsWsConnector(
        initialText: _qwenSessionCreated,
        onTextSend: (text, connection) =>
            _qwenScript.respond(_decodeClientTextEvent(text), connection),
      );

      final session = await QwenRealtimeTtsGateway(connector).openSession(
        config: _qwenConfig,
        apiKey: 'sk-dashscope-test',
        sessionId: 'chat-1',
      );
      expect(session, isNotNull);

      final chunks = <VoiceAudioChunk>[];
      final done = Completer<void>();
      session!.chunks.listen(
        chunks.add,
        onError: (Object error) => fail('不应失败：$error'),
        onDone: done.complete,
      );

      session.appendText('我在');
      await _settle();
      session.appendText('。刚忙完。');
      await _settle();
      await session.close();
      await done.future.timeout(const Duration(seconds: 5));

      expect(chunks.map((chunk) => chunk.bytes), [
        [1, 2],
        [3],
        [1, 2],
        [3],
      ]);
      expect(chunks.every((chunk) => chunk.sampleRate == 24000), isTrue);
    });

    test('上行事件形状与派生端点：Bearer 鉴权、model 走 query', () async {
      final connector = _ScriptedTtsWsConnector(
        initialText: _qwenSessionCreated,
        onTextSend: (text, connection) =>
            _qwenScript.respond(_decodeClientTextEvent(text), connection),
      );

      final session = await QwenRealtimeTtsGateway(connector).openSession(
        config: _qwenConfig,
        apiKey: 'sk-dashscope-test',
        sessionId: 'chat-1',
      );
      session!.appendText('我在');
      await _settle();
      await session.close();
      await _settle();

      expect(
        connector.lastUri.toString(),
        'wss://dashscope.aliyuncs.com/api-ws/v1/realtime'
        '?model=qwen3-tts-flash-realtime',
      );
      expect(connector.lastHeaders!['authorization'], 'Bearer sk-dashscope-test');

      final events = connector.connection!.sentText.map(
        _decodeClientTextEvent,
      );
      expect(events.map((event) => event['type']), [
        'session.update',
        'input_text_buffer.append',
        'session.finish',
      ]);
      // session.update：server_commit 分段 + PCM 24kHz + 音色（与 HTTP
      // 档同一缺省音色口径）。
      expect(events.first['session'], {
        'mode': 'server_commit',
        'voice': 'Cherry',
        'language_type': 'Chinese',
        'response_format': 'pcm',
        'sample_rate': 24000,
      });
      // input_text_buffer.append：增量原文逐段进，不切句。
      expect(events.elementAt(1)['text'], '我在');
    });

    test('整段路径（试听/重听）：一次性会话收完整 PCM 并包 WAV 头', () async {
      final connector = _ScriptedTtsWsConnector(
        initialText: _qwenSessionCreated,
        onTextSend: (text, connection) =>
            _qwenScript.respond(_decodeClientTextEvent(text), connection),
      );

      final audio = await QwenRealtimeTtsGateway(connector).synthesize(
        config: _qwenConfig,
        apiKey: 'sk-dashscope-test',
        text: '你好，我是栖语。',
      );
      final wav = Uint8List.fromList(audio);

      // WAV 头 + 一段 PCM（[1,2] 与 [3] 两个 delta 块）：现有整段播放器
      // 零改动。
      expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
      expect(ascii.decode(wav.sublist(8, 12)), 'WAVE');
      expect(
        ByteData.sublistView(wav, 24, 28).getUint32(0, Endian.little),
        24000,
      );
      expect(wav.sublist(44), [1, 2, 3]);
    });

    test('建连前 SSRF 拒绝与错误事件分类', () async {
      final connector = _ScriptedTtsWsConnector();
      await expectLater(
        QwenRealtimeTtsGateway(connector).openSession(
          config: const TtsConfig(
            provider: TtsProviderKind.qwenTts,
            baseUrl: 'http://127.0.0.1:1/api/v1/services/aigc/multimodal-generation/generation',
            model: 'qwen3-tts-flash-realtime',
            apiKey: 'sk-dashscope-test',
          ),
          apiKey: 'sk-dashscope-test',
          sessionId: 'chat-1',
        ),
        throwsA(
          isA<TtsGatewayException>().having(
            (e) => e.message,
            'message',
            '语音服务地址不允许指向本机或内网。',
          ),
        ),
      );
      expect(connector.connectCalls, isZero);

      final unauthorized = _ScriptedTtsWsConnector(
        initialText: _qwenSessionCreated,
        onTextSend: (text, connection) => _qwenScript.respond(
          _decodeClientTextEvent(text),
          connection,
          errorType: 'error',
          errorCode: 'invalid_api_key',
        ),
      );
      final session = await QwenRealtimeTtsGateway(unauthorized).openSession(
        config: _qwenConfig,
        apiKey: 'sk-dashscope-test',
        sessionId: 'chat-1',
      );
      final failure = Completer<Object>();
      session!.chunks.listen((_) {}, onError: failure.complete);
      session.appendText('我在');
      await expectLater(
        failure.future.timeout(const Duration(seconds: 5)),
        completion(
          isA<TtsGatewayException>()
              .having((e) => e.kind, 'kind', ModelFailureKind.authentication)
              .having(
                (e) => e.message,
                'message',
                'API Key 未通过语音合成服务验证。',
              ),
        ),
      );

      final limited = _ScriptedTtsWsConnector(
        initialText: _qwenSessionCreated,
        onTextSend: (text, connection) => _qwenScript.respond(
          _decodeClientTextEvent(text),
          connection,
          errorType: 'error',
          errorCode: 'rate_limit_exceeded',
        ),
      );
      final limitedSession = await QwenRealtimeTtsGateway(limited).openSession(
        config: _qwenConfig,
        apiKey: 'sk-dashscope-test',
        sessionId: 'chat-1',
      );
      final limitedFailure = Completer<Object>();
      limitedSession!.chunks.listen((_) {}, onError: limitedFailure.complete);
      limitedSession.appendText('我在');
      await expectLater(
        limitedFailure.future.timeout(const Duration(seconds: 5)),
        completion(
          isA<TtsGatewayException>().having(
            (e) => e.kind,
            'kind',
            ModelFailureKind.rateLimited,
          ),
        ),
      );
    });

    test('中途断流：没等到 session.finished 按音频不完整失败', () async {
      final connector = _ScriptedTtsWsConnector(
        initialText: _qwenSessionCreated,
        onTextSend: (text, connection) => _qwenScript.respond(
          _decodeClientTextEvent(text),
          connection,
          dropOnFinish: true,
        ),
      );

      final session = await QwenRealtimeTtsGateway(connector).openSession(
        config: _qwenConfig,
        apiKey: 'sk-dashscope-test',
        sessionId: 'chat-1',
      );
      final failure = Completer<Object>();
      session!.chunks.listen((_) {}, onError: failure.complete);

      session.appendText('我在');
      await _settle();
      await session.close();

      await expectLater(
        failure.future.timeout(const Duration(seconds: 5)),
        completion(
          isA<TtsGatewayException>()
              .having((e) => e.kind, 'kind', ModelFailureKind.contentParsing)
              .having((e) => e.message, 'message', '语音合成服务返回的音频不完整。'),
        ),
      );
    });

    test('握手一步超时：session.created 永不来按连接超时失败', () async {
      // 千问握手只有一步（建连后等 session.created，再发 session.update）。
      // 连接器建连成功但永不发首帧：握手等待自带预算，到点按「连接超时」
      // 失败——与豆包两级握手的同律口径一致（握手阶段不武装空闲计时器）。
      final connector = _ScriptedTtsWsConnector();

      await expectLater(
        QwenRealtimeTtsGateway(
          connector,
          timeout: const Duration(milliseconds: 50),
        ).openSession(
          config: _qwenConfig,
          apiKey: 'sk-dashscope-test',
          sessionId: 'chat-1',
        ),
        throwsA(
          isA<TtsGatewayException>()
              .having((e) => e.kind, 'kind', ModelFailureKind.timeout)
              .having((e) => e.message, 'message', '连接语音合成服务超时。'),
        ),
      );
      expect(connector.connectCalls, 1);
    });
  });

  group('连续供给会话的分派', () {
    test('豆包 ws_bidirection 与千问 realtime 型号开会话，其余不开', () async {
      final connector = _ScriptedTtsWsConnector(
        initialText: _qwenSessionCreated,
        onBinarySend: (frame, connection) =>
            _volcScript.respond(_decodeClientEvent(frame), connection),
        onTextSend: (text, connection) =>
            _qwenScript.respond(_decodeClientTextEvent(text), connection),
      );
      final gateway = TtsModelGateway(
        _ExplodingBytesHttpClient(),
        webSocketConnector: connector,
      );

      // 豆包档：传输选了 WebSocket 双向才开会话。
      expect(
        await gateway.openSession(
          config: _volcConfig,
          apiKey: 'ark-test-key',
          sessionId: 'chat-1',
        ),
        isNotNull,
      );
      // 豆包档 HTTP 分块（缺省）：不开会话，一个字节的网络请求都不发。
      expect(
        await gateway.openSession(
          config: const TtsConfig(
            provider: TtsProviderKind.volcTts,
            baseUrl:
                'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
            model: 'seed-tts-2.0',
            apiKey: 'ark-test-key',
          ),
          apiKey: 'ark-test-key',
          sessionId: 'chat-1',
        ),
        isNull,
      );

      // 千问档：型号驱动——realtime 型号开会话，其余走 HTTP SSE。
      expect(
        await gateway.openSession(
          config: _qwenConfig,
          apiKey: 'sk-dashscope-test',
          sessionId: 'chat-1',
        ),
        isNotNull,
      );
      expect(
        await gateway.openSession(
          config: const TtsConfig(
            provider: TtsProviderKind.qwenTts,
            baseUrl:
                'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
            model: 'qwen3-tts-flash',
            apiKey: 'sk-dashscope-test',
          ),
          apiKey: 'sk-dashscope-test',
          sessionId: 'chat-1',
        ),
        isNull,
      );

      // OpenAI 兼容与自定义档不开会话。
      for (final provider in [
        TtsProviderKind.openAiCompatible,
        TtsProviderKind.custom,
      ]) {
        expect(
          await gateway.openSession(
            config: TtsConfig(
              provider: provider,
              baseUrl: 'https://tts.example.com/v1',
              model: 'tts-test',
              apiKey: 'key',
            ),
            apiKey: 'key',
            sessionId: 'chat-1',
          ),
          isNull,
        );
      }
    });

    test('整段路径分派：豆包 ws 档走一次性 WS 会话，HTTP 档走 HTTP', () async {
      final connector = _ScriptedTtsWsConnector(
        onBinarySend: (frame, connection) =>
            _volcScript.respond(_decodeClientEvent(frame), connection),
      );
      final gateway = TtsModelGateway(
        _ExplodingBytesHttpClient(),
        webSocketConnector: connector,
      );

      // 传输选了 WebSocket 双向：试听/重听/连接测试也走一次性会话
      // （连接测试由此覆盖用户实际选的传输）。
      final audio = await gateway.synthesize(
        config: _volcConfig,
        apiKey: 'ark-test-key',
        text: '你好，我是栖语。',
      );
      final wav = Uint8List.fromList(audio);
      expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
      expect(wav.sublist(44), [1, 2, 3]);

      // HTTP 分块档（缺省）：整段路径照旧走 HTTP 单向端点——WS 连接子
      // 一个字节都不发。
      final httpGateway = TtsModelGateway(
        _RecordingBytesHttpClient(
          response: textResponse(
            [
              jsonEncode({'code': 0, 'data': base64Encode([7, 8])}),
              jsonEncode({'code': 20000000, 'usage': const {}}),
            ].join('\n'),
          ),
        ),
        webSocketConnector: connector,
      );
      final httpAudio = await httpGateway.synthesize(
        config: const TtsConfig(
          provider: TtsProviderKind.volcTts,
          baseUrl:
              'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
          model: 'seed-tts-2.0',
          apiKey: 'ark-test-key',
        ),
        apiKey: 'ark-test-key',
        text: '你好，我是栖语。',
      );
      expect(httpAudio.sublist(44), [7, 8]);
      expect(connector.connectCalls, 1);
    });
  });
}

/// 千问建连后服务端主动发出的首帧（官方生命周期：session.created 先于
/// 客户端的 session.update）。
const _qwenSessionCreated =
    '{"type":"session.created","event_id":"e-0",'
    '"session":{"id":"sess-1","model":"qwen3-tts-flash-realtime"}}';

/// 官方示例时序的豆包脚本：客户端事件 → 服务端帧。
final _volcScript = _VolcBidirectionScript();

final class _VolcBidirectionScript {
  void respond(
    Map<String, Object?> event,
    _ScriptedTtsWsConnection connection, {
    bool dropOnFinish = false,
    int? errorCodeOnTask,
    String? failedEvent,
  }) {
    switch (event['EventType']) {
      case 'StartConnection':
        connection.serverBinary(
          _serverEventFrame({'EventType': 'ConnectionStarted'}),
        );
      case 'StartSession':
        if (failedEvent case final name?) {
          connection.serverBinary(_serverEventFrame({'EventType': name}));
          return;
        }
        connection.serverBinary(
          _serverEventFrame({
            'EventType': 'SessionStarted',
            'SessionId': 'srv-session-1',
          }),
        );
      case 'TaskRequest':
        if (errorCodeOnTask case final code?) {
          connection.serverBinary(_serverErrorFrame(code));
          return;
        }
        connection.serverBinary(_serverAudioFrame([1, 2]));
        connection.serverBinary(_serverAudioFrame([3]));
        connection.serverBinary(
          _serverEventFrame({'EventType': 'TTSSentenceEnd'}),
        );
      case 'FinishSession':
        if (dropOnFinish) {
          connection.drop();
          return;
        }
        connection.serverBinary(
          _serverEventFrame({'EventType': 'SessionFinished'}),
        );
      case 'CancelSession':
        connection.serverBinary(
          _serverEventFrame({'EventType': 'SessionCanceled'}),
        );
    }
  }
}

/// 千问 Realtime 脚本：客户端事件 → 服务端事件。
final _qwenScript = _QwenRealtimeScript();

final class _QwenRealtimeScript {
  void respond(
    Map<String, Object?> event,
    _ScriptedTtsWsConnection connection, {
    bool dropOnFinish = false,
    String? errorType,
    String? errorCode,
  }) {
    switch (event['type']) {
      case 'session.update':
        connection.serverText(
          jsonEncode({'type': 'session.updated', 'event_id': 'e-1'}),
        );
      case 'input_text_buffer.append':
        if (errorType case final type?) {
          connection.serverText(
            jsonEncode({
              'type': type,
              'error': {'code': ?errorCode, 'message': 'upstream secret detail'},
            }),
          );
          return;
        }
        connection.serverText(
          jsonEncode({
            'type': 'response.audio.delta',
            'delta': base64Encode([1, 2]),
          }),
        );
        connection.serverText(
          jsonEncode({
            'type': 'response.audio.delta',
            'delta': base64Encode([3]),
          }),
        );
      case 'session.finish':
        if (dropOnFinish) {
          connection.drop();
          return;
        }
        connection.serverText(jsonEncode({'type': 'session.finished'}));
    }
  }
}

/// 脚本化 WS 连接器：记录上行帧并按协议脚本回放服务端帧。[initialText]
/// 是建连后服务端主动发出的首帧（千问的 session.created——豆包等客户端
/// StartConnection 之后才回，由脚本负责）。
final class _ScriptedTtsWsConnector implements ProviderWebSocketConnector {
  _ScriptedTtsWsConnector({
    this.onBinarySend,
    this.onTextSend,
    this.initialText,
    this.connectError,
  });

  /// 建连阶段抛出的异常（连接失败分类用例用）。
  final Object? connectError;

  final void Function(List<int> frame, _ScriptedTtsWsConnection connection)?
  onBinarySend;
  final void Function(String text, _ScriptedTtsWsConnection connection)?
  onTextSend;
  final String? initialText;

  int connectCalls = 0;
  Uri? lastUri;
  Map<String, String>? lastHeaders;

  /// 每次建连一条新连接（与生产同构：一个会话一条连接，section_id 跨
  /// 连接保持合成上下文）。
  final List<_ScriptedTtsWsConnection> connections = [];

  _ScriptedTtsWsConnection? get connection =>
      connections.isEmpty ? null : connections.last;

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
    final created = _ScriptedTtsWsConnection(this);
    connections.add(created);
    if (initialText case final text?) {
      created.serverText(text);
    }
    return created;
  }
}

final class _ScriptedTtsWsConnection implements ProviderWebSocketConnection {
  _ScriptedTtsWsConnection(this._connector);

  final _ScriptedTtsWsConnector _connector;
  final _binary = StreamController<List<int>>();
  final _text = StreamController<String>();
  final sentBinary = <List<int>>[];
  final sentText = <String>[];
  bool closed = false;

  @override
  Stream<List<int>> get messages => _binary.stream;

  @override
  Stream<String> get textMessages => _text.stream;

  @override
  void send(List<int> bytes) {
    sentBinary.add(bytes);
    _connector.onBinarySend?.call(bytes, this);
  }

  @override
  void sendText(String text) {
    sentText.add(text);
    _connector.onTextSend?.call(text, this);
  }

  @override
  Future<void> close() async {
    closed = true;
    _closeBoth();
  }

  void serverBinary(List<int> frame) => _binary.add(frame);

  void serverText(String text) => _text.add(text);

  /// 服务端主动断开（没有结束事件的断流）。
  Future<void> drop() async {
    _closeBoth();
  }

  /// 两个视图都未必有监听方（豆包只听二进制、千问只听文本），而单订阅
  /// 流里没有监听方的控制器 close() future 永不完成——顺序 await 会互
  /// 堵，并发发起两个关闭即可。
  void _closeBoth() {
    unawaited(_binary.close());
    unawaited(_text.close());
  }
}

/// 排空微任务：脚本帧经 StreamController 投递， listen 侧在微任务里
/// 收到；几次零延迟让读循环与测试监听都推进到稳定点。
Future<void> _settle() async {
  for (var i = 0; i < 8; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

Map<String, Object?> _decodeClientEvent(List<int> frame) {
  final length = _readU32(frame, 4);
  return jsonDecode(utf8.decode(frame.sublist(8, 8 + length)))
      as Map<String, Object?>;
}

Map<String, Object?> _decodeClientTextEvent(String text) =>
    jsonDecode(text) as Map<String, Object?>;

/// 构造一帧服务端 JSON 事件帧（位域与实现同口径，见 ADR 0019）。
Uint8List _serverEventFrame(
  Map<String, Object?> payload, {
  int? sequence,
  int? headerEvent,
}) {
  final json = utf8.encode(jsonEncode(payload));
  final flags = (sequence != null ? 0x01 : 0x00) | (headerEvent != null ? 0x04 : 0x00);
  final builder = BytesBuilder(copy: false)
    ..add([0x11, 0x90 | flags, 0x10, 0x00]);
  if (sequence != null) {
    builder.add(_u32(sequence));
  }
  if (headerEvent != null) {
    builder.add(_u32(headerEvent));
  }
  builder
    ..add(_u32(json.length))
    ..add(json);
  return builder.takeBytes();
}

Uint8List _serverAudioFrame(List<int> audio) =>
    (BytesBuilder(copy: false)
          ..add([0x11, 0xB0, 0x00, 0x00])
          ..add(_u32(audio.length))
          ..add(audio))
        .takeBytes();

Uint8List _serverErrorFrame(int code) {
  final message = utf8.encode('upstream secret detail');
  return (BytesBuilder(copy: false)
        ..add([0x11, 0xF0, 0x00, 0x00])
        ..add(_u32(code))
        ..add(_u32(message.length))
        ..add(message))
      .takeBytes();
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
final class _ExplodingBytesHttpClient implements ProviderBytesHttpClient {
  @override
  Future<ProviderBytesHttpResponse> postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) => throw StateError('WS 会话路径不得走 HTTP 出网');

  @override
  Future<ProviderBytesHttpResponse> getBytes({
    required Uri uri,
    required Duration timeout,
  }) => throw StateError('WS 会话路径不得走 HTTP 出网');
}

/// 记录型二进制 HTTP 客户端：整段 HTTP 路径用（返回脚本化逐行 JSON
/// 响应），证明 WS 档的整段路径不走 HTTP。
final class _RecordingBytesHttpClient implements ProviderBytesHttpClient {
  _RecordingBytesHttpClient({required this.response});

  final ProviderBytesHttpResponse response;
  int postCalls = 0;

  @override
  Future<ProviderBytesHttpResponse> postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) async {
    postCalls += 1;
    return response;
  }

  @override
  Future<ProviderBytesHttpResponse> getBytes({
    required Uri uri,
    required Duration timeout,
  }) => throw StateError('unused');
}

ProviderBytesHttpResponse textResponse(
  String text, {
  int statusCode = 200,
}) => ProviderBytesHttpResponse(
  statusCode: statusCode,
  body: Stream.value(utf8.encode(text)),
);
