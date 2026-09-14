import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart' hide ProviderTestResult;

import '../../../packages/qiyu_local_host/test/support/in_process_chat_host.dart';
import 'support/host_transport.dart';
import 'support/shared_fakes.dart';

const _secret = 'private-provider-body-sk-secret-C:\\private\\runtime-cookie';

void main() {
  final cases = [
    (
      label: '401',
      status: 401,
      code: null,
      failure: null,
      category: 'authentication',
      title: 'API Key 鉴权失败',
    ),
    (
      label: '403',
      status: 403,
      code: null,
      failure: null,
      category: 'authentication',
      title: 'API Key 鉴权失败',
    ),
    (
      label: '模型404',
      status: 404,
      code: 'model_not_found',
      failure: null,
      category: 'modelNotFound',
      title: '模型名称不存在',
    ),
    (
      label: '429',
      status: 429,
      code: null,
      failure: null,
      category: 'rateLimited',
      title: '服务请求受限',
    ),
    (
      label: '400',
      status: 400,
      code: null,
      failure: null,
      category: 'client',
      title: '模型服务异常',
    ),
    (
      label: '422',
      status: 422,
      code: null,
      failure: null,
      category: 'client',
      title: '模型服务异常',
    ),
    (
      label: '非模型404',
      status: 404,
      code: 'route_not_found',
      failure: null,
      category: 'client',
      title: '模型服务异常',
    ),
    (
      label: '500',
      status: 500,
      code: null,
      failure: null,
      category: 'server',
      title: null,
    ),
    (
      label: '503',
      status: 503,
      code: null,
      failure: null,
      category: 'server',
      title: null,
    ),
    (
      label: '超时',
      status: 0,
      code: null,
      failure: TimeoutException(_secret),
      category: 'network',
      title: null,
    ),
    (
      label: '断网',
      status: 0,
      code: null,
      failure: const SocketException(_secret),
      category: 'network',
      title: null,
    ),
    (
      label: 'TLS',
      status: 0,
      code: null,
      failure: const HandshakeException(_secret),
      category: 'network',
      title: null,
    ),
    (
      label: 'DNS',
      status: 0,
      code: null,
      failure: const SocketException('Failed host lookup: $_secret'),
      category: 'network',
      title: null,
    ),
  ];
  for (final item in cases) {
    testWidgets('真实 Provider ${item.label} 经 Host 解析、落定延迟与会话频控', (
      tester,
    ) async {
      final traces = await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          () => _produce(item.status, code: item.code, failure: item.failure),
          _LoopbackHttpOverrides(),
        ),
      );
      for (final trace in traces!) {
        for (final event in trace.events.where(
          (e) =>
              e.kind == ChatDeliveryEventKind.state ||
              e.kind == ChatDeliveryEventKind.fallback,
        )) {
          expect(event.toJson()['serviceError'], item.category);
        }
      }
      final exchange = await _gateway([
        traces.first,
      ]).send(requestId: 'r1', text: '在吗');
      expect(exchange.serviceError?.name, item.category);
      final model = await _mount(tester, traces);
      await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pump();
      expect(
        model.messages.where((m) => m.speaker == LocalChatSpeaker.qiyu),
        hasLength(1),
      );
      expect(model.sending, isFalse);
      expect(model.messages.last.serviceError?.name, item.category);
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
      await tester.pump(const Duration(milliseconds: 299));
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      if (item.title != null) {
        expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
        expect(find.text(item.title!), findsOneWidget);
        await tester.tap(find.byKey(const Key('api-error-dialog-dismiss')));
        await tester.pumpAndSettle();
      } else {
        expect(find.byKey(const Key('api-error-dialog')), findsNothing);
        expect(model.latestFallbackReason, isNotNull);
        expect(
          find.byKey(const Key('api-error-notice-banner')),
          findsOneWidget,
        );
      }
      final visible = tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
          .join('\n');
      _expectNoPrivateDetails(visible);
      await tester.enterText(find.byKey(const Key('chat-input')), '还在吗');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();
      expect(
        model.messages.where((m) => m.speaker == LocalChatSpeaker.qiyu),
        hasLength(2),
      );
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
      if (item.title != null) {
        expect(
          find.byKey(const Key('api-error-notice-banner')),
          findsOneWidget,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

Future<List<ChatEventTrace>> _produce(
  int status, {
  String? code,
  Object? failure,
}) async {
  final client = _StatusClient(status, code: code, failure: failure);
  final host = await InProcessChatHost.start(
    modelGateway: ProviderModelGateway(client),
  );
  try {
    final first = await host.sendChat(requestId: 'r1', text: '在吗');
    final second = await host.sendChat(
      requestId: 'r2',
      text: '还在吗',
      sessionId: first.sessionId,
    );
    expect(client.calls, greaterThanOrEqualTo(2));
    expect(second.sessionId, first.sessionId);
    for (final trace in [first, second]) {
      expect(trace.events.last.kind, ChatDeliveryEventKind.done);
      _expectNoPrivateDetails(trace.body);
      expect(trace.body, isNot(contains(host.rootDirectory.path)));
    }
    final stored = await host.storedSession(first.sessionId);
    expect(stored.turns, hasLength(4));
    return [first, second];
  } finally {
    await host.dispose();
  }
}

Future<LocalChatViewModel> _mount(
  WidgetTester tester,
  List<ChatEventTrace> traces,
) async {
  final gateway = _gateway(traces);
  var request = 0;
  final model = LocalChatViewModel(
    gateway,
    requestIdFactory: () => 'r${++request}',
    hostConnectionProbe: FakeHostConnectionProbe(const [true]),
    autoStart: false,
  );
  final router = GoRouter(
    initialLocation: '/chat',
    routes: [
      GoRoute(
        path: '/chat',
        builder: (_, _) =>
            const LocalChatView(sttSettingsGateway: _DisabledStt()),
      ),
      GoRoute(
        path: '/settings',
        builder: (_, _) => const Scaffold(body: Text('设置页')),
      ),
    ],
  );
  addTearDown(model.dispose);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: model,
      child: MaterialApp.router(theme: qiyuDarkTheme(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return model;
}

HttpLocalChatGateway _gateway(List<ChatEventTrace> traces) {
  var index = 0;
  return HttpLocalChatGateway(
    client: hostTransportClient((request) {
      final trace = traces[index++];
      return http.Response(
        trace.body,
        trace.statusCode,
        headers: {'content-type': 'application/x-ndjson; charset=utf-8'},
      );
    }),
    baseUri: Uri.parse('http://127.0.0.1:5173/'),
  );
}

void _expectNoPrivateDetails(String text) {
  for (final secret in [
    'private-provider-body',
    'sk-secret',
    'private\\runtime',
    'runtime-cookie',
    'scripted-test-key',
  ]) {
    expect(text, isNot(contains(secret)));
  }
}

// Provider 请求由 _StatusClient 截断，只有临时 Host 的 loopback HTTP 使用真实客户端。
final class _LoopbackHttpOverrides extends HttpOverrides {}

final class _StatusClient implements ProviderHttpClient {
  _StatusClient(this.status, {this.code, this.failure});
  final int status;
  final String? code;
  final Object? failure;
  int calls = 0;
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
    if (failure != null) throw failure!;
    return ProviderHttpResponse(
      statusCode: status,
      body: Stream.value(
        jsonEncode({
          'error': {'code': code ?? 'request_failed', 'message': _secret},
        }),
      ),
    );
  }
}

final class _DisabledStt implements SttSettingsGateway {
  const _DisabledStt();
  @override
  Future<SttSettings> read() async =>
      const SttSettings(configured: false, keySet: false);
  @override
  Future<SttSettings> save(SttSettingsDraft draft) =>
      throw UnimplementedError();
  @override
  Future<SttSettings> forgetApiKey() => throw UnimplementedError();
  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) =>
      throw UnimplementedError();
}
