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
        personaConstitution: '测试人格宪法',
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
      expect(contentSecurityPolicy, contains("frame-ancestors 'none'"));
      expect(response.headers.value('x-frame-options'), 'DENY');

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
        personaConstitution: '测试人格宪法',
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
        personaConstitution: '测试人格宪法',
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

  test('startup URL 只能兑换一次会话，兑换后旧凭据失效', () async {
    final host = await LocalAppHost.start(
      webRoot: webRoot.path,
      memoryDirectory: memoryDirectory.path,
      personaConstitution: '测试人格宪法',
    );

    final originalUri = host.launchUri;
    final firstStart = await _send(originalUri);
    expect(firstStart.statusCode, HttpStatus.seeOther);

    final replay = await _send(originalUri);
    expect(replay.statusCode, HttpStatus.unauthorized);

    await host.close();
  });

  test('拒绝超过 64KB 的 chunked 聊天请求体与非对象 JSON', () async {
    final host = await LocalAppHost.start(
      webRoot: webRoot.path,
      memoryDirectory: memoryDirectory.path,
      personaConstitution: '测试人格宪法',
    );
    final session = await _openBrowserSession(host);

    final client = HttpClient();
    final oversizeRequest = await client.openUrl(
      'POST',
      host.origin.resolve('/api/chat'),
    );
    session.mutationHeaders(host.origin).forEach(oversizeRequest.headers.set);
    // 不设置 contentLength，让客户端走 chunked 传输编码。
    oversizeRequest.add(
      utf8.encode(
        jsonEncode({'requestId': 'oversize-test', 'text': '长' * (70 * 1024)}),
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
  });

  test(
    'sends, persists, restarts, and restores one local chat exactly once',
    () async {
      final host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        personaConstitution: '测试人格宪法',
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

      // recovery/ 是启动恢复扫描的诊断区（ticket 21），不属于会话持久化。
      final markdownFiles = memoryDirectory
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (file) =>
                file.path.endsWith('.md') &&
                !file.path.contains(
                  '${Platform.pathSeparator}recovery${Platform.pathSeparator}',
                ),
          )
          .toList();
      expect(markdownFiles, hasLength(1));
      final markdown = await markdownFiles.single.readAsString();
      expect(markdown.indexOf('今天有点累'), lessThan(markdown.indexOf('咋了')));

      final restarted = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        personaConstitution: '测试人格宪法',
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
        const ModelPromptBuilder('测试人格宪法'),
      );
      var host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        personaConstitution: '测试人格宪法',
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
        personaConstitution: '测试人格宪法',
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
      const ModelPromptBuilder('测试人格宪法'),
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
      personaConstitution: '测试人格宪法',
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
        personaConstitution: '测试人格宪法',
      );
      var browser = await _openBrowserSession(host);
      final chat = await _send(
        host.origin.resolve('/api/chat'),
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'requestId': 'history-1', 'text': '今天有点累'}),
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

      // recovery/ 是启动恢复扫描的诊断区（ticket 21），不属于会话持久化。
      final markdownFile = memoryDirectory
          .listSync(recursive: true)
          .whereType<File>()
          .singleWhere(
            (file) =>
                file.path.endsWith('.md') &&
                !file.path.contains(
                  '${Platform.pathSeparator}recovery${Platform.pathSeparator}',
                ),
          );
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
        personaConstitution: '测试人格宪法',
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
            .where(
              (file) =>
                  file.path.endsWith('.md') &&
                  !file.path.contains(
                    '${Platform.pathSeparator}recovery${Platform.pathSeparator}',
                  ),
            ),
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
        personaConstitution: '测试人格宪法',
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
        personaConstitution: '测试人格宪法',
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
        personaConstitution: '测试人格宪法',
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
        personaConstitution: '测试人格宪法',
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
        personaConstitution: '测试人格宪法',
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

  test(
    'memory center endpoints serve the four read-only sections over HTTP',
    () async {
      final host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        personaConstitution: '测试人格宪法',
      );
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: memoryDirectory.path,
      );
      final today = localSessionDate(DateTime.now());
      final date = DateTime.parse(today);
      await pipeline.synchronizedOnDayFiles(
        () => pipeline.writeFinalization(
          today,
          entries: [
            EpisodeEntry(
              id: 's1:r1:0',
              sessionId: 'seed-session',
              requestId: 'seed',
              summary: '用户说这周在准备演讲',
              evidence: '周四有个演讲',
              at: date.add(const Duration(hours: 20)).toUtc(),
            ),
          ],
          summary: '聊了演讲准备',
          finalized: true,
          finalizedAt: date.add(const Duration(hours: 23)).toUtc(),
        ),
      );
      File(
        '${memoryDirectory.path}${Platform.pathSeparator}long-memory.md',
      ).writeAsStringSync('# long-memory\n\n## 人与关系\n- 用户和家人关系亲近\n');
      final browser = await _openBrowserSession(host);

      final missingSession = await _send(host.origin.resolve('/api/memory'));
      expect(missingSession.statusCode, HttpStatus.unauthorized);

      final overviewResponse = await _send(
        host.origin.resolve('/api/memory'),
        headers: browser.readHeaders(host.origin),
      );
      expect(overviewResponse.statusCode, HttpStatus.ok);
      final overview =
          jsonDecode(overviewResponse.body) as Map<String, Object?>;
      for (final section in ['recent', 'longTerm', 'persona', 'relationship']) {
        expect(overview[section], isA<Map<String, Object?>>(), reason: section);
      }
      final days =
          (overview['recent']! as Map<String, Object?>)['days']!
              as List<Object?>;
      final day = days.single! as Map<String, Object?>;
      expect(day['date'], today);
      final dayId = day['id']! as String;
      // opaque ID 不暴露文件路径。
      expect(dayId, isNot(contains('/')));
      expect(dayId, isNot(contains('episodes')));

      final unknownItem = await _send(
        host.origin.resolve('/api/memory/items/no-such-id'),
        headers: browser.readHeaders(host.origin),
      );
      expect(unknownItem.statusCode, HttpStatus.notFound);
      expect(
        (jsonDecode(unknownItem.body) as Map<String, Object?>)['code'],
        'memory_item_not_found',
      );

      final dayResponse = await _send(
        host.origin.resolve('/api/memory/items/$dayId'),
        headers: browser.readHeaders(host.origin),
      );
      expect(dayResponse.statusCode, HttpStatus.ok);
      final dayDetail = jsonDecode(dayResponse.body) as Map<String, Object?>;
      expect(dayDetail['kind'], 'day');
      expect(dayDetail['date'], today);
      final entries = dayDetail['entries']! as List<Object?>;
      final entry = entries.single! as Map<String, Object?>;
      expect(entry['content'], '用户说这周在准备演讲');

      final entryResponse = await _send(
        host.origin.resolve('/api/memory/items/${entry['id']}'),
        headers: browser.readHeaders(host.origin),
      );
      expect(entryResponse.statusCode, HttpStatus.ok);
      final entryDetail =
          jsonDecode(entryResponse.body) as Map<String, Object?>;
      expect(entryDetail['kind'], 'episode-entry');
      expect(entryDetail['evidence'], '周四有个演讲');
      expect(entryDetail['sessionId'], 'seed-session');

      // 只读红线：整轮浏览不改动记忆目录里的任何文件。
      final filesBefore = {
        for (final file
            in memoryDirectory.listSync(recursive: true).whereType<File>())
          file.path: file.readAsStringSync(),
      };
      await _send(
        host.origin.resolve('/api/memory'),
        headers: browser.readHeaders(host.origin),
      );
      await _send(
        host.origin.resolve('/api/memory/items/$dayId'),
        headers: browser.readHeaders(host.origin),
      );
      final filesAfter = {
        for (final file
            in memoryDirectory.listSync(recursive: true).whereType<File>())
          file.path: file.readAsStringSync(),
      };
      expect(filesAfter, filesBefore);
      await host.close();
    },
  );

  test(
    'memory action endpoint edits, controls, deletes and reveals over HTTP',
    () async {
      final host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        personaConstitution: '测试人格宪法',
      );
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: memoryDirectory.path,
      );
      final today = localSessionDate(DateTime.now());
      final date = DateTime.parse(today);
      await pipeline.synchronizedOnDayFiles(
        () => pipeline.writeFinalization(
          today,
          entries: [
            EpisodeEntry(
              id: 's1:r1:0',
              sessionId: 'seed-session',
              requestId: 'seed',
              summary: '用户的手机号是13812345678',
              at: date.add(const Duration(hours: 20)).toUtc(),
            ),
            EpisodeEntry(
              id: 's1:r1:1',
              sessionId: 'seed-session',
              requestId: 'seed',
              summary: '用户在准备演讲',
              evidence: '周四有个演讲',
              at: date.add(const Duration(hours: 21)).toUtc(),
            ),
          ],
          summary: '聊了近况',
          finalized: true,
          finalizedAt: date.add(const Duration(hours: 23)).toUtc(),
        ),
      );
      File(
        '${memoryDirectory.path}${Platform.pathSeparator}long-memory.md',
      ).writeAsStringSync('# long-memory\n\n## 人与关系\n- 用户养了一只猫\n');
      final browser = await _openBrowserSession(host);
      final actionUri = host.origin.resolve('/api/memory/action');

      // 变更请求缺 CSRF 一律拒绝。
      final noCsrf = await _send(
        actionUri,
        method: 'POST',
        headers: browser.readHeaders(host.origin),
        requestBody: jsonEncode({'action': 'freeze', 'id': 'whatever'}),
      );
      expect(noCsrf.statusCode, HttpStatus.forbidden);

      // 未知 opaque ID → 404。
      final unknown = await _send(
        actionUri,
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'action': 'freeze', 'id': 'no-such-id'}),
      );
      expect(unknown.statusCode, HttpStatus.notFound);

      Future<Map<String, Object?>> overviewJson() async {
        final response = await _send(
          host.origin.resolve('/api/memory'),
          headers: browser.readHeaders(host.origin),
        );
        return jsonDecode(response.body) as Map<String, Object?>;
      }

      Map<String, Object?> entryById(
        Map<String, Object?> overview,
        String content,
      ) {
        final days =
            (overview['recent']! as Map<String, Object?>)['days']!
                as List<Object?>;
        for (final day in days) {
          for (final entry
              in (day! as Map<String, Object?>)['entries']! as List<Object?>) {
            final map = entry! as Map<String, Object?>;
            if (map['content'] == content) {
              return map;
            }
          }
        }
        fail('entry not found in overview: $content');
      }

      // 编辑 episode：修正按用户声明保存，摘录移除。
      final beforeEdit = await overviewJson();
      final editTarget = entryById(beforeEdit, '用户在准备演讲');
      final editResponse = await _send(
        actionUri,
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({
          'action': 'edit',
          'id': editTarget['id'],
          'text': '用户在准备一场辩论赛',
        }),
      );
      expect(editResponse.statusCode, HttpStatus.ok);
      final edited = await overviewJson();
      final editedEntry = entryById(edited, '用户在准备一场辩论赛');
      expect(editedEntry['userEdited'], isTrue);
      expect(editedEntry['hasEvidence'], isFalse);

      // 冻结与解除：控制状态立即反映到总览。
      final freezeResponse = await _send(
        actionUri,
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'action': 'freeze', 'id': editedEntry['id']}),
      );
      expect(freezeResponse.statusCode, HttpStatus.ok);
      final frozen = await overviewJson();
      expect(entryById(frozen, '用户在准备一场辩论赛')['control'], 'frozen');
      final unfreezeResponse = await _send(
        actionUri,
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({
          'action': 'unfreeze',
          'id': editedEntry['id'],
        }),
      );
      expect(unfreezeResponse.statusCode, HttpStatus.ok);
      final unfrozen = await overviewJson();
      expect(entryById(unfrozen, '用户在准备一场辩论赛')['control'], isNull);

      // 敏感条目：列表遮罩，揭示只返回一次原文。
      Map<String, Object?> masked() {
        final days =
            (unfrozen['recent']! as Map<String, Object?>)['days']!
                as List<Object?>;
        for (final day in days) {
          for (final entry
              in (day! as Map<String, Object?>)['entries']! as List<Object?>) {
            final map = entry! as Map<String, Object?>;
            if (map['masked'] == true) {
              return map;
            }
          }
        }
        fail('no masked entry in overview');
      }

      final maskedEntryReal = masked();
      expect(maskedEntryReal['content'], isNull);
      final revealResponse = await _send(
        actionUri,
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({
          'action': 'reveal',
          'id': maskedEntryReal['id'],
        }),
      );
      expect(revealResponse.statusCode, HttpStatus.ok);
      final revealJson =
          jsonDecode(revealResponse.body) as Map<String, Object?>;
      expect(revealJson['text'], '用户的手机号是13812345678');
      // 非敏感条目没有可揭示内容。
      final plainReveal = await _send(
        actionUri,
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'action': 'reveal', 'id': editedEntry['id']}),
      );
      expect(plainReveal.statusCode, HttpStatus.badRequest);
      expect(
        (jsonDecode(plainReveal.body) as Map<String, Object?>)['code'],
        'memory_item_not_masked',
      );

      // 长期印象条目：预览删除影响 → 确认删除。
      final longTerm = (unfrozen['longTerm']! as Map<String, Object?>);
      final group =
          (longTerm['groups']! as List<Object?>).single!
              as Map<String, Object?>;
      final item =
          (group['items']! as List<Object?>).single! as Map<String, Object?>;
      expect(item['content'], '用户养了一只猫');
      final preview = await _send(
        actionUri,
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'action': 'delete-preview', 'id': item['id']}),
      );
      expect(preview.statusCode, HttpStatus.ok);
      final impact = jsonDecode(preview.body) as Map<String, Object?>;
      expect(impact['longTermItems'], 1);
      expect(impact['lines'], isA<List<Object?>>());

      final deleteResponse = await _send(
        actionUri,
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'action': 'delete', 'id': item['id']}),
      );
      expect(deleteResponse.statusCode, HttpStatus.ok);
      final afterDelete = await overviewJson();
      final groupsAfter =
          (afterDelete['longTerm']! as Map<String, Object?>)['groups']!
              as List<Object?>;
      expect(groupsAfter, isEmpty);
      final controlsContents = File(
        '${memoryDirectory.path}${Platform.pathSeparator}memory-controls.md',
      ).readAsStringSync();
      expect(controlsContents, contains('## deleted'));
      await host.close();
    },
  );

  test(
    'backup export, preview, import and rollback stay honest end to end',
    () async {
      final host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        personaConstitution: '测试人格宪法',
      );
      final browser = await _openBrowserSession(host);

      // 先产生一份真实会话作为备份内容。
      final chat = await _send(
        host.origin.resolve('/api/chat'),
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'requestId': 'backup-1', 'text': '今天有点累'}),
      );
      expect(chat.statusCode, HttpStatus.ok);

      // 导出：zip 字节流 + 附件下载头。
      final client = HttpClient();
      final exportRequest = await client.openUrl(
        'GET',
        host.origin.resolve('/api/backup/export'),
      );
      browser.readHeaders(host.origin).forEach(exportRequest.headers.set);
      final exportResponse = await exportRequest.close();
      expect(exportResponse.statusCode, HttpStatus.ok);
      expect(exportResponse.headers.contentType?.mimeType, 'application/zip');
      expect(
        exportResponse.headers.value('content-disposition'),
        contains('attachment'),
      );
      final exportBytes = <int>[];
      await for (final chunk in exportResponse) {
        exportBytes.addAll(chunk);
      }
      // zip 本地文件头原样保存文件名：清单必须存在。
      expect(latin1.decode(exportBytes), contains('manifest.md'));
      client.close(force: true);

      // 无效备份被拒绝：结构校验在写入之前完成。
      final rejected = await _send(
        host.origin.resolve('/api/backup/preview'),
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'dataBase64': base64.encode([1, 2, 3])}),
      );
      expect(rejected.statusCode, HttpStatus.badRequest);
      expect(rejected.body, contains('not-a-backup'));

      // 预览：本机数据完整时全部跳过。
      final preview = await _send(
        host.origin.resolve('/api/backup/preview'),
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'dataBase64': base64.encode(exportBytes)}),
      );
      expect(preview.statusCode, HttpStatus.ok);
      final previewJson = jsonDecode(preview.body) as Map<String, Object?>;
      final counts = previewJson['counts']! as Map<String, Object?>;
      expect(counts['added'], 0);
      expect(counts['replaced'], 0);

      // 确认导入：生成快照，重复数据全部跳过。
      final imported = await _send(
        host.origin.resolve('/api/backup/import'),
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'dataBase64': base64.encode(exportBytes)}),
      );
      expect(imported.statusCode, HttpStatus.ok);
      final importJson = jsonDecode(imported.body) as Map<String, Object?>;
      expect(importJson['added'], 0);
      expect(importJson['snapshotId'], isNotEmpty);

      // 快照列表包含导入前快照。
      final snapshots = await _send(
        host.origin.resolve('/api/backup/snapshots'),
        headers: browser.readHeaders(host.origin),
      );
      expect(snapshots.statusCode, HttpStatus.ok);
      final snapshotsJson = jsonDecode(snapshots.body) as Map<String, Object?>;
      expect(snapshotsJson['snapshots']! as List<Object?>, isNotEmpty);

      // 回滚：恢复快照并留下保底快照。
      final rollback = await _send(
        host.origin.resolve('/api/backup/rollback'),
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({}),
      );
      expect(rollback.statusCode, HttpStatus.ok);
      final rollbackJson = jsonDecode(rollback.body) as Map<String, Object?>;
      expect(rollbackJson['restoredFiles'], greaterThan(0));
      expect(rollbackJson['safetySnapshotId'], isNotEmpty);

      // 变更请求缺少 CSRF 一律拒绝。
      final missingCsrf = await _send(
        host.origin.resolve('/api/backup/import'),
        method: 'POST',
        headers: browser.readHeaders(host.origin),
        requestBody: jsonEncode({'dataBase64': base64.encode(exportBytes)}),
      );
      expect(missingCsrf.statusCode, HttpStatus.forbidden);
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
