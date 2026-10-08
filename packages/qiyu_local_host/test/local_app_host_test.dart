import 'dart:convert';
import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/failing_atomic_writer.dart';
import 'support/legacy_episode_fixture.dart';

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

  group('静态资源与会话入口', () {
    test(
      'serves bundled Web assets on a random loopback port and releases it',
      () async {
        final host = await _startHost(webRoot, memoryDirectory);
  
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
        final scriptSources = contentSecurityPolicy!
            .split(';')
            .map((directive) => directive.trim())
            .singleWhere((directive) => directive.startsWith('script-src '))
            .split(RegExp(r'\s+'));
        // AudioWorklet 模块受 script-src 控制，worker-src 放行并不足够。
        expect(scriptSources, contains('blob:'));
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
        final host = await _startHost(webRoot, memoryDirectory);
  
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
      final host = await _startHost(webRoot, memoryDirectory);
  
      final originalUri = host.launchUri;
      final firstStart = await _send(originalUri);
      expect(firstStart.statusCode, HttpStatus.seeOther);
  
      final replay = await _send(originalUri);
      expect(replay.statusCode, HttpStatus.unauthorized);
  
      await host.close();
    });
  });
  group('鉴权拒绝无副作用', () {
    test(
      '配置写入被鉴权拒绝时逐字保留 provider.json，且按基线最先检查到的那一步报错',
      () async {
        final (host, browser) = await _startHostWithBrowser(
          webRoot,
          memoryDirectory,
        );
        const path = '/api/provider/proxy';
        final endpoint = host.origin.resolve(path);
        const payload = '{"enabled":true,"host":"192.168.1.2","port":7890}';

        // 先按合法凭据写入一次：既确立「载荷本身有效、这条路径写得进去」，
        // 也让后面的比较面对一份真实已有设置，而不是不存在的文件。
        final seeded = await _send(
          endpoint,
          method: 'PUT',
          headers: browser.mutationHeaders(host.origin),
          requestBody: payload,
        );
        expect(seeded.statusCode, HttpStatus.ok);
        // 启动后台任务链先排空，否则整理自身的写入会污染字节前后对照。
        await host.memoryCadence.finalizePending();
        final providerFile = File(_providerJsonPath(temporaryDirectory));
        final bytesBefore = await providerFile.readAsBytes();

        // 逐条单独破坏凭据：每一次都重新读 provider.json，断言字节与保存前逐字相同。
        await _expectRejectedMutations(
          host,
          browser,
          path,
          method: 'PUT',
          payload: payload,
          cases: _configWriteRejectionCases,
          expectEndpointUntouched: (label) async => expect(
            await providerFile.readAsBytes(),
            equals(bytesBefore),
            reason: label,
          ),
        );
        // 未被认领的路径同样先过安全检查：无会话时报会话拒绝而不是 404。
        final unknownWithoutSession = await _send(
          host.origin.resolve('/api/no-such-namespace/endpoint'),
          method: 'POST',
          headers: browser
              .mutationHeaders(host.origin)
              ..remove(HttpHeaders.cookieHeader),
          requestBody: payload,
        );
        expect(unknownWithoutSession.statusCode, HttpStatus.unauthorized);
        expect(unknownWithoutSession.body, 'Invalid session');
        final unknownWithSession = await _send(
          host.origin.resolve('/api/no-such-namespace/endpoint'),
          method: 'POST',
          headers: browser.mutationHeaders(host.origin),
          requestBody: payload,
        );
        expect(unknownWithSession.statusCode, HttpStatus.notFound);
        expect(unknownWithSession.body, 'Not found');
        expect(await providerFile.readAsBytes(), equals(bytesBefore));
        await host.close();
      },
    );

    test(
      '聊天写入被鉴权拒绝时既不调用 Provider 也不新增会话落盘',
      () async {
        final gateway = _StaticModelGateway('还没睡？');
        final configPath = _providerJsonPath(temporaryDirectory);
        final settings = ProviderSettingsService(
          JsonProviderConfigRepository(filePath: configPath),
          _MemorySecretStore(),
          gateway,
          const ModelPromptBuilder('测试人格宪法'),
        );
        await settings.save(
          config: const ProviderConfig(
            kind: ProviderKind.openAiCompatible,
            baseUrl: 'https://example.com/v1',
            model: 'chat-model',
            temperature: 0.6,
            timeoutSeconds: 25,
          ),
          apiKey: 'auth-test-secret-value',
        );
        final (host, browser) = await _startHostWithBrowser(
          webRoot,
          memoryDirectory,
          providerSettingsService: settings,
        );
        await host.memoryCadence.finalizePending();
        final sessionsDirectory = Directory(
          '${memoryDirectory.path}${Platform.pathSeparator}sessions',
        );
        final sessionsBefore = await _snapshotFiles(sessionsDirectory);
        const payload = '{"requestId":"auth-chat-1","text":"在吗"}';

        // 四条破坏组合逐条发出：Provider 替身一次都没被调用，
        // 会话落盘集合与内容逐字不变。
        await _expectRejectedMutations(
          host,
          browser,
          '/api/chat',
          method: 'POST',
          payload: payload,
          cases: _commonWriteRejectionCases,
          expectEndpointUntouched: (label) async {
            expect(gateway.calls, 0, reason: label);
            expect(
              await _snapshotFiles(sessionsDirectory),
              sessionsBefore,
              reason: label,
            );
          },
        );

        // 对照组：同一载荷配上合法凭据确实会走到 Provider，
        // 说明上面那条「调用数为 0」不是替身没接上线路造成的空断言。
        final accepted = await _postJson(host, browser, '/api/chat', {
          'requestId': 'auth-chat-ok',
          'text': '在吗',
        });
        expect(accepted.statusCode, HttpStatus.ok);
        expect(_chatEvent(_chatEvents(accepted.body), 'state')['source'], 'llm');
        expect(gateway.calls, 1);
        expect(await _snapshotFiles(sessionsDirectory), isNot(sessionsBefore));
        await host.close();
      },
    );

    // Spec 实现决策 10「GET 与 HEAD 仍使用当前的『是否修改』判定」与 A 验收矩阵
    // 「未知请求保持 404」两格的方法半边。以下两条用例的期望值全部取自未改动生产
    // 实现上的实跑结果（HEAD 的正文按 HTTP 语义由服务器剥掉，故只比状态码、
    // 空正文与 Content-Length）。
    test(
      'HEAD 走产品路径按基线方法判定：不被当修改请求，也不豁免来源与会话检查',
      () async {
        final gateway = _StaticModelGateway('还没睡？');
        final configPath = _providerJsonPath(temporaryDirectory);
        final settings = ProviderSettingsService(
          JsonProviderConfigRepository(filePath: configPath),
          _MemorySecretStore(),
          gateway,
          const ModelPromptBuilder('测试人格宪法'),
        );
        await settings.save(
          config: const ProviderConfig(
            kind: ProviderKind.openAiCompatible,
            baseUrl: 'https://example.com/v1',
            model: 'chat-model',
            temperature: 0.6,
            timeoutSeconds: 25,
          ),
          apiKey: 'head-case-secret-value',
        );
        final (host, browser) = await _startHostWithBrowser(
          webRoot,
          memoryDirectory,
          providerSettingsService: settings,
        );
        await host.memoryCadence.finalizePending();
        final sessionsDirectory = Directory(
          '${memoryDirectory.path}${Platform.pathSeparator}sessions',
        );
        final sessionsBefore = await _snapshotFiles(sessionsDirectory);
        final providerFile = File(configPath);
        final bytesBefore = await providerFile.readAsBytes();

        /// 发一次 HEAD：断言状态码、正文为空、Content-Length 与基线文案的字节数
        /// 一致（HEAD 无正文，文案只能这样核对），随后复核该入口对应的落盘与
        /// Provider 调用分毫未动。
        Future<void> expectHead(
          String label,
          String path,
          Map<String, String> headers,
          int statusCode,
          String baselineText,
        ) async {
          final response = await _send(
            host.origin.resolve(path),
            method: 'HEAD',
            headers: headers,
          );
          expect(response.statusCode, statusCode, reason: label);
          expect(response.bodyBytes, isEmpty, reason: label);
          expect(
            response.headers.contentLength,
            utf8.encode(baselineText).length,
            reason: '$label：HEAD 无正文，按基线文案字节数核对',
          );
          expect(gateway.calls, 0, reason: label);
          expect(
            await _snapshotFiles(sessionsDirectory),
            sessionsBefore,
            reason: label,
          );
          expect(
            await providerFile.readAsBytes(),
            equals(bytesBefore),
            reason: label,
          );
        }

        await expectHead(
          '聊天入口带齐合法凭据的 HEAD 仍无人认领',
          '/api/chat',
          browser.mutationHeaders(host.origin),
          HttpStatus.notFound,
          'Not found',
        );
        await expectHead(
          '聊天入口把 CSRF 换成错值的 HEAD：CSRF 只查修改请求，不因此被拒',
          '/api/chat',
          browser.mutationHeaders(host.origin)
            ..['x-qiyu-csrf'] = 'wrong-csrf',
          HttpStatus.notFound,
          'Not found',
        );
        await expectHead(
          '配置写入口的 HEAD 不触发写入',
          '/api/provider/proxy',
          browser.mutationHeaders(host.origin),
          HttpStatus.notFound,
          'Not found',
        );
        await expectHead(
          '内建读入口 bootstrap 只认 GET，HEAD 落到未知请求',
          '/api/bootstrap',
          browser.mutationHeaders(host.origin),
          HttpStatus.notFound,
          'Not found',
        );
        await expectHead(
          'HEAD 不豁免来源检查：Origin 指站外仍是来源拒绝',
          '/api/chat',
          browser.mutationHeaders(host.origin)
            ..['origin'] = 'https://evil.example',
          HttpStatus.forbidden,
          'Unexpected request source',
        );
        await expectHead(
          'HEAD 不豁免会话检查：缺会话 Cookie 仍是会话拒绝',
          '/api/chat',
          browser.mutationHeaders(host.origin)
            ..remove(HttpHeaders.cookieHeader),
          HttpStatus.unauthorized,
          'Invalid session',
        );

        // 对照组：同一 Host 上合法 POST 聊天确实会走到 Provider 并新增落盘，
        // 上面那些「调用数为 0、快照不变」才不是替身没接线造成的空断言。
        final accepted = await _postJson(host, browser, '/api/chat', {
          'requestId': 'head-case-ok',
          'text': '在吗',
        });
        expect(accepted.statusCode, HttpStatus.ok);
        expect(gateway.calls, 1);
        expect(await _snapshotFiles(sessionsDirectory), isNot(sessionsBefore));
        await host.close();
      },
    );

    test(
      '未使用方法 PATCH 保持未知请求的 404：按修改请求走 CSRF，也不绕过鉴权',
      () async {
        final gateway = _StaticModelGateway('还没睡？');
        final configPath = _providerJsonPath(temporaryDirectory);
        final settings = ProviderSettingsService(
          JsonProviderConfigRepository(filePath: configPath),
          _MemorySecretStore(),
          gateway,
          const ModelPromptBuilder('测试人格宪法'),
        );
        await settings.save(
          config: const ProviderConfig(
            kind: ProviderKind.openAiCompatible,
            baseUrl: 'https://example.com/v1',
            model: 'chat-model',
            temperature: 0.6,
            timeoutSeconds: 25,
          ),
          apiKey: 'patch-case-secret-value',
        );
        final (host, browser) = await _startHostWithBrowser(
          webRoot,
          memoryDirectory,
          providerSettingsService: settings,
        );
        await host.memoryCadence.finalizePending();
        final sessionsDirectory = Directory(
          '${memoryDirectory.path}${Platform.pathSeparator}sessions',
        );
        final sessionsBefore = await _snapshotFiles(sessionsDirectory);
        final providerFile = File(configPath);
        final bytesBefore = await providerFile.readAsBytes();
        const chatPayload = '{"requestId":"patch-case-1","text":"在吗"}';
        const proxyPayload =
            '{"enabled":true,"host":"192.168.1.2","port":7890}';

        /// 在 [path] 上发一次 PATCH（本应用未使用的方法），断言状态码与响应体
        /// 文案精确相等，随后复核 Provider 未被调用、会话与配置落盘字节未动。
        Future<void> expectPatch(
          String label,
          String path,
          Map<String, String> headers,
          String? payload,
          int statusCode,
          String body,
        ) async {
          final response = await _send(
            host.origin.resolve(path),
            method: 'PATCH',
            headers: headers,
            requestBody: payload,
          );
          expect(response.statusCode, statusCode, reason: label);
          expect(response.body, body, reason: label);
          expect(gateway.calls, 0, reason: label);
          expect(
            await _snapshotFiles(sessionsDirectory),
            sessionsBefore,
            reason: label,
          );
          expect(
            await providerFile.readAsBytes(),
            equals(bytesBefore),
            reason: label,
          );
        }

        await expectPatch(
          '未知路径上的 PATCH 与既有 POST/GET/DELETE 同样保持 404',
          '/api/no-such-namespace/endpoint',
          browser.mutationHeaders(host.origin),
          proxyPayload,
          HttpStatus.notFound,
          'Not found',
        );
        await expectPatch(
          '聊天入口收到 PATCH 时不认领，载荷再合法也不触发交付',
          '/api/chat',
          browser.mutationHeaders(host.origin),
          chatPayload,
          HttpStatus.notFound,
          'Not found',
        );
        await expectPatch(
          '配置写入口收到 PATCH 时不写入，provider.json 逐字未变',
          '/api/provider/proxy',
          browser.mutationHeaders(host.origin),
          proxyPayload,
          HttpStatus.notFound,
          'Not found',
        );
        await expectPatch(
          'PATCH 属修改请求：CSRF 错值先于分发被拒',
          '/api/chat',
          browser.mutationHeaders(host.origin)
            ..['x-qiyu-csrf'] = 'wrong-csrf',
          chatPayload,
          HttpStatus.forbidden,
          'Invalid CSRF token',
        );
        await expectPatch(
          '未知路径上的 PATCH 也不绕过鉴权：缺 Cookie 先是会话拒绝',
          '/api/no-such-namespace/endpoint',
          browser.mutationHeaders(host.origin)
            ..remove(HttpHeaders.cookieHeader),
          proxyPayload,
          HttpStatus.unauthorized,
          'Invalid session',
        );

        final accepted = await _postJson(host, browser, '/api/chat', {
          'requestId': 'patch-case-ok',
          'text': '在吗',
        });
        expect(accepted.statusCode, HttpStatus.ok);
        expect(gateway.calls, 1);
        expect(await _snapshotFiles(sessionsDirectory), isNot(sessionsBefore));
        await host.close();
      },
    );
  });

  group('聊天交付与幂等', () {

    test('拒绝超过 64KB 的 chunked 聊天请求体与非对象 JSON', () async {
      final (host, session) = await _startHostWithBrowser(
        webRoot,
        memoryDirectory,
      );
  
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
        final host = await _startHost(webRoot, memoryDirectory);
        final firstSession = await _openBrowserSession(host);
        final firstChat = await _postJson(host, firstSession, '/api/chat', {
          'requestId': 'restart-1',
          'text': '今天有点累',
        });
  
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
  
        final replay = await _postJson(restarted, restartedSession, '/api/chat', {
          'requestId': 'restart-1',
          'sessionId': sessionId,
          'text': '今天有点累',
        });
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
  });
  group('Provider 配置与降级', () {
    test('启动偏好默认手动，受保护保存、切换服务及重启保留且不泄露 Key', () async {
      final configPath = _providerJsonPath(temporaryDirectory);
      ProviderSettingsService settingsService() => ProviderSettingsService(
        JsonProviderConfigRepository(filePath: configPath),
        _MemorySecretStore(),
        _StaticModelGateway('在。'),
        const ModelPromptBuilder('测试人格宪法'),
      );
      var host = await _startHost(
        webRoot,
        memoryDirectory,
        providerSettingsService: settingsService(),
      );
      addTearDown(() => host.close());
      var browser = await _openBrowserSession(host);
      Future<_HttpResponse> save(
        Map<String, Object?> payload, {
        Map<String, String>? headers,
      }) => _send(
        host.origin.resolve('/api/provider'),
        method: 'PUT',
        headers: headers ?? browser.mutationHeaders(host.origin),
        requestBody: jsonEncode(payload),
      );
      final initial = await _send(
        host.origin.resolve('/api/provider'),
        headers: browser.readHeaders(host.origin),
      );
      expect(
        jsonDecode(initial.body),
        containsPair('callStartupMode', 'manual'),
      );
      final omni = <String, Object?>{
        'provider': 'qwen_omni_realtime',
        'baseUrl': 'wss://dashscope.example.com/api-ws/v1/realtime',
        'model': 'qwen3.8-omni-flash-realtime',
        'temperature': 0.7,
        'timeoutSeconds': 30,
        'callStartupMode': 'auto_on_chat_entry',
      };
      final forbidden = await save(
        omni,
        headers: browser.readHeaders(host.origin),
      );
      expect(forbidden.statusCode, HttpStatus.forbidden);
      final accepted = await save(omni);
      expect(accepted.statusCode, HttpStatus.ok);
      expect(
        jsonDecode(accepted.body),
        allOf(
          containsPair('callStartupMode', 'auto_on_chat_entry'),
          containsPair('keySet', false),
        ),
      );
      final withKey = await save({...omni, 'apiKey': 'startup-private-key'});
      expect(withKey.body, isNot(contains('startup-private-key')));
      for (final invalid in ['unknown', null, true, 3]) {
        final rejected = await save({...omni, 'callStartupMode': invalid});
        expect(rejected.statusCode, HttpStatus.badRequest);
        expect(rejected.body, contains('通话启动方式'));
      }
      final chat = {...omni}
        ..remove('callStartupMode')
        ..['provider'] = 'anthropic'
        ..['baseUrl'] = 'https://api.example.com/v1';
      final switched = await save(chat);
      expect(
        jsonDecode(switched.body),
        allOf(
          containsPair('callStartupMode', 'auto_on_chat_entry'),
          containsPair('keySet', false),
        ),
      );
      final back = {...omni}..remove('callStartupMode');
      expect(
        jsonDecode((await save(back)).body),
        containsPair('callStartupMode', 'auto_on_chat_entry'),
      );
      await host.close();
      host = await _startHost(
        webRoot,
        memoryDirectory,
        providerSettingsService: settingsService(),
      );
      browser = await _openBrowserSession(host);
      final restored = await _send(
        host.origin.resolve('/api/provider'),
        headers: browser.readHeaders(host.origin),
      );
      expect(
        jsonDecode(restored.body),
        containsPair('callStartupMode', 'auto_on_chat_entry'),
      );
      final manual = await save({...omni, 'callStartupMode': 'manual'});
      expect(
        jsonDecode(manual.body),
        containsPair('callStartupMode', 'manual'),
      );
    });


    test(
      'persists Provider settings, masks Key, tests it, and uses model chat',
      () async {
        final configPath = _providerJsonPath(temporaryDirectory);
        final secrets = _MemorySecretStore();
        final gateway = _StaticModelGateway('还没睡？');
        ProviderSettingsService settingsService() => ProviderSettingsService(
          JsonProviderConfigRepository(filePath: configPath),
          secrets,
          gateway,
          const ModelPromptBuilder('测试人格宪法'),
        );
        var host = await _startHost(
          webRoot,
          memoryDirectory,
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
  
        // Key 随配置落盘 provider.json：用户可直接编辑该文件更换 Key。
        final storedConfig =
            jsonDecode(await File(configPath).readAsString())
                as Map<String, Object?>;
        expect(storedConfig['apiKey'], 'private-test-value');
  
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
  
        final chat = await _postJson(host, browser, '/api/chat', {
          'requestId': 'provider-chat',
          'text': '在吗',
        });
        final chatEvents = _chatEvents(chat.body);
        expect(_chatEvent(chatEvents, 'message')['messages'], ['还没睡？']);
        expect(_chatEvent(chatEvents, 'state')['source'], 'llm');
        expect(gateway.apiKey, 'private-test-value');
        await host.close();
      },
    );

    test('主聊天完成 web_search 两轮闭环且工具中间态不出现在流与落盘', () async {
      final configPath = _providerJsonPath(temporaryDirectory);
      final repository = JsonProviderConfigRepository(filePath: configPath);
      final http = _WebSearchRoundTripHttpClient();
      final settings = ProviderSettingsService(
        repository,
        _MemorySecretStore(),
        ProviderModelGateway(http),
        const ModelPromptBuilder('测试人格宪法'),
        webSearchConfigRepository: repository,
        webSearchClient: AnySearchClient(http),
      );
      final (host, browser) = await _startHostWithBrowser(
        webRoot,
        memoryDirectory,
        providerSettingsService: settings,
        webSearchSettingsService: WebSearchSettingsService(repository),
      );
      await _send(
        host.origin.resolve('/api/provider'),
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({
          'provider': 'anthropic',
          'baseUrl': 'https://api.example.com/v1',
          'model': 'deepseek-v4-flash',
          'temperature': 0.6,
          'timeoutSeconds': 25,
          'apiKey': 'provider-secret',
        }),
      );
      await _send(
        host.origin.resolve('/api/provider/web-search'),
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'apiKey': 'any-secret'}),
      );
      await _send(
        host.origin.resolve('/api/preferences'),
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'developerMode': true}),
      );
  
      final chat = await _postJson(host, browser, '/api/chat', {
        'requestId': 'web-search-round-trip',
        'text': '今天天气怎么样',
      });
      final events = _chatEvents(chat.body);
      expect(_chatEvent(events, 'message')['messages'], ['查到了，今天会下雨。']);
      expect(chat.body, isNot(contains('web_search')));
      expect(chat.body, isNot(contains('今天天气')));
      expect(chat.body, isNot(contains('天气来源')));
      expect(
        chat.body,
        isNot(contains(_WebSearchRoundTripHttpClient.queryMarker)),
      );
      expect(
        chat.body,
        isNot(contains(_WebSearchRoundTripHttpClient.resultMarker)),
      );
      expect(http.providerBodies, hasLength(2));
      final systemPrompt = http.providerBodies.first['system'] as String;
      expect(
        RegExp(
          RegExp.escape(webSearchSystemInstruction),
        ).allMatches(systemPrompt),
        hasLength(1),
      );
      expect(http.searchBodies, hasLength(1));
      final searchArguments =
          ((http.searchBodies.single['params']!
                  as Map<String, Object?>)['arguments']!
              as Map<String, Object?>);
      expect(searchArguments['query'], contains('[已脱敏]'));
      expect(
        searchArguments['query'],
        contains(_WebSearchRoundTripHttpClient.queryMarker),
      );
      for (final secret in _WebSearchRoundTripHttpClient.leakedSecrets) {
        expect(searchArguments['query'], isNot(contains(secret)), reason: secret);
      }
  
      final replay = await _postJson(host, browser, '/api/chat', {
        'requestId': 'web-search-round-trip',
        'text': '今天天气怎么样',
      });
      expect(_chatEvent(_chatEvents(replay.body), 'message')['messages'], [
        '查到了，今天会下雨。',
      ]);
      expect(http.searchBodies, hasLength(1));
      final sessionFile = Directory(
        '${memoryDirectory.path}${Platform.pathSeparator}sessions',
      ).listSync(recursive: true).whereType<File>().single;
      final sessionText = await sessionFile.readAsString();
      expect(sessionText, isNot(contains('web_search')));
      expect(sessionText, isNot(contains('北京今天气温')));
      expect(sessionText, isNot(contains('天气来源')));
      expect(sessionText, isNot(contains('any-secret')));
      for (final secret in _WebSearchRoundTripHttpClient.leakedSecrets) {
        expect(sessionText, isNot(contains(secret)), reason: secret);
      }
      expect(
        sessionText,
        isNot(contains(_WebSearchRoundTripHttpClient.queryMarker)),
      );
      expect(
        sessionText,
        isNot(contains(_WebSearchRoundTripHttpClient.resultMarker)),
      );
      final episodesDirectory = Directory(
        '${memoryDirectory.path}${Platform.pathSeparator}episodes',
      );
      final episodeText = StringBuffer();
      if (await episodesDirectory.exists()) {
        await for (final entity in episodesDirectory.list(recursive: true)) {
          if (entity is File) {
            episodeText.write(await entity.readAsString());
          }
        }
      }
      expect(
        episodeText.toString(),
        isNot(contains(_WebSearchRoundTripHttpClient.queryMarker)),
      );
      expect(
        episodeText.toString(),
        isNot(contains(_WebSearchRoundTripHttpClient.resultMarker)),
      );
      final diagnostics = await _send(
        host.origin.resolve('/api/dev/diagnostics'),
        headers: browser.readHeaders(host.origin),
      );
      expect(diagnostics.statusCode, HttpStatus.ok);
      expect(
        diagnostics.body,
        isNot(contains(_WebSearchRoundTripHttpClient.queryMarker)),
      );
      expect(
        diagnostics.body,
        isNot(contains(_WebSearchRoundTripHttpClient.resultMarker)),
      );
      await host.close();
    });

    test('chat API exposes only a diagnostic fallback category', () async {
      final configPath = _providerJsonPath(temporaryDirectory);
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
      final (host, browser) = await _startHostWithBrowser(
        webRoot,
        memoryDirectory,
        providerSettingsService: settings,
      );
  
      final response = await _postJson(host, browser, '/api/chat', {
        'requestId': 'diagnostic-timeout',
        'text': 'API Key: host-test-secret-value 今天有点累',
      });
  
      expect(response.statusCode, HttpStatus.ok);
      expect(
        _chatEvent(_chatEvents(response.body), 'fallback'),
        containsPair('fallbackReason', 'model_timeout'),
      );
      expect(response.body, isNot(contains('已脱敏的测试错误')));
      expect(response.body, isNot(contains('Authorization')));
      await host.close();
    });
  });
  group('历史与损坏会话', () {

    test(
      'history API lists by local day, survives restart, and deletes with CSRF',
      () async {
        var host = await _startHost(webRoot, memoryDirectory);
        var browser = await _openBrowserSession(host);
        final chat = await _postJson(host, browser, '/api/chat', {
          'requestId': 'history-1',
          'text': '今天有点累',
        });
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
        final (host, browser) = await _startHostWithBrowser(
          webRoot,
          memoryDirectory,
        );
        final chat = await _postJson(host, browser, '/api/chat', {
          'requestId': 'corrupt-1',
          'text': '在吗',
        });
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
  
        final continued = await _postJson(host, browser, '/api/chat', {
          'requestId': 'corrupt-2',
          'sessionId': sessionId,
          'text': '还想再说一句',
        });
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
  });
  group('首见引导', () {

    test(
      'onboarding starts open, persists completion across restarts, and reopens after clearing local data',
      () async {
        var host = await _startHost(webRoot, memoryDirectory);
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
      'onboarding completion accepts an appellation and the memory center serves and edits it',
      () async {
        final (host, browser) = await _startHostWithBrowser(
          webRoot,
          memoryDirectory,
        );
  
        // 首见引导带称呼：落到 persona.md 受保护设定行。
        final completed = await _send(
          host.origin.resolve('/api/onboarding/complete'),
          method: 'POST',
          headers: browser.mutationHeaders(host.origin),
          requestBody: '{"appellation":"凯奇"}',
        );
        expect(completed.statusCode, HttpStatus.ok);
        expect(
          File(
            '${memoryDirectory.path}${Platform.pathSeparator}persona.md',
          ).readAsStringSync(),
          contains('称呼：凯奇'),
        );
  
        // 记忆中心 Persona 区读到处呼。
        final overviewResponse = await _send(
          host.origin.resolve('/api/memory'),
          headers: browser.readHeaders(host.origin),
        );
        final overview = jsonDecode(overviewResponse.body) as Map<String, Object?>;
        final persona = overview['persona']! as Map<String, Object?>;
        expect(persona['appellation'], '凯奇');
  
        // 记忆中心修改称呼。
        final updated = await _send(
          host.origin.resolve('/api/memory/appellation'),
          method: 'POST',
          headers: browser.mutationHeaders(host.origin),
          requestBody: '{"appellation":"老王"}',
        );
        expect(updated.statusCode, HttpStatus.ok);
        expect(
          jsonDecode(updated.body) as Map<String, Object?>,
          {'appellation': '老王'},
        );
        expect(
          File(
            '${memoryDirectory.path}${Platform.pathSeparator}persona.md',
          ).readAsStringSync(),
          contains('称呼：老王'),
        );
  
        // 格式校验：空、超长、换行都被拒，称呼保持原值。
        for (final rejected in ['{"appellation":"  "}', '{"appellation":"${'长' * 21}"}', '{"appellation":"两\n行"}']) {
          final response = await _send(
            host.origin.resolve('/api/memory/appellation'),
            method: 'POST',
            headers: browser.mutationHeaders(host.origin),
            requestBody: rejected,
          );
          expect(response.statusCode, HttpStatus.badRequest, reason: rejected);
        }
        expect(
          File(
            '${memoryDirectory.path}${Platform.pathSeparator}persona.md',
          ).readAsStringSync(),
          contains('称呼：老王'),
        );
        await host.close();
      },
    );

    test(
      'onboarding completion rejects an invalid appellation without completing',
      () async {
        final (host, browser) = await _startHostWithBrowser(
          webRoot,
          memoryDirectory,
        );
  
        final rejected = await _send(
          host.origin.resolve('/api/onboarding/complete'),
          method: 'POST',
          headers: browser.mutationHeaders(host.origin),
          requestBody: '{"appellation":"${'长' * 21}"}',
        );
        expect(rejected.statusCode, HttpStatus.badRequest);
        expect(
          (jsonDecode(rejected.body) as Map<String, Object?>)['code'],
          'invalid_appellation',
        );
  
        // 称呼被拒时引导保持未完成：留在首见页可改后重试或跳过。
        final state = await _send(
          host.origin.resolve('/api/onboarding'),
          headers: browser.readHeaders(host.origin),
        );
        expect(jsonDecode(state.body), {'completed': false});
        expect(
          File(
            '${memoryDirectory.path}${Platform.pathSeparator}persona.md',
          ).existsSync(),
          isFalse,
        );
        await host.close();
      },
    );
  });
  group('记忆中心', () {

    test(
      'memory center endpoints serve the four read-only sections over HTTP',
      () async {
        final host = await _startHost(webRoot, memoryDirectory);
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

    test('memory reveal returns a safe legacy view over HTTP', () async {
      final host = await _startHost(webRoot, memoryDirectory);
      addTearDown(host.close);
      final today = localSessionDate(DateTime.now());
      final clean = '<!-- qiyu-episode-entry:${encodeMarkerPayload({
        'summary': 'A)>abcdefghijklmnop',
      })} -->';
      final inner = '<!-- qiyu-episode-entry:${encodeMarkerPayload({
        'id': 'inner-entry',
        'summary': '{"Cookie":"sid=audit04HttpCookie"}',
        'details': {
          'password': 'audit04HttpDirectPassword',
          'api_key': 'audit04HttpDirectKey',
          'Cookie': 'sid=audit04HttpDirectCookie',
          'count': 42,
          'password: audit04HttpKeyA': '普通说明甲',
          'password: [已脱敏]': '原有占位说明',
          'password: audit04HttpKeyB': '普通说明乙',
        },
      })} -->';
      final outer = '<!-- qiyu-episode-entry:${encodeMarkerPayload({
        'id': 'outer-entry',
        'summary': jsonEncode({'note': inner}).replaceAll('<', r'\u003c'),
        'evidence': '{"password":"audit04Before${clean}audit04After"}',
      })} -->';
      const ordinary = '复诊后心情低落，联系 audit04@example.test。';
      await seedLegacyEpisode(
        memoryDirectory.path,
        today,
        summary: '$ordinary '
            '{"password":"audit04HttpPassword${clean}audit04HttpAfter"}\n$outer',
      );
      final browser = await _openBrowserSession(host);
      final overview = await _send(
        host.origin.resolve('/api/memory'),
        headers: browser.readHeaders(host.origin),
      );
      expect(overview.statusCode, HttpStatus.ok);
      final overviewJson = jsonDecode(overview.body) as Map<String, Object?>;
      final days = (overviewJson['recent']! as Map)['days']! as List;
      final entry = ((days.single as Map)['entries']! as List).single as Map;
      expect(entry['masked'], isTrue);
      expect(entry['content'], isNull);
      final request = {'action': 'reveal', 'id': entry['id']};
      final uri = host.origin.resolve('/api/memory/action');
      for (final headers in [
        <String, String>{},
        browser.mutationHeaders(host.origin)..remove('origin'),
        browser.mutationHeaders(host.origin)..remove('x-qiyu-csrf'),
      ]) {
        final denied = await _send(
          uri,
          method: 'POST',
          headers: headers,
          requestBody: jsonEncode(request),
        );
        expect(denied.statusCode, HttpStatus.forbidden);
        expect(denied.body, isNot(contains('audit04')));
      }
      final missing = await _postJson(host, browser, '/api/memory/action', {
        'action': 'reveal',
        'id': 'unknown-opaque-id',
      });
      expect(missing.statusCode, HttpStatus.notFound);
      expect((jsonDecode(missing.body) as Map)['code'], 'memory_item_not_found');

      final response = await _postJson(
        host,
        browser,
        '/api/memory/action',
        request,
      );
      expect(response.statusCode, HttpStatus.ok);
      final result = jsonDecode(response.body) as Map<String, Object?>;
      expect(result.keys, unorderedEquals(['status', 'message', 'text']));
      expect(result['status'], 'success');
      expect(result['message'], '仅本次展示，离开页面或稍后会自动重新遮罩。');
      final text = result['text']! as String;
      expect(text, startsWith('$ordinary {"password":"[已脱敏]"}\n'));
      expect(response.body, isNot(contains('audit04HttpPassword')));
      expect(response.body, isNot(contains('audit04HttpAfter')));
      final payload = decodeMarkerPayload(
        memoryMarkerBlockPattern.firstMatch(text)!.group(2)!,
      );
      expect(payload['id'], 'outer-entry');
      expect(payload['evidence'], '{"password":"[已脱敏]"}');
      expect(payload['summary'], contains(r'\u003c!-- qiyu-'));
      final note = (jsonDecode(payload['summary']! as String) as Map)['note']
          as String;
      expect(
        decodeMarkerPayload(
          memoryMarkerBlockPattern.firstMatch(note)!.group(2)!,
        ),
        {
          'id': 'inner-entry',
          'summary': '{"Cookie":"[已脱敏]"}',
          'details': {
            'password': '[已脱敏]',
            'api_key': '[已脱敏]',
            'Cookie': '[已脱敏]',
            'count': 42,
            'password: [已脱敏] (2)': '普通说明甲',
            'password: [已脱敏]': '原有占位说明',
            'password: [已脱敏] (3)': '普通说明乙',
          },
        },
      );
    });

    test(
      'memory action endpoint edits, controls, deletes and reveals over HTTP',
      () async {
        final host = await _startHost(webRoot, memoryDirectory);
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
        final unknown = await _postJson(host, browser, '/api/memory/action', {
          'action': 'freeze',
          'id': 'no-such-id',
        });
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
        final editResponse = await _postJson(
          host,
          browser,
          '/api/memory/action',
          {'action': 'edit', 'id': editTarget['id'], 'text': '用户在准备一场辩论赛'},
        );
        expect(editResponse.statusCode, HttpStatus.ok);
        final edited = await overviewJson();
        final editedEntry = entryById(edited, '用户在准备一场辩论赛');
        expect(editedEntry['userEdited'], isTrue);
        expect(editedEntry['hasEvidence'], isFalse);
  
        // 冻结与解除：控制状态立即反映到总览。
        final freezeResponse = await _postJson(
          host,
          browser,
          '/api/memory/action',
          {'action': 'freeze', 'id': editedEntry['id']},
        );
        expect(freezeResponse.statusCode, HttpStatus.ok);
        final frozen = await overviewJson();
        expect(entryById(frozen, '用户在准备一场辩论赛')['control'], 'frozen');
        final unfreezeResponse = await _postJson(
          host,
          browser,
          '/api/memory/action',
          {'action': 'unfreeze', 'id': editedEntry['id']},
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
        final revealResponse = await _postJson(
          host,
          browser,
          '/api/memory/action',
          {'action': 'reveal', 'id': maskedEntryReal['id']},
        );
        expect(revealResponse.statusCode, HttpStatus.ok);
        final revealJson =
            jsonDecode(revealResponse.body) as Map<String, Object?>;
        expect(revealJson['text'], '用户的手机号是13812345678');
        // 非敏感条目没有可揭示内容。
        final plainReveal = await _postJson(host, browser, '/api/memory/action', {
          'action': 'reveal',
          'id': editedEntry['id'],
        });
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
        final preview = await _postJson(host, browser, '/api/memory/action', {
          'action': 'delete-preview',
          'id': item['id'],
        });
        expect(preview.statusCode, HttpStatus.ok);
        final impact = jsonDecode(preview.body) as Map<String, Object?>;
        expect(impact['longTermItems'], 1);
        expect(impact['lines'], isA<List<Object?>>());
  
        final deleteResponse = await _postJson(
          host,
          browser,
          '/api/memory/action',
          {'action': 'delete', 'id': item['id']},
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
  });
  group('备份', () {

    test(
      'backup export, preview, import and rollback stay honest end to end',
      () async {
        final (host, browser) = await _startHostWithBrowser(
          webRoot,
          memoryDirectory,
        );
  
        // 先产生一份真实会话作为备份内容。
        final chat = await _postJson(host, browser, '/api/chat', {
          'requestId': 'backup-1',
          'text': '今天有点累',
        });
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
        final rejected = await _postJson(host, browser, '/api/backup/preview', {
          'dataBase64': base64.encode([1, 2, 3]),
        });
        expect(rejected.statusCode, HttpStatus.badRequest);
        expect(rejected.body, contains('not-a-backup'));
  
        // 预览：本机数据完整时全部跳过。
        final preview = await _postJson(host, browser, '/api/backup/preview', {
          'dataBase64': base64.encode(exportBytes),
        });
        expect(preview.statusCode, HttpStatus.ok);
        final previewJson = jsonDecode(preview.body) as Map<String, Object?>;
        final counts = previewJson['counts']! as Map<String, Object?>;
        expect(counts['added'], 0);
        expect(counts['replaced'], 0);
  
        // 确认导入：生成快照，重复数据全部跳过。
        final imported = await _postJson(host, browser, '/api/backup/import', {
          'dataBase64': base64.encode(exportBytes),
        });
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
        final rollback = await _postJson(
          host,
          browser,
          '/api/backup/rollback',
          {},
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
  });
  group('开发者诊断', () {

    test(
      'developer diagnostics stay closed until developer mode is turned on',
      () async {
        final (host, browser) = await _startHostWithBrowser(
          webRoot,
          memoryDirectory,
        );
  
        // 体验选项默认关闭开发者模式。
        final preferences = await _send(
          host.origin.resolve('/api/preferences'),
          headers: browser.readHeaders(host.origin),
        );
        expect(preferences.statusCode, HttpStatus.ok);
        expect(
          jsonDecode(preferences.body),
          containsPair('developerMode', false),
        );
  
        // 未开启时诊断按不存在处理；变更请求更不被接受（只读能力）。
        final closed = await _send(
          host.origin.resolve('/api/dev/diagnostics'),
          headers: browser.readHeaders(host.origin),
        );
        expect(closed.statusCode, HttpStatus.notFound);
        final posted = await _send(
          host.origin.resolve('/api/dev/diagnostics'),
          method: 'POST',
          headers: browser.mutationHeaders(host.origin),
          requestBody: '{}',
        );
        expect(posted.statusCode, HttpStatus.notFound);
  
        // 非法体验选项负载被拒绝。
        final invalid = await _send(
          host.origin.resolve('/api/preferences'),
          method: 'PUT',
          headers: browser.mutationHeaders(host.origin),
          requestBody: jsonEncode({'developerMode': 'yes'}),
        );
        expect(invalid.statusCode, HttpStatus.badRequest);
  
        // 开启后可读，且负载缺 CSRF 一律拒绝。
        final turnedOn = await _send(
          host.origin.resolve('/api/preferences'),
          method: 'PUT',
          headers: browser.mutationHeaders(host.origin),
          requestBody: jsonEncode({'developerMode': true}),
        );
        expect(turnedOn.statusCode, HttpStatus.ok);
        expect(jsonDecode(turnedOn.body), containsPair('developerMode', true));
        final missingCsrf = await _send(
          host.origin.resolve('/api/preferences'),
          method: 'PUT',
          headers: browser.readHeaders(host.origin),
          requestBody: jsonEncode({'developerMode': false}),
        );
        expect(missingCsrf.statusCode, HttpStatus.forbidden);
  
        final diagnostics = await _send(
          host.origin.resolve('/api/dev/diagnostics'),
          headers: browser.readHeaders(host.origin),
        );
        expect(diagnostics.statusCode, HttpStatus.ok);
        final snapshot = jsonDecode(diagnostics.body) as Map<String, Object?>;
        expect(snapshot['recentRequests'], isA<List<Object?>>());
        expect(snapshot['finalization'], isA<Map<String, Object?>>());
        expect(snapshot['dream'], isA<Map<String, Object?>>());
        expect(snapshot['fileHealth'], isA<Map<String, Object?>>());
        expect(snapshot['memoryDirectory'], memoryDirectory.path);
        await host.close();
      },
    );

    test(
      'diagnostics show recent chat source and fallback reason without secrets',
      () async {
        final configPath = _providerJsonPath(temporaryDirectory);
        final settings = ProviderSettingsService(
          JsonProviderConfigRepository(filePath: configPath),
          _MemorySecretStore(),
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
          apiKey: 'diagnostics-secret-key-value',
        );
        final (host, browser) = await _startHostWithBrowser(
          webRoot,
          memoryDirectory,
          providerSettingsService: settings,
        );
  
        await _send(
          host.origin.resolve('/api/preferences'),
          method: 'PUT',
          headers: browser.mutationHeaders(host.origin),
          requestBody: jsonEncode({'developerMode': true}),
        );
        final chat = await _postJson(host, browser, '/api/chat', {
          'requestId': 'diagnostics-chat',
          'text': '今天有点累',
        });
        expect(chat.statusCode, HttpStatus.ok);
        expect(
          _chatEvent(_chatEvents(chat.body), 'fallback'),
          containsPair('fallbackReason', 'model_timeout'),
        );
  
        final diagnostics = await _send(
          host.origin.resolve('/api/dev/diagnostics'),
          headers: browser.readHeaders(host.origin),
        );
        expect(diagnostics.statusCode, HttpStatus.ok);
        final snapshot = jsonDecode(diagnostics.body) as Map<String, Object?>;
        final requests = (snapshot['recentRequests']! as List<Object?>)
            .cast<Map<String, Object?>>();
        final chatEntry = requests.firstWhere(
          (entry) => entry['source'] == 'chat',
        );
        expect(chatEntry['result'], 'fallback');
        expect(chatEntry['fallbackReason'], 'model_timeout');
        expect(chatEntry['replySource'], 'local');
        // 诊断导出统一脱敏：API Key 原文绝不出现。
        expect(diagnostics.body, isNot(contains('diagnostics-secret-key-value')));
        await host.close();
      },
    );
  });
  group('语音 STT 与 TTS', () {

    test(
      'STT routes persist per-section, mask keys, test, and transcribe safely',
      () async {
        final configPath = _providerJsonPath(temporaryDirectory);
        JsonProviderConfigRepository repository() =>
            JsonProviderConfigRepository(filePath: configPath);
        // 记录型出网客户端：转写返回固定文本，供路由全链路验证。
        final sttHttp = _RecordingSttHttpClient('{"text":"今天有点累"}');
        SttSettingsService sttService() =>
            SttSettingsService(repository(), SttModelGateway(sttHttp));
        final (host, browser) = await _startHostWithBrowser(
          webRoot,
          memoryDirectory,
          sttSettingsService: sttService(),
        );
  
        // 变更请求缺 CSRF / 缺 Origin / 缺会话一律拒绝。
        final noCsrf = await _send(
          host.origin.resolve('/api/provider/stt'),
          method: 'PUT',
          headers: {
            ...browser.readHeaders(host.origin),
            'origin': host.origin.toString().replaceFirst(RegExp(r'/$'), ''),
          },
          requestBody: jsonEncode({
            'baseUrl': 'https://stt.example.com/v1',
            'model': 'w',
          }),
        );
        expect(noCsrf.statusCode, HttpStatus.forbidden);
        final noOrigin = await _send(
          host.origin.resolve('/api/provider/stt'),
          method: 'PUT',
          headers: {
            // 有会话、有 referer、有 CSRF，唯独缺 Origin 头：
            // 变更请求仍必须拒绝。
            ...browser.readHeaders(host.origin),
            'x-qiyu-csrf': browser.csrfToken,
          },
          requestBody: jsonEncode({
            'baseUrl': 'https://stt.example.com/v1',
            'model': 'w',
          }),
        );
        expect(noOrigin.statusCode, HttpStatus.forbidden);
        final noSession = await _send(
          host.origin.resolve('/api/provider/stt'),
          headers: {HttpHeaders.refererHeader: host.origin.toString()},
        );
        expect(noSession.statusCode, HttpStatus.unauthorized);
  
        // 保存：Key 只落文件，响应永不回明文。
        final saved = await _send(
          host.origin.resolve('/api/provider/stt'),
          method: 'PUT',
          headers: browser.mutationHeaders(host.origin),
          requestBody: jsonEncode({
            'baseUrl': 'https://stt.example.com/v1',
            'model': 'whisper-test',
            'apiKey': 'stt-secret-value',
          }),
        );
        expect(saved.statusCode, HttpStatus.ok);
        expect(saved.body, isNot(contains('stt-secret-value')));
        expect(
          jsonDecode(saved.body),
          allOf(
            containsPair('configured', true),
            containsPair('keySet', true),
            containsPair('provider', 'openai_compatible'),
            containsPair('baseUrl', 'https://stt.example.com/v1'),
            containsPair('model', 'whisper-test'),
          ),
        );
  
        // 保存聊天 Provider 不得抹掉 stt 段。
        final chatSaved = await _send(
          host.origin.resolve('/api/provider'),
          method: 'PUT',
          headers: browser.mutationHeaders(host.origin),
          requestBody: jsonEncode({
            'provider': 'openai_compatible',
            'baseUrl': 'https://chat.example.com/v1',
            'model': 'chat-model',
            'temperature': 0.6,
            'timeoutSeconds': 25,
          }),
        );
        expect(chatSaved.statusCode, HttpStatus.ok);
        final sttStillThere = await _send(
          host.origin.resolve('/api/provider/stt'),
          headers: browser.readHeaders(host.origin),
        );
        expect(jsonDecode(sttStillThere.body), containsPair('configured', true));
        // 读回的设置 JSON 不携带 apiKey 字段，更不含明文 Key。
        expect(sttStillThere.body, isNot(contains('apiKey')));
        expect(sttStillThere.body, isNot(contains('stt-secret-value')));
        final providerStillThere = await _send(
          host.origin.resolve('/api/provider'),
          headers: browser.readHeaders(host.origin),
        );
        expect(
          jsonDecode(providerStillThere.body),
          containsPair('configured', true),
        );
  
        // 连接测试：空负载按已保存配置测试，静音音频也算成功。
        final tested = await _send(
          host.origin.resolve('/api/provider/stt/test'),
          method: 'POST',
          headers: browser.mutationHeaders(host.origin),
          requestBody: '{}',
        );
        expect(tested.statusCode, HttpStatus.ok);
        expect(jsonDecode(tested.body), containsPair('ok', true));
  
        // 正式转写：二进制 body 成功返回文本；鉴权头不回显。
        final transcribed = await _sendBytes(
          host.origin.resolve('/api/chat/transcribe'),
          headers: {
            ...browser.mutationHeaders(host.origin)
              ..remove(HttpHeaders.contentTypeHeader),
            HttpHeaders.contentTypeHeader: 'audio/webm',
          },
          body: [1, 2, 3],
        );
        expect(transcribed.statusCode, HttpStatus.ok);
        expect(jsonDecode(transcribed.body), {'text': '今天有点累'});
        expect(transcribed.body, isNot(contains('Bearer')));
  
        // 非 audio/* 内容类型拒绝。
        final wrongType = await _sendBytes(
          host.origin.resolve('/api/chat/transcribe'),
          headers: {
            ...browser.mutationHeaders(host.origin)
              ..remove(HttpHeaders.contentTypeHeader),
            HttpHeaders.contentTypeHeader: 'text/plain',
          },
          body: [1, 2, 3],
        );
        expect(wrongType.statusCode, HttpStatus.badRequest);
  
        // 上游失败映射为允许列表诊断码，不透出服务商原文。
        sttHttp.statusCode = 429;
        sttHttp.responseBody = '{"error":"429 quota secret detail"}';
        final upstreamFailure = await _sendBytes(
          host.origin.resolve('/api/chat/transcribe'),
          headers: {
            ...browser.mutationHeaders(host.origin)
              ..remove(HttpHeaders.contentTypeHeader),
            HttpHeaders.contentTypeHeader: 'audio/webm',
          },
          body: [1, 2, 3],
        );
        expect(upstreamFailure.statusCode, HttpStatus.badGateway);
        final failureJson =
            jsonDecode(upstreamFailure.body) as Map<String, Object?>;
        expect(failureJson['code'], 'stt_rate_limited');
        expect(failureJson['message'], '语音服务请求过于频繁。');
        expect(upstreamFailure.body, isNot(contains('secret')));
  
        // 空文本视为「没有识别到语音」的可重试失败。
        sttHttp.statusCode = 200;
        sttHttp.responseBody = '{"text":""}';
        final noSpeech = await _sendBytes(
          host.origin.resolve('/api/chat/transcribe'),
          headers: {
            ...browser.mutationHeaders(host.origin)
              ..remove(HttpHeaders.contentTypeHeader),
            HttpHeaders.contentTypeHeader: 'audio/webm',
          },
          body: [1, 2, 3],
        );
        expect(noSpeech.statusCode, HttpStatus.badRequest);
        final noSpeechJson = jsonDecode(noSpeech.body) as Map<String, Object?>;
        expect(noSpeechJson['code'], 'stt_no_speech');
        expect(noSpeechJson['message'], contains('没有识别到语音'));
        expect(noSpeechJson['retryable'], isTrue);
  
        // 保存的 Key 带零宽空格：本地配置无效按 400 拒（不是上游 502）。
        await _send(
          host.origin.resolve('/api/provider/stt'),
          method: 'PUT',
          headers: browser.mutationHeaders(host.origin),
          requestBody: jsonEncode({
            'baseUrl': 'https://stt.example.com/v1',
            'model': 'whisper-test',
            'apiKey': 'stt-secret-value\u200B',
          }),
        );
        final dirtyKey = await _sendBytes(
          host.origin.resolve('/api/chat/transcribe'),
          headers: {
            ...browser.mutationHeaders(host.origin)
              ..remove(HttpHeaders.contentTypeHeader),
            HttpHeaders.contentTypeHeader: 'audio/webm',
          },
          body: [1, 2, 3],
        );
        expect(dirtyKey.statusCode, HttpStatus.badRequest);
        final dirtyKeyJson = jsonDecode(dirtyKey.body) as Map<String, Object?>;
        expect(dirtyKeyJson['code'], 'stt_config_invalid');
        expect(dirtyKeyJson['retryable'], isFalse);
        expect(dirtyKey.body, isNot(contains('stt-secret-value')));
  
        // 忘记 Key：配置保留、keySet 归零。
        final forgotten = await _send(
          host.origin.resolve('/api/provider/stt/key'),
          method: 'DELETE',
          headers: browser.mutationHeaders(host.origin),
        );
        expect(forgotten.statusCode, HttpStatus.ok);
        expect(
          jsonDecode(forgotten.body),
          allOf(containsPair('configured', true), containsPair('keySet', false)),
        );
        await host.close();
      },
    );

    test('STT provider 字段：豆包配置往返，非法协议名按中文报错拒绝', () async {
      final configPath = _providerJsonPath(temporaryDirectory);
      final sttHttp = _RecordingSttHttpClient('{"text":"今天有点累"}');
      final (host, browser) = await _startHostWithBrowser(
        webRoot,
        memoryDirectory,
        sttSettingsService: SttSettingsService(
          JsonProviderConfigRepository(filePath: configPath),
          SttModelGateway(sttHttp),
        ),
      );
  
      // 豆包配置保存与读回：provider 字段往返一致。
      final saved = await _send(
        host.origin.resolve('/api/provider/stt'),
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({
          'provider': 'volc_seed_asr',
          'baseUrl':
              'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream',
          'model': 'volc.seedasr.sauc.duration',
          'apiKey': 'ark-secret-value',
        }),
      );
      expect(saved.statusCode, HttpStatus.ok);
      expect(jsonDecode(saved.body), containsPair('provider', 'volc_seed_asr'));
      expect(saved.body, isNot(contains('ark-secret-value')));
      final read = await _send(
        host.origin.resolve('/api/provider/stt'),
        headers: browser.readHeaders(host.origin),
      );
      expect(jsonDecode(read.body), containsPair('provider', 'volc_seed_asr'));
  
      // 非法协议名：拒绝且给出中文提示，不落盘。
      final invalid = await _send(
        host.origin.resolve('/api/provider/stt'),
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({
          'provider': 'azure_speech',
          'baseUrl':
              'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream',
          'model': 'volc.seedasr.sauc.duration',
        }),
      );
      expect(invalid.statusCode, HttpStatus.badRequest);
      expect(invalid.body, contains('不支持这个语音服务协议'));
      final afterInvalid = await _send(
        host.origin.resolve('/api/provider/stt'),
        headers: browser.readHeaders(host.origin),
      );
      expect(
        jsonDecode(afterInvalid.body),
        containsPair('provider', 'volc_seed_asr'),
      );
      await host.close();
    });

    test(
      'TTS routes persist per-section, mask keys, and return preview audio',
      () async {
        final configPath = _providerJsonPath(temporaryDirectory);
        final ttsGateway = _RecordingTtsGateway(audio: [1, 2, 3]);
        final (host, browser) = await _startHostWithBrowser(
          webRoot,
          memoryDirectory,
          ttsSettingsService: TtsSettingsService(
            JsonProviderConfigRepository(filePath: configPath),
            ttsGateway,
          ),
        );
  
        // 变更请求缺 CSRF / 缺 Origin / 缺会话一律拒绝。
        final noCsrf = await _send(
          host.origin.resolve('/api/provider/tts'),
          method: 'PUT',
          headers: {
            ...browser.readHeaders(host.origin),
            'origin': host.origin.toString().replaceFirst(RegExp(r'/$'), ''),
          },
          requestBody: jsonEncode({
            'baseUrl': 'https://tts.example.com/v1',
            'model': 't',
          }),
        );
        expect(noCsrf.statusCode, HttpStatus.forbidden);
        final noOrigin = await _send(
          host.origin.resolve('/api/provider/tts'),
          method: 'PUT',
          headers: {
            ...browser.readHeaders(host.origin),
            'x-qiyu-csrf': browser.csrfToken,
          },
          requestBody: jsonEncode({
            'baseUrl': 'https://tts.example.com/v1',
            'model': 't',
          }),
        );
        expect(noOrigin.statusCode, HttpStatus.forbidden);
        final noSession = await _send(
          host.origin.resolve('/api/provider/tts'),
          headers: {HttpHeaders.refererHeader: host.origin.toString()},
        );
        expect(noSession.statusCode, HttpStatus.unauthorized);
  
        // 保存：Key 只落文件，响应永不回明文；音色/语速/开关往返。
        final saved = await _send(
          host.origin.resolve('/api/provider/tts'),
          method: 'PUT',
          headers: browser.mutationHeaders(host.origin),
          requestBody: jsonEncode({
            'baseUrl': 'https://tts.example.com/v1',
            'model': 'tts-test',
            'apiKey': 'tts-secret-value',
            'voice': 'nova',
            'speed': 1.2,
            'autoSpeak': false,
          }),
        );
        expect(saved.statusCode, HttpStatus.ok);
        expect(saved.body, isNot(contains('tts-secret-value')));
        expect(
          jsonDecode(saved.body),
          allOf(
            containsPair('configured', true),
            containsPair('keySet', true),
            containsPair('provider', 'openai_compatible'),
            containsPair('voice', 'nova'),
            containsPair('speed', 1.2),
            containsPair('autoSpeak', false),
          ),
        );
  
        // 保存聊天 Provider 与 STT 不得抹掉 tts 段。
        await _send(
          host.origin.resolve('/api/provider'),
          method: 'PUT',
          headers: browser.mutationHeaders(host.origin),
          requestBody: jsonEncode({
            'provider': 'openai_compatible',
            'baseUrl': 'https://chat.example.com/v1',
            'model': 'chat-model',
            'temperature': 0.6,
            'timeoutSeconds': 25,
          }),
        );
        await _send(
          host.origin.resolve('/api/provider/stt'),
          method: 'PUT',
          headers: browser.mutationHeaders(host.origin),
          requestBody: jsonEncode({
            'baseUrl': 'https://stt.example.com/v1',
            'model': 'whisper-test',
          }),
        );
        final read = await _send(
          host.origin.resolve('/api/provider/tts'),
          headers: browser.readHeaders(host.origin),
        );
        expect(jsonDecode(read.body), containsPair('configured', true));
        expect(read.body, isNot(contains('apiKey')));
        expect(read.body, isNot(contains('tts-secret-value')));
  
        // 连接测试：空负载按已保存配置测试，成功并带回试听音频
        // （fake 网关返回 [1,2,3] → base64 "AQID"）。
        final tested = await _send(
          host.origin.resolve('/api/provider/tts/test'),
          method: 'POST',
          headers: browser.mutationHeaders(host.origin),
          requestBody: '{}',
        );
        expect(tested.statusCode, HttpStatus.ok);
        expect(jsonDecode(tested.body), containsPair('ok', true));
        expect(jsonDecode(tested.body), containsPair('audioBase64', 'AQID'));
        expect(ttsGateway.lastText, ttsConnectionTestSentence);
  
        // 上游失败：分类文案，不带音频，不透出服务商原文。
        ttsGateway.error = const TtsGatewayException(
          kind: ModelFailureKind.authentication,
          message: 'x',
        );
        final failed = await _send(
          host.origin.resolve('/api/provider/tts/test'),
          method: 'POST',
          headers: browser.mutationHeaders(host.origin),
          requestBody: '{}',
        );
        expect(failed.statusCode, HttpStatus.ok);
        final failedJson = jsonDecode(failed.body) as Map<String, Object?>;
        expect(failedJson['ok'], false);
        expect(failedJson.containsKey('audioBase64'), isFalse);
        expect(failedJson['message'], 'API Key 没有通过验证。');
        ttsGateway.error = null;
  
        // 非法协议名：中文报错拒绝，不落盘。
        final invalid = await _send(
          host.origin.resolve('/api/provider/tts'),
          method: 'PUT',
          headers: browser.mutationHeaders(host.origin),
          requestBody: jsonEncode({
            'provider': 'azure_speech',
            'baseUrl': 'https://tts.example.com/v1',
            'model': 'tts-test',
          }),
        );
        expect(invalid.statusCode, HttpStatus.badRequest);
        expect(invalid.body, contains('不支持这个语音合成服务协议'));
  
        // 忘记 Key：配置保留、keySet 归零。
        final forgotten = await _send(
          host.origin.resolve('/api/provider/tts/key'),
          method: 'DELETE',
          headers: browser.mutationHeaders(host.origin),
        );
        expect(forgotten.statusCode, HttpStatus.ok);
        expect(
          jsonDecode(forgotten.body),
          allOf(
            containsPair('configured', true),
            containsPair('keySet', false),
            containsPair('voice', 'nova'),
          ),
        );
  
        // 朗读开关：只写 autoSpeak 位，协议/地址/音色/Key 不动；缺 CSRF
        // 拒绝；enabled 非布尔按格式错误拒绝。
        final toggled = await _send(
          host.origin.resolve('/api/provider/tts/auto-speak'),
          method: 'PUT',
          headers: browser.mutationHeaders(host.origin),
          requestBody: jsonEncode({'enabled': false}),
        );
        expect(toggled.statusCode, HttpStatus.ok);
        expect(
          jsonDecode(toggled.body),
          allOf(
            containsPair('configured', true),
            containsPair('autoSpeak', false),
          ),
        );
        final noCsrfToggle = await _send(
          host.origin.resolve('/api/provider/tts/auto-speak'),
          method: 'PUT',
          headers: {
            ...browser.readHeaders(host.origin),
            'origin': host.origin.toString().replaceFirst(RegExp(r'/$'), ''),
          },
          requestBody: jsonEncode({'enabled': true}),
        );
        expect(noCsrfToggle.statusCode, HttpStatus.forbidden);
        final malformedToggle = await _send(
          host.origin.resolve('/api/provider/tts/auto-speak'),
          method: 'PUT',
          headers: browser.mutationHeaders(host.origin),
          requestBody: jsonEncode({'enabled': 'yes'}),
        );
        expect(malformedToggle.statusCode, HttpStatus.badRequest);

        // 自定义合成档：三个旋钮随保存落盘，响应永不回明文 Key。
        final customSaved = await _send(
          host.origin.resolve('/api/provider/tts'),
          method: 'PUT',
          headers: browser.mutationHeaders(host.origin),
          requestBody: jsonEncode({
            'provider': 'custom',
            'baseUrl': 'https://tts.example.com/v1/audio/speech',
            'model': 'tts-test',
            'apiKey': 'custom-secret-value',
            'authHeader': 'X-Api-Key',
            'responseShape': 'json_lines',
            'responseField': 'result.audio',
          }),
        );
        expect(customSaved.statusCode, HttpStatus.ok);
        expect(customSaved.body, isNot(contains('custom-secret-value')));
        expect(
          jsonDecode(customSaved.body),
          allOf(
            containsPair('provider', 'custom'),
            containsPair('authHeader', 'X-Api-Key'),
            containsPair('responseShape', 'json_lines'),
            containsPair('responseField', 'result.audio'),
          ),
        );

        // 非法响应形态 wire 名（转写侧的 sse 不是合成形态）：拒绝且已存
        // 配置不动。
        final invalidShape = await _send(
          host.origin.resolve('/api/provider/tts'),
          method: 'PUT',
          headers: browser.mutationHeaders(host.origin),
          requestBody: jsonEncode({
            'provider': 'custom',
            'baseUrl': 'https://tts.example.com/v1/audio/speech',
            'model': 'tts-test',
            'responseShape': 'sse',
          }),
        );
        expect(invalidShape.statusCode, HttpStatus.badRequest);
        expect(invalidShape.body, contains('不支持这个合成响应形态'));
        final afterInvalidShape = await _send(
          host.origin.resolve('/api/provider/tts'),
          headers: browser.readHeaders(host.origin),
        );
        expect(
          jsonDecode(afterInvalidShape.body),
          allOf(
            containsPair('provider', 'custom'),
            containsPair('responseShape', 'json_lines'),
            containsPair('responseField', 'result.audio'),
          ),
        );
        await host.close();
      },
    );

    test(
      'speak reads the persisted qiyu turn and returns synthesized audio',
      () async {
        final configPath = _providerJsonPath(temporaryDirectory);
        final ttsGateway = _RecordingTtsGateway(audio: [1, 2, 3]);
        final (host, browser) = await _startHostWithBrowser(
          webRoot,
          memoryDirectory,
          providerSettingsService: ProviderSettingsService(
            JsonProviderConfigRepository(filePath: configPath),
            _MemorySecretStore(),
            _StaticModelGateway('还没睡？'),
            const ModelPromptBuilder('测试人格宪法'),
          ),
          ttsSettingsService: TtsSettingsService(
            JsonProviderConfigRepository(filePath: configPath),
            ttsGateway,
          ),
        );
  
        // 配置聊天与 TTS（否则回复不落模型 turn、朗读没 Key）。
        await _send(
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
        await _send(
          host.origin.resolve('/api/provider/tts'),
          method: 'PUT',
          headers: browser.mutationHeaders(host.origin),
          requestBody: jsonEncode({
            'baseUrl': 'https://tts.example.com/v1',
            'model': 'tts-test',
            'apiKey': 'tts-secret-value',
          }),
        );
  
        // 变更请求缺 CSRF 拒绝。
        final noCsrf = await _send(
          host.origin.resolve('/api/chat/speak'),
          method: 'POST',
          headers: {
            ...browser.readHeaders(host.origin),
            'origin': host.origin.toString().replaceFirst(RegExp(r'/$'), ''),
          },
          requestBody: jsonEncode({'requestId': 'speak-1', 'turnIndex': 0}),
        );
        expect(noCsrf.statusCode, HttpStatus.forbidden);
  
        // 聊天交付一轮：栖语 turn 完整落盘。
        final chat = await _postJson(host, browser, '/api/chat', {
          'requestId': 'speak-1',
          'text': '在吗',
        });
        expect(chat.statusCode, HttpStatus.ok);
  
        // 朗读：Host 从落盘 turn 取该 bubble 的文字去合成。
        final spoken = await _postJson(host, browser, '/api/chat/speak', {
          'requestId': 'speak-1',
          'turnIndex': 0,
        });
        expect(spoken.statusCode, HttpStatus.ok);
        expect(spoken.headers.value(HttpHeaders.contentTypeHeader), 'audio/mpeg');
        expect(spoken.bodyBytes, [1, 2, 3]);
        expect(ttsGateway.lastText, '还没睡？');
  
        // turnIndex 越界与未知 requestId：允许列表诊断码。
        final overflow = await _postJson(host, browser, '/api/chat/speak', {
          'requestId': 'speak-1',
          'turnIndex': 9,
        });
        expect(overflow.statusCode, HttpStatus.badRequest);
        expect(
          jsonDecode(overflow.body),
          containsPair('code', 'tts_turn_not_found'),
        );
  
        final unknown = await _postJson(host, browser, '/api/chat/speak', {
          'requestId': 'nope',
          'turnIndex': 0,
        });
        expect(unknown.statusCode, HttpStatus.badRequest);
        expect(
          jsonDecode(unknown.body),
          containsPair('code', 'tts_turn_not_found'),
        );
  
        // 请求格式不对（缺 requestId / turnIndex 非整数）。
        final malformed = await _postJson(host, browser, '/api/chat/speak', {
          'requestId': 'speak-1',
          'turnIndex': 'zero',
        });
        expect(malformed.statusCode, HttpStatus.badRequest);
  
        // 上游合成失败映射为允许列表诊断码与人话文案，网关异常里的
        // 服务商原文不得进入 HTTP 响应。
        ttsGateway.error = const TtsGatewayException(
          kind: ModelFailureKind.rateLimited,
          message: '上游额度详情 secret-provider-body',
        );
        final upstreamFailure = await _postJson(
          host,
          browser,
          '/api/chat/speak',
          {'requestId': 'speak-1', 'turnIndex': 0},
        );
        expect(upstreamFailure.statusCode, HttpStatus.badGateway);
        expect(
          jsonDecode(upstreamFailure.body),
          containsPair('code', 'tts_rate_limited'),
        );
        expect(
          jsonDecode(upstreamFailure.body),
          containsPair('message', '语音合成服务请求过于频繁，请稍后再试。'),
        );
        expect(upstreamFailure.body, isNot(contains('secret-provider-body')));
        await host.close();
      },
    );

    test('transcribe rejects unconfigured and oversize audio bodies', () async {
      final configPath = _providerJsonPath(temporaryDirectory);
      final host = await _startHost(
        webRoot,
        memoryDirectory,
        sttSettingsService: SttSettingsService(
          JsonProviderConfigRepository(filePath: configPath),
          SttModelGateway(_RecordingSttHttpClient('{"text":"x"}')),
        ),
      );
      final browser = await _openBrowserSession(host);
  
      // 未配置 STT：可读诊断码，不出网。
      final unconfigured = await _sendBytes(
        host.origin.resolve('/api/chat/transcribe'),
        headers: {
          ...browser.mutationHeaders(host.origin)
            ..remove(HttpHeaders.contentTypeHeader),
          HttpHeaders.contentTypeHeader: 'audio/webm',
        },
        body: [1, 2, 3],
      );
      expect(unconfigured.statusCode, HttpStatus.badRequest);
      expect(
        (jsonDecode(unconfigured.body) as Map<String, Object?>)['code'],
        'stt_not_configured',
      );
  
      // 超过 10MB 上限：拒绝且不进入转写。
      final oversize = await _sendBytes(
        host.origin.resolve('/api/chat/transcribe'),
        headers: {
          ...browser.mutationHeaders(host.origin)
            ..remove(HttpHeaders.contentTypeHeader),
          HttpHeaders.contentTypeHeader: 'audio/webm',
        },
        body: List<int>.filled(10 * 1024 * 1024 + 1, 0),
      );
      expect(oversize.statusCode, HttpStatus.badRequest);
      expect(oversize.body, contains('录音文件太大'));
  
      // 被拒后服务依然健康。
      final health = await _send(
        host.origin.resolve('/api/health'),
        headers: browser.readHeaders(host.origin),
      );
      expect(health.statusCode, HttpStatus.ok);
      await host.close();
    });
  });
  group('记忆控制与清数据', () {

    test('memory controls overview and clear-product-data flow', () async {
      final (host, browser) = await _startHostWithBrowser(
        webRoot,
        memoryDirectory,
      );
  
      final webSearchEndpoint = host.origin.resolve('/api/provider/web-search');
      final webSearchSaved = await _send(
        webSearchEndpoint,
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'apiKey': 'clear-me-anysearch-key'}),
      );
      expect(jsonDecode(webSearchSaved.body), {
        'configured': true,
        'keySet': true,
      });
  
      // 先产生一条真实会话，并放一份控制记录夹具。
      final chat = await _postJson(host, browser, '/api/chat', {
        'requestId': 'clear-flow',
        'text': '在吗',
      });
      expect(chat.statusCode, HttpStatus.ok);
      File(
        '${memoryDirectory.path}${Platform.pathSeparator}memory-controls.md',
      ).writeAsStringSync(
        '# memory-controls\n'
        '## frozen\n'
        '- [MC001] chat | 一段冻结的记忆\n'
        '## banned\n'
        '- [MC002] chat | 一段禁提的往事\n'
        '## deleted\n',
      );
  
      // 记忆控制总览：冻结与禁提逐条可见，删除只给数量。
      final controls = await _send(
        host.origin.resolve('/api/memory/controls'),
        headers: browser.readHeaders(host.origin),
      );
      expect(controls.statusCode, HttpStatus.ok);
      final controlsJson = jsonDecode(controls.body) as Map<String, Object?>;
      expect(controlsJson['readable'], isTrue);
      expect(controlsJson['frozen'], hasLength(1));
      expect(controlsJson['banned'], hasLength(1));
      expect(controlsJson['deletedCount'], 0);
  
      // 清除前影响概览：位置与数量准确。
      final preview = await _send(
        host.origin.resolve('/api/data/clear-preview'),
        headers: browser.readHeaders(host.origin),
      );
      expect(preview.statusCode, HttpStatus.ok);
      final previewJson = jsonDecode(preview.body) as Map<String, Object?>;
      expect(previewJson['memoryDirectory'], memoryDirectory.path);
      expect(previewJson['sessionCount'], 1);
      expect(previewJson['frozenCount'], 1);
      expect(previewJson['bannedCount'], 1);
  
      // 未明确确认一律拒绝。
      final unconfirmed = await _postJson(host, browser, '/api/data/clear', {
        'confirm': false,
      });
      expect(unconfirmed.statusCode, HttpStatus.badRequest);
  
      // 确认后清除：产品数据消失，清除前快照保留。
      final cleared = await _postJson(host, browser, '/api/data/clear', {
        'confirm': true,
      });
      expect(cleared.statusCode, HttpStatus.ok);
      expect(jsonDecode(cleared.body), containsPair('cleared', true));
      expect(
        Directory(
          '${memoryDirectory.path}${Platform.pathSeparator}sessions',
        ).existsSync(),
        isFalse,
      );
      expect(
        File(
          '${memoryDirectory.path}${Platform.pathSeparator}memory-controls.md',
        ).existsSync(),
        isFalse,
      );
      final webSearchAfterClear = await _send(
        webSearchEndpoint,
        headers: browser.readHeaders(host.origin),
      );
      expect(jsonDecode(webSearchAfterClear.body), {
        'configured': false,
        'keySet': false,
      });
      expect(
        File(_providerJsonPath(temporaryDirectory)).readAsStringSync(),
        isNot(contains('clear-me-anysearch-key')),
      );
      final snapshots = await _send(
        host.origin.resolve('/api/backup/snapshots'),
        headers: browser.readHeaders(host.origin),
      );
      final snapshotsJson = jsonDecode(snapshots.body) as Map<String, Object?>;
      expect(snapshotsJson['snapshots']! as List<Object?>, hasLength(1));
      await host.close();
    });
  });
  group('记忆召回 embedding 设置', () {

    test('embedding 路由受会话、Origin 与 CSRF 保护，保存后只回 keySet', () async {
      final configPath = _providerJsonPath(temporaryDirectory);
      JsonProviderConfigRepository repository() =>
          JsonProviderConfigRepository(filePath: configPath);
      final embeddingHttp = _RecordingEmbeddingHttpClient();
      EmbeddingSettingsService embeddingService() => EmbeddingSettingsService(
        repository(),
        OpenAiEmbeddingGateway(embeddingHttp),
      );
      final (host, browser) = await _startHostWithBrowser(
        webRoot,
        memoryDirectory,
        embeddingSettingsService: embeddingService(),
      );

      // 变更请求缺 CSRF / 缺 Origin 一律拒绝；读取缺会话拒绝。
      final noCsrf = await _send(
        host.origin.resolve('/api/provider/embedding'),
        method: 'PUT',
        headers: {
          ...browser.readHeaders(host.origin),
          'origin': host.origin.toString().replaceFirst(RegExp(r'/$'), ''),
        },
        requestBody: jsonEncode({
          'baseUrl': 'https://embedding.example.com/v1',
          'model': 'text-embedding-test',
        }),
      );
      expect(noCsrf.statusCode, HttpStatus.forbidden);
      final noOrigin = await _send(
        host.origin.resolve('/api/provider/embedding'),
        method: 'PUT',
        headers: {
          ...browser.readHeaders(host.origin),
          'x-qiyu-csrf': browser.csrfToken,
        },
        requestBody: jsonEncode({
          'baseUrl': 'https://embedding.example.com/v1',
          'model': 'text-embedding-test',
        }),
      );
      expect(noOrigin.statusCode, HttpStatus.forbidden);
      final noSession = await _send(
        host.origin.resolve('/api/provider/embedding'),
        headers: {HttpHeaders.refererHeader: host.origin.toString()},
      );
      expect(noSession.statusCode, HttpStatus.unauthorized);
      await host.close();

      // 保存：Key 只落文件，响应永不回明文，也不带 apiKey 字段名。
      final (savedHost, savedBrowser) = await _startHostWithBrowser(
        webRoot,
        memoryDirectory,
        embeddingSettingsService: embeddingService(),
      );
      final saved = await _send(
        savedHost.origin.resolve('/api/provider/embedding'),
        method: 'PUT',
        headers: savedBrowser.mutationHeaders(savedHost.origin),
        requestBody: jsonEncode({
          'baseUrl': 'https://embedding.example.com/v1',
          'model': 'text-embedding-test',
          'apiKey': 'embedding-secret-value',
        }),
      );
      expect(saved.statusCode, HttpStatus.ok);
      expect(saved.body, isNot(contains('embedding-secret-value')));
      expect(saved.body, isNot(contains('apiKey')));
      expect(
        jsonDecode(saved.body),
        allOf(
          containsPair('configured', true),
          containsPair('keySet', true),
          containsPair('baseUrl', 'https://embedding.example.com/v1'),
          containsPair('model', 'text-embedding-test'),
        ),
      );

      // 连接测试：空负载按已保存配置，只发送固定测试句，成功回 ok。
      embeddingHttp.responseBody = jsonEncode({
        'data': [
          {'index': 0, 'embedding': [0.1, 0.2, 0.3]},
        ],
      });
      final tested = await _send(
        savedHost.origin.resolve('/api/provider/embedding/test'),
        method: 'POST',
        headers: savedBrowser.mutationHeaders(savedHost.origin),
        requestBody: '{}',
      );
      expect(tested.statusCode, HttpStatus.ok);
      expect(jsonDecode(tested.body), containsPair('ok', true));
      final testBody =
          jsonDecode(utf8.decode(embeddingHttp.lastBody!))
              as Map<String, Object?>;
      expect(testBody['input'], [embeddingConnectionTestText]);
      expect(
        embeddingHttp.lastHeaders!['authorization'],
        'Bearer embedding-secret-value',
      );

      // 保存聊天 Provider 不得抹掉 embedding 段；embedding 读取仍就绪。
      final chatSaved = await _send(
        savedHost.origin.resolve('/api/provider'),
        method: 'PUT',
        headers: savedBrowser.mutationHeaders(savedHost.origin),
        requestBody: jsonEncode({
          'provider': 'openai_compatible',
          'baseUrl': 'https://chat.example.com/v1',
          'model': 'chat-model',
          'temperature': 0.6,
          'timeoutSeconds': 25,
        }),
      );
      expect(chatSaved.statusCode, HttpStatus.ok);
      final embeddingStillThere = await _send(
        savedHost.origin.resolve('/api/provider/embedding'),
        headers: savedBrowser.readHeaders(savedHost.origin),
      );
      expect(
        jsonDecode(embeddingStillThere.body),
        containsPair('configured', true),
      );
      expect(embeddingStillThere.body, isNot(contains('apiKey')));

      // 忘记 Key：keySet 变 false，配置本身保留。
      final forgotten = await _send(
        savedHost.origin.resolve('/api/provider/embedding/key'),
        method: 'DELETE',
        headers: savedBrowser.mutationHeaders(savedHost.origin),
      );
      expect(forgotten.statusCode, HttpStatus.ok);
      expect(jsonDecode(forgotten.body), containsPair('keySet', false));
      expect(jsonDecode(forgotten.body), containsPair('configured', true));
      await savedHost.close();
    });

    test('记忆召回启用/停用/重建操作经设置路由生效，状态随读取返回', () async {
      // 预置一条有效 episode：启用后的构建只发送日期与摘要。
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: memoryDirectory.path,
      );
      await pipeline.synchronizedOnDayFiles(
        () => pipeline.writeFinalization(
          '2026-08-10',
          entries: [
            EpisodeEntry(
              id: 'seed:r1:0',
              sessionId: 'seed',
              requestId: 'r1',
              summary: '用户聊到旧书店的事',
              at: DateTime.utc(2026, 8, 10, 12),
            ),
          ],
          summary: '用户聊到旧书店的事',
          finalized: true,
          finalizedAt: DateTime(2026, 8, 15, 22),
        ),
      );
      final configPath = _providerJsonPath(temporaryDirectory);
      final embeddingHttp = _RecordingEmbeddingHttpClient();
      final rag = EpisodeRagService(
        memoryDirectory: memoryDirectory.path,
        configRepository: JsonProviderConfigRepository(filePath: configPath),
        embeddingClient: OpenAiEmbeddingGateway(embeddingHttp),
        episodePipeline: pipeline,
        openLoopStore: OpenLoopStore(memoryDirectory: memoryDirectory.path),
        diagnosticsSink: (_) {},
      );
      final (host, browser) = await _startHostWithBrowser(
        webRoot,
        memoryDirectory,
        episodeRagService: rag,
      );

      // 保存配置（不启用）。
      final saved = await _send(
        host.origin.resolve('/api/provider/embedding'),
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({
          'baseUrl': 'https://embedding.example.com/v1',
          'model': 'text-embedding-test',
          'apiKey': 'embedding-secret-value',
        }),
      );
      expect(saved.statusCode, HttpStatus.ok);
      final savedBody = jsonDecode(saved.body) as Map<String, Object?>;
      expect(savedBody['enabled'], false);
      expect(savedBody['rag'], containsPair('state', 'disabled'));

      // 未启用时重建是无效操作。
      final prematureRebuild = await _send(
        host.origin.resolve('/api/provider/embedding/rebuild'),
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: '{}',
      );
      expect(prematureRebuild.statusCode, HttpStatus.badRequest);

      // 显式启用：触发后台完整构建；响应反映启用之后的事实。
      final enabled = await _send(
        host.origin.resolve('/api/provider/embedding/enable'),
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: '{}',
      );
      expect(enabled.statusCode, HttpStatus.ok);
      final enabledBody = jsonDecode(enabled.body) as Map<String, Object?>;
      expect(enabledBody['enabled'], true, reason: '响应必须是启用后的快照');
      expect((enabledBody['rag']! as Map)['state'], 'preparing');
      expect(enabled.body, isNot(contains('embedding-secret-value')));
      await rag.settlePendingWork();

      // 构建完成：就绪；出网只有日期+摘要，绝无摘录或 Key。
      final ready = await _send(
        host.origin.resolve('/api/provider/embedding'),
        headers: browser.readHeaders(host.origin),
      );
      final readyBody = jsonDecode(ready.body) as Map<String, Object?>;
      expect(readyBody['enabled'], true);
      expect((readyBody['rag']! as Map)['state'], 'ready');
      final buildInput =
          jsonDecode(utf8.decode(embeddingHttp.lastBody!))
              as Map<String, Object?>;
      expect(buildInput['input'], ['2026-08-10\n用户聊到旧书店的事']);
      expect(
        embeddingHttp.lastHeaders!['authorization'],
        'Bearer embedding-secret-value',
      );

      // 明确停用：回到旧路径，状态 disabled。
      final disabled = await _send(
        host.origin.resolve('/api/provider/embedding/disable'),
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: '{}',
      );
      expect(disabled.statusCode, HttpStatus.ok);
      final disabledBody = jsonDecode(disabled.body) as Map<String, Object?>;
      expect(disabledBody['enabled'], false);
      expect((disabledBody['rag']! as Map)['state'], 'disabled');
      await host.close();
    });

    test('embedding 测试失败按允许列表上报，不透出服务商原文或旧 Key', () async {
      final configPath = _providerJsonPath(temporaryDirectory);
      final embeddingHttp = _RecordingEmbeddingHttpClient()
        ..statusCode = 429
        ..responseBody = '{"error":"quota detail with 10.0.0.1 path"}';
      final (host, browser) = await _startHostWithBrowser(
        webRoot,
        memoryDirectory,
        embeddingSettingsService: EmbeddingSettingsService(
          JsonProviderConfigRepository(filePath: configPath),
          OpenAiEmbeddingGateway(embeddingHttp),
        ),
      );

      final saved = await _send(
        host.origin.resolve('/api/provider/embedding'),
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({
          'baseUrl': 'https://embedding.example.com/v1',
          'model': 'text-embedding-test',
          'apiKey': 'embedding-secret-value',
        }),
      );
      expect(saved.statusCode, HttpStatus.ok);

      final tested = await _send(
        host.origin.resolve('/api/provider/embedding/test'),
        method: 'POST',
        headers: browser.mutationHeaders(host.origin),
        requestBody: '{}',
      );
      expect(tested.statusCode, HttpStatus.ok);
      final result = jsonDecode(tested.body) as Map<String, Object?>;
      expect(result['ok'], false);
      expect(result['status'], 'rateLimited');
      expect(result['message'], '记忆召回服务请求过于频繁，请稍后再试。');
      expect(tested.body, isNot(contains('10.0.0.1')));
      expect(tested.body, isNot(contains('quota detail')));
      expect(tested.body, isNot(contains('embedding-secret-value')));
      await host.close();
    });
  });
  group('Web Search 设置', () {

    test('Web Search 设置端点只返回状态并与其他配置段互不覆盖', () async {
      var host = await _startHost(webRoot, memoryDirectory);
      var endpoint = host.origin.resolve('/api/provider/web-search');
      final missingSession = await _send(endpoint);
      expect(missingSession.statusCode, HttpStatus.unauthorized);
  
      var browser = await _openBrowserSession(host);
  
      final initial = await _send(
        endpoint,
        headers: browser.readHeaders(host.origin),
      );
      expect(jsonDecode(initial.body), {'configured': false, 'keySet': false});
  
      final badOriginHeaders = browser.mutationHeaders(host.origin)
        ..['origin'] = 'https://evil.example';
      final badOrigin = await _send(
        endpoint,
        method: 'PUT',
        headers: badOriginHeaders,
        requestBody: jsonEncode({'apiKey': 'must-not-save'}),
      );
      expect(badOrigin.statusCode, HttpStatus.forbidden);
  
      final rejected = await _send(
        endpoint,
        method: 'PUT',
        headers: browser.readHeaders(host.origin),
        requestBody: jsonEncode({'apiKey': 'must-not-save'}),
      );
      expect(rejected.statusCode, HttpStatus.forbidden);
  
      try {
        final oversize = await _send(
          endpoint,
          method: 'PUT',
          headers: browser.mutationHeaders(host.origin),
          requestBody: jsonEncode({'apiKey': 'x' * (9 * 1024)}),
        );
        expect(oversize.statusCode, HttpStatus.badRequest);
      } on SocketException {
        // Host 在读满前中止超限连接同样是拒绝。
      } on HttpException {
        // 中止时机不同时可能收不全响应头，不影响拒绝语义。
      }
  
      final saved = await _send(
        endpoint,
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'apiKey': 'any-secret-value'}),
      );
      expect(jsonDecode(saved.body), {'configured': true, 'keySet': true});
      expect(saved.body, isNot(contains('any-secret-value')));
  
      final replaced = await _send(
        endpoint,
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'apiKey': 'replacement-secret-value'}),
      );
      expect(jsonDecode(replaced.body), {'configured': true, 'keySet': true});
      expect(replaced.body, isNot(contains('replacement-secret-value')));
  
      final retained = await _send(
        endpoint,
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'apiKey': '   '}),
      );
      expect(jsonDecode(retained.body), {'configured': true, 'keySet': true});
  
      final providerFile = File(_providerJsonPath(temporaryDirectory));
      expect(
        await providerFile.readAsString(),
        contains('replacement-secret-value'),
      );
      expect(await providerFile.readAsString(), isNot(contains('any-secret-value')));
      await host.close();
  
      host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        personaConstitution: '测试人格宪法',
      );
      browser = await _openBrowserSession(host);
      endpoint = host.origin.resolve('/api/provider/web-search');
      final restored = await _send(
        endpoint,
        headers: browser.readHeaders(host.origin),
      );
      expect(jsonDecode(restored.body), {'configured': true, 'keySet': true});
      expect(restored.body, isNot(contains('replacement-secret-value')));
  
      final forgotten = await _send(
        host.origin.resolve('/api/provider/web-search/key'),
        method: 'DELETE',
        headers: browser.mutationHeaders(host.origin),
      );
      expect(jsonDecode(forgotten.body), {'configured': false, 'keySet': false});
      expect(
        await providerFile.readAsString(),
        isNot(contains('replacement-secret-value')),
      );
      await host.close();
    });

    test('代理设置端点与局域网 Ollama（ticket 08）', () async {
      var host = await _startHost(webRoot, memoryDirectory);
      var browser = await _openBrowserSession(host);
      final proxyEndpoint = host.origin.resolve('/api/provider/proxy');

      // 初始关闭态；代理没有凭据字段，快照原样回显地址与端口。
      final initial = await _send(
        proxyEndpoint,
        headers: browser.readHeaders(host.origin),
      );
      expect(
        jsonDecode(initial.body),
        {'configured': false, 'enabled': false, 'host': '', 'port': 0},
      );

      // 类型不对的负载按配置格式错误拒绝。
      final malformed = await _send(
        proxyEndpoint,
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'enabled': 'yes'}),
      );
      expect(malformed.statusCode, HttpStatus.badRequest);

      // 启用中的配置缺地址被拒。
      final rejected = await _send(
        proxyEndpoint,
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({'enabled': true, 'host': '', 'port': 7890}),
      );
      expect(rejected.statusCode, HttpStatus.badRequest);
      expect(jsonDecode(rejected.body)['message'], contains('代理地址'));

      // 正常保存：回显地址端口并落盘 provider.json。
      final saved = await _send(
        proxyEndpoint,
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({
          'enabled': true,
          'host': '192.168.1.2',
          'port': 7890,
        }),
      );
      expect(jsonDecode(saved.body), {
        'configured': true,
        'enabled': true,
        'host': '192.168.1.2',
        'port': 7890,
      });
      final providerFile = File(_providerJsonPath(temporaryDirectory));
      final stored =
          jsonDecode(await providerFile.readAsString()) as Map<String, Object?>;
      expect((stored['proxy']! as Map)['host'], '192.168.1.2');
      await host.close();

      // 重启后照常读到（持久化语义与其余设置段一致）。
      host = await LocalAppHost.start(
        webRoot: webRoot.path,
        memoryDirectory: memoryDirectory.path,
        personaConstitution: '测试人格宪法',
      );
      browser = await _openBrowserSession(host);
      final restored = await _send(
        host.origin.resolve('/api/provider/proxy'),
        headers: browser.readHeaders(host.origin),
      );
      expect(jsonDecode(restored.body), {
        'configured': true,
        'enabled': true,
        'host': '192.168.1.2',
        'port': 7890,
      });

      // 局域网 Ollama（明文私网地址、无密钥）可以保存，不要求 Key。
      final ollama = await _send(
        host.origin.resolve('/api/provider'),
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({
          'provider': 'ollama',
          'baseUrl': 'http://192.168.1.10:11434',
          'model': 'qwen3',
          'temperature': 0.7,
          'timeoutSeconds': 60,
        }),
      );
      expect(ollama.statusCode, HttpStatus.ok);
      expect(jsonDecode(ollama.body), containsPair('keySet', false));
      expect(jsonDecode(ollama.body), containsPair('provider', 'ollama'));
      await host.close();
    });

    test('明文公网模型地址拒绝保存并给出人话（ticket 08）', () async {
      final host = await _startHost(webRoot, memoryDirectory);
      final browser = await _openBrowserSession(host);

      // 主机名形态：文案点「请直接填 IP」（它不是公网 IP，不误导）。
      final hostnameRefused = await _send(
        host.origin.resolve('/api/provider'),
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({
          'provider': 'openai_compatible',
          'baseUrl': 'http://api.example.com/v1',
          'model': 'chat-model',
          'temperature': 0.6,
          'timeoutSeconds': 30,
        }),
      );
      expect(hostnameRefused.statusCode, HttpStatus.badRequest);
      expect(jsonDecode(hostnameRefused.body)['code'], 'invalid_provider_config');
      expect(jsonDecode(hostnameRefused.body)['message'], contains('填 IP 地址'));

      // 公网 IP 字面量：文案点「改用 HTTPS」。
      final ipRefused = await _send(
        host.origin.resolve('/api/provider'),
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({
          'provider': 'openai_compatible',
          'baseUrl': 'http://8.8.8.8/v1',
          'model': 'chat-model',
          'temperature': 0.6,
          'timeoutSeconds': 30,
        }),
      );
      expect(ipRefused.statusCode, HttpStatus.badRequest);
      expect(jsonDecode(ipRefused.body)['message'], contains('私有网段'));

      // 同一地址换 https 即放行。
      final accepted = await _send(
        host.origin.resolve('/api/provider'),
        method: 'PUT',
        headers: browser.mutationHeaders(host.origin),
        requestBody: jsonEncode({
          'provider': 'openai_compatible',
          'baseUrl': 'https://api.example.com/v1',
          'model': 'chat-model',
          'temperature': 0.6,
          'timeoutSeconds': 30,
        }),
      );
      expect(accepted.statusCode, HttpStatus.ok);
      await host.close();
    });
  });

  group('后台失败状态（ticket 21）', () {
    test(
      'exposes a sanitized background failure after a failed startup catch-up',
      () async {
        // 预置一份未定稿的历史日期；拦写注入只拦这一天的写入，让启动
        // 补扫真正尝试并失败，其余启动写入不受影响。
        await Directory(
          memoryDirectory.path,
        ).create(recursive: true);
        await _seedUnfinalizedEpisodeDay(
          memoryDirectory.path,
          '2026-08-10',
          summary: '用户完成了演讲',
        );
        final host = await LocalAppHost.start(
          webRoot: webRoot.path,
          memoryDirectory: memoryDirectory.path,
          personaConstitution: '测试人格宪法',
          atomicWriter: FailingAtomicTextWriter(
            shouldFail: (path) => path.contains('2026-08-10'),
          ),
        );
        await host.memoryCadence.finalizePending();

        final browser = await _openBrowserSession(host);
        final response = await _send(
          host.origin.resolve('/api/memory/cadence-status'),
          headers: browser.readHeaders(host.origin),
        );
        expect(response.statusCode, HttpStatus.ok);
        final status = jsonDecode(response.body) as Map<String, Object?>;
        expect(status['task'], '日终归档');
        expect(status['failedAt'], isA<String>());
        expect(status['count'], 1);
        expect(status['recovered'], false);
        // 脱敏：响应只含任务名、时刻、次数与是否已恢复，绝不含内部
        // 错误原文与本机路径。
        expect(response.body, isNot(contains('mock interrupted write')));
        expect(response.body, isNot(contains('Exception')));
        expect(response.body, isNot(contains(temporaryDirectory.path)));
        await host.close();
      },
    );

    test('stays quiet when no background failure was recorded', () async {
      final host = await _startHost(webRoot, memoryDirectory);
      final browser = await _openBrowserSession(host);
      final response = await _send(
        host.origin.resolve('/api/memory/cadence-status'),
        headers: browser.readHeaders(host.origin),
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(jsonDecode(response.body), {'task': null});
      await host.close();
    });
  });
}

/// 播种一份未定稿的 episode 日文件（与记忆节奏模块测试同构）：
/// writeFinalization 契约要求调用方持有 episode 日文件写锁，测试也照做。
Future<void> _seedUnfinalizedEpisodeDay(
  String memoryDirectory,
  String date, {
  required String summary,
}) {
  final pipeline = EpisodeMemoryPipeline(
    memoryDirectory: memoryDirectory,
    clock: () => DateTime(2026, 8, 10, 22),
  );
  return pipeline.synchronizedOnDayFiles(
    () => pipeline.writeFinalization(
      date,
      entries: [
        EpisodeEntry(
          id: 'seed:1:0',
          sessionId: 'seed',
          requestId: 'seed',
          summary: summary,
          at: DateTime.parse('${date}T21:00:00').toUtc(),
        ),
      ],
      summary: summary,
      finalized: false,
    ),
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
  final body = await response.fold<List<int>>(
    <int>[],
    (buffer, chunk) => buffer..addAll(chunk),
  );
  final result = _HttpResponse(response.statusCode, response.headers, body);
  client.close(force: true);
  return result;
}

Future<LocalAppHost> _startHost(
  Directory webRoot,
  Directory memoryDirectory, {
  ProviderSettingsService? providerSettingsService,
  SttSettingsService? sttSettingsService,
  TtsSettingsService? ttsSettingsService,
  WebSearchSettingsService? webSearchSettingsService,
  EmbeddingSettingsService? embeddingSettingsService,
  EpisodeRagService? episodeRagService,
}) => LocalAppHost.start(
  webRoot: webRoot.path,
  memoryDirectory: memoryDirectory.path,
  personaConstitution: '测试人格宪法',
  providerSettingsService: providerSettingsService,
  sttSettingsService: sttSettingsService,
  ttsSettingsService: ttsSettingsService,
  webSearchSettingsService: webSearchSettingsService,
  embeddingSettingsService: embeddingSettingsService,
  episodeRagService: episodeRagService,
);

Future<(LocalAppHost, _BrowserSession)> _startHostWithBrowser(
  Directory webRoot,
  Directory memoryDirectory, {
  ProviderSettingsService? providerSettingsService,
  SttSettingsService? sttSettingsService,
  TtsSettingsService? ttsSettingsService,
  WebSearchSettingsService? webSearchSettingsService,
  EmbeddingSettingsService? embeddingSettingsService,
  EpisodeRagService? episodeRagService,
}) async {
  final host = await _startHost(
    webRoot,
    memoryDirectory,
    providerSettingsService: providerSettingsService,
    sttSettingsService: sttSettingsService,
    ttsSettingsService: ttsSettingsService,
    webSearchSettingsService: webSearchSettingsService,
    embeddingSettingsService: embeddingSettingsService,
    episodeRagService: episodeRagService,
  );
  final browser = await _openBrowserSession(host);
  return (host, browser);
}

String _providerJsonPath(Directory temporaryDirectory) =>
    '${temporaryDirectory.path}${Platform.pathSeparator}provider.json';

/// 目录内「绝对路径 → 文件字节」快照：落盘无副作用断言用它做前后对照，
/// 既看文件集合有没有新增，也看已有文件的字节有没有变。
Future<Map<String, List<int>>> _snapshotFiles(Directory directory) async {
  final snapshot = <String, List<int>>{};
  if (!await directory.exists()) {
    return snapshot;
  }
  await for (final entity in directory.list(recursive: true)) {
    if (entity is File) {
      snapshot[entity.path] = await entity.readAsBytes();
    }
  }
  return snapshot;
}

/// 一条「凭据被破坏的产品写请求」用例：只记请求侧（怎么破坏、期望状态码、期望文案）。
/// 「被拒之后本机状态分毫未动」的判据因写入口而异（配置口看文件字节，聊天口看模型
/// 替身调用数与会话落盘），所以留在各自用例里，不进这张表。
/// 字段名沿用本文件的 HTTP 词汇：statusCode 与 body 同名于 [_HttpResponse] 上被断言
/// 的成员；请求侧的 headers 在本文件指真实请求头 map（[_send] 的 headers 具名实参），
/// 这里放的是「产出被改坏后的请求头」的函数，故按仓库既有的 xxxFor 写法命名为
/// headersFor。[_HttpResponse] 上的 headers 是响应头，不属这条先例。
typedef _RejectedMutationCase = ({
  String label,
  Map<String, String> Function(_BrowserSession browser, Uri origin) headersFor,
  int statusCode,
  String body,
});

/// 配置写入口与聊天写入口共用的四条破坏组合：每条只改坏一项凭据，其余保持合法，
/// 最后一条三样同时坏，必须报基线最先检查到的那一步（来源）。
///
/// **这张表的顺序就是两个写入口发出请求的顺序**，且入口专属条目只能追加在它后面。
/// 套件里有「多个凭据同时错误时报基线最先检查到的那一步」这一优先级断言（末条），
/// 重排任何一行之前先看那条还成不成立。
final List<_RejectedMutationCase> _commonWriteRejectionCases =
    <_RejectedMutationCase>[
      (
        label: '只把 CSRF 令牌换掉，命中修改请求的 CSRF 检查',
        headersFor: (browser, origin) =>
            browser.mutationHeaders(origin)..['x-qiyu-csrf'] = 'wrong-csrf',
        statusCode: HttpStatus.forbidden,
        body: 'Invalid CSRF token',
      ),
      (
        label: 'Cookie、CSRF 都合法，只破坏来源 Origin',
        headersFor: (browser, origin) =>
            browser.mutationHeaders(origin)
              ..['origin'] = 'https://evil.example',
        statusCode: HttpStatus.forbidden,
        body: 'Unexpected request source',
      ),
      (
        label: '载荷、来源与 CSRF 都合法，只移除会话 Cookie',
        headersFor: (browser, origin) =>
            browser.mutationHeaders(origin)..remove(HttpHeaders.cookieHeader),
        statusCode: HttpStatus.unauthorized,
        body: 'Invalid session',
      ),
      (
        label: '三样凭据同时错误：来源检查排在会话与 CSRF 之前',
        headersFor: (browser, origin) => browser.mutationHeaders(origin)
          ..remove(HttpHeaders.cookieHeader)
          ..['origin'] = 'https://evil.example'
          ..['x-qiyu-csrf'] = 'wrong-csrf',
        statusCode: HttpStatus.forbidden,
        body: 'Unexpected request source',
      ),
    ];

/// 配置写入口比聊天写入口多验一条「Origin 等其余凭据合法，只有 Referer 指向站外」，
/// 追加在共用四条之后；顺序约束同 [_commonWriteRejectionCases]。
final List<_RejectedMutationCase> _configWriteRejectionCases =
    <_RejectedMutationCase>[
      ..._commonWriteRejectionCases,
      (
        label: 'Origin、CSRF 都合法，只破坏来源 Referer',
        headersFor: (browser, origin) =>
            browser.mutationHeaders(origin)
              ..[HttpHeaders.refererHeader] = 'https://evil.example/x',
        statusCode: HttpStatus.forbidden,
        body: 'Unexpected request source',
      ),
    ];

/// 在 [path] 这个产品写入口逐条发出 [cases]：断言状态码与响应体文案精确相等，
/// 紧接把这一条的 label 交给 [expectEndpointUntouched] 复核一次。端点、方法与载荷由
/// 用例传入，两个写入口各用一条独立用例把同一批破坏组合对自己的判据验一遍。
///
/// [expectEndpointUntouched] 的尺度只到该入口对应的那一片状态：配置口是
/// provider.json 的字节，聊天口是 Provider 替身调用数与 sessions/ 落盘快照；两份判据
/// 都不覆盖本机其它状态，helper 也不替用例补判据。传入空回调（`(label) async {}`）
/// 照样通过类型检查，代价是整个入口的副作用判据被静默丢掉——这条判据必须由用例给出。
Future<void> _expectRejectedMutations(
  LocalAppHost host,
  _BrowserSession browser,
  String path, {
  required String method,
  required String payload,
  required List<_RejectedMutationCase> cases,
  required Future<void> Function(String label) expectEndpointUntouched,
}) async {
  for (final testCase in cases) {
    final rejected = await _send(
      host.origin.resolve(path),
      method: method,
      headers: testCase.headersFor(browser, host.origin),
      requestBody: payload,
    );
    expect(rejected.statusCode, testCase.statusCode, reason: testCase.label);
    expect(rejected.body, testCase.body, reason: testCase.label);
    await expectEndpointUntouched(testCase.label);
  }
}

/// POST + mutationHeaders + JSON 请求体的固定三参形状：内部仍走 [_send]。
Future<_HttpResponse> _postJson(
  LocalAppHost host,
  _BrowserSession browser,
  String path,
  Object? body,
) => _send(
  host.origin.resolve(path),
  method: 'POST',
  headers: browser.mutationHeaders(host.origin),
  requestBody: jsonEncode(body),
);

/// 与 [_send] 同构，但携带二进制请求体（语音转写路由）。
Future<_HttpResponse> _sendBytes(
  Uri uri, {
  String method = 'POST',
  Map<String, String> headers = const {},
  required List<int> body,
}) async {
  final client = HttpClient();
  final request = await client.openUrl(method, uri);
  request.followRedirects = false;
  headers.forEach(request.headers.set);
  // 明确 Content-Length：超限请求可被服务器在读体前直接拒绝。
  request.contentLength = body.length;
  request.add(body);
  final response = await request.close();
  final responseBody = await response.fold<List<int>>(
    <int>[],
    (buffer, chunk) => buffer..addAll(chunk),
  );
  final result = _HttpResponse(
    response.statusCode,
    response.headers,
    responseBody,
  );
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
  const _HttpResponse(this.statusCode, this.headers, this.bodyBytes);

  final int statusCode;
  final HttpHeaders headers;
  final List<int> bodyBytes;

  /// 文本视图：既有断言用 String 匹配。二进制响应（朗读音频）请用
  /// [bodyBytes]。
  String get body => utf8.decode(bodyBytes, allowMalformed: true);
}

final class _MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> deleteApiKey(String scope) async => values.remove(scope);

  @override
  Future<String?> readApiKey(String scope) async => values[scope];
}

final class _StaticModelGateway implements ModelGateway {
  _StaticModelGateway(this.reply);

  final String reply;
  String? apiKey;

  /// 被调用次数：鉴权拒绝无副作用用例用它断言被拒请求一次都没碰到 Provider。
  int calls = 0;

  @override
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
    int? maxTokens,
  }) async {
    calls += 1;
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
    int? maxTokens,
  }) {
    throw ModelGatewayException(kind: kind, message: '已脱敏的测试错误');
  }
}

/// STT 出网测试客户端：响应内容与状态可按用例改写。
final class _WebSearchRoundTripHttpClient implements ProviderHttpClient {
  static const queryMarker = 'internal-query-marker-9274';
  static const resultMarker = 'internal-result-marker-6841';
  static const leakedSecrets = [
    'as_sk_abcdefghijklmnopqrstuvwxyz123456',
    'ghp_abcdefghijklmnopqrstuvwxyz1234567890',
    'github_pat_abcdefghijklmnopqrstuvwxyz_1234567890',
    'glpat-abcdefghijklmnopqrst',
    'xoxb-123456789012-abcdefghijklmnopqrstuvwx',
    'AKIAIOSFODNN7EXAMPLE',
    'AIzaSyA1234567890abcdefghijklmnopqrstuvwxyz',
    'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnop',
  ];

  final providerBodies = <Map<String, Object?>>[];
  final searchBodies = <Map<String, Object?>>[];

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    Future<void>? whenCancelled,
    ProviderResponseBudget? budget,
  }) async {
    if (uri.toString() == anySearchEndpoint) {
      searchBodies.add(jsonDecode(utf8.decode(body)) as Map<String, Object?>);
      return ProviderHttpResponse(
        statusCode: 200,
        body: Stream.value(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 'qiyu-web-search',
            'result': {
              'results': [
                {
                  'title': '天气来源',
                  'url': 'https://example.com/weather',
                  'snippet': resultMarker,
                },
              ],
            },
          }),
        ),
      );
    }
    providerBodies.add(jsonDecode(utf8.decode(body)) as Map<String, Object?>);
    if (providerBodies.length == 1) {
      return ProviderHttpResponse(
        statusCode: 200,
        body: Stream.fromIterable([
          'data: ${jsonEncode({
            'type': 'content_block_start',
            'content_block': {'type': 'tool_use', 'id': 'tool-1', 'name': 'web_search', 'input': <String, Object?>{}},
          })}\n\n',
          'data: ${jsonEncode({
            'type': 'content_block_delta',
            'delta': {
              'type': 'input_json_delta',
              'partial_json': jsonEncode({
                'query': '$queryMarker ${leakedSecrets.join(' ')} 今天气温',
              }),
            },
          })}\n\n',
          'data: {"type":"message_stop"}\n\n',
        ]),
      );
    }
    return ProviderHttpResponse(
      statusCode: 200,
      body: Stream.fromIterable([
        'data: ${jsonEncode({
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': '查到了，今天会下雨。'},
        })}\n\n',
        'data: {"type":"message_stop"}\n\n',
      ]),
    );
  }
}

final class _RecordingSttHttpClient implements ProviderHttpClient {
  _RecordingSttHttpClient(this.responseBody);

  int statusCode = 200;
  String responseBody;

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    Future<void>? whenCancelled,
    ProviderResponseBudget? budget,
  }) async => ProviderHttpResponse(
    statusCode: statusCode,
    body: Stream.value(responseBody),
  );
}

/// 记录型 embedding 出网客户端：响应可编排，记录最后一次请求的载荷与
/// 鉴权头，供路由全链路验证「测试只发送固定文本」「不发送旧 Key」。
final class _RecordingEmbeddingHttpClient implements ProviderHttpClient {
  _RecordingEmbeddingHttpClient({String? responseBody})
    : responseBody =
          responseBody ??
          jsonEncode({
            'data': [
              {
                'index': 0,
                'embedding': [0.1, 0.2, 0.3],
              },
            ],
          });

  int statusCode = 200;
  String responseBody;
  int postCalls = 0;
  List<int>? lastBody;
  Map<String, String>? lastHeaders;

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
    Future<void>? whenCancelled,
    ProviderResponseBudget? budget,
  }) async {
    postCalls += 1;
    lastBody = body;
    lastHeaders = headers;
    return ProviderHttpResponse(
      statusCode: statusCode,
      body: Stream.value(responseBody),
    );
  }
}

/// TTS 网关测试替身：合成结果与异常可按用例改写，记录最近一次文本。
final class _RecordingTtsGateway implements TtsSynthesisGateway {
  _RecordingTtsGateway({this.audio = const []});

  List<int> audio;
  TtsGatewayException? error;
  String? lastText;

  @override
  Future<List<int>> synthesize({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async {
    lastText = text;
    if (error case final failure?) {
      throw failure;
    }
    return audio;
  }
}
