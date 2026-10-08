import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/settings/embedding_settings_client.dart';
import 'package:qiyu_flutter/features/settings/embedding_settings_section.dart';
import 'package:qiyu_flutter/features/settings/embedding_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_section_shell.dart';

/// 记忆召回设置领域测试：表单草稿校验与保存编排在
/// [EmbeddingSettingsForm]，告知义务、忘记确认与测试编排挂在区块
/// widget 上；票 03 覆盖启用确认、状态展示与停用/重建入口。
void main() {
  final gateway = _RecordingEmbeddingGateway();
  late EmbeddingSettingsViewModel viewModel;

  setUp(() {
    gateway.reset();
    viewModel = EmbeddingSettingsViewModel(gateway, autoStart: false);
  });

  Future<void> pumpSection(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await viewModel.initialize();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: viewModel,
        child: MaterialApp(
          home: Scaffold(
            body: SettingsSectionCollapseScope(
              collapsed: const {},
              onToggle: (_) {},
              child: ListView(children: const [EmbeddingSettingsSection()]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 区块挂载期持有状态刷新计时器：测试结束时卸载整树，dispose 取消
    // 计时器，不留 pending timer。
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  test('保存编排：地址与模型必填，Key 去空白、空白等价于不换 Key', () async {
    final value = EmbeddingSettingsForm();
    final reports = <String>[];

    // 缺地址或模型：草稿驳回，人话上报，不出网。
    value.readDraftOrReport(reports.add);
    expect(reports.single, '请填写记忆召回服务地址和模型名称。');
    expect(gateway.savedDrafts, isEmpty);

    value.baseUrlController.text = ' https://embedding.example.com/v1 ';
    value.modelController.text = ' text-embedding-test ';
    value.apiKeyController.text = '  embedding-secret  ';

    final saved = await value.save(viewModel, report: (_) {});

    expect(saved, isTrue);
    final draft = gateway.savedDrafts.single;
    expect(draft.baseUrl, 'https://embedding.example.com/v1');
    expect(draft.model, 'text-embedding-test');
    expect(draft.apiKey, 'embedding-secret');
  });

  test('保存编排：Key 空白存 null，成功清草稿、失败保留待重试', () async {
    final value = EmbeddingSettingsForm();
    value.baseUrlController.text = 'https://embedding.example.com/v1';
    value.modelController.text = 'text-embedding-test';

    await value.save(viewModel, report: (_) {});
    expect(gateway.savedDrafts.last.apiKey, isNull);
    expect(value.apiKeyController.text, isEmpty);

    gateway.failSave = true;
    value.apiKeyController.text = 'embedding-retry';
    final saved = await value.save(viewModel, report: (_) {});

    expect(saved, isFalse);
    expect(viewModel.errorMessage, isNotNull);
    // 壳层保存编排的语义：失败时草稿保留待重试，不回填也不清空。
    expect(value.apiKeyController.text, 'embedding-retry');
  });

  testWidgets('说明文案如实告知发送范围、费用与摘录边界', (tester) async {
    await pumpSection(tester);

    expect(find.text('记忆召回'), findsOneWidget);
    // 告知义务（Spec 用户故事 17、18）：启用后发送日期与摘要、查询发送
    // 语义搜索词、费用按该服务计费；摘录不发给该服务。
    expect(find.textContaining('不会启用召回'), findsOneWidget);
    expect(find.textContaining('日期与摘要'), findsOneWidget);
    expect(find.textContaining('语义搜索词'), findsOneWidget);
    expect(find.textContaining('费用按该服务计费'), findsOneWidget);
    expect(find.textContaining('证据摘录不会发给这个服务'), findsOneWidget);

    // 未配置时启用入口存在但不可点（先保存配置再启用），状态未就绪。
    final enableButton = tester.widget<FilledButton>(
      find.byKey(const Key('enable-memory-recall')),
    );
    expect(enableButton.onPressed, isNull);
    expect(find.textContaining('已就绪'), findsNothing);
  });

  testWidgets('首次启用前呈现外发范围与费用确认；确认后才出网启用', (tester) async {
    gateway.configured = true;
    await pumpSection(tester);
    expect(find.byKey(const Key('forget-embedding-key')), findsOneWidget);

    // 启用按钮可点：先弹确认对话框，取消不出网。确认文案如实说明
    // 外发范围与费用（与区块常驻说明同文并存，断言至少一处即可）。
    final enableButton = tester.widget<FilledButton>(
      find.byKey(const Key('enable-memory-recall')),
    );
    expect(enableButton.onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('enable-memory-recall')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('embedding-enable-cancel')), findsOneWidget);
    expect(find.byKey(const Key('embedding-enable-confirm')), findsOneWidget);
    expect(find.textContaining('日期与摘要会发送'), findsWidgets);
    expect(find.textContaining('费用按该服务计费'), findsWidgets);
    await tester.tap(find.byKey(const Key('embedding-enable-cancel')));
    await tester.pumpAndSettle();
    expect(gateway.enableCalls, 0);

    // 确认启用：出网一次，状态快照回填（准备中 → 就绪）。
    await tester.tap(find.byKey(const Key('enable-memory-recall')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('embedding-enable-confirm')));
    await tester.pumpAndSettle();
    expect(gateway.enableCalls, 1);
    expect(viewModel.settings?.enabled, isTrue);
    expect(find.textContaining('准备中'), findsOneWidget);
    gateway.ragState = 'ready';
    await viewModel.refresh();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('embedding-recall-state')), findsOneWidget);
    expect(find.text('已就绪'), findsOneWidget);
  });

  testWidgets('状态行展示准备中进度、暂不可用原因与重建入口', (tester) async {
    gateway.configured = true;
    gateway.enabled = true;
    gateway.ragState = 'preparing';
    gateway.progressDone = 1;
    gateway.progressTotal = 3;
    await pumpSection(tester);

    expect(find.textContaining('准备中：1/3'), findsOneWidget);
    expect(find.byKey(const Key('embedding-recall-progress')), findsOneWidget);
    // 准备中不给重建入口（构建还在推进）。
    expect(find.byKey(const Key('rebuild-memory-recall')), findsNothing);

    // 暂不可用：人话原因 + 重建入口；停用入口常驻。
    gateway.ragState = 'unavailable';
    gateway.ragReason = '记忆召回服务连接超时。';
    await viewModel.refresh();
    await tester.pumpAndSettle();
    expect(find.textContaining('暂不可用'), findsOneWidget);
    expect(find.text('记忆召回服务连接超时。'), findsOneWidget);
    expect(find.byKey(const Key('rebuild-memory-recall')), findsOneWidget);
    expect(find.byKey(const Key('disable-memory-recall')), findsOneWidget);

    // 需重建同样给重建入口。
    gateway.ragState = 'rebuildNeeded';
    gateway.ragReason = null;
    await viewModel.refresh();
    await tester.pumpAndSettle();
    expect(find.textContaining('需要重建'), findsOneWidget);
    expect(find.byKey(const Key('rebuild-memory-recall')), findsOneWidget);
  });

  testWidgets('停用与重建是显式操作：点击出网并以返回快照回显', (tester) async {
    gateway.configured = true;
    gateway.enabled = true;
    gateway.ragState = 'ready';
    await pumpSection(tester);
    expect(find.text('已就绪'), findsOneWidget);

    // 停用：回未启用，旧召回路径继续。
    await tester.tap(find.byKey(const Key('disable-memory-recall')));
    await tester.pumpAndSettle();
    expect(gateway.disableCalls, 1);
    expect(viewModel.settings?.enabled, isFalse);

    // 重建：显式出网（状态机同样允许对已启用实例重建）。
    gateway.enabled = true;
    gateway.ragState = 'rebuildNeeded';
    await viewModel.refresh();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rebuild-memory-recall')));
    await tester.pumpAndSettle();
    expect(gateway.rebuildCalls, 1);
    expect(find.textContaining('准备中'), findsOneWidget);
  });

  testWidgets('keySet 状态驱动 Key 标题与忘记入口；忘记需确认且确认后出网', (tester) async {
    await pumpSection(tester);
    expect(find.text('尚未保存 API Key'), findsOneWidget);
    expect(find.byKey(const Key('forget-embedding-key')), findsNothing);

    // 已保存配置到达（快照回 keySet）：忘记入口出现。
    gateway.configured = true;
    await viewModel.refresh();
    await tester.pumpAndSettle();
    expect(find.text('Key 已保存在本机'), findsOneWidget);

    await tester.tap(find.byKey(const Key('forget-embedding-key')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('embedding-forget-key-dialog')), findsOneWidget);

    // 先取消：不出网。
    await tester.tap(find.byKey(const Key('embedding-forget-key-cancel')));
    await tester.pumpAndSettle();
    expect(gateway.forgetCalls, 0);

    await tester.tap(find.byKey(const Key('forget-embedding-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('embedding-forget-key-confirm')));
    await tester.pumpAndSettle();
    expect(gateway.forgetCalls, 1);
  });

  testWidgets('测试连接按表单草稿出网并把结果渲染成横幅；草稿不合法不出网', (tester) async {
    await pumpSection(tester);

    // 地址与模型都空：草稿驳回，网关零调用。
    await tester.tap(find.byKey(const Key('test-embedding-connection')));
    await tester.pumpAndSettle();
    expect(gateway.testDrafts, isEmpty);

    await tester.enterText(
      find.byKey(const Key('embedding-base-url')),
      'https://embedding.example.com/v1',
    );
    await tester.enterText(find.byKey(const Key('embedding-model')), 'text-embedding-test');
    await tester.enterText(find.byKey(const Key('embedding-api-key')), 'embedding-secret');
    await tester.tap(find.byKey(const Key('test-embedding-connection')));
    await tester.pumpAndSettle();

    expect(gateway.testDrafts.single.baseUrl, 'https://embedding.example.com/v1');
    expect(gateway.testDrafts.single.apiKey, 'embedding-secret');
    expect(
      find.text('连接成功，记忆召回服务可以使用。'),
      findsOneWidget,
    );
  });
}

final class _RecordingEmbeddingGateway implements EmbeddingSettingsGateway {
  bool configured = false;
  bool enabled = false;
  String ragState = 'disabled';
  String? ragReason;
  int progressDone = 0;
  int progressTotal = 0;
  bool failSave = false;
  final savedDrafts = <EmbeddingSettingsDraft>[];
  final testDrafts = <EmbeddingSettingsDraft>[];
  int forgetCalls = 0;
  int enableCalls = 0;
  int disableCalls = 0;
  int rebuildCalls = 0;

  void reset() {
    configured = false;
    enabled = false;
    ragState = 'disabled';
    ragReason = null;
    progressDone = 0;
    progressTotal = 0;
    failSave = false;
    savedDrafts.clear();
    testDrafts.clear();
    forgetCalls = 0;
    enableCalls = 0;
    disableCalls = 0;
    rebuildCalls = 0;
  }

  EmbeddingSettings get snapshot => EmbeddingSettings(
    configured: configured,
    keySet: configured,
    enabled: enabled,
    baseUrl: configured ? 'https://embedding.example.com/v1' : null,
    model: configured ? 'text-embedding-test' : null,
    rag: MemoryRecallStatus(
      state: ragState,
      progressDone: progressDone,
      progressTotal: progressTotal,
      reason: ragReason,
    ),
  );

  @override
  Future<EmbeddingSettings> read() async => snapshot;

  @override
  Future<EmbeddingSettings> save(EmbeddingSettingsDraft draft) async {
    if (failSave) {
      throw const ProviderSettingsGatewayException('记忆召回设置暂时不可用，请稍后重试。');
    }
    savedDrafts.add(draft);
    configured = true;
    return EmbeddingSettings(
      configured: true,
      keySet: draft.apiKey != null,
      enabled: enabled,
      baseUrl: draft.baseUrl,
      model: draft.model,
      rag: snapshot.rag,
    );
  }

  @override
  Future<EmbeddingSettings> forgetApiKey() async {
    forgetCalls += 1;
    return EmbeddingSettings(
      configured: true,
      keySet: false,
      enabled: enabled,
      baseUrl: snapshot.baseUrl,
      model: snapshot.model,
      rag: snapshot.rag,
    );
  }

  @override
  Future<ProviderTestResult> testConnection(EmbeddingSettingsDraft draft) async {
    testDrafts.add(draft);
    return const ProviderTestResult(
      succeeded: true,
      status: ProviderTestStatus.success,
      message: '连接成功，记忆召回服务可以使用。',
    );
  }

  @override
  Future<EmbeddingSettings> enable() async {
    enableCalls += 1;
    enabled = true;
    ragState = 'preparing';
    progressDone = 0;
    progressTotal = 1;
    return snapshot;
  }

  @override
  Future<EmbeddingSettings> disable() async {
    disableCalls += 1;
    enabled = false;
    ragState = 'disabled';
    ragReason = null;
    return snapshot;
  }

  @override
  Future<EmbeddingSettings> rebuild() async {
    rebuildCalls += 1;
    ragState = 'preparing';
    progressDone = 0;
    progressTotal = 1;
    ragReason = null;
    return snapshot;
  }
}
