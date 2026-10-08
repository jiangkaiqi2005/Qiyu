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
/// widget 上。本票不出现「启用」或「就绪」状态——那是后续票的交付。
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

  testWidgets('说明文案如实告知发送范围、费用与摘录边界，不出现启用态', (tester) async {
    await pumpSection(tester);

    expect(find.text('记忆召回'), findsOneWidget);
    // 告知义务（Spec 用户故事 17、18 与票 02 验收）：启用后发送日期与
    // 摘要、查询发送语义搜索词、费用按该服务计费；摘录不发给该服务。
    expect(find.textContaining('不会启用召回'), findsOneWidget);
    expect(find.textContaining('日期与摘要'), findsOneWidget);
    expect(find.textContaining('语义搜索词'), findsOneWidget);
    expect(find.textContaining('费用按该服务计费'), findsOneWidget);
    expect(find.textContaining('证据摘录不会发给这个服务'), findsOneWidget);

    // 范围边界：本票没有启用开关，也不以假的已就绪状态占位。
    expect(find.byKey(const Key('enable-embedding')), findsNothing);
    expect(find.textContaining('已就绪'), findsNothing);
  });

  testWidgets('keySet 状态驱动 Key 标题与忘记入口；忘记需确认且确认后出网', (tester) async {
    await pumpSection(tester);
    expect(find.text('尚未保存 API Key'), findsOneWidget);
    expect(find.byKey(const Key('forget-embedding-key')), findsNothing);

    // 已保存配置到达（快照回 keySet）：忘记入口出现。
    gateway.configured = true;
    await viewModel.initialize();
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
  bool failSave = false;
  final savedDrafts = <EmbeddingSettingsDraft>[];
  final testDrafts = <EmbeddingSettingsDraft>[];
  int forgetCalls = 0;

  void reset() {
    configured = false;
    failSave = false;
    savedDrafts.clear();
    testDrafts.clear();
    forgetCalls = 0;
  }

  EmbeddingSettings get snapshot =>
      EmbeddingSettings(
        configured: configured,
        keySet: configured,
        baseUrl: configured ? 'https://embedding.example.com/v1' : null,
        model: configured ? 'text-embedding-test' : null,
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
      baseUrl: draft.baseUrl,
      model: draft.model,
    );
  }

  @override
  Future<EmbeddingSettings> forgetApiKey() async {
    forgetCalls += 1;
    return EmbeddingSettings(
      configured: true,
      keySet: false,
      baseUrl: snapshot.baseUrl,
      model: snapshot.model,
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
}
