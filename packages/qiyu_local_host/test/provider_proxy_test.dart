import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  group('代理注入（DartIoProviderHttpClient）', () {
    test('公网目标带代理规则：工厂收到规则，findProxy 指向代理', () async {
      final created = <_FakeHttpClient>[];
      final client = DartIoProviderHttpClient(
        httpClientFactory: (proxyRules) {
          final fake = _FakeHttpClient()..observedRules = proxyRules;
          created.add(fake);
          return fake;
        },
        proxyRulesSource: () async =>
            const ProxyRules(host: 'proxy.lan', port: 7890),
      );

      await expectLater(
        client.postStream(
          uri: Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: const {'content-type': 'application/json'},
          body: '{}',
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<SocketException>()),
      );
      expect(created, hasLength(1));
      expect(created.single.observedRules, isNotNull);
      expect(
        created.single.findProxy!(
          Uri.parse('https://api.openai.com/v1/chat/completions'),
        ),
        'PROXY proxy.lan:7890',
      );
      // 假件不真连：请求失败后照常走关闭收尾。
      expect(created.single.closed, isTrue);
    });

    test('本机／私有网段目标摘除代理：工厂收到 null 规则', () async {
      final created = <_FakeHttpClient>[];
      final client = DartIoProviderHttpClient(
        httpClientFactory: (proxyRules) {
          final fake = _FakeHttpClient()..observedRules = proxyRules;
          created.add(fake);
          return fake;
        },
        proxyRulesSource: () async =>
            const ProxyRules(host: 'proxy.lan', port: 7890),
      );

      await expectLater(
        client.postStream(
          uri: Uri.parse('http://192.168.1.10:11434/api/chat'),
          headers: const {'content-type': 'application/json'},
          body: '{}',
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<SocketException>()),
      );
      expect(created.single.observedRules, isNull);
      expect(created.single.findProxy, isNull);
    });

    test('未装配代理来源的客户端即使有配置也恒直连', () async {
      final created = <_FakeHttpClient>[];
      final client = DartIoProviderHttpClient(
        httpClientFactory: (proxyRules) {
          final fake = _FakeHttpClient()..observedRules = proxyRules;
          created.add(fake);
          return fake;
        },
      );

      await expectLater(
        client.postStream(
          uri: Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: const {},
          body: '{}',
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<SocketException>()),
      );
      expect(created.single.observedRules, isNull);
      expect(created.single.findProxy, isNull);
    });
  });

  group('网关出网分叉（ProviderModelGateway）', () {
    test('OpenAI 兼容走代理通道，Ollama 恒走直连', () async {
      final direct = _RecordingHttpClient(responses: [
        ProviderHttpResponse(
          statusCode: 200,
          body: Stream.fromIterable([
            '{"message":{"role":"assistant","content":"好"},"done":true}\n',
          ]),
        ),
      ]);
      final proxied = _RecordingHttpClient(responses: [
        ProviderHttpResponse(
          statusCode: 200,
          body: Stream.fromIterable([
            'data: {"choices":[{"delta":{"content":"好"},"finish_reason":"stop"}]}\n\n',
          ]),
        ),
      ]);
      final gateway = ProviderModelGateway(
        direct,
        proxyHttpClient: proxied,
      );
      const messages = [
        ModelMessage(ModelMessageRole.system, '你是栖语。'),
        ModelMessage(ModelMessageRole.user, '在吗'),
      ];

      await gateway.complete(
        config: ProviderConfig(
          kind: ProviderKind.openAiCompatible,
          baseUrl: 'https://api.openai.com/v1',
          model: 'chat-model',
          temperature: 0.6,
          timeoutSeconds: 30,
        ),
        apiKey: 'test-key',
        messages: messages,
      );
      expect(proxied.uri.path, '/v1/chat/completions');
      expect(direct.requestCount, isZero);

      await gateway.complete(
        config: ProviderConfig(
          kind: ProviderKind.ollama,
          baseUrl: 'http://127.0.0.1:11434',
          model: 'chat-model',
          temperature: 0.6,
          timeoutSeconds: 30,
        ),
        apiKey: null,
        messages: messages,
      );
      expect(direct.uri.path, '/api/chat');
      expect(direct.headers.containsKey('authorization'), isFalse);
      expect(proxied.requestCount, 1);
    });

    test('未装配代理通道时全部直连（历史行为不变）', () async {
      final direct = _RecordingHttpClient(responses: [
        ProviderHttpResponse(
          statusCode: 200,
          body: Stream.fromIterable([
            'data: {"choices":[{"delta":{"content":"好"},"finish_reason":"stop"}]}\n\n',
          ]),
        ),
      ]);
      final gateway = ProviderModelGateway(direct);

      await gateway.complete(
        config: ProviderConfig(
          kind: ProviderKind.openAiCompatible,
          baseUrl: 'https://api.openai.com/v1',
          model: 'chat-model',
          temperature: 0.6,
          timeoutSeconds: 30,
        ),
        apiKey: 'test-key',
        messages: const [ModelMessage(ModelMessageRole.user, '在吗')],
      );
      expect(direct.requestCount, 1);
    });

    test('明文公网目标在网关出网前拒绝并给出人话', () async {
      final direct = _RecordingHttpClient(responses: [
        ProviderHttpResponse(statusCode: 200, body: const Stream.empty()),
      ]);
      final gateway = ProviderModelGateway(direct);

      // 公网 IP 字面量：文案点「改用 HTTPS」。
      final events = await gateway
          .stream(
            config: ProviderConfig(
              kind: ProviderKind.openAiCompatible,
              baseUrl: 'http://8.8.8.8/v1',
              model: 'chat-model',
              temperature: 0.6,
              timeoutSeconds: 30,
            ),
            apiKey: 'test-key',
            messages: const [ModelMessage(ModelMessageRole.user, '在吗')],
          )
          .toList();

      expect(events, hasLength(1));
      expect(events.single.kind, ModelStreamEventKind.failure);
      expect(events.single.failure, ModelFailureKind.network);
      expect(events.single.message, contains('私有网段'));
      // 请求绝不出网。
      expect(direct.requestCount, isZero);

      // 主机名形态：文案点「请直接填 IP」，不说「公网地址」。
      final hostnameEvents = await gateway
          .stream(
            config: ProviderConfig(
              kind: ProviderKind.openAiCompatible,
              baseUrl: 'http://api.example.com/v1',
              model: 'chat-model',
              temperature: 0.6,
              timeoutSeconds: 30,
            ),
            apiKey: 'test-key',
            messages: const [ModelMessage(ModelMessageRole.user, '在吗')],
          )
          .toList();
      expect(hostnameEvents.single.message, contains('填 IP 地址'));
      expect(hostnameEvents.single.message, isNot(contains('公网')));
      expect(direct.requestCount, isZero);
    });

    test('明文本机目标放行（Ollama 局域网部署）', () async {
      final direct = _RecordingHttpClient(responses: [
        ProviderHttpResponse(
          statusCode: 200,
          body: Stream.fromIterable([
            '{"message":{"role":"assistant","content":"在。"},"done":true}\n',
          ]),
        ),
      ]);
      final gateway = ProviderModelGateway(direct);

      await gateway.complete(
        config: ProviderConfig(
          kind: ProviderKind.ollama,
          baseUrl: 'http://192.168.1.10:11434',
          model: 'chat-model',
          temperature: 0.6,
          timeoutSeconds: 30,
        ),
        apiKey: null,
        messages: const [ModelMessage(ModelMessageRole.user, '在吗')],
      );
      expect(direct.uri.host, '192.168.1.10');
      expect(direct.requestCount, 1);
    });
  });

  group('代理设置服务与仓库', () {
    late Directory temporaryDirectory;
    late String configPath;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'qiyu-proxy-test-',
      );
      configPath =
          '${temporaryDirectory.path}${Platform.pathSeparator}provider.json';
    });

    tearDown(() async {
      if (temporaryDirectory.existsSync()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    ProxySettingsService service() => ProxySettingsService(
      JsonProviderConfigRepository(filePath: configPath),
    );

    test('保存即启用，loadRules 返回规则；关闭后回到直连', () async {
      final proxy = service();
      final saved = await proxy.save(enabled: true, host: 'proxy.lan', port: 7890);
      expect(saved.enabled, isTrue);
      expect(saved.configured, isTrue);
      expect(saved.host, 'proxy.lan');

      final rules = await proxy.loadRules();
      expect(rules, isNotNull);
      expect(rules!.port, 7890);

      await proxy.save(enabled: false, host: 'proxy.lan', port: 7890);
      expect(await proxy.loadRules(), isNull);
    });

    test('未配置时读取得到关闭态，loadRules 返回 null', () async {
      final proxy = service();
      final snapshot = await proxy.read();
      expect(snapshot.enabled, isFalse);
      expect(snapshot.host, isEmpty);
      expect(await proxy.loadRules(), isNull);
    });

    test('启用中的校验：地址必填、端口必填、拒绝带前缀与脏字符', () async {
      final proxy = service();
      await expectLater(
        proxy.save(enabled: true, host: '', port: 7890),
        throwsA(isA<ProviderConfigException>()),
      );
      await expectLater(
        proxy.save(enabled: true, host: 'proxy.lan', port: 0),
        throwsA(isA<ProviderConfigException>()),
      );
      await expectLater(
        proxy.save(enabled: true, host: 'http://proxy.lan', port: 7890),
        throwsA(isA<ProviderConfigException>()),
      );
      await expectLater(
        proxy.save(enabled: true, host: '代理.lan', port: 7890),
        throwsA(isA<ProviderConfigException>()),
      );
      // 端口有独立字段：「IP:端口」合写在地址里保存即拒，给出专属文案。
      await expectLater(
        proxy.save(enabled: true, host: '1.2.3.4:8080', port: 7890),
        throwsA(
          isA<ProviderConfigException>().having(
            (error) => error.message,
            'message',
            '代理地址请填主机名或 IP，端口单独填。',
          ),
        ),
      );
    });

    test('proxy 段段级保存：保留聊天与语音段，读不出的残缺段按未配置', () async {
      final repository = JsonProviderConfigRepository(filePath: configPath);
      final chat = ProviderConfig(
        kind: ProviderKind.openAiCompatible,
        baseUrl: 'https://api.openai.com/v1',
        model: 'chat-model',
        temperature: 0.6,
        timeoutSeconds: 30,
      );
      await repository.save(chat);
      final proxy = service();
      await proxy.save(enabled: true, host: 'proxy.lan', port: 7890);

      final stored =
          jsonDecode(await File(configPath).readAsString())
              as Map<String, Object?>;
      expect(stored['provider'], 'openai_compatible');
      expect((stored['proxy']! as Map)['host'], 'proxy.lan');
      expect(await repository.load(), isNotNull);

      // 手改文件把段写残：代理静默回关闭态，其余配置照常。
      await File(configPath).writeAsString(
        jsonEncode({
          ...stored,
          'proxy': {'enabled': true},
        }),
      );
      expect(await repository.loadProxy(), isNull);
      expect(await proxy.loadRules(), isNull);
      expect((await repository.load())!.baseUrl, chat.baseUrl);
    });
  });
}

/// 记录型 HttpClient 假件：不真连，观察代理决策与请求目标。
final class _FakeHttpClient implements HttpClient {
  ProxyRules? observedRules;
  String Function(Uri uri)? findProxy;
  @override
  Duration? connectionTimeout;
  bool closed = false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    if (invocation.isSetter && name.contains('findProxy')) {
      findProxy = invocation.positionalArguments.single as String Function(
        Uri uri,
      )?;
      return null;
    }
    if (invocation.isSetter && name.contains('connectionTimeout')) {
      connectionTimeout = invocation.positionalArguments.single as Duration?;
      return null;
    }
    if (invocation.isMethod && name.contains('close')) {
      closed = true;
      return Future<void>.value();
    }
    if (invocation.isMethod && name.contains('postUrl')) {
      throw const SocketException('测试假件不建立真实连接');
    }
    throw StateError('测试假件未实现该成员：$name');
  }
}

final class _RecordingHttpClient implements ProviderHttpClient {
  _RecordingHttpClient({required this.responses});

  /// 每次请求出队一份响应；队列耗尽后复用最后一份。
  final List<ProviderHttpResponse> responses;
  var requestCount = 0;
  late Uri uri;
  late Map<String, String> headers;

  @override
  Future<ProviderHttpResponse> postStream({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
  }) async {
    requestCount += 1;
    this.uri = uri;
    this.headers = headers;
    return responses.length > 1
        ? responses.removeAt(0)
        : responses.single;
  }

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) async {
    requestCount += 1;
    this.uri = uri;
    this.headers = headers;
    return responses.length > 1
        ? responses.removeAt(0)
        : responses.single;
  }
}
