import 'dart:convert';
import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late Directory webRoot;
  late Directory memoryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-local-host-test-',
    );
    webRoot = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}web',
    )..createSync();
    memoryDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}memories',
    );
    File(
      '${webRoot.path}${Platform.pathSeparator}index.html',
    ).writeAsStringSync(
      '<!doctype html><title>栖语</title><script src="flutter_bootstrap.js"></script>',
    );
    File(
      '${webRoot.path}${Platform.pathSeparator}flutter_bootstrap.js',
    ).writeAsStringSync('globalThis.qiyuLoaded = true;');
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'serves bundled Web assets on a random loopback port and releases it',
    () async {
      final host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        productSoul: '测试产品灵魂',
      );

      expect(host.address.address, InternetAddress.loopbackIPv4.address);
      expect(host.port, greaterThan(0));
      final client = HttpClient();
      final response = await (await client.getUrl(host.origin)).close();
      final body = await response.transform(utf8.decoder).join();
      client.close(force: true);

      expect(response.statusCode, HttpStatus.ok);
      expect(body, contains('<title>栖语</title>'));
      expect(body, isNot(contains(RegExp(r'<(?:script|link)[^>]+https?://'))));
      final contentSecurityPolicy = response.headers.value(
        'content-security-policy',
      );
      expect(contentSecurityPolicy, contains("'wasm-unsafe-eval'"));
      expect(contentSecurityPolicy, isNot(contains(" 'unsafe-eval'")));

      final releasedPort = host.port;
      await host.close();
      final rebound = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        releasedPort,
      );
      await rebound.close();
    },
  );

  test(
    'issues a host-lifetime browser session and rejects invalid API sources',
    () async {
      final host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        productSoul: '测试产品灵魂',
      );

      final sessionStart = await _send(host.launchUri);
      expect(sessionStart.statusCode, HttpStatus.seeOther);
      expect(sessionStart.headers.value(HttpHeaders.locationHeader), '/');
      final setCookie =
          sessionStart.headers[HttpHeaders.setCookieHeader]!.single;
      final cookie = setCookie.split(';').first;
      expect(cookie, startsWith('qiyu_session='));
      expect(
        setCookie,
        allOf(contains('HttpOnly'), contains('SameSite=Strict')),
      );

      final bootstrap = await _send(
        host.origin.resolve('/api/bootstrap'),
        headers: {
          HttpHeaders.cookieHeader: cookie,
          HttpHeaders.refererHeader: host.origin.toString(),
        },
      );
      expect(bootstrap.statusCode, HttpStatus.ok);
      final bootstrapJson = jsonDecode(bootstrap.body) as Map<String, Object?>;
      final csrfToken = bootstrapJson['csrfToken']! as String;
      expect(csrfToken, isNotEmpty);

      final missingSession = await _send(
        host.origin.resolve('/api/bootstrap'),
        headers: {HttpHeaders.refererHeader: host.origin.toString()},
      );
      expect(missingSession.statusCode, HttpStatus.unauthorized);

      final badOrigin = await _send(
        host.origin.resolve('/api/bootstrap'),
        headers: {
          HttpHeaders.cookieHeader: cookie,
          'origin': 'https://evil.example',
        },
      );
      expect(badOrigin.statusCode, HttpStatus.forbidden);

      final badHost = await _send(
        host.origin.resolve('/api/bootstrap'),
        hostOverride: 'evil.example',
        headers: {
          HttpHeaders.cookieHeader: cookie,
          HttpHeaders.refererHeader: host.origin.toString(),
        },
      );
      expect(badHost.statusCode, HttpStatus.forbidden);

      final missingCsrf = await _send(
        host.origin.resolve('/api/session/verify'),
        method: 'POST',
        headers: {
          HttpHeaders.cookieHeader: cookie,
          'origin': host.origin.toString().replaceFirst(RegExp(r'/$'), ''),
        },
      );
      expect(missingCsrf.statusCode, HttpStatus.forbidden);

      final acceptedMutation = await _send(
        host.origin.resolve('/api/session/verify'),
        method: 'POST',
        headers: {
          HttpHeaders.cookieHeader: cookie,
          'origin': host.origin.toString().replaceFirst(RegExp(r'/$'), ''),
          'x-qiyu-csrf': csrfToken,
        },
      );
      expect(acceptedMutation.statusCode, HttpStatus.noContent);

      final oldLaunchUri = host.launchUri;
      await host.close();
      final restartedHost = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        productSoul: '测试产品灵魂',
      );
      final oldSession = await _send(
        restartedHost.origin.resolve('/api/bootstrap'),
        headers: {
          HttpHeaders.cookieHeader: cookie,
          HttpHeaders.refererHeader: restartedHost.origin.toString(),
        },
      );
      expect(oldSession.statusCode, HttpStatus.unauthorized);
      final oldStartupCredential = await _send(
        restartedHost.origin.replace(
          path: oldLaunchUri.path,
          query: oldLaunchUri.query,
        ),
      );
      expect(oldStartupCredential.statusCode, HttpStatus.unauthorized);
      await restartedHost.close();
    },
  );

  test(
    'startup URL 只能兑换一次会话，兑换后旧凭据失效',
    () async {
      final host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        productSoul: '测试产品灵魂',
      );

      final originalUri = host.launchUri;
      final firstStart = await _send(originalUri);
      expect(firstStart.statusCode, HttpStatus.seeOther);

      final replay = await _send(originalUri);
      expect(replay.statusCode, HttpStatus.unauthorized);

      await host.close();
    },
  );

  test(
    '拒绝超过 64KB 的 chunked 聊天请求体与非对象 JSON',
    () async {
      final host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        productSoul: '测试产品灵魂',
      );
      final session = await _openBrowserSession(host);

      final client = HttpClient();
      final oversizeRequest = await client.openUrl(
        'POST',
        host.origin.resolve('/api/chat'),
      );
      session
          .mutationHeaders(host.origin)
          .forEach(oversizeRequest.headers.set);
      // 不设置 contentLength，让客户端走 chunked 传输编码。
      oversizeRequest.add(
        utf8.encode(
          jsonEncode({
            'requestId': 'oversize-test',
            'text': '长' * (70 * 1024),
          }),
        ),
      );
      try {
        final oversizeResponse = await oversizeRequest.close();
        final oversizeBody = await oversizeResponse
            .transform(utf8.decoder)
            .join();
        expect(oversizeResponse.statusCode, HttpStatus.badRequest);
        expect(oversizeBody, contains('invalid_request'));
      } on SocketException {
        // 服务器在超限时提前中止连接，客户端收到连接重置同样是拒绝。
      } on HttpException {
        // 中止时机不同时客户端也可能报 header 未收全，同样属于拒绝。
      }

      // 被拒后服务依然健康：正常大小的请求照常处理。
      final healthyRequest = await client.openUrl(
        'POST',
        host.origin.resolve('/api/session/verify'),
      );
      session.mutationHeaders(host.origin).forEach(healthyRequest.headers.set);
      final healthyResponse = await healthyRequest.close();
      expect(healthyResponse.statusCode, HttpStatus.noContent);

      final nonObjectRequest = await client.openUrl(
        'POST',
        host.origin.resolve('/api/chat'),
      );
      session.mutationHeaders(host.origin).forEach(nonObjectRequest.headers.set);
      nonObjectRequest.add(utf8.encode('[1,2,3]'));
      final nonObjectResponse = await nonObjectRequest.close();
      final nonObjectBody = await nonObjectResponse
          .transform(utf8.decoder)
          .join();
      expect(nonObjectResponse.statusCode, HttpStatus.badRequest);
      expect(nonObjectBody, contains('invalid_request'));

      client.close(force: true);
      await host.close();
    },
  );

  test(
    'sends, persists, restarts, and restores one local chat exactly once',
    () async {
      final host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        productSoul: '测试产品灵魂',
      );
      final firstSession = await _openBrowserSession(host);
      final firstChat = await _send(
        host.origin.resolve('/api/chat'),
        method: 'POST',
        headers: firstSession.mutationHeaders(host.origin),
        requestBody: jsonEncode({'requestId': 'restart-1', 'text': '今天有点累'}),
      );

      expect(firstChat.statusCode, HttpStatus.ok);
      final firstEvents = _chatEvents(firstChat.body);
      expect(_chatEvent(firstEvents, 'state')['source'], 'local');
      expect(
        _chatEvent(firstEvents, 'state')['fallbackReason'],
        'no_llm_config',
      );
      expect(_chatEvent(firstEvents, 'message')['messages'], ['咋了']);
      final sessionId =
          _chatEvent(firstEvents, 'accepted')['sessionId']! as String;
      await host.close();

      final markdownFiles = memoryDirectory
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.md'))
          .toList();
      expect(markdownFiles, hasLength(1));
      final markdown = await markdownFiles.single.readAsString();
      expect(markdown.indexOf('今天有点累'), lessThan(markdown.indexOf('咋了')));

      final restarted = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        productSoul: '测试产品灵魂',
      );
      final restartedSession = await _openBrowserSession(restarted);
      final restored = await _send(
        restarted.origin.resolve('/api/chat/session?sessionId=$sessionId'),
        headers: restartedSession.readHeaders(restarted.origin),
      );
      expect(restored.statusCode, HttpStatus.ok);
      final restoredJson = jsonDecode(restored.body) as Map<String, Object?>;
      expect(restoredJson['sessionId'], sessionId);
      expect(restoredJson['turns'], hasLength(2));

      final replay = await _send(
        restarted.origin.resolve('/api/chat'),
        method: 'POST',
        headers: restartedSession.mutationHeaders(restarted.origin),
        requestBody: jsonEncode({
          'requestId': 'restart-1',
          'sessionId': sessionId,
          'text': '今天有点累',
        }),
      );
      expect(replay.statusCode, HttpStatus.ok);
      expect(_chatEvent(_chatEvents(replay.body), 'message')['messages'], [
        '咋了',
      ]);

      final restoredAgain = await _send(
        restarted.origin.resolve('/api/chat/session?sessionId=$sessionId'),
        headers: restartedSession.readHeaders(restarted.origin),
      );
      final restoredAgainJson =
          jsonDecode(restoredAgain.body) as Map<String, Object?>;
      expect(restoredAgainJson['turns'], hasLength(2));
      await restarted.close();
    },
  );

  test(
    'persists Provider settings, masks Key, tests it, and uses model chat',
    () async {
      final configPath =
          '${temporaryDirectory.path}${Platform.pathSeparator}provider.json';
      final secrets = _MemorySecretStore();
      final gateway = _StaticModelGateway('还没睡？');
      ProviderSettingsService settingsService() => ProviderSettingsService(
        JsonProviderConfigRepository(filePath: configPath),
        secrets,
        gateway,
        const ModelPromptBuilder('测试产品灵魂'),
      );
      var host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        productSoul: '测试产品灵魂',
        providerSettingsService: settingsService(),
      );
      var browser = await _openBrowserSession(host);

      final saved = await _send(
        host.origin.resolve('/api/provider'),
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({
          'provider': 'openai_compatible',
          'baseUrl': 'https://example.com/v1',
          'model': 'chat-model',
          'temperature': 0.6,
          'timeoutSeconds': 25,
          'apiKey': 'private-test-value',
        }),
      );
      expect(saved.statusCode, HttpStatus.ok);
      expect(saved.body, isNot(contains('private-test-value')));
      expect(jsonDecode(saved.body), containsPair('keySet', true));

      final tested = await _send(
        host.origin.resolve('/api/provider/test'),
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: '{}',
      );
      expect(tested.statusCode, HttpStatus.ok);
      expect(jsonDecode(tested.body), containsPair('status', 'success'));
      await host.close();

      host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        productSoul: '测试产品灵魂',
        providerSettingsService: settingsService(),
      );
      browser = await _openBrowserSession(host);
      final restored = await _send(
        host.origin.resolve('/api/provider'),
        headers: browser.readHeaders(host.origin),
      );
      expect(restored.body, isNot(contains('private-test-value')));
      expect(
        jsonDecode(restored.body),
        allOf(
          containsPair('configured', true),
          containsPair('keySet', true),
          containsPair('model', 'chat-model'),
        ),
      );

      final chat = await _send(
        host.origin.resolve('/api/chat'),
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'requestId': 'provider-chat', 'text': '在吗'}),
      );
      final chatEvents = _chatEvents(chat.body);
      expect(_chatEvent(chatEvents, 'message')['messages'], ['还没睡？']);
      expect(_chatEvent(chatEvents, 'state')['source'], 'llm');
      expect(gateway.apiKey, 'private-test-value');
      await host.close();
    },
  );

  test('chat API exposes only a diagnostic fallback category', () async {
    final configPath =
        '${temporaryDirectory.path}${Platform.pathSeparator}provider.json';
    final secrets = _MemorySecretStore();
    final settings = ProviderSettingsService(
      JsonProviderConfigRepository(filePath: configPath),
      secrets,
      const _FailingModelGateway(ModelFailureKind.timeout),
      const ModelPromptBuilder('测试产品灵魂'),
    );
    await settings.save(
      config: ProviderConfig(
        kind: ProviderKind.openAiCompatible,
        baseUrl: 'https://example.com/v1',
        model: 'chat-model',
        temperature: 0.6,
        timeoutSeconds: 25,
      ),
      apiKey: 'host-test-secret-value',
    );
    final host = await LocalAppHost.start(
      webRoot: webRoot.path,
      memoryDirectory: memoryDirectory.path,
      productSoul: '测试产品灵魂',
      providerSettingsService: settings,
    );
    final browser = await _openBrowserSession(host);

    final response = await _send(
      host.origin.resolve('/api/chat'),
      method: 'POST',
      headers: browser.mutationHeaders(host.origin),
      requestBody: jsonEncode({
        'requestId': 'diagnostic-timeout',
        'text': 'API Key: host-test-secret-value 今天有点累',
      }),
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(
      _chatEvent(_chatEvents(response.body), 'fallback'),
      containsPair('fallbackReason', 'model_timeout'),
    );
    expect(response.body, isNot(contains('已脱敏的测试错误')));
    expect(response.body, isNot(contains('Authorization')));
    await host.close();
  });

  test(
    'history API lists by local day, survives restart, and deletes with CSRF',
    () async {
      var host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        productSoul: '测试产品灵魂',
      );
      var browser = await _openBrowserSession(host);
      final chat = await _send(
        host.origin.resolve('/api/chat'),
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({
          'requestId': 'history-1',
          'text': '今天有点累',
        }),
      );
      final sessionId =
          _chatEvent(_chatEvents(chat.body), 'accepted')['sessionId']!
              as String;

      final history = await _send(
        host.origin.resolve('/api/history'),
        headers: browser.readHeaders(host.origin),
      );
      expect(history.statusCode, HttpStatus.ok);
      final historyJson = jsonDecode(history.body) as Map<String, Object?>;
      expect(historyJson['latestSessionId'], sessionId);
      final days = historyJson['days']! as List<Object?>;
      expect(days, hasLength(1));
      final day = days.single! as Map<String, Object?>;
      expect(day['date'], localSessionDate(DateTime.now()));
      final sessions = day['sessions']! as List<Object?>;
      final summary = sessions.single! as Map<String, Object?>;
      expect(summary['sessionId'], sessionId);
      expect(summary['turnCount'], 2);
      expect(summary['preview'], '今天有点累');
      expect(historyJson['unavailable'], isEmpty);

      final markdownFile = memoryDirectory
          .listSync(recursive: true)
          .whereType<File>()
          .singleWhere((file) => file.path.endsWith('.md'));
      final markdownBefore = await markdownFile.readAsString();
      final browsed = await _send(
        host.origin.resolve('/api/chat/session?sessionId=$sessionId'),
        headers: browser.readHeaders(host.origin),
      );
      expect(browsed.statusCode, HttpStatus.ok);
      expect(
        (jsonDecode(browsed.body) as Map<String, Object?>)['turns'],
        hasLength(2),
      );
      expect(await markdownFile.readAsString(), markdownBefore);
      await host.close();

      host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        productSoul: '测试产品灵魂',
      );
      browser = await _openBrowserSession(host);
      final afterRestart = await _send(
        host.origin.resolve('/api/history'),
        headers: browser.readHeaders(host.origin),
      );
      expect(afterRestart.statusCode, HttpStatus.ok);
      final afterRestartJson =
          jsonDecode(afterRestart.body) as Map<String, Object?>;
      expect(afterRestartJson['latestSessionId'], sessionId);

      final missingCsrf = await _send(
        host.origin.resolve('/api/history/sessions/$sessionId'),
        method: 'DELETE',
        headers: {
          ...browser.readHeaders(host.origin),
          'origin': host.origin.toString().replaceFirst(RegExp(r'/$'), ''),
        },
      );
      expect(missingCsrf.statusCode, HttpStatus.forbidden);

      final invalidId = await _send(
        host.origin.resolve('/api/history/sessions/not:valid'),
        method: 'DELETE',
        headers: browser.mutationHeaders(host.origin),
      );
      expect(invalidId.statusCode, HttpStatus.badRequest);

      final deleted = await _send(
        host.origin.resolve('/api/history/sessions/$sessionId'),
        method: 'DELETE',
        headers: browser.mutationHeaders(host.origin),
      );
      expect(deleted.statusCode, HttpStatus.ok);
      expect(jsonDecode(deleted.body), {'deleted': true});
      expect(
        memoryDirectory
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.md')),
        isEmpty,
      );

      final emptyHistory = await _send(
        host.origin.resolve('/api/history'),
        headers: browser.readHeaders(host.origin),
      );
      final emptyHistoryJson =
          jsonDecode(emptyHistory.body) as Map<String, Object?>;
      expect(emptyHistoryJson['days'], isEmpty);
      expect(emptyHistoryJson.containsKey('latestSessionId'), isFalse);

      final freshRestore = await _send(
        host.origin.resolve('/api/chat/session'),
        headers: browser.readHeaders(host.origin),
      );
      final freshSessionId =
          (jsonDecode(freshRestore.body) as Map<String, Object?>)['sessionId']
              as String;
      expect(freshSessionId, isNot(sessionId));

      final deletedAgain = await _send(
        host.origin.resolve('/api/history/sessions/$sessionId'),
        method: 'DELETE',
        headers: browser.mutationHeaders(host.origin),
      );
      expect(deletedAgain.statusCode, HttpStatus.notFound);
      await host.close();
    },
  );

  test(
    'an unreadable session file is reported without blocking browsing, chat, or deletion',
    () async {
      final host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        productSoul: '测试产品灵魂',
      );
      final browser = await _openBrowserSession(host);
      final chat = await _send(
        host.origin.resolve('/api/chat'),
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'requestId': 'corrupt-1', 'text': '在吗'}),
      );
      final sessionId =
          _chatEvent(_chatEvents(chat.body), 'accepted')['sessionId']!
              as String;
      final today = localSessionDate(DateTime.now());
      final corruptFile = File(
        '${memoryDirectory.path}${Platform.pathSeparator}sessions'
        '${Platform.pathSeparator}${today.substring(0, 4)}'
        '${Platform.pathSeparator}${today.substring(5, 7)}'
        '${Platform.pathSeparator}$today-002.md',
      );
      await corruptFile.writeAsString('# 不是有效的栖语会话');

      final history = await _send(
        host.origin.resolve('/api/history'),
        headers: browser.readHeaders(host.origin),
      );
      final historyJson = jsonDecode(history.body) as Map<String, Object?>;
      expect(historyJson['latestSessionId'], sessionId);
      final days = historyJson['days']! as List<Object?>;
      final daySessions =
          (days.single! as Map<String, Object?>)['sessions']! as List<Object?>;
      expect(
        daySessions.map(
          (session) =>
              (session! as Map<String, Object?>)['sessionId'] as String,
        ),
        [sessionId],
      );
      final unavailable = historyJson['unavailable']! as List<Object?>;
      final entry = unavailable.single! as Map<String, Object?>;
      expect(entry['name'], '$today-002.md');
      expect(entry['message']! as String, contains('无法读取'));

      final fullText = await _send(
        host.origin.resolve('/api/chat/session?sessionId=$sessionId'),
        headers: browser.readHeaders(host.origin),
      );
      expect(fullText.statusCode, HttpStatus.ok);

      final continued = await _send(
        host.origin.resolve('/api/chat'),
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({
          'requestId': 'corrupt-2',
          'sessionId': sessionId,
          'text': '还想再说一句',
        }),
      );
      expect(continued.statusCode, HttpStatus.ok);
      expect(
        _chatEvent(_chatEvents(continued.body), 'accepted')['sessionId'],
        sessionId,
      );

      final deleted = await _send(
        host.origin.resolve('/api/history/sessions/$sessionId'),
        method: 'DELETE',
        headers: browser.mutationHeaders(host.origin),
      );
      expect(deleted.statusCode, HttpStatus.ok);
      expect(await corruptFile.exists(), isTrue);
      expect(await corruptFile.readAsString(), '# 不是有效的栖语会话');
      await host.close();
    },
  );

  test(
    'onboarding starts open, persists completion across restarts, and reopens after clearing local data',
    () async {
      var host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        productSoul: '测试产品灵魂',
      );
      var browser = await _openBrowserSession(host);

      final fresh = await _send(
        host.origin.resolve('/api/onboarding'),
        headers: browser.readHeaders(host.origin),
      );
      expect(fresh.statusCode, HttpStatus.ok);
      expect(jsonDecode(fresh.body), {'completed': false});

      final missingCsrf = await _send(
        host.origin.resolve('/api/onboarding/complete'),
        method: 'POST',
        headers: {
          ...browser.readHeaders(host.origin),
          'origin': host.origin.toString().replaceFirst(RegExp(r'/$'), ''),
        },
      );
      expect(missingCsrf.statusCode, HttpStatus.forbidden);

      final completed = await _send(
        host.origin.resolve('/api/onboarding/complete'),
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: '{}',
      );
      expect(completed.statusCode, HttpStatus.ok);
      expect(jsonDecode(completed.body), {'completed': true});
      final onboardingFile = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}onboarding.json',
      );
      expect(await onboardingFile.exists(), isTrue);
      await host.close();

      host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        productSoul: '测试产品灵魂',
      );
      browser = await _openBrowserSession(host);
      final afterRestart = await _send(
        host.origin.resolve('/api/onboarding'),
        headers: browser.readHeaders(host.origin),
      );
      expect(jsonDecode(afterRestart.body), {'completed': true});
      await host.close();

      await onboardingFile.writeAsString('不是有效的 JSON');
      host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        productSoul: '测试产品灵魂',
      );
      browser = await _openBrowserSession(host);
      final afterCorruption = await _send(
        host.origin.resolve('/api/onboarding'),
        headers: browser.readHeaders(host.origin),
      );
      expect(jsonDecode(afterCorruption.body), {'completed': false});
      await host.close();

      await onboardingFile.delete();
      host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        productSoul: '测试产品灵魂',
      );
      browser = await _openBrowserSession(host);
      final afterClear = await _send(
        host.origin.resolve('/api/onboarding'),
        headers: browser.readHeaders(host.origin),
      );
      expect(jsonDecode(afterClear.body), {'completed': false});
      await host.close();
    },
  );
}

List<Map<String, Object?>> _chatEvents(String body) => body
    .split('\n')
    .where((line) => line.trim().isNotEmpty)
    .map((line) => jsonDecode(line) as Map<String, Object?>)
    .toList(growable: false);

Map<String, Object?> _chatEvent(
  List<Map<String, Object?>> events,
  String kind,
) => events.singleWhere((event) => event['event'] == kind);

Future<_HttpResponse> _send(
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const {},
  String? hostOverride,
  String? requestBody,
}) async {
  final client = HttpClient();
  final request = await client.openUrl(method, uri);
  request.followRedirects = false;
  if (hostOverride != null) {
    request.headers.host = hostOverride;
  }
  headers.forEach(request.headers.set);
  if (requestBody != null) {
    request.add(utf8.encode(requestBody));
  }
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  final result = _HttpResponse(response.statusCode, response.headers, body);
  client.close(force: true);
  return result;
}

Future<_BrowserSession> _openBrowserSession(LocalAppHost host) async {
  final sessionStart = await _send(host.launchUri);
  final cookie = sessionStart.headers[HttpHeaders.setCookieHeader]!.single
      .split(';')
      .first;
  final bootstrap = await _send(
    host.origin.resolve('/api/bootstrap'),
    headers: {
      HttpHeaders.cookieHeader: cookie,
      HttpHeaders.refererHeader: host.origin.toString(),
    },
  );
  final bootstrapJson = jsonDecode(bootstrap.body) as Map<String, Object?>;
  return _BrowserSession(cookie, bootstrapJson['csrfToken']! as String);
}

final class _BrowserSession {
  const _BrowserSession(this.cookie, this.csrfToken);

  final String cookie;
  final String csrfToken;

  Map<String, String> readHeaders(Uri origin) => {
    HttpHeaders.cookieHeader: cookie,
    HttpHeaders.refererHeader: origin.toString(),
  };

  Map<String, String> mutationHeaders(Uri origin) => {
    ...readHeaders(origin),
    'origin': origin.toString().replaceFirst(RegExp(r'/$'), ''),
    'x-qiyu-csrf': csrfToken,
    HttpHeaders.contentTypeHeader: 'application/json',
  };
}

final class _HttpResponse {
  const _HttpResponse(this.statusCode, this.headers, this.body);

  final int statusCode;
  final HttpHeaders headers;
  final String body;
}

final class _MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> deleteApiKey(String scope) async => values.remove(scope);

  @override
  Future<String?> readApiKey(String scope) async => values[scope];

  @override
  Future<void> writeApiKey(String scope, String value) async {
    values[scope] = value;
  }
}

final class _StaticModelGateway implements ModelGateway {
  _StaticModelGateway(this.reply);

  final String reply;
  String? apiKey;

  @override
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
  }) async {
    this.apiKey = apiKey;
    return reply;
  }
}

final class _FailingModelGateway implements ModelGateway {
  const _FailingModelGateway(this.kind);

  final ModelFailureKind kind;

  @override
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
  }) {
    throw ModelGatewayException(kind: kind, message: '已脱敏的测试错误');
  }
}
