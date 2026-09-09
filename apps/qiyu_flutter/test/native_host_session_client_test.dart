import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qiyu_flutter/features/baseline/native_host_session_client.dart';

void main() {
  // 与 Host `/_session/start` 响应一致的引导 fixture：303 + Set-Cookie。
  http.Response seeOtherWithSession() => http.Response(
    '',
    HttpStatus.seeOther,
    headers: const {
      'set-cookie': 'qiyu_session=s1; Path=/; HttpOnly; SameSite=Strict',
      'location': '/',
    },
  );

  NativeHostSessionClient clientFor(
    List<http.Request> requests,
    http.Response Function(http.Request request) respond,
  ) {
    final inner = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/_session/start') {
        return seeOtherWithSession();
      }
      return respond(request);
    });
    return NativeHostSessionClient(
      baseUri: Uri.parse('http://127.0.0.1:43210/'),
      startupToken: 'boot-token',
      inner: inner,
    );
  }

  group('NativeHostSessionClient 会话接管', () {
    test('非 Request 子类（MultipartRequest）同样带上 Cookie 与 Origin', () async {
      // MockClient 只收 http.Request；捕获 BaseRequest 的 fake 才能锁住
      // 「非 Request 子类不静默漏头」——MultipartRequest 是 BaseRequest
      // 直接子类，漏带 Cookie/Origin 会被 Host 401/403 拒。
      final inner = _CapturingBaseClient();
      final client = NativeHostSessionClient(
        baseUri: Uri.parse('http://127.0.0.1:43210/'),
        startupToken: 'boot-token',
        inner: inner,
      );

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('http://127.0.0.1:43210/api/upload'),
      )..fields['name'] = 'audio';
      await client.send(request);

      final sent = inner.sent.single;
      expect(sent, isNot(isA<http.Request>()));
      expect(sent.headers['cookie'], 'qiyu_session=s1');
      expect(sent.headers['origin'], 'http://127.0.0.1:43210');
    });

    test('首个请求前先以启动凭据引导并接住会话 Cookie', () async {
      final requests = <http.Request>[];
      final client = clientFor(requests, (_) => http.Response('ok', 200));

      await client.get(Uri.parse('http://127.0.0.1:43210/api/health'));

      expect(requests, hasLength(2));
      final start = requests.first;
      expect(start.url.path, '/_session/start');
      expect(start.url.queryParameters['token'], 'boot-token');
      // 引导不是页面导航：不跟随 303，从响应头直接接住会话 Cookie。
      expect(start.followRedirects, isFalse);
      expect(requests.last.headers['cookie'], 'qiyu_session=s1');
    });

    test('引导只发生一次：后续请求复用会话，不重复兑换启动凭据', () async {
      final requests = <http.Request>[];
      final client = clientFor(requests, (_) => http.Response('ok', 200));

      await client.get(Uri.parse('http://127.0.0.1:43210/api/health'));
      await client.get(Uri.parse('http://127.0.0.1:43210/api/memory'));

      final starts = requests
          .where((request) => request.url.path == '/_session/start')
          .toList();
      expect(starts, hasLength(1));
      expect(
        requests.where((request) => request.url.path != '/_session/start'),
        everyElement(
          predicate<http.Request>(
            (request) => request.headers['cookie'] == 'qiyu_session=s1',
            '带会话 Cookie',
          ),
        ),
      );
    });

    test('修改请求带同源 Origin（与 Host 修改请求口径一致）', () async {
      final requests = <http.Request>[];
      final client = clientFor(requests, (_) => http.Response('ok', 200));

      await client.post(
        Uri.parse('http://127.0.0.1:43210/api/chat/cancel'),
        body: '{"requestId":"r1"}',
      );

      final post = requests.last;
      expect(post.headers['origin'], 'http://127.0.0.1:43210');
      expect(post.headers['cookie'], 'qiyu_session=s1');
    });

    test('只读请求带 Cookie 但不带 Origin（同源 GET 浏览器同样不带）', () async {
      final requests = <http.Request>[];
      final client = clientFor(requests, (_) => http.Response('ok', 200));

      await client.get(Uri.parse('http://127.0.0.1:43210/api/health'));

      final get = requests.last;
      expect(get.headers['cookie'], 'qiyu_session=s1');
      expect(get.headers.containsKey('origin'), isFalse);
    });

    test('引导响应不是 303 时显式失败', () async {
      final inner = MockClient(
        (_) async => http.Response('nope', HttpStatus.notFound),
      );
      final client = NativeHostSessionClient(
        baseUri: Uri.parse('http://127.0.0.1:43210/'),
        startupToken: 'boot-token',
        inner: inner,
      );

      await expectLater(
        client.get(Uri.parse('http://127.0.0.1:43210/api/health')),
        throwsA(isA<NativeHostException>()),
      );
    });

    test('引导响应没有会话 Cookie 时显式失败', () async {
      final inner = MockClient(
        (_) async => http.Response('', HttpStatus.seeOther),
      );
      final client = NativeHostSessionClient(
        baseUri: Uri.parse('http://127.0.0.1:43210/'),
        startupToken: 'boot-token',
        inner: inner,
      );

      await expectLater(
        client.get(Uri.parse('http://127.0.0.1:43210/api/health')),
        throwsA(isA<NativeHostException>()),
      );
    });

    test('close 转发给内层客户端', () async {
      var closed = false;
      final inner = _CloseTrackingClient(() => closed = true);
      final client = NativeHostSessionClient(
        baseUri: Uri.parse('http://127.0.0.1:43210/'),
        startupToken: 'boot-token',
        inner: inner,
      );

      client.close();

      expect(closed, isTrue);
    });
  });
}

final class _CloseTrackingClient extends http.BaseClient {
  _CloseTrackingClient(this.onClose);

  final void Function() onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.value(utf8.encode('ok')),
      HttpStatus.ok,
    );
  }

  @override
  void close() => onClose();
}

/// 捕获任意 BaseRequest 的内层 fake：引导请求自行应答，其余请求留档。
final class _CapturingBaseClient extends http.BaseClient {
  final List<http.BaseRequest> sent = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path == '/_session/start') {
      return http.StreamedResponse(
        Stream.empty(),
        HttpStatus.seeOther,
        headers: const {
          'set-cookie': 'qiyu_session=s1; Path=/; HttpOnly; SameSite=Strict',
        },
      );
    }
    sent.add(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode('ok')),
      HttpStatus.ok,
    );
  }
}
