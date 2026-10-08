import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/settings/embedding_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';

import 'support/shared_fakes.dart';

/// 聊天输入旁的记忆召回简短状态行（票 03）：准备中显示完成量、需重建
/// 与暂不可用给一句人话；已就绪与未启用零占位。状态不是消息、不进
/// 会话历史，随视图模型转发的监控状态刷新。
void main() {
  testWidgets('准备中占位并显示完成量；已就绪时收起', (tester) async {
    final gateway = _FakeRecallGateway(
      _settingsFor('preparing', done: 1, total: 3),
    );
    final viewModel = _viewModel(gateway);
    await _pump(tester, viewModel);

    // 轮询 tick 推进：探测可达 → 读状态快照 → 通知 → 状态行出现。
    // 注意准备中带永续转圈动画，本测试只用定长 pump，不用 pumpAndSettle。
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.byKey(const Key('memory-recall-status')), findsOneWidget);
    expect(find.textContaining('准备中 1/3'), findsOneWidget);
    expect(find.byKey(const Key('recall-preparing-spinner')), findsOneWidget);

    // 转为已就绪：下一次 tick 后状态行收起（零占位）。
    gateway.settings = _settingsFor('ready');
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.byKey(const Key('memory-recall-status')), findsNothing);

    await _teardown(tester, viewModel);
  });

  testWidgets('需重建与暂不可用给出人话提示；会话消息列表不受影响', (tester) async {
    final gateway = _FakeRecallGateway(_settingsFor('rebuildNeeded'));
    final viewModel = _viewModel(gateway);
    await _pump(tester, viewModel);
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.textContaining('需要重建'), findsOneWidget);

    gateway.settings = EmbeddingSettings(
      configured: true,
      keySet: true,
      enabled: true,
      baseUrl: 'https://embedding.example.com/v1',
      model: 'text-embedding-test',
      rag: MemoryRecallStatus(
        state: 'unavailable',
        progressDone: 0,
        progressTotal: 0,
        reason: '记忆召回服务连接超时。',
      ),
    );
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('记忆召回服务连接超时。'), findsOneWidget);
    // 状态只是旁路快照：空会话照常进入首页问候态，没有新增消息 turn。
    expect(find.byKey(const Key('home-greeting')), findsOneWidget);

    await _teardown(tester, viewModel);
  });
}

LocalChatViewModel _viewModel(_FakeRecallGateway gateway) => LocalChatViewModel(
  _StubChatGateway(),
  hostConnectionProbe: FakeHostConnectionProbe(const [true]),
  memoryRecallStatusGateway: gateway,
  autoStart: true,
  monitorInterval: const Duration(milliseconds: 10),
);

Future<void> _pump(WidgetTester tester, LocalChatViewModel viewModel) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [ChangeNotifierProvider.value(value: viewModel)],
      child: MaterialApp(
        home: LocalChatView(sttSettingsGateway: const _FixedSttGateway()),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 5));
}

/// 显式卸载并释放：监控的轮询计时器必须在测试体结束前取消，否则
/// flutter_test 的 pending-timer 不变量会失败。
Future<void> _teardown(WidgetTester tester, LocalChatViewModel viewModel) async {
  await tester.pumpWidget(const SizedBox.shrink());
  viewModel.dispose();
}

EmbeddingSettings _settingsFor(
  String state, {
  int done = 0,
  int total = 0,
}) => EmbeddingSettings(
  configured: true,
  keySet: true,
  enabled: true,
  baseUrl: 'https://embedding.example.com/v1',
  model: 'text-embedding-test',
  rag: MemoryRecallStatus(
    state: state,
    progressDone: done,
    progressTotal: total,
  ),
);

final class _FakeRecallGateway implements MemoryRecallStatusGateway {
  _FakeRecallGateway(this.settings);

  EmbeddingSettings settings;

  @override
  Future<EmbeddingSettings?> read() async => settings;
}

final class _FixedSttGateway implements SttSettingsGateway {
  const _FixedSttGateway();

  @override
  Future<SttSettings> read() async => const SttSettings(
    configured: false,
    keySet: false,
    provider: SttServiceKind.openaiCompatible,
  );

  @override
  Future<SttSettings> save(SttSettingsDraft draft) =>
      throw UnimplementedError();

  @override
  Future<SttSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) =>
      throw UnimplementedError();
}

/// 最小聊天网关：恢复空会话，收发路径在本测试不触达。
final class _StubChatGateway implements StreamingLocalChatGateway {
  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      const LocalChatSnapshot(sessionId: 'session-1', messages: []);

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<bool> stopVoice(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
    String? locale,
  }) async => '';

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
    String? locale,
  }) async* {}
}
