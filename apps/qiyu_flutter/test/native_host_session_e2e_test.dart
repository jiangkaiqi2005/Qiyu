import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/baseline/native_host_session_client.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';

/// 原生会话接管的端到端验收（进程内真 127.0.0.1 服务器）：
///
/// - 正例：[NativeHostSessionClient] 作为共享 client 注入网关后，引导
///   兑换、会话 Cookie 回传、修改请求的 Origin/CSRF 全链路在**真 Host
///   校验**下通过（读改写经验设置）。
/// - 反例（证明接管真实生效而非摆设）：无 Cookie／无 Origin／无 CSRF
///   的请求被 Host 的会话前置逐项拒绝。
void main() {
  late Directory root;
  late LocalAppHost host;
  late NativeHostSessionClient session;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('qiyu-native-session-test-');
    final webRoot = Directory('${root.path}${Platform.pathSeparator}web')
      ..createSync(recursive: true);
    Directory(
      '${root.path}${Platform.pathSeparator}memories',
    ).createSync(recursive: true);
    File(
      '${webRoot.path}${Platform.pathSeparator}index.html',
    ).writeAsStringSync('<!doctype html><title>栖语</title>');
    host = await LocalAppHost.start(
      webRoot: webRoot.path,
      memoryDirectory: '${root.path}${Platform.pathSeparator}memories',
      personaConstitution: '测试人格宪法',
    );
    // 在任何引导发生前取出启动凭据：launchUri 是 getter，每次读 Host
    // 当前的启动凭据（兑换成功即轮换）。这里取的初始值仅供共享 client
    // 引导一次；反面用例各自在运行时经 exchangeSessionCookie 读同一
    // getter，拿到的是轮换后的当前凭据，互不影响。
    final startupToken = host.launchUri.queryParameters['token']!;
    session = NativeHostSessionClient(
      baseUri: host.origin,
      startupToken: startupToken,
    );
  });

  tearDownAll(() async {
    session.close();
    await host.close();
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  group('正例：原生接管在真 Host 校验下全链路通过', () {
    // 两个用例各自「先写后读同键自证」，不预设初值：共享 Host 下用例
    // 声明序如何交换都独立成立（ExperiencePreferences 目前只有
    // developerMode 一个键，无第二键可分）。
    test('引导 + 会话 Cookie 回传：读改写闭环读到 false', () async {
      final gateway = HttpSettingsGateway(
        client: session,
        baseUri: session.baseUri,
      );

      expect(
        (await gateway.savePreferences(developerMode: false)).developerMode,
        isFalse,
      );
      expect((await gateway.readPreferences()).developerMode, isFalse);
    });

    test('修改请求（Cookie + Origin + CSRF）：保存 true 并回读一致', () async {
      final gateway = HttpSettingsGateway(
        client: session,
        baseUri: session.baseUri,
      );

      final saved = await gateway.savePreferences(developerMode: true);

      expect(saved.developerMode, isTrue);
      expect((await gateway.readPreferences()).developerMode, isTrue);
    });

    test('连接探测接缝：同一共享 client 探活成功', () async {
      final probe = HttpHostConnectionProbe(
        client: session,
        healthUri: session.baseUri.resolve('/api/health'),
      );

      expect(await probe.isHostAvailable(), isTrue);
    });
  });

  group('反面用例：缺任一接管项即被 Host 拒绝', () {
    /// 绕过接管 client，手动兑换一份会话（用 Host 当前的启动凭据），
    /// 反面用例据此精确缺掉单一接管项。
    Future<String> exchangeSessionCookie() async {
      final client = HttpClient();
      final request = await client.openUrl('GET', host.launchUri);
      request.followRedirects = false;
      final response = await request.close();
      await response.drain<void>();
      client.close(force: true);
      expect(response.statusCode, HttpStatus.seeOther);
      // dart:io 的 HttpHeaders 按头名返回值列表；Host 只发一条会话 Cookie。
      return response.headers[HttpHeaders.setCookieHeader]!.single
          .split(';')
          .first
          .trim();
    }

    Future<String> bootstrapCsrf(String cookie) async {
      final client = HttpClient();
      final request = await client.openUrl(
        'GET',
        host.origin.resolve('/api/bootstrap'),
      );
      request.headers.set(HttpHeaders.cookieHeader, cookie);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close(force: true);
      expect(response.statusCode, HttpStatus.ok);
      return (jsonDecode(body) as Map<String, Object?>)['csrfToken']! as String;
    }

    /// 手发一个 POST /api/session/verify（204 空操作端点，只受会话
    /// 前置校验），按参数决定是否带 Origin 与 CSRF；返回（状态码，
    /// 响应体）。
    Future<(int, String)> postVerify({
      required String cookie,
      bool withOrigin = true,
      bool withCsrf = true,
      required String csrfToken,
    }) async {
      final client = HttpClient();
      final request = await client.openUrl(
        'POST',
        host.origin.resolve('/api/session/verify'),
      );
      request.headers.set(HttpHeaders.cookieHeader, cookie);
      if (withOrigin) {
        request.headers.set('origin', session.origin);
      }
      if (withCsrf) {
        request.headers.set('x-qiyu-csrf', csrfToken);
      }
      request.headers.contentType = ContentType.json;
      request.write('{}');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close(force: true);
      return (response.statusCode, body);
    }

    test('无会话 Cookie 的请求被拒（401）', () async {
      final client = HttpClient();
      final request = await client.openUrl(
        'GET',
        host.origin.resolve('/api/bootstrap'),
      );
      final response = await request.close();
      await response.drain<void>();
      client.close(force: true);

      expect(response.statusCode, HttpStatus.unauthorized);
    });

    test('有 Cookie 但无 Origin 的修改请求被拒（403 源校验）', () async {
      final cookie = await exchangeSessionCookie();
      final csrfToken = await bootstrapCsrf(cookie);

      final (statusCode, body) = await postVerify(
        cookie: cookie,
        withOrigin: false,
        csrfToken: csrfToken,
      );

      expect(statusCode, HttpStatus.forbidden);
      expect(body, 'Unexpected request source');
    });

    test('有 Cookie 与 Origin 但无 CSRF 的修改请求被拒（403 令牌校验）', () async {
      final cookie = await exchangeSessionCookie();
      final csrfToken = await bootstrapCsrf(cookie);

      final (statusCode, body) = await postVerify(
        cookie: cookie,
        withOrigin: true,
        withCsrf: false,
        csrfToken: csrfToken,
      );

      expect(statusCode, HttpStatus.forbidden);
      expect(body, 'Invalid CSRF token');
    });
  });
}
