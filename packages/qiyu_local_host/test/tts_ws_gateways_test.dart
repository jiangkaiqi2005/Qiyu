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

  group('千问 WS 推理（经典 SpeechSynthesizer）合成会话', () {
    const inferenceConfig = TtsConfig(
      provider: TtsProviderKind.qwenTts,
      baseUrl: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
      model: 'qwen-audio-3.0-tts-flash',
      apiKey: 'sk-dashscope-test',
    );

    /// 探针基线形状的脚本（probe 02/03）：run-task → task-started；
    /// continue-task → WAV binary 帧 + result-generated 文本帧；
    /// finish-task → WAV binary 帧 + task-finished。变体经参数注入。
    _ScriptedTtsWsConnector inferenceConnector({
      bool extendedFrame = false,
      bool rawPcmFrames = false,
      String? failedEventOnContinue,
      String? errorCodeOnRun,
    }) => _ScriptedTtsWsConnector(
      onTextSend: (text, connection) {
        final event = jsonDecode(text) as Map<String, Object?>;
        final action = (event['header']! as Map)['action']! as String;
        switch (action) {
          case 'run-task':
            if (errorCodeOnRun case final code?) {
              connection.serverText(
                jsonEncode({
                  'header': {
                    'task_id': 't-1',
                    'event': 'task-failed',
                    'error_code': code,
                    'error_message': 'upstream secret detail',
                  },
                  'payload': {},
                }),
              );
              return;
            }
            connection.serverText(
              jsonEncode({
                'header': {'task_id': 't-1', 'event': 'task-started'},
                'payload': {},
              }),
            );
          case 'continue-task':
            if (failedEventOnContinue case final name?) {
              connection.serverText(
                jsonEncode({
                  'header': {
                    'task_id': 't-1',
                    'event': name,
                    'error_code': 'InvalidParameter',
                    'error_message':
                        '[cosyvoice:]Engine error [411]: TTS speak operation failed',
                  },
                  'payload': {},
                }),
              );
              return;
            }
            // rawPcmFrames：format=pcm 覆盖时服务端回裸样本帧（无 RIFF 头）。
            connection.serverBinary(
              rawPcmFrames ? Uint8List.fromList([1, 2]) : _inferenceWavFrame([1, 2]),
            );
            connection.serverText(
              jsonEncode({
                'header': {'task_id': 't-1', 'event': 'result-generated'},
                'payload': {
                  'output': {
                    'sentence': {
                      'index': 0,
                      'type': 'sentence-begin',
                      'original_text': '晚安',
                    },
                  },
                },
              }),
            );
          case 'finish-task':
            connection.serverBinary(
              rawPcmFrames
                  ? Uint8List.fromList([3])
                  : _inferenceWavFrame([3], extended: extendedFrame),
            );
            connection.serverText(
              jsonEncode({
                'header': {'task_id': 't-1', 'event': 'task-finished'},
                'payload': {'output': {}},
              }),
            );
        }
      },
    );

    test('全生命周期：上行帧逐字段、binary WAV 帧剥头转块、task-finished 收束', () async {
      final connector = inferenceConnector();
      final session = await QwenWsInferenceTtsGateway(connector).openSession(
        config: inferenceConfig,
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

      // binary 帧是自带 WAV 头的完整文件（probe 02 基线）：块只留裸
      // PCM；每次 continue-task 后各到一帧，finish-task 后一帧收尾。
      expect(chunks.map((chunk) => chunk.bytes), [
        [1, 2],
        [1, 2],
        [3],
      ]);
      expect(chunks.every((chunk) => chunk.sampleRate == 24000), isTrue);
      // result-generated 文本帧只登记不参与判定：流程照常走到收尾。

      // 端点与鉴权：地址原样使用，Bearer 握手头。
      expect(
        connector.lastUri.toString(),
        'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
      );
      expect(
        connector.lastHeaders!['authorization'],
        'Bearer sk-dashscope-test',
      );

      // 上行文本帧逐字段：动作序列、固定 task_group/task/function、
      // streaming=duplex、同一任务共用同一 task_id。
      final events = connector.connection!.sentText
          .map((text) => jsonDecode(text) as Map<String, Object?>)
          .toList();
      expect(
        events.map((event) => (event['header']! as Map)['action']),
        ['run-task', 'continue-task', 'continue-task', 'finish-task'],
      );
      final runTask = events.first;
      final runTaskHeader = runTask['header']! as Map<String, Object?>;
      expect(runTaskHeader['streaming'], 'duplex');
      expect(
        _uuidPattern.hasMatch(runTaskHeader['task_id']! as String),
        isTrue,
      );
      expect(
        events.map((event) => (event['header']! as Map)['task_id']),
        everyElement(runTaskHeader['task_id']),
      );
      expect(runTask['payload'], {
        'task_group': 'audio',
        'task': 'tts',
        'function': 'SpeechSynthesizer',
        'model': 'qwen-audio-3.0-tts-flash',
        // 音色空缺回落本家族官方示例音色；format/sample_rate 缺省
        // wav/24000（与 maas 形状同律）。
        'parameters': {
          'text_type': 'PlainText',
          'voice': 'longanhuan_v3.6',
          'format': 'wav',
          'sample_rate': 24000,
        },
        'input': <String, Object?>{},
      });
      // 增量原文逐段进 continue-task 的 payload.input.text。
      expect((events[1]['payload']! as Map)['input'], {'text': '我在'});
      expect((events[2]['payload']! as Map)['input'], {'text': '。刚忙完。'});
      // finish-task 的 payload.input 为空对象（probe 0 文档形状）。
      expect((events[3]['payload']! as Map)['input'], <String, Object?>{});
    });

    test('显式音色原样上送；extraParams 深合并进 parameters 并覆盖缺省', () async {
      final connector = inferenceConnector();
      final session = await QwenWsInferenceTtsGateway(connector).openSession(
        config: const TtsConfig(
          provider: TtsProviderKind.qwenTts,
          baseUrl: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
          model: 'qwen-audio-3.0-tts-flash',
          apiKey: 'sk-dashscope-test',
          voice: 'longanlingxi',
          extraParams: {'volume': 50, 'sample_rate': 16000},
        ),
        apiKey: 'sk-dashscope-test',
        sessionId: 'chat-1',
      );
      final chunks = <VoiceAudioChunk>[];
      final done = Completer<void>();
      session!.chunks.listen(chunks.add, onDone: done.complete);
      session.appendText('嗯。');
      await session.close();
      await done.future.timeout(const Duration(seconds: 5));

      final runTask =
          jsonDecode(connector.connection!.sentText.first)
              as Map<String, Object?>;
      expect((runTask['payload']! as Map)['parameters'], {
        'text_type': 'PlainText',
        'voice': 'longanlingxi',
        'format': 'wav',
        'sample_rate': 16000,
        'volume': 50,
      });
      // 协商采样率随覆盖后的参数标注在块上（请求送的就是它）。
      expect(chunks.every((chunk) => chunk.sampleRate == 16000), isTrue);
    });

    test('带 LIST 扩展块的 WAV 帧按块遍历剥头（不按固定 44 字节）', () async {
      final connector = inferenceConnector(extendedFrame: true);
      final session = await QwenWsInferenceTtsGateway(connector).openSession(
        config: inferenceConfig,
        apiKey: 'sk-dashscope-test',
        sessionId: 'chat-1',
      );
      final chunks = <VoiceAudioChunk>[];
      final done = Completer<void>();
      session!.chunks.listen(chunks.add, onDone: done.complete);
      session.appendText('嗯。');
      await session.close();
      await done.future.timeout(const Duration(seconds: 5));
      // continue 帧是标准 44 字节头，finish 帧带 LIST 扩展块：都剥成裸 PCM。
      expect(chunks.map((chunk) => chunk.bytes), [
        [1, 2],
        [3],
      ]);
    });

    test('整段路径（试听/重听/连接测试）：一次性会话收完整 PCM 并包 WAV 头', () async {
      final connector = inferenceConnector();
      final audio = await QwenWsInferenceTtsGateway(connector).synthesize(
        config: inferenceConfig,
        apiKey: 'sk-dashscope-test',
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
      // 同一任务：run-task 一次，continue + finish 各一次。
      final actions = connector.connection!.sentText
          .map(
            (text) =>
                (jsonDecode(text) as Map<String, Object?>)['header'] as Map,
          )
          .map((header) => header['action']);
      expect(actions, ['run-task', 'continue-task', 'finish-task']);
    });

    test('按句流式：一次会话内 binary 帧边到边转块，不等整句合成完', () async {
      final connector = inferenceConnector();
      final chunks = <VoiceAudioChunk>[];
      await QwenWsInferenceTtsGateway(
        connector,
      ).synthesizeStream(
        config: inferenceConfig,
        apiKey: 'sk-dashscope-test',
        text: '晚安。',
      ).forEach(chunks.add);
      expect(chunks.map((chunk) => chunk.bytes), [
        [1, 2],
        [3],
      ]);
      expect(chunks.every((chunk) => chunk.sampleRate == 24000), isTrue);
    });

    test('task-failed 各映射：ModelNotFound／鉴权／限流／其余按服务拒绝', () async {
      // ModelNotFound（probe 1.1 实测形状）：握手期即失败，按既有
      // 「找不到模型」分类，第三方错误原文不透出。
      await expectLater(
        QwenWsInferenceTtsGateway(
          inferenceConnector(errorCodeOnRun: 'ModelNotFound'),
        ).openSession(
          config: inferenceConfig,
          apiKey: 'sk-dashscope-test',
          sessionId: 'c',
        ),
        throwsA(
          isA<TtsGatewayException>()
              .having((e) => e.kind, 'kind', ModelFailureKind.modelNotFound)
              .having(
                (e) => e.message,
                'message',
                '找不到这个模型，请检查模型名称。',
              ),
        ),
      );

      // 鉴权指纹按既有口径说话。
      await expectLater(
        QwenWsInferenceTtsGateway(
          inferenceConnector(errorCodeOnRun: 'InvalidAuthorization'),
        ).openSession(
          config: inferenceConfig,
          apiKey: 'sk-dashscope-test',
          sessionId: 'c',
        ),
        throwsA(
          isA<TtsGatewayException>().having(
            (e) => e.kind,
            'kind',
            ModelFailureKind.authentication,
          ),
        ),
      );

      // 限流指纹同律。
      await expectLater(
        QwenWsInferenceTtsGateway(
          inferenceConnector(errorCodeOnRun: 'Throttling'),
        ).openSession(
          config: inferenceConfig,
          apiKey: 'sk-dashscope-test',
          sessionId: 'c',
        ),
        throwsA(
          isA<TtsGatewayException>().having(
            (e) => e.kind,
            'kind',
            ModelFailureKind.rateLimited,
          ),
        ),
      );

      // 其余错误码（3.1 引擎 411 的 InvalidParameter 指纹，probe 02/03）
      // 按服务拒绝说话：错误发生在握手后的会话中途，经块流上报。
      final connector = inferenceConnector(
        failedEventOnContinue: 'task-failed',
      );
      final session = await QwenWsInferenceTtsGateway(connector).openSession(
        config: inferenceConfig,
        apiKey: 'sk-dashscope-test',
        sessionId: 'c',
      );
      final failure = Completer<Object>();
      session!.chunks.listen((_) {}, onError: failure.complete);
      session.appendText('嗯。');
      await expectLater(
        failure.future.timeout(const Duration(seconds: 5)),
        completion(
          isA<TtsGatewayException>()
              .having((e) => e.kind, 'kind', ModelFailureKind.provider)
              .having(
                (e) => e.message,
                'message',
                '语音合成服务拒绝了这次请求。',
              ),
        ),
      );
    });

    test('E1：高级参数覆盖 format=mp3 按人话拒绝，连接子零调用', () async {
      // 压缩帧既不能当 PCM 流式播（噪音）也不能包出有效 WAV：本通道没有
      // HTTP 回落（地址即 WS 端点），出网前按人话拒绝（票 07 评审收口）。
      for (final format in ['mp3', 'opus']) {
        final connector = inferenceConnector();
        await expectLater(
          QwenWsInferenceTtsGateway(connector).openSession(
            config: TtsConfig(
              provider: TtsProviderKind.qwenTts,
              baseUrl: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
              model: 'qwen-audio-3.0-tts-flash',
              apiKey: 'sk-dashscope-test',
              extraParams: {'format': format},
            ),
            apiKey: 'sk-dashscope-test',
            sessionId: 'c',
          ),
          throwsA(
            isA<TtsGatewayException>()
                .having((e) => e.kind, 'kind', ModelFailureKind.provider)
                .having(
                  (e) => e.message,
                  'message',
                  '高级参数把音频格式覆盖成了压缩格式，本通道只支持 wav 或 '
                      'pcm，请改回后再试。',
                ),
          ),
          reason: format,
        );
        expect(connector.connectCalls, isZero, reason: format);
      }
    });

    test('高级参数覆盖 format=pcm：binary 裸帧不以 RIFF 开头原样透传', () async {
      final connector = inferenceConnector(rawPcmFrames: true);
      final session = await QwenWsInferenceTtsGateway(connector).openSession(
        config: const TtsConfig(
          provider: TtsProviderKind.qwenTts,
          baseUrl: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
          model: 'qwen-audio-3.0-tts-flash',
          apiKey: 'sk-dashscope-test',
          extraParams: {'format': 'pcm'},
        ),
        apiKey: 'sk-dashscope-test',
        sessionId: 'chat-1',
      );
      final chunks = <VoiceAudioChunk>[];
      final done = Completer<void>();
      session!.chunks.listen(chunks.add, onDone: done.complete);
      session.appendText('嗯。');
      await session.close();
      await done.future.timeout(const Duration(seconds: 5));
      // 裸样本帧原样通过（与 SSE 路径同一语义），协商采样率照常标注。
      expect(chunks.map((chunk) => chunk.bytes), [
        [1, 2],
        [3],
      ]);
      expect(chunks.every((chunk) => chunk.sampleRate == 24000), isTrue);
    });

    test('取消按协议发 finish-task 的 cancel 指令，迟到帧丢弃', () async {
      final connector = inferenceConnector();
      final session = await QwenWsInferenceTtsGateway(connector).openSession(
        config: inferenceConfig,
        apiKey: 'sk-dashscope-test',
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
      expect(chunks, hasLength(1));

      session.cancel();
      await done.future.timeout(const Duration(seconds: 5));
      // 取消后追加不再产生请求；取消帧是 finish-task 带 cancel 指令。
      session.appendText('。刚忙完。');
      await _settle();
      expect(chunks, hasLength(1));
      final events = connector.connection!.sentText
          .map((text) => jsonDecode(text) as Map<String, Object?>)
          .toList();
      final cancelFrame = events
          .where(
            (event) =>
                ((event['header']! as Map)['action'] as String) ==
                'finish-task',
          )
          .last;
      expect((cancelFrame['payload']! as Map)['input'], {
        'directive': 'cancel',
      });
    });

    test('地址缺路径时补默认推理路径，host/port 保留', () async {
      final connector = inferenceConnector();
      await QwenWsInferenceTtsGateway(connector).openSession(
        config: const TtsConfig(
          provider: TtsProviderKind.qwenTts,
          baseUrl: 'wss://tts-gateway.example.com:8443',
          model: 'qwen-audio-3.0-tts-flash',
          apiKey: 'sk-dashscope-test',
        ),
        apiKey: 'sk-dashscope-test',
        sessionId: 'c',
      );
      expect(
        connector.lastUri.toString(),
        'wss://tts-gateway.example.com:8443/api-ws/v1/inference',
      );
    });

    test('建连前 SSRF 拒绝：环回/私有地址一个都不连', () async {
      for (final baseUrl in [
        'wss://127.0.0.1/api-ws/v1/inference',
        'ws://localhost:8080/api-ws/v1/inference',
        'wss://192.168.1.10/api-ws/v1/inference',
      ]) {
        final connector = inferenceConnector();
        await expectLater(
          QwenWsInferenceTtsGateway(connector).openSession(
            config: TtsConfig(
              provider: TtsProviderKind.qwenTts,
              baseUrl: baseUrl,
              model: 'qwen-audio-3.0-tts-flash',
              apiKey: 'sk-dashscope-test',
            ),
            apiKey: 'sk-dashscope-test',
            sessionId: 'c',
          ),
          throwsA(
            isA<TtsGatewayException>().having(
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

    test('非 http(s)/ws(s) scheme 在配置校验就被拒，出网前一个字节不发', () async {
      final connector = inferenceConnector();
      await expectLater(
        QwenWsInferenceTtsGateway(connector).openSession(
          config: const TtsConfig(
            provider: TtsProviderKind.qwenTts,
            baseUrl: 'ftp://dashscope.aliyuncs.com/api-ws/v1/inference',
            model: 'qwen-audio-3.0-tts-flash',
            apiKey: 'sk-dashscope-test',
          ),
          apiKey: 'sk-dashscope-test',
          sessionId: 'c',
        ),
        throwsA(
          isA<ProviderConfigException>().having(
            (e) => e.message,
            'message',
            '语音合成服务地址必须是有效的 HTTP 或 WebSocket 地址。',
          ),
        ),
      );
      expect(connector.connectCalls, isZero);
    });

    test('缺 Key 在出网前按未保存鉴权拒绝', () async {
      final connector = inferenceConnector();
      await expectLater(
        QwenWsInferenceTtsGateway(connector).openSession(
          config: inferenceConfig,
          apiKey: null,
          sessionId: 'c',
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

    test('握手超时：task-started 永不来按连接超时失败，连接被断开', () async {
      // 脚本对 run-task 不作回应：握手等待自带预算，到点按「连接超时」
      // 失败（握手阶段不武装空闲计时器，与豆包/Realtime 同律）。
      final connector = _ScriptedTtsWsConnector();
      await expectLater(
        QwenWsInferenceTtsGateway(
          connector,
          timeout: const Duration(milliseconds: 50),
        ).openSession(
          config: inferenceConfig,
          apiKey: 'sk-dashscope-test',
          sessionId: 'c',
        ),
        throwsA(
          isA<TtsGatewayException>()
              .having((e) => e.kind, 'kind', ModelFailureKind.timeout)
              .having((e) => e.message, 'message', '连接语音合成服务超时。'),
        ),
      );
      expect(connector.connection?.closed, isTrue);
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

  group('千问朗读档地址派形状的四分支分派（票 07）', () {
    // 分派优先级：① 型号驱动（-realtime）→ ② 地址 scheme ws/wss →
    // ③ 主机含 maas.aliyuncs.com（HTTP maas 形状）→ ④ 现行 multimodal。
    // 既有三分支的用例在原文件逐字不动，本组只锁优先级与第三分支。
    test('① wss 地址配 -realtime 型号：Realtime 网关优先（派生 realtime 路径）', () async {
      final connector = _ScriptedTtsWsConnector(
        initialText: _qwenSessionCreated,
        onTextSend: (text, connection) =>
            _qwenScript.respond(_decodeClientTextEvent(text), connection),
      );
      final session = await TtsModelGateway(
        _ExplodingBytesHttpClient(),
        webSocketConnector: connector,
      ).openSession(
        config: const TtsConfig(
          provider: TtsProviderKind.qwenTts,
          baseUrl: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
          model: 'qwen3-tts-flash-realtime',
          apiKey: 'sk-dashscope-test',
        ),
        apiKey: 'sk-dashscope-test',
        sessionId: 'chat-1',
      );
      expect(session, isNotNull);
      // Realtime 网关的既有派生逻辑天然支持 wss 地址：路径按协议写死，
      // 不保留用户地址里的推理路径。
      expect(
        connector.lastUri.toString(),
        'wss://dashscope.aliyuncs.com/api-ws/v1/realtime'
        '?model=qwen3-tts-flash-realtime',
      );
    });

    test('② wss 地址：整段与流式都走 WS 推理会话，HTTP 客户端零调用', () async {
      final connector = _ScriptedTtsWsConnector(
        onTextSend: (text, connection) {
          final event = jsonDecode(text) as Map<String, Object?>;
          final action = (event['header']! as Map)['action']! as String;
          switch (action) {
            case 'run-task':
              connection.serverText(
                jsonEncode({
                  'header': {'task_id': 't-1', 'event': 'task-started'},
                  'payload': {},
                }),
              );
            case 'continue-task':
              connection.serverBinary(_inferenceWavFrame([5]));
            case 'finish-task':
              connection.serverBinary(_inferenceWavFrame([6]));
              connection.serverText(
                jsonEncode({
                  'header': {'task_id': 't-1', 'event': 'task-finished'},
                  'payload': {},
                }),
              );
          }
        },
      );
      final gateway = TtsModelGateway(
        _ExplodingBytesHttpClient(),
        webSocketConnector: connector,
      );
      const wssConfig = TtsConfig(
        provider: TtsProviderKind.qwenTts,
        baseUrl: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
        model: 'qwen-audio-3.0-tts-flash',
        apiKey: 'sk-dashscope-test',
      );

      final wav = Uint8List.fromList(
        await gateway.synthesize(config: wssConfig, apiKey: 'sk-dashscope-test', text: '晚安。'),
      );
      expect(wav.sublist(44), [5, 6]);
      expect(
        connector.lastUri.toString(),
        'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
      );
      final streamed = <VoiceAudioChunk>[];
      await gateway
          .synthesizeStream(config: wssConfig, apiKey: 'sk-dashscope-test', text: '晚安。')
          .forEach(streamed.add);
      expect(streamed.map((chunk) => chunk.bytes), [
        [5],
        [6],
      ]);
      // 连续供给会话同样可开：wss 地址是会话档。
      expect(
        await gateway.openSession(
          config: wssConfig,
          apiKey: 'sk-dashscope-test',
          sessionId: 'chat-1',
        ),
        isNotNull,
      );
    });

    test('② 压过 ③：wss 配 maas 主机按地址 scheme 走 WS 推理', () async {
      final connector = _ScriptedTtsWsConnector(
        onTextSend: (text, connection) {
          final event = jsonDecode(text) as Map<String, Object?>;
          switch (((event['header']! as Map)['action'] as String)) {
            case 'run-task':
              connection.serverText(
                jsonEncode({
                  'header': {'task_id': 't-1', 'event': 'task-started'},
                  'payload': {},
                }),
              );
            case 'continue-task':
              connection.serverBinary(_inferenceWavFrame([5]));
            case 'finish-task':
              connection.serverBinary(_inferenceWavFrame([6]));
              connection.serverText(
                jsonEncode({
                  'header': {'task_id': 't-1', 'event': 'task-finished'},
                  'payload': {},
                }),
              );
          }
        },
      );
      final audio = await TtsModelGateway(
        _ExplodingBytesHttpClient(),
        webSocketConnector: connector,
      ).synthesize(
        config: const TtsConfig(
          provider: TtsProviderKind.qwenTts,
          baseUrl: 'wss://ws-12345.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference',
          model: 'qwen-audio-3.1-tts-flash',
          apiKey: 'sk-bailian',
        ),
        apiKey: 'sk-bailian',
        text: '晚安。',
      );
      // 出网目标是 wss 地址、经 WS 连接子：maas 主机的 HTTP 形状没有截胡。
      expect(audio.sublist(44), [5, 6]);
      expect(connector.connectCalls, 1);
    });

    test('③ 压过 ④：https 配 maas 主机仍走 HTTP maas 形状（既有用例逐字不动）', () async {
      // 分派只改请求体形状（ADR 0020 既有裁定），本组只确认它没有被
      // 新分支截胡：https 地址照旧 POST 到用户填的地址，CosyVoice 家族
      // 请求体不变，响应音频地址照旧走下载跳。
      final client = _MaasRecordingBytesHttpClient(
        postResponse: textResponse(
          jsonEncode({
            'output': {
              'audio': {'url': 'https://oss.example.com/a.wav'},
            },
          }),
        ),
        downloadResponse: ProviderBytesHttpResponse(
          statusCode: 200,
          body: Stream.value([4, 5]),
        ),
      );
      final gateway = TtsModelGateway(
        client,
        webSocketConnector: _ScriptedTtsWsConnector(),
      );
      final audio = await gateway.synthesize(
        config: const TtsConfig(
          provider: TtsProviderKind.qwenTts,
          baseUrl: 'https://ws-12345.cn-beijing.maas.aliyuncs.com'
              '/api/v1/services/audio/tts/SpeechSynthesizer',
          model: 'qwen-audio-3.1-tts-flash',
          apiKey: 'sk-bailian',
        ),
        apiKey: 'sk-bailian',
        text: '晚安。',
      );
      expect(audio, [4, 5]);
      expect(client.postCalls, 1);
      expect(client.downloadCalled, isTrue);
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

  /// 服务端帧的统一派发队列：真实连接上 binary 与 text 是同一条流按
  /// wire 序派发的两个视图（见 DartIoProviderWebSocketConnection 的广播
  /// 派生）。内存 fake 用两个独立控制器时，同一次脚本回调里「先音频帧
  /// 后终态事件」的同步 add 会因微任务调度交错而乱序——经典推理协议
  /// （票 07）的尾帧与 task-finished 正是靠 wire 序区分先后，这里按入队
  /// 序逐帧派发以保真。
  final _serverQueue = <({bool binary, Object? frame})>[];
  var _serverDispatchScheduled = false;

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

  void serverBinary(List<int> frame) =>
      _enqueueServerFrame(binary: true, frame: frame);

  void serverText(String text) =>
      _enqueueServerFrame(binary: false, frame: text);

  /// 服务端主动断开（没有结束事件的断流）。
  Future<void> drop() async {
    _closeBoth();
  }

  void _enqueueServerFrame({required bool binary, required Object? frame}) {
    _serverQueue.add((binary: binary, frame: frame));
    _scheduleServerDispatch();
  }

  void _scheduleServerDispatch() {
    if (_serverDispatchScheduled) {
      return;
    }
    _serverDispatchScheduled = true;
    scheduleMicrotask(() {
      _serverDispatchScheduled = false;
      if (_serverQueue.isNotEmpty) {
        final queued = _serverQueue.removeAt(0);
        if (queued.binary) {
          if (!_binary.isClosed) {
            _binary.add(queued.frame as List<int>);
          }
        } else {
          if (!_text.isClosed) {
            _text.add(queued.frame as String);
          }
        }
      }
      if (_serverQueue.isNotEmpty) {
        _scheduleServerDispatch();
      }
    });
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

/// 记录型二进制 HTTP 客户端（带下载跳）：千问朗读档 maas 形状的分派
/// 用例用——POST 与 GET 分别留档，证明新分支没有截胡既有 HTTP 形状。
final class _MaasRecordingBytesHttpClient implements ProviderBytesHttpClient {
  _MaasRecordingBytesHttpClient({
    required this.postResponse,
    required this.downloadResponse,
  });

  final ProviderBytesHttpResponse postResponse;
  final ProviderBytesHttpResponse downloadResponse;

  int postCalls = 0;
  bool downloadCalled = false;

  @override
  Future<ProviderBytesHttpResponse> postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) async {
    postCalls += 1;
    return postResponse;
  }

  @override
  Future<ProviderBytesHttpResponse> getBytes({
    required Uri uri,
    required Duration timeout,
  }) async {
    downloadCalled = true;
    return downloadResponse;
  }
}

/// 一帧自带完整 WAV 头的音频（probe 02/03 基线形状：每个 binary 帧是
/// 独立的 WAV 文件）。[extended] 为 true 时 fmt 前插一个 LIST 扩展块，
/// data 不在固定 44 字节偏移——剥头必须按块遍历。
Uint8List _inferenceWavFrame(List<int> pcm, {bool extended = false}) {
  final bytes = BytesBuilder(copy: false);
  void tag(String value) => bytes.add(ascii.encode(value));
  List<int> u32(int value) => [
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ];
  List<int> u16(int value) => [value & 0xff, (value >> 8) & 0xff];
  void chunk(String id, List<int> body) {
    tag(id);
    bytes.add(u32(body.length));
    bytes.add(body);
    if (body.length.isOdd) {
      bytes.add([0]);
    }
  }

  // 扩展块夹具：fmt 前插一个 LIST/INFO 块（8 字节体，偶数无填充），
  // data 不在固定 44 字节偏移——固定剥会剥错。
  final listChunkSize = extended ? 8 + 8 : 0;
  tag('RIFF');
  bytes.add(u32(36 + pcm.length + listChunkSize));
  tag('WAVE');
  if (extended) {
    chunk('LIST', ascii.encode('INFOqiyu'));
  }
  chunk('fmt ', [
    ...u16(1), // PCM
    ...u16(1), // 单声道
    ...u32(24000),
    ...u32(24000 * 2),
    ...u16(2),
    ...u16(16),
  ]);
  chunk('data', pcm);
  return bytes.takeBytes();
}
