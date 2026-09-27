import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_section_shell.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_section.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_view_model.dart';

/// 语音输入领域表单的单元测试：协议缺省值、同步、协议切换的地址
/// 兼容回填、校验与保存编排都在 [SttSettingsForm] 内。
void main() {
  final gateway = _RecordingSttGateway();
  late SttSettingsViewModel viewModel;

  setUp(() {
    gateway.reset();
    viewModel = SttSettingsViewModel(gateway, autoStart: false);
  });

  SttSettingsForm form() {
    final value = SttSettingsForm();
    value.sync(gateway.snapshot);
    return value;
  }

  test('未配置时按当前协议回填缺省地址与模型（OpenAI 兼容为空档）', () {
    final value = form();

    expect(value.provider, SttServiceKind.openaiCompatible);
    expect(value.baseUrlController.text, isEmpty);
    expect(value.modelController.text, isEmpty);
    expect(value.protocolDefaults.urlHint, 'https://api.example.com/v1');
    expect(value.apiKeyController.text, isEmpty);
  });

  test('未配置的豆包协议回填官方 wss 端点与 Resource-Id', () {
    final value = form();
    value.selectProvider('volc_seed_asr');

    expect(
      value.baseUrlController.text,
      'wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream',
    );
    expect(value.modelController.text, 'volc.seedasr.sauc.duration');
  });

  test('未配置的千问协议回填 DashScope 完整端点与 qwen3-asr-flash', () {
    final value = form();
    value.selectProvider('qwen_asr');

    expect(value.provider, SttServiceKind.qwenAsr);
    expect(value.baseUrlController.text, qwenAsrDefaultEndpoint);
    expect(value.modelController.text, qwenAsrDefaultModel);
    expect(value.protocolDefaults.urlHint, qwenAsrDefaultEndpoint);
    expect(value.protocolDefaults.modelHint, qwenAsrDefaultModel);
  });

  test('已配置时回填保存值：协议、地址与模型', () {
    gateway.configured = true;
    final value = form();

    expect(value.provider, SttServiceKind.volcSeedAsr);
    expect(value.baseUrlController.text, 'wss://example.example/wss');
    expect(value.modelController.text, 'asr-model');
  });

  testWidgets('获焦字段在同步时保留草稿，未获焦字段照常覆盖', (tester) async {
    final value = SttSettingsForm();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(
            controller: value.baseUrlController,
            focusNode: value.baseUrlFocusNode,
          ),
        ),
      ),
    );
    await tester.showKeyboard(find.byType(TextField));
    value.baseUrlController.text = 'wss://my-draft.example/ws';
    await tester.pump();
    expect(value.baseUrlFocusNode.hasFocus, isTrue, reason: '前置：字段已获焦');

    value.sync(gateway.snapshotWithConfigured());

    expect(
      value.baseUrlController.text,
      'wss://my-draft.example/ws',
      reason: '获焦编辑中的草稿被同步冲掉了',
    );
    expect(value.modelController.text, 'asr-model');
  });

  testWidgets('模型框支持范围说明只在千问档出现，其余档不出现', (tester) async {
    // 区块嵌在设置页分节壳里：拉高视口保证模型框在命中范围内。
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
              child: ListView(children: const [SttSettingsSection()]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const qwenModelHelp = '支持 HTTP 非流式识别模型，如 $qwenAsrDefaultModel';

    // 说明归属锁死在模型名称框：helperText 渲染在 TextField 子树内，同一句
    // 误挂到服务地址等别的框上时断言会红。
    Finder modelFieldHelp() => find.descendant(
      of: find.byKey(const Key('stt-model')),
      matching: find.text(qwenModelHelp),
    );

    // 初值 OpenAI 兼容档：模型框旁没有支持范围说明。
    expect(modelFieldHelp(), findsNothing);

    // 切到千问档：说明出现在模型名称框旁，且只渲染一处。
    await tester.tap(find.byKey(const Key('stt-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('千问语音识别').last);
    await tester.pumpAndSettle();
    expect(modelFieldHelp(), findsOneWidget);
    // 全页也只此一处：同一句不得重复挂到别的字段上。
    expect(find.text(qwenModelHelp), findsOneWidget);

    // 切到豆包档：说明不再出现。
    await tester.tap(find.byKey(const Key('stt-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('豆包流式语音识别').last);
    await tester.pumpAndSettle();
    expect(modelFieldHelp(), findsNothing);

    // 切到自定义档：同样不出现。
    await tester.tap(find.byKey(const Key('stt-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义转写服务').last);
    await tester.pumpAndSettle();
    expect(modelFieldHelp(), findsNothing);
  });

  test('同一份设置重复同步是幂等的，不重置输入中的草稿', () {
    final settings = gateway.snapshot;
    final value = SttSettingsForm();
    value.sync(settings);
    value.baseUrlController.text = 'https://my-draft.example/v1';

    value.sync(settings);

    expect(value.baseUrlController.text, 'https://my-draft.example/v1');
  });

  test('协议切换：兼容地址保留，仅回填缺省模型；不兼容地址整体换成新协议档', () {
    final value = form();
    value.baseUrlController.text = 'https://api.example.com/v1';
    value.modelController.text = 'whisper-1';

    // https 给豆包不兼容：地址与模型都换成豆包缺省档。
    value.selectProvider('volc_seed_asr');
    expect(
      value.baseUrlController.text,
      'wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream',
    );
    expect(value.modelController.text, 'volc.seedasr.sauc.duration');

    // wss 给 OpenAI 兼容也不兼容：整体换回 OpenAI 空档。
    value.selectProvider('openai_compatible');
    expect(value.baseUrlController.text, isEmpty);
    expect(value.modelController.text, isEmpty);
  });

  test('协议切换：https 地址在 OpenAI 兼容与千问之间互认，模型按既有口径回填', () {
    final value = form();
    value.baseUrlController.text = 'https://api.example.com/v1';
    // 模型留空：切换后按新协议缺省回填（既有口径：空模型才回填）。
    value.modelController.text = '';

    value.selectProvider('qwen_asr');
    expect(value.baseUrlController.text, 'https://api.example.com/v1');
    expect(value.modelController.text, qwenAsrDefaultModel);

    value.selectProvider('openai_compatible');
    expect(value.baseUrlController.text, 'https://api.example.com/v1');
    expect(value.modelController.text, isEmpty);
  });

  test('协议切换：HTTP 家族内互认地址，用户自填的模型不被覆盖', () {
    final value = form();
    value.baseUrlController.text = 'https://api.example.com/v1';
    value.modelController.text = 'my-own-model';

    value.selectProvider('qwen_asr');

    expect(value.baseUrlController.text, 'https://api.example.com/v1');
    expect(value.modelController.text, 'my-own-model');
  });

  test('协议切换：豆包 wss 地址切到千问不兼容，整体换成千问缺省档', () {
    final value = form();
    value.selectProvider('volc_seed_asr');
    value.baseUrlController.text = 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream';
    value.modelController.text = 'volc.seedasr.sauc.duration';

    value.selectProvider('qwen_asr');

    expect(value.baseUrlController.text, qwenAsrDefaultEndpoint);
    expect(value.modelController.text, qwenAsrDefaultModel);
  });

  test('未知 wire 名按缺省协议处理，不改动表单', () {
    final value = form();
    value.baseUrlController.text = 'https://api.example.com/v1';
    value.modelController.text = 'whisper-1';

    value.selectProvider('some_future_protocol');

    expect(value.provider, SttServiceKind.openaiCompatible);
    expect(value.baseUrlController.text, 'https://api.example.com/v1');
    expect(value.modelController.text, 'whisper-1');
  });

  test('未配置的自定义协议回填空档：完整地址与模型都等用户填', () {
    final value = form();
    value.selectProvider('custom');

    expect(value.provider, SttServiceKind.custom);
    expect(value.baseUrlController.text, isEmpty);
    expect(value.modelController.text, isEmpty);
    expect(
      value.protocolDefaults.urlHint,
      'https://api.example.com/v1/audio/transcriptions',
    );
    // 旋钮缺省态：默认 Bearer（输入框留空）、JSON 字段路径、路径缺省 text。
    expect(value.authHeaderController.text, isEmpty);
    expect(value.responseShape, SttResponseShape.jsonPath);
    expect(value.responseFieldController.text, isEmpty);
    expect(value.extraParamsController.text, isEmpty);
  });

  test('已配置自定义档回填旋钮：鉴权头、响应形态、字段路径与高级参数 JSON', () {
    final value = SttSettingsForm();
    value.sync(
      const SttSettings(
        configured: true,
        keySet: true,
        provider: SttServiceKind.custom,
        baseUrl: 'https://stt.example.com/v1/audio/transcriptions',
        model: 'whisper-test',
        authHeader: 'X-Api-Key',
        responseShape: SttResponseShape.sse,
        responseField: 'result.text',
        extraParams: {'speaker': 'zh'},
      ),
    );

    expect(value.provider, SttServiceKind.custom);
    expect(
      value.baseUrlController.text,
      'https://stt.example.com/v1/audio/transcriptions',
    );
    expect(value.authHeaderController.text, 'X-Api-Key');
    expect(value.responseShape, SttResponseShape.sse);
    expect(value.responseFieldController.text, 'result.text');
    expect(value.extraParamsController.text, '{\n  "speaker": "zh"\n}');
  });

  test('协议切换：HTTP 家族内自定义与千问互认地址，切走时清掉自定义旋钮草稿', () {
    final value = form();
    value.baseUrlController.text = 'https://api.example.com/v1';
    value.modelController.text = 'my-own-model';

    value.selectProvider('custom');
    value.authHeaderController.text = 'X-Api-Key';
    value.selectResponseShape('sse');
    value.responseFieldController.text = 'result.text';
    value.extraParamsController.text = '{"speaker":"zh"}';

    // https 地址在自定义与千问之间互认：用户自填的模型不被覆盖。
    value.selectProvider('qwen_asr');
    expect(value.baseUrlController.text, 'https://api.example.com/v1');
    expect(value.modelController.text, 'my-own-model');
    // 旋钮只对自定义档有意义：切走即清草稿，不残留到别的档。
    expect(value.authHeaderController.text, isEmpty);
    expect(value.responseShape, SttResponseShape.jsonPath);
    expect(value.responseFieldController.text, isEmpty);
    expect(value.extraParamsController.text, isEmpty);

    value.selectProvider('custom');
    expect(value.baseUrlController.text, 'https://api.example.com/v1');
  });

  test('协议切换：豆包 wss 地址切到自定义档不兼容，整体换成空档', () {
    final value = form();
    value.selectProvider('volc_seed_asr');

    value.selectProvider('custom');

    expect(value.baseUrlController.text, isEmpty);
    expect(value.modelController.text, isEmpty);
  });

  test('校验要求自定义高级参数是合法 JSON 对象', () {
    final scenarios = [
      (extraText: '[1,2]', message: '自定义高级参数必须是 JSON 对象。'),
      (extraText: '"text"', message: '自定义高级参数必须是 JSON 对象。'),
      (extraText: '{', message: '自定义高级参数 JSON 格式不正确，请检查语法。'),
    ];
    for (final scenario in scenarios) {
      final value = form();
      value.selectProvider('custom');
      value.baseUrlController.text =
          'https://stt.example.com/v1/audio/transcriptions';
      value.modelController.text = 'whisper-test';
      value.extraParamsController.text = scenario.extraText;

      final reported = <String>[];
      final draft = value.readDraftOrReport(reported.add);

      expect(draft, isNull, reason: scenario.extraText);
      expect(reported, [scenario.message], reason: scenario.extraText);
      expect(gateway.saveCalls, 0);
    }
  });

  test('保存编排：自定义草稿带着旋钮与高级参数上送，鉴权头去空白', () async {
    final value = form();
    value.selectProvider('custom');
    value.baseUrlController.text =
        'https://stt.example.com/v1/audio/transcriptions';
    value.modelController.text = 'whisper-test';
    value.apiKeyController.text = '  sk-custom  ';
    value.authHeaderController.text = '  X-Api-Key  ';
    value.selectResponseShape('sse');
    value.responseFieldController.text = 'result.text';
    value.extraParamsController.text = '{"speaker":"zh"}';

    final saved = await value.save(viewModel, report: (_) {});

    expect(saved, isTrue);
    final draft = gateway.savedDrafts.single;
    expect(draft.provider, SttServiceKind.custom);
    expect(draft.baseUrl, 'https://stt.example.com/v1/audio/transcriptions');
    expect(draft.model, 'whisper-test');
    expect(draft.apiKey, 'sk-custom');
    expect(draft.authHeader, 'X-Api-Key');
    expect(draft.responseShape, SttResponseShape.sse);
    expect(draft.responseField, 'result.text');
    expect(draft.extraParams, {'speaker': 'zh'});
    // 保存成功后 Key 草稿即刻清空，不留明文在输入框。
    expect(value.apiKeyController.text, isEmpty);
  });

  test('保存编排：非自定义档草稿不带自定义旋钮', () async {
    final value = form();
    value.selectProvider('custom');
    value.authHeaderController.text = 'X-Api-Key';
    value.extraParamsController.text = '{"speaker":"zh"}';
    value.selectProvider('openai_compatible');
    value.baseUrlController.text = 'https://api.example.com/v1';
    value.modelController.text = 'whisper-1';

    await value.save(viewModel, report: (_) {});

    final draft = gateway.savedDrafts.single;
    expect(draft.provider, SttServiceKind.openaiCompatible);
    expect(draft.authHeader, isNull);
    expect(draft.responseShape, isNull);
    expect(draft.responseField, isNull);
    expect(draft.extraParams, isNull);
  });

  test('校验驳回空白服务地址或模型名称，并给出人话且不触达网关', () async {
    final value = form();
    value.baseUrlController.text = '   ';

    final reported = <String>[];
    final draft = value.readDraftOrReport(reported.add);

    expect(draft, isNull);
    expect(reported, ['请填写语音服务地址和模型名称。']);
    expect(gateway.saveCalls, 0);
  });

  test('保存编排：合法草稿带着所选协议上送，Key 去空白、空值存 null', () async {
    final value = form();
    value.selectProvider('volc_seed_asr');
    value.apiKeyController.text = '  sk-stt  ';

    final saved = await value.save(viewModel, report: (_) {});

    expect(saved, isTrue);
    expect(gateway.savedDrafts.single.provider, SttServiceKind.volcSeedAsr);
    expect(
      gateway.savedDrafts.single.baseUrl,
      'wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream',
    );
    expect(gateway.savedDrafts.single.model, 'volc.seedasr.sauc.duration');
    expect(gateway.savedDrafts.single.apiKey, 'sk-stt');
    // 保存成功后 Key 草稿即刻清空，不留明文在输入框。
    expect(value.apiKeyController.text, isEmpty);
  });

  test('保存编排：千问草稿带着所选协议与端点原值上送', () async {
    final value = form();
    value.selectProvider('qwen_asr');
    value.apiKeyController.text = '  sk-qwen  ';

    final saved = await value.save(viewModel, report: (_) {});

    expect(saved, isTrue);
    expect(gateway.savedDrafts.single.provider, SttServiceKind.qwenAsr);
    expect(gateway.savedDrafts.single.baseUrl, qwenAsrDefaultEndpoint);
    expect(gateway.savedDrafts.single.model, qwenAsrDefaultModel);
    expect(gateway.savedDrafts.single.apiKey, 'sk-qwen');
    expect(value.apiKeyController.text, isEmpty);
  });

  test('保存编排：空白 Key 等价于不换 Key（存 null）', () async {
    final value = form();
    value.baseUrlController.text = 'https://api.example.com/v1';
    value.modelController.text = 'whisper-1';
    value.apiKeyController.text = '   ';

    await value.save(viewModel, report: (_) {});

    expect(gateway.savedDrafts.single.apiKey, isNull);
  });

  test('保存编排：草稿不合法时不触达网关、不误报保存成功', () async {
    final value = form();
    value.modelController.text = '   ';

    final reported = <String>[];
    final saved = await value.save(viewModel, report: reported.add);

    expect(saved, isFalse);
    expect(reported, ['请填写语音服务地址和模型名称。']);
    expect(gateway.saveCalls, 0);
  });

  test('保存编排：网关失败时返回失败，Key 草稿保留待重试', () async {
    gateway.failSave = true;
    final value = form();
    value.baseUrlController.text = 'https://api.example.com/v1';
    value.modelController.text = 'whisper-1';
    value.apiKeyController.text = 'sk-stt';

    final saved = await value.save(viewModel, report: (_) {});

    expect(saved, isFalse);
    expect(viewModel.errorMessage, isNotNull);
    expect(value.apiKeyController.text, 'sk-stt');
  });
}

final class _RecordingSttGateway implements SttSettingsGateway {
  bool configured = false;
  bool failSave = false;
  final savedDrafts = <SttSettingsDraft>[];
  int saveCalls = 0;

  void reset() {
    configured = false;
    failSave = false;
    savedDrafts.clear();
    saveCalls = 0;
  }

  SttSettings get snapshot => SttSettings(
    configured: configured,
    keySet: configured,
    provider: configured
        ? SttServiceKind.volcSeedAsr
        : SttServiceKind.openaiCompatible,
    baseUrl: configured ? 'wss://example.example/wss' : null,
    model: configured ? 'asr-model' : null,
  );

  SttSettings snapshotWithConfigured() {
    configured = true;
    return snapshot;
  }

  @override
  Future<SttSettings> read() async => snapshot;

  @override
  Future<SttSettings> save(SttSettingsDraft draft) async {
    saveCalls += 1;
    if (failSave) {
      throw const ProviderSettingsGatewayException('语音设置暂时不可用，请稍后重试。');
    }
    savedDrafts.add(draft);
    return SttSettings(
      configured: true,
      keySet: draft.apiKey != null,
      provider: draft.provider,
      baseUrl: draft.baseUrl,
      model: draft.model,
    );
  }

  @override
  Future<SttSettings> forgetApiKey() async {
    configured = true;
    return SttSettings(
      configured: true,
      keySet: false,
      provider: SttServiceKind.openaiCompatible,
      baseUrl: 'https://api.example.com/v1',
      model: 'whisper-1',
    );
  }

  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) async =>
      const ProviderTestResult(
        succeeded: true,
        status: ProviderTestStatus.success,
        message: '连接成功。',
      );
}
