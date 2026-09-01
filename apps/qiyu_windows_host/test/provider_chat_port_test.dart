import 'dart:async';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

/// 三种 Provider 经统一 prepare/open 端口、真实 ProviderModelGateway
/// 逐一回归四个象限：正常终止、提前 EOF、超时/原生错误、底层订阅取消。
void main() {
  const messages = [
    ModelMessage(ModelMessageRole.system, '你是栖语。'),
    ModelMessage(ModelMessageRole.user, '在吗'),
  ];

  final providers = [
    (
      name: 'OpenAI-compatible',
      kind: ProviderKind.openAiCompatible,
      baseUrl: 'https://api.example.com/v1',
      withApiKey: true,
      normalBody: [
        'data: {"choices":[{"delta":{"content":"嗯"}}]}\n\n',
        'data: {"choices":[{"delta":{"content":"。"},"finish_reason":"stop"}]}\n\n',
      ],
      expectedReply: '嗯。',
      firstDeltaLine: 'data: {"choices":[{"delta":{"content":"嗯"}}]}\n\n',
      eofBody: ['data: {"choices":[{"delta":{"content":"半句"}}]}\n\n'],
      nativeErrorBody: ['{"error":{"message":"internal boom"}}\n\n'],
      nativeErrorStatus: 500,
      nativeErrorFailure: ModelFailureKind.provider,
      nativeErrorLeak: 'internal boom',
    ),
    (
      name: 'Anthropic',
      kind: ProviderKind.anthropic,
      baseUrl: 'https://api.anthropic.com/v1',
      withApiKey: true,
      normalBody: [
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"嗯"}}\n\n',
        'data: {"type":"message_stop"}\n\n',
      ],
      expectedReply: '嗯',
      firstDeltaLine:
          'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"嗯"}}\n\n',
      eofBody: [
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"半句"}}\n\n',
      ],
      nativeErrorBody: [
        'data: {"type":"error","error":{"message":"Authorization: Bearer leaked-token"}}\n\n',
      ],
      nativeErrorStatus: 200,
      nativeErrorFailure: ModelFailureKind.provider,
      nativeErrorLeak: 'leaked-token',
    ),
    (
      name: 'Ollama',
      kind: ProviderKind.ollama,
      baseUrl: 'http://127.0.0.1:11434',
      withApiKey: false,
      normalBody: [
        '{"message":{"role":"assistant","content":"嗯"},"done":false}\n',
        '{"message":{"role":"assistant","content":"？"},"done":true}\n',
      ],
      expectedReply: '嗯？',
      firstDeltaLine:
          '{"message":{"role":"assistant","content":"嗯"},"done":false}\n',
      eofBody: [
        '{"message":{"role":"assistant","content":"半句"},"done":false}\n',
      ],
      // Ollama 的原生错误行不带可解析内容且没有终止标记：网关按无法
      // 解析失败关闭，不把错误原文回传，也不当作完成。
      nativeErrorBody: ['{"error":"boom"}\n'],
      nativeErrorStatus: 200,
      nativeErrorFailure: ModelFailureKind.contentParsing,
      nativeErrorLeak: 'boom',
    ),
  ];

  ProviderConfig configOf(
    ProviderKind kind,
    String baseUrl, {
    required bool withApiKey,
  }) => ProviderConfig(
    kind: kind,
    baseUrl: baseUrl,
    model: 'chat-model',
    temperature: 0.6,
    timeoutSeconds: 25,
    apiKey: withApiKey ? 'test-key' : null,
  );

  ProviderSettingsService serviceFor(
    ProviderConfig config,
    ProviderHttpClient client,
  ) => ProviderSettingsService(
    _FixedConfigRepository(config),
    const _NoSecretStore(),
    ProviderModelGateway(client),
    const ModelPromptBuilder('测试人格宪法'),
  );

  for (final provider in providers) {
    group('统一端口回归 ${provider.name}', () {
      test('prepare 打包快照且 open 正常终止于协议原生标记', () async {
        final service = serviceFor(
          configOf(
            provider.kind,
            provider.baseUrl,
            withApiKey: provider.withApiKey,
          ),
          _ScriptedHttpClient(
            response: ProviderHttpResponse(
              statusCode: 200,
              body: Stream.fromIterable(provider.normalBody),
            ),
          ),
        );

        final prepared = await service.prepareChatRequest();
        expect(prepared, isNotNull);
        expect(prepared!.hardRulesAddendum, isEmpty);
        final events = await (await prepared.openStream(messages))!.toList();

        expect(events.last.kind, ModelStreamEventKind.done);
        expect(
          events
              .where((event) => event.kind == ModelStreamEventKind.delta)
              .map((event) => event.text)
              .join(),
          provider.expectedReply,
        );
      });

      test('open 在提前 EOF 时失败关闭，不把半句当完成', () async {
        final service = serviceFor(
          configOf(
            provider.kind,
            provider.baseUrl,
            withApiKey: provider.withApiKey,
          ),
          _ScriptedHttpClient(
            response: ProviderHttpResponse(
              statusCode: 200,
              body: Stream.fromIterable(provider.eofBody),
            ),
          ),
        );

        final prepared = await service.prepareChatRequest();
        final events = await (await prepared!.openStream(messages))!.toList();

        expect(events, isNotEmpty);
        expect(
          events.map((event) => event.kind),
          isNot(contains(ModelStreamEventKind.done)),
        );
        expect(events.last.kind, ModelStreamEventKind.failure);
        expect(events.last.failure, ModelFailureKind.network);
      });

      test('open 在连接超时时报告超时失败', () async {
        final service = serviceFor(
          configOf(
            provider.kind,
            provider.baseUrl,
            withApiKey: provider.withApiKey,
          ),
          _ScriptedHttpClient(error: TimeoutException('slow')),
        );

        final prepared = await service.prepareChatRequest();
        final events = await (await prepared!.openStream(messages))!.toList();

        expect(events, hasLength(1));
        expect(events.single.kind, ModelStreamEventKind.failure);
        expect(events.single.failure, ModelFailureKind.timeout);
        expect(events.single.message, '连接模型服务超时。');
      });

      test('open 在 Provider 原生错误时安全关闭且不回传原文', () async {
        final service = serviceFor(
          configOf(
            provider.kind,
            provider.baseUrl,
            withApiKey: provider.withApiKey,
          ),
          _ScriptedHttpClient(
            response: ProviderHttpResponse(
              statusCode: provider.nativeErrorStatus,
              body: Stream.fromIterable(provider.nativeErrorBody),
            ),
          ),
        );

        final prepared = await service.prepareChatRequest();
        final events = await (await prepared!.openStream(messages))!.toList();

        expect(
          events.map((event) => event.kind),
          isNot(contains(ModelStreamEventKind.done)),
        );
        expect(events.last.kind, ModelStreamEventKind.failure);
        expect(events.last.failure, provider.nativeErrorFailure);
        expect(events.last.message, isNot(contains(provider.nativeErrorLeak)));
      });

      test('取消 open 返回的流会取消底层 HTTP 响应订阅', () async {
        final cancelled = Completer<void>();
        final deltaReceived = Completer<void>();
        final controller = StreamController<String>(
          onCancel: () {
            if (!cancelled.isCompleted) {
              cancelled.complete();
            }
          },
        );
        final service = serviceFor(
          configOf(
            provider.kind,
            provider.baseUrl,
            withApiKey: provider.withApiKey,
          ),
          _ScriptedHttpClient(
            response: ProviderHttpResponse(
              statusCode: 200,
              body: controller.stream,
            ),
          ),
        );

        final prepared = await service.prepareChatRequest();
        final stream = await prepared!.openStream(messages);
        final subscription = stream!.listen((event) {
          if (event.kind == ModelStreamEventKind.delta &&
              !deltaReceived.isCompleted) {
            deltaReceived.complete();
          }
        });

        controller.add(provider.firstDeltaLine);
        await deltaReceived.future;
        final cancellation = subscription.cancel();
        await cancelled.future;
        await controller.close();
        await cancellation;

        expect(cancelled.isCompleted, isTrue);
      });
    });
  }

  test('未配置 Provider 时统一端口 prepare 返回 null', () async {
    final service = ProviderSettingsService(
      _FixedConfigRepository(null),
      const _NoSecretStore(),
      ProviderModelGateway(_ScriptedHttpClient(error: StateError('不该出网'))),
      const ModelPromptBuilder('测试人格宪法'),
    );

    expect(await service.prepareChatRequest(), isNull);
  });

  test('不支持流式的网关经快照回退为整段完成的单增量流', () async {
    final service = ProviderSettingsService(
      _FixedConfigRepository(
        configOf(
          ProviderKind.openAiCompatible,
          'https://api.example.com/v1',
          withApiKey: true,
        ),
      ),
      const _NoSecretStore(),
      const _CompleteOnlyGateway(reply: '嗯。'),
      const ModelPromptBuilder('测试人格宪法'),
    );

    final prepared = await service.prepareChatRequest();
    final events = await (await prepared!.openStream(messages))!.toList();

    expect(events.map((event) => event.kind), [
      ModelStreamEventKind.delta,
      ModelStreamEventKind.done,
    ]);
    expect(events.first.text, '嗯。');
  });
}

final class _FixedConfigRepository implements ProviderConfigRepository {
  _FixedConfigRepository(this.config);

  final ProviderConfig? config;

  @override
  Future<ProviderConfig?> load() async => config;

  @override
  Future<void> save(ProviderConfig config) async {
    throw UnimplementedError('回归测试不写配置');
  }
}

final class _NoSecretStore implements SecretStore {
  const _NoSecretStore();

  @override
  Future<void> deleteApiKey(String scope) async {}

  @override
  Future<String?> readApiKey(String scope) async => null;
}

final class _ScriptedHttpClient implements ProviderHttpClient {
  _ScriptedHttpClient({this.response, this.error});

  final ProviderHttpResponse? response;
  final Object? error;

  @override
  Future<ProviderHttpResponse> postStream({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
  }) async {
    if (error case final failure?) {
      throw failure;
    }
    return response!;
  }

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) async {
    throw UnimplementedError('回归测试只走流式出网');
  }
}

/// 只会整段完成的网关：模拟不支持流式协议的普通能力分支。
final class _CompleteOnlyGateway implements ModelGateway {
  const _CompleteOnlyGateway({required this.reply});

  final String reply;

  @override
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  }) async => reply;
}
