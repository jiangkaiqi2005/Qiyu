import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
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
    provider: configured ? SttServiceKind.volcSeedAsr : SttServiceKind.openaiCompatible,
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
      throw const ProviderSettingsException('语音设置暂时不可用，请稍后重试。');
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
  Future<ProviderTestResult> testConnection(
    SttSettingsDraft draft,
  ) async => const ProviderTestResult(
    succeeded: true,
    status: ProviderTestStatus.success,
    message: '连接成功。',
  );
}
