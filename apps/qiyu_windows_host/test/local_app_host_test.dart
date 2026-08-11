import 'dart:convert';
import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late Directory webRoot;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-local-host-test-',
    );
    webRoot = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}web',
    )..createSync();
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
      final host = await LocalAppHost.start(webRoot: webRoot.path);

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
      final host = await LocalAppHost.start(webRoot: webRoot.path);

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
      final restartedHost = await LocalAppHost.start(webRoot: webRoot.path);
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
}

Future<_HttpResponse> _send(
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const {},
  String? hostOverride,
}) async {
  final client = HttpClient();
  final request = await client.openUrl(method, uri);
  request.followRedirects = false;
  if (hostOverride != null) {
    request.headers.host = hostOverride;
  }
  headers.forEach(request.headers.set);
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  final result = _HttpResponse(response.statusCode, response.headers, body);
  client.close(force: true);
  return result;
}

final class _HttpResponse {
  const _HttpResponse(this.statusCode, this.headers, this.body);

  final int statusCode;
  final HttpHeaders headers;
  final String body;
}
