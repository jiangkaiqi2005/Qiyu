import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/in_process_chat_host.dart';

const _privateBody =
    '{"error":{"message":"Authorization: Bearer synthetic-secret; '
    'Cookie: session=synthetic-cookie; C:\\\\private\\\\provider.json"}}';

void main() {
  for (final scenario in [
    (status: 400, body: _privateBody, stt: 'stt_client', tts: 'tts_client'),
    (
      status: 401,
      body: _privateBody,
      stt: 'stt_authentication',
      tts: 'tts_authentication',
    ),
    (
      status: 403,
      body: _privateBody,
      stt: 'stt_authentication',
      tts: 'tts_authentication',
    ),
    (status: 404, body: _privateBody, stt: 'stt_client', tts: 'tts_client'),
    (
      status: 404,
      body: '{"error":{"code":"model_not_found"}}',
      stt: 'stt_model_not_found',
      tts: 'tts_model_not_found',
    ),
    (status: 422, body: _privateBody, stt: 'stt_client', tts: 'tts_client'),
    (
      status: 429,
      body: _privateBody,
      stt: 'stt_rate_limited',
      tts: 'tts_rate_limited',
    ),
    (
      status: 500,
      body: _privateBody,
      stt: 'stt_service_error',
      tts: 'tts_provider',
    ),
  ]) {
    test(
      '语音 HTTP ${scenario.status} 明确映射 ${scenario.stt} 与 ${scenario.tts}',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'qiyu-voice-category-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final repository = JsonProviderConfigRepository(
          filePath: '${directory.path}/provider.json',
        );
        final http = _StatusHttpClient(scenario.status, body: scenario.body);
        final stt = SttSettingsService(repository, SttModelGateway(http));
        final tts = TtsSettingsService(repository, TtsModelGateway(http));
        await stt.save(
          baseUrl: 'https://example.com/v1',
          model: 'test',
          apiKey: 'synthetic-key',
        );
        await tts.save(
          baseUrl: 'https://example.com/v1',
          model: 'test',
          apiKey: 'synthetic-key',
        );
        await expectLater(
          stt.transcribe(audio: [1], mimeType: 'audio/wav'),
          throwsA(
            isA<SttServiceException>()
                .having((error) => error.code, 'code', scenario.stt)
                .having(
                  (error) => error.message,
                  'safe message',
                  isNot(contains('synthetic-secret')),
                ),
          ),
        );
        await expectLater(
          tts.synthesize('在。'),
          throwsA(
            isA<TtsServiceException>()
                .having((error) => error.code, 'code', scenario.tts)
                .having(
                  (error) => error.message,
                  'safe message',
                  isNot(contains('synthetic-secret')),
                ),
          ),
        );
      },
    );
  }

  test('理解类完整调用保留 HTTP 类别到 ModelCompletion', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qiyu-completion-category-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final repository = JsonProviderConfigRepository(
      filePath: '${directory.path}/provider.json',
    );
    await repository.save(
      const ProviderConfig(
        kind: ProviderKind.openAiCompatible,
        baseUrl: 'https://example.com/v1',
        model: 'test',
        temperature: 0.6,
        timeoutSeconds: 25,
        apiKey: 'synthetic-key',
      ),
    );
    final service = ProviderSettingsService(
      repository,
      _NoSecrets(),
      ProviderModelGateway(_StatusHttpClient(422)),
      const ModelPromptBuilder('测试人格宪法'),
    );
    final result = await service.complete(const [
      ModelMessage(ModelMessageRole.user, '在吗'),
    ]);
    expect(result!.failure, ModelFailureKind.provider);
    expect(result.serviceError, ServiceErrorCategory.client);
  });

  for (final scenario in [
    (status: 400, body: _privateBody, category: 'client'),
    (status: 401, body: _privateBody, category: 'authentication'),
    (status: 403, body: _privateBody, category: 'authentication'),
    (status: 404, body: _privateBody, category: 'client'),
    (
      status: 404,
      body: '{"error":{"message":"model unknown does not exist"}}',
      category: 'modelNotFound',
    ),
    (
      status: 404,
      body: '{"error":{"code":"model_not_found","message":"synthetic-secret"}}',
      category: 'modelNotFound',
    ),
    (status: 422, body: _privateBody, category: 'client'),
    (status: 429, body: _privateBody, category: 'rateLimited'),
    (status: 500, body: _privateBody, category: 'server'),
    (
      status: 503,
      body: '{"error":{"message":"model not found in upstream"}}',
      category: 'server',
    ),
  ]) {
    test(
      'HTTP ${scenario.status} 经 Provider 与 Host 交付 ${scenario.category}',
      () async {
        final http = _StatusHttpClient(scenario.status, body: scenario.body);
        final host = await InProcessChatHost.start(
          modelGateway: ProviderModelGateway(http),
        );
        addTearDown(host.close);
        final trace = await host.sendChat(
          requestId: 'status-error',
          text: '在吗',
        );
        final frames = _frames(trace);
        expect(
          frames.singleWhere(
            (frame) => frame['event'] == 'fallback',
          )['serviceError'],
          scenario.category,
        );
        expect(
          frames.singleWhere(
            (frame) => frame['event'] == 'state',
          )['serviceError'],
          scenario.category,
        );
        expect(trace.state.source, ReplySource.local);
        expect(trace.events.last.kind, ChatDeliveryEventKind.done);
        expect(trace.message.messages, isNotEmpty);
        for (final secret in [
          'synthetic-secret',
          'synthetic-cookie',
          'private',
          'Authorization',
          'Cookie',
        ]) {
          expect(trace.body, isNot(contains(secret)));
        }
        final snapshot = await host.readSession(sessionId: trace.sessionId);
        expect(
          snapshot.body,
          contains('"serviceError":"${scenario.category}"'),
        );
        expect(snapshot.body, isNot(contains('synthetic-secret')));
        // 重启后幂等重放来自 Markdown；类别不能在存储边界丢失。
        await host.restart();
        final replay = await host.sendChat(
          requestId: 'status-error',
          text: '在吗',
          sessionId: trace.sessionId,
        );
        expect(
          _frames(
            replay,
          ).singleWhere((frame) => frame['event'] == 'state')['serviceError'],
          scenario.category,
        );
        expect(http.calls, 1);
      },
    );
  }

  for (final error in <Object>[
    TimeoutException('synthetic-secret'),
    const SocketException('Failed host lookup synthetic-secret'),
    const SocketException('offline synthetic-secret'),
    const HandshakeException('synthetic-secret'),
  ]) {
    test('网络异常 ${error.runtimeType} 保留 network 类别且无原始异常', () async {
      final host = await InProcessChatHost.start(
        modelGateway: ProviderModelGateway(
          _StatusHttpClient(200, error: error),
        ),
      );
      addTearDown(host.close);
      final trace = await host.sendChat(requestId: 'network-error', text: '在吗');
      expect(trace.state.serviceError, ServiceErrorCategory.network);
      expect(trace.events.last.kind, ChatDeliveryEventKind.done);
      expect(trace.body, isNot(contains('synthetic-secret')));
    });
  }

  test('安全、未配置和输出校验回退不携带服务类别', () async {
    for (final scenario in [
      // 危机输入照常外呼；输出不合格时按分类降级兜底话术，同样不带
      // 服务类别。
      (configured: true, text: '我想自杀', expectedCalls: 1),
      (configured: false, text: '在吗', expectedCalls: 0),
      (configured: true, text: '在吗', expectedCalls: 1),
    ]) {
      final http = _StatusHttpClient(200, body: 'data: [DONE]\n\n');
      final host = await InProcessChatHost.start(
        modelGateway: ProviderModelGateway(http),
        configureProvider: scenario.configured,
      );
      addTearDown(host.close);
      final trace = await host.sendChat(
        requestId: 'local-only',
        text: scenario.text,
      );
      expect(trace.state.source, ReplySource.local);
      expect(trace.state.serviceError, isNull);
      expect(trace.body, isNot(contains('serviceError')));
      expect(http.calls, scenario.expectedCalls);
    }
  });
}

List<Map<String, Object?>> _frames(ChatEventTrace trace) => trace.body
    .split('\n')
    .where((line) => line.isNotEmpty)
    .map((line) => jsonDecode(line) as Map<String, Object?>)
    .toList();

final class _StatusHttpClient
    implements ProviderHttpClient, ProviderBytesHttpClient {
  _StatusHttpClient(this.status, {this.body = _privateBody, this.error});
  final int status;
  final String body;
  final Object? error;
  int calls = 0;

  @override
  Future<ProviderBytesHttpResponse> postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) async => ProviderBytesHttpResponse(
    statusCode: status,
    body: Stream.value(utf8.encode(this.body)),
  );

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    Future<void>? whenCancelled,
    ProviderResponseBudget? budget,
  }) async {
    calls++;
    if (error != null) throw error!;
    return ProviderHttpResponse(
      statusCode: status,
      body: Stream.value(this.body),
    );
  }
}

final class _NoSecrets implements SecretStore {
  @override
  Future<void> deleteApiKey(String scope) async {}
  @override
  Future<String?> readApiKey(String scope) async => null;
}
