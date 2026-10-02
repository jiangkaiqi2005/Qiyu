import 'dart:async';
import 'dart:convert';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/scripted_omni_realtime.dart';

/// T02 验证矩阵（票面验证与完成）：用脱敏固定事件与可注入连接验证
/// 文本、音频 transcript、工具调用、正常终止、提前关闭、取消、错误、
/// 旧事件隔离；事件形状全部取自 T01 原型实测（2026-10-02 真实凭据）。
void main() {
  final config = ProviderConfig(
    kind: ProviderKind.qwenOmniRealtime,
    baseUrl: 'wss://dashscope.example.com/api-ws/v1/realtime',
    model: 'qwen3.8-omni-flash-realtime',
    temperature: 0.7,
    timeoutSeconds: 1,
  );

  OmniRealtimeSessionConfig sessionConfig({
    String instructions = '你是栖语。',
    bool audioOutput = true,
    String? voice,
    OmniRealtimeTurnDetection turnDetection =
        OmniRealtimeTurnDetection.serverVad,
    List<OmniRealtimeTool> tools = const [],
  }) => OmniRealtimeSessionConfig(
    instructions: instructions,
    audioOutput: audioOutput,
    voice: voice,
    turnDetection: turnDetection,
    tools: tools,
  );

  Map<String, Object?> responseDone(String id, String status) => {
    'type': 'response.done',
    'response': {'id': id, 'status': status},
  };

  test('会话地址按配置拼装 model query 参数，既有 query 保留', () {
    final base = ProviderConfig(
      kind: ProviderKind.qwenOmniRealtime,
      baseUrl: 'wss://gw.example.com/realtime?workspace=ws-1',
      model: 'qwen3.8-omni-flash-realtime',
      temperature: 0.7,
      timeoutSeconds: 30,
    );
    final uri = QwenOmniRealtimeGateway(
      ScriptedOmniRealtimeConnector(),
    ).resolveUri(base);
    expect(uri.scheme, 'wss');
    expect(uri.host, 'gw.example.com');
    expect(uri.path, '/realtime');
    expect(uri.queryParameters['model'], 'qwen3.8-omni-flash-realtime');
    expect(uri.queryParameters['workspace'], 'ws-1');
  });

  group('session.update 载荷形状（T01 §4 完整扁平 OpenAI 形）', () {
    test('有声会话显式携带默认音色 Tina 与 server_vad，不依赖服务端默认音色', () {
      final payload = sessionConfig().toSessionPayload();
      expect(payload['instructions'], '你是栖语。');
      expect(payload['modalities'], ['text', 'audio']);
      expect(payload['voice'], qwenOmniRealtimeDefaultVoice);
      expect(payload['voice'], 'Tina');
      expect(payload['turn_detection'], {'type': 'server_vad'});
      expect(payload.containsKey('tools'), isFalse);
      expect(payload['input_audio_format'], qwenOmniRealtimeInputAudioFormat);
      expect(payload['output_audio_format'], qwenOmniRealtimeOutputAudioFormat);
      expect(payload['input_audio_transcription'], {
        'model': qwenOmniRealtimeInputTranscriptionModel,
      });
    });

    test('纯文字会话同样携带音色/格式/转录字段（真实端点实测必带）', () {
      final payload = sessionConfig(audioOutput: false).toSessionPayload();
      expect(payload['modalities'], ['text']);
      expect(payload['voice'], qwenOmniRealtimeDefaultVoice);
      expect(payload['turn_detection'], {'type': 'server_vad'});
      expect(payload['input_audio_format'], qwenOmniRealtimeInputAudioFormat);
      expect(payload['output_audio_format'], qwenOmniRealtimeOutputAudioFormat);
      expect(payload['input_audio_transcription'], {
        'model': qwenOmniRealtimeInputTranscriptionModel,
      });
    });

    test('显式音色与 VAD 选型原样下发，工具按扁平 function 形状注册', () {
      final payload = sessionConfig(
        voice: 'Serena',
        turnDetection: OmniRealtimeTurnDetection.semanticVad,
        tools: [
          OmniRealtimeTool(
            name: 'memory_recall',
            description: '回忆检索',
            parameters: {
              'type': 'object',
              'properties': {
                'query': {'type': 'string'},
              },
            },
          ),
        ],
      ).toSessionPayload();
      expect(payload['voice'], 'Serena');
      expect(payload['turn_detection'], {'type': 'semantic_vad'});
      expect(payload['tools'], [
        {
          'type': 'function',
          'name': 'memory_recall',
          'description': '回忆检索',
          'parameters': {
            'type': 'object',
            'properties': {
              'query': {'type': 'string'},
            },
          },
        },
      ]);
    });

    test('空 instructions 不下发该键（已核实更新始终携带实义提示词）', () {
      final payload = sessionConfig(instructions: '   ').toSessionPayload();
      expect(payload.containsKey('instructions'), isFalse);
    });
  });

  group('建连与就绪', () {
    test('缺 Key 按认证失败拒绝，不出网', () async {
      final connector = ScriptedOmniRealtimeConnector();
      final gateway = QwenOmniRealtimeGateway(connector);
      await expectLater(
        gateway.connect(
          config: config,
          apiKey: '  ',
          sessionConfig: sessionConfig(),
        ),
        throwsA(
          isA<ModelGatewayException>().having(
            (error) => error.kind,
            'kind',
            ModelFailureKind.authentication,
          ),
        ),
      );
      expect(connector.connection.connectCount, 0);
    });

    test('内网 ws 目标按 SSRF 拒绝，不出网', () async {
      final connector = ScriptedOmniRealtimeConnector();
      final gateway = QwenOmniRealtimeGateway(connector);
      await expectLater(
        gateway.connect(
          config: ProviderConfig(
            kind: ProviderKind.qwenOmniRealtime,
            baseUrl: 'ws://192.168.1.10:9000/realtime',
            model: 'qwen3.8-omni-flash-realtime',
            temperature: 0.7,
            timeoutSeconds: 1,
          ),
          apiKey: 'k',
          sessionConfig: sessionConfig(),
        ),
        throwsA(
          isA<ModelGatewayException>().having(
            (error) => error.kind,
            'kind',
            ModelFailureKind.network,
          ),
        ),
      );
      expect(connector.connection.connectCount, 0);
    });

    test('就绪等待 session.updated；客户端首帧是唯一的 session.update 且事件 id 唯一', () async {
      final connector = ScriptedOmniRealtimeConnector();
      connector.connection.onClientFrame = (frame) {
        if (frame['type'] == 'session.update') {
          connector.connection.server({
            'type': 'session.updated',
            'session': {},
          });
        }
      };
      final gateway = QwenOmniRealtimeGateway(connector);
      final session = await gateway.connect(
        config: config,
        apiKey: 'k',
        sessionConfig: sessionConfig(),
      );
      final updates = connector.connection
          .framesOfType('session.update')
          .toList();
      expect(updates, hasLength(1));
      final sessionPayload = updates.single['session']! as Map<String, Object?>;
      expect(sessionPayload['voice'], 'Tina');
      // 客户端事件 id 全连接唯一（T01 §12.1 回归）。
      final ids = connector.connection.sentFrames
          .map((frame) => frame['event_id'])
          .toList();
      expect(ids.toSet().length, ids.length);
      await session.close();
    });

    test('建连后模型长时间不回 session.updated：超时有界失败（真实故障）', () async {
      final connector = ScriptedOmniRealtimeConnector();
      final gateway = QwenOmniRealtimeGateway(connector);
      await expectLater(
        gateway.connect(
          config: config,
          apiKey: 'k',
          sessionConfig: sessionConfig(),
        ),
        throwsA(
          isA<ModelGatewayException>().having(
            (error) => error.kind,
            'kind',
            ModelFailureKind.timeout,
          ),
        ),
      );
    });

    test('就绪期收到 error 事件：按允许列表指纹分类（鉴权），连接收束', () async {
      final connector = ScriptedOmniRealtimeConnector();
      connector.connection.onClientFrame = (frame) {
        if (frame['type'] == 'session.update') {
          connector.connection.server({
            'type': 'error',
            'error': {'code': 'InvalidApiKey', 'message': 'secret-detail'},
          });
        }
      };
      final gateway = QwenOmniRealtimeGateway(connector);
      await expectLater(
        gateway.connect(
          config: config,
          apiKey: 'k',
          sessionConfig: sessionConfig(),
        ),
        throwsA(
          isA<ModelGatewayException>()
              .having(
                (error) => error.kind,
                'kind',
                ModelFailureKind.authentication,
              )
              .having(
                (error) => error.message,
                'message',
                isNot(contains('secret-detail')),
              ),
        ),
      );
    });
  });

  group('文字轮（completeText）', () {
    test('system 并入 instructions，消息按原序重放，response.text 增量收全，正常终止', () async {
      final connector = ScriptedOmniRealtimeConnector();
      connector.connection.onClientFrame = scriptedOmniResponder(
        connector.connection,
        [
          {
            'type': 'response.created',
            'response': {'id': 'resp-1'},
          },
          {
            'type': 'response.text.delta',
            'response_id': 'resp-1',
            'delta': '你',
          },
          {
            'type': 'response.text.delta',
            'response_id': 'resp-1',
            'delta': '好呀。',
          },
          {'type': 'response.text.done', 'response_id': 'resp-1'},
          responseDone('resp-1', 'completed'),
        ],
      );
      final gateway = QwenOmniRealtimeGateway(connector);
      final reply = await gateway.completeText(
        config: config,
        apiKey: 'k',
        messages: const [
          ModelMessage(ModelMessageRole.system, '人格宪法'),
          ModelMessage(ModelMessageRole.user, '在吗'),
          ModelMessage(ModelMessageRole.assistant, '嗯。'),
          ModelMessage(ModelMessageRole.user, '今晚讲个故事吗'),
        ],
      );
      expect(reply, '你好呀。');
      final connection = connector.connection;
      final items = connection.framesOfType('conversation.item.create');
      expect(items, hasLength(3));
      expect(
        items
            .map(
              (frame) =>
                  ((frame['item']! as Map)['content']! as List).first! as Map,
            )
            .map((content) => content['type']),
        ['input_text', 'text', 'input_text'],
      );
      expect(items.map((frame) => (frame['item']! as Map)['role']), [
        'user',
        'assistant',
        'user',
      ]);
      expect(connection.framesOfType('response.create'), hasLength(1));
      // system 消息进了 instructions，不作为 item 重放。
      final update = connection.framesOfType('session.update').single;
      final sessionPayload = update['session']! as Map<String, Object?>;
      expect(sessionPayload['instructions'], '人格宪法');
      expect(sessionPayload['modalities'], ['text']);
    });

    test('response.done status=cancelled 不当完整回复（原生取消）', () async {
      final connector = ScriptedOmniRealtimeConnector();
      connector.connection.onClientFrame = scriptedOmniResponder(
        connector.connection,
        [
          {
            'type': 'response.created',
            'response': {'id': 'resp-1'},
          },
          {
            'type': 'response.text.delta',
            'response_id': 'resp-1',
            'delta': '半句',
          },
          responseDone('resp-1', 'cancelled'),
        ],
      );
      final gateway = QwenOmniRealtimeGateway(connector);
      await expectLater(
        gateway.completeText(
          config: config,
          apiKey: 'k',
          messages: const [ModelMessage(ModelMessageRole.user, '在吗')],
        ),
        throwsA(
          isA<ModelGatewayException>().having(
            (error) => error.kind,
            'kind',
            ModelFailureKind.network,
          ),
        ),
      );
    });

    test('response.done status=incomplete 按截断失败', () async {
      final connector = ScriptedOmniRealtimeConnector();
      connector.connection.onClientFrame = scriptedOmniResponder(
        connector.connection,
        [
          {
            'type': 'response.created',
            'response': {'id': 'resp-1'},
          },
          {
            'type': 'response.text.delta',
            'response_id': 'resp-1',
            'delta': '半句',
          },
          responseDone('resp-1', 'incomplete'),
        ],
      );
      final gateway = QwenOmniRealtimeGateway(connector);
      await expectLater(
        gateway.completeText(
          config: config,
          apiKey: 'k',
          messages: const [ModelMessage(ModelMessageRole.user, '在吗')],
        ),
        throwsA(
          isA<ModelGatewayException>().having(
            (error) => error.kind,
            'kind',
            ModelFailureKind.contentParsing,
          ),
        ),
      );
    });

    test('response.done status=failed 按服务方失败', () async {
      final connector = ScriptedOmniRealtimeConnector();
      connector.connection.onClientFrame = scriptedOmniResponder(
        connector.connection,
        [
          {
            'type': 'response.created',
            'response': {'id': 'resp-1'},
          },
          responseDone('resp-1', 'failed'),
        ],
      );
      final gateway = QwenOmniRealtimeGateway(connector);
      await expectLater(
        gateway.completeText(
          config: config,
          apiKey: 'k',
          messages: const [ModelMessage(ModelMessageRole.user, '在吗')],
        ),
        throwsA(
          isA<ModelGatewayException>().having(
            (error) => error.kind,
            'kind',
            ModelFailureKind.provider,
          ),
        ),
      );
    });

    test('response.create 被服务端静默忽略：请求级看门狗超时有界失败（T01 §9.4）', () async {
      final connector = ScriptedOmniRealtimeConnector();
      // 只应答 session.update，不回应 response.create。
      connector.connection.onClientFrame = scriptedOmniResponder(
        connector.connection,
        const [],
      );
      final gateway = QwenOmniRealtimeGateway(connector);
      await expectLater(
        gateway.completeText(
          config: config,
          apiKey: 'k',
          messages: const [ModelMessage(ModelMessageRole.user, '在吗')],
        ),
        throwsA(
          isA<ModelGatewayException>().having(
            (error) => error.kind,
            'kind',
            ModelFailureKind.timeout,
          ),
        ),
      );
    });

    test('回复中途模型静默：空闲看门狗超时有界失败（T01 §11 降级窗口）', () async {
      final connector = ScriptedOmniRealtimeConnector();
      connector
          .connection
          .onClientFrame = scriptedOmniResponder(connector.connection, [
        {
          'type': 'response.created',
          'response': {'id': 'resp-1'},
        },
        {'type': 'response.text.delta', 'response_id': 'resp-1', 'delta': '半'},
        // 之后彻底静默，无 response.done、无 error、无 close 帧。
      ]);
      final gateway = QwenOmniRealtimeGateway(connector);
      await expectLater(
        gateway.completeText(
          config: config,
          apiKey: 'k',
          messages: const [ModelMessage(ModelMessageRole.user, '在吗')],
        ),
        throwsA(
          isA<ModelGatewayException>().having(
            (error) => error.kind,
            'kind',
            ModelFailureKind.timeout,
          ),
        ),
      );
    });
  });

  group('事件面（手动驱动会话）', () {
    Future<OmniRealtimeSession> openSession(
      ScriptedOmniRealtimeConnector connector,
    ) async {
      connector.connection.onClientFrame = scriptedOmniResponder(
        connector.connection,
        const [],
      );
      return QwenOmniRealtimeGateway(
        connector,
      ).connect(config: config, apiKey: 'k', sessionConfig: sessionConfig());
    }

    test('音频块解码、transcript 增量、VAD 与输入转录按事件归一交付', () async {
      final connector = ScriptedOmniRealtimeConnector();
      final session = await openSession(connector);
      final received = <OmniRealtimeEvent>[];
      final subscription = session.events.listen(received.add);
      final audio = base64Encode([1, 2, 3, 4]);
      connector.connection.server({
        'type': 'response.created',
        'response': {'id': 'resp-1'},
      });
      connector.connection.server({
        'type': 'input_audio_buffer.speech_started',
      });
      connector.connection.server({
        'type': 'input_audio_buffer.speech_stopped',
      });
      connector.connection.server({
        'type': 'conversation.item.input_audio_transcription.completed',
        'transcript': '晚上好',
      });
      connector.connection.server({
        'type': 'response.audio.delta',
        'response_id': 'resp-1',
        'delta': audio,
      });
      connector.connection.server({
        'type': 'response.audio_transcript.delta',
        'response_id': 'resp-1',
        'delta': '晚上',
      });
      connector.connection.server({
        'type': 'response.audio.done',
        'response_id': 'resp-1',
      });
      await pumpEventQueue();
      expect(received.whereType<OmniRealtimeSpeechStarted>(), isNotEmpty);
      expect(received.whereType<OmniRealtimeSpeechStopped>(), isNotEmpty);
      expect(
        received.whereType<OmniRealtimeInputTranscript>().single.text,
        '晚上好',
      );
      final chunk = received.whereType<OmniRealtimeAudioChunk>().single;
      expect(chunk.responseId, 'resp-1');
      expect(chunk.bytes, [1, 2, 3, 4]);
      expect(received.whereType<OmniRealtimeReplyDelta>().single.text, '晚上');
      // audio.done 不是完成信号：不产生任何终态事件（T01 §13.3）。
      expect(received.whereType<OmniRealtimeResponseFinished>(), isEmpty);
      await subscription.cancel();
      await session.close();
    });

    test('旧事件按轮次隔离：终结回复的迟到音频与未知回复的游离事件都丢弃', () async {
      final connector = ScriptedOmniRealtimeConnector();
      final session = await openSession(connector);
      final received = <OmniRealtimeEvent>[];
      final subscription = session.events.listen(received.add);
      connector.connection.server({
        'type': 'response.created',
        'response': {'id': 'resp-1'},
      });
      connector.connection.server(responseDone('resp-1', 'cancelled'));
      // 终结后迟到的旧回复音频包（T02:15）。
      connector.connection.server({
        'type': 'response.audio.delta',
        'response_id': 'resp-1',
        'delta': base64Encode([9, 9]),
      });
      connector.connection.server({
        'type': 'response.audio_transcript.delta',
        'response_id': 'resp-1',
        'delta': '迟到的旧话',
      });
      // 迟到的重复终态同样不复活旧回复。
      connector.connection.server(responseDone('resp-1', 'completed'));
      // 从未见过的回复 id（游离事件）。
      connector.connection.server({
        'type': 'response.audio.delta',
        'response_id': 'resp-404',
        'delta': base64Encode([8, 8]),
      });
      await pumpEventQueue();
      expect(received.whereType<OmniRealtimeAudioChunk>(), isEmpty);
      expect(received.whereType<OmniRealtimeReplyDelta>(), isEmpty);
      expect(
        received.whereType<OmniRealtimeResponseFinished>().single.status,
        OmniRealtimeResponseStatus.cancelled,
      );
      await subscription.cancel();
      await session.close();
    });

    test('原生工具调用：item 登记 → arguments 归并 → call_id 配对交付', () async {
      final connector = ScriptedOmniRealtimeConnector();
      final session = await openSession(connector);
      final received = <OmniRealtimeEvent>[];
      final subscription = session.events.listen(received.add);
      connector.connection.server({
        'type': 'response.created',
        'response': {'id': 'resp-1'},
      });
      connector.connection.server({
        'type': 'response.output_item.added',
        'response_id': 'resp-1',
        'item': {
          'type': 'function_call',
          'id': 'item-1',
          'call_id': 'call_1',
          'name': 'memory_recall',
        },
      });
      connector.connection.server({
        'type': 'response.function_call_arguments.delta',
        'response_id': 'resp-1',
        'item_id': 'item-1',
        'delta': '{"que',
      });
      connector.connection.server({
        'type': 'response.function_call_arguments.done',
        'response_id': 'resp-1',
        'item_id': 'item-1',
        'arguments': '{"query":"搬家前的小区"}',
      });
      connector.connection.server(responseDone('resp-1', 'completed'));
      await pumpEventQueue();
      final call = received.whereType<OmniRealtimeToolCall>().single;
      expect(call.responseId, 'resp-1');
      expect(call.callId, 'call_1');
      expect(call.name, 'memory_recall');
      expect(call.arguments, '{"query":"搬家前的小区"}');
      await subscription.cancel();

      // 回填走 function_call_output + response.create（T01 §9.3 形状）。
      session.sendToolResult(callId: 'call_1', output: '梧桐里');
      final outputs = connector.connection
          .framesOfType('conversation.item.create')
          .where(
            (frame) =>
                (frame['item']! as Map)['type'] == 'function_call_output',
          )
          .toList();
      expect(outputs, hasLength(1));
      expect((outputs.single['item']! as Map)['call_id'], 'call_1');
      expect((outputs.single['item']! as Map)['output'], '梧桐里');
      expect(
        connector.connection.framesOfType('response.create'),
        hasLength(1),
      );
      await session.close();
    });

    test('arguments.done 无已登记 item：工具链路已断，会话失败关闭', () async {
      final connector = ScriptedOmniRealtimeConnector();
      final session = await openSession(connector);
      final received = <OmniRealtimeEvent>[];
      final subscription = session.events.listen(received.add);
      connector.connection.server({
        'type': 'response.created',
        'response': {'id': 'resp-1'},
      });
      connector.connection.server({
        'type': 'response.function_call_arguments.done',
        'response_id': 'resp-1',
        'item_id': 'ghost',
        'arguments': '{}',
      });
      await pumpEventQueue();
      expect(
        received.whereType<OmniRealtimeSessionFailed>().single.kind,
        ModelFailureKind.incompatibleResponse,
      );
      expect(session.isClosed, isTrue);
      await subscription.cancel();
    });

    test('未知 response 状态按协议不兼容失败关闭，不猜语义', () async {
      final connector = ScriptedOmniRealtimeConnector();
      final session = await openSession(connector);
      final received = <OmniRealtimeEvent>[];
      final subscription = session.events.listen(received.add);
      connector.connection.server({
        'type': 'response.created',
        'response': {'id': 'resp-1'},
      });
      connector.connection.server(responseDone('resp-1', 'mystery'));
      await pumpEventQueue();
      expect(
        received.whereType<OmniRealtimeSessionFailed>().single.kind,
        ModelFailureKind.incompatibleResponse,
      );
      await subscription.cancel();
    });

    test('error 事件分类为会话失败，第三方原文不透出', () async {
      final connector = ScriptedOmniRealtimeConnector();
      final session = await openSession(connector);
      final received = <OmniRealtimeEvent>[];
      final subscription = session.events.listen(received.add);
      connector.connection.server({
        'type': 'error',
        'error': {
          'code': 'Throttling.RateQuota',
          'message': 'request id: leaked-trace-id',
        },
      });
      await pumpEventQueue();
      final failure = received.whereType<OmniRealtimeSessionFailed>().single;
      expect(failure.kind, ModelFailureKind.rateLimited);
      expect(failure.message, isNot(contains('leaked-trace-id')));
      expect(session.isClosed, isTrue);
      await subscription.cancel();
    });

    test('无帧断开（远端静默关闭）：会话按连接中断失败收束，事件流结束', () async {
      final connector = ScriptedOmniRealtimeConnector();
      final session = await openSession(connector);
      final received = <OmniRealtimeEvent>[];
      final ended = Completer<void>();
      final subscription = session.events.listen(
        received.add,
        onDone: ended.complete,
      );
      await connector.connection.close();
      await pumpEventQueue();
      expect(
        received.whereType<OmniRealtimeSessionFailed>().single.kind,
        ModelFailureKind.network,
      );
      await ended.future;
      await subscription.cancel();
      await session.done;
    });

    test('close 幂等；关闭后客户端动作为空操作，不再发出任何帧', () async {
      final connector = ScriptedOmniRealtimeConnector();
      final session = await openSession(connector);
      await session.close();
      final sentBefore = connector.connection.sentFrames.length;
      await session.close();
      session.appendAudio([1, 2, 3]);
      session.sendUserItem('迟到的输入');
      session.updateSession(sessionConfig());
      session.createResponse();
      expect(connector.connection.sentFrames.length, sentBefore);
      expect(connector.connection.closed, isTrue);
      await session.done;
    });

    test('appendAudio 以 base64 进 input_audio_buffer.append', () async {
      final connector = ScriptedOmniRealtimeConnector();
      final session = await openSession(connector);
      session.appendAudio([250, 0, 10, 200]);
      final appends = connector.connection
          .framesOfType('input_audio_buffer.append')
          .toList();
      expect(appends, hasLength(1));
      expect(base64Decode(appends.single['audio']! as String), [
        250,
        0,
        10,
        200,
      ]);
      await session.close();
    });
  });
}
