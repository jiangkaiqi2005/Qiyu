import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/settings/provider_catalog.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_section.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';

/// 模型连接领域表单的单元测试：同步、套餐选择、校验与保存编排都在
/// [ProviderSettingsForm] 内，这里直接在 seam 上验，不需要架起整个页面。
void main() {
  /// 记录型领域网关：保存与测试直接落账，忘记 Key 翻转 keySet。
  final gateway = _RecordingProviderGateway();
  late ProviderSettingsViewModel viewModel;

  setUp(() {
    gateway.reset();
    viewModel = ProviderSettingsViewModel(gateway, autoStart: false);
  });

  ProviderSettingsForm form() {
    final value = ProviderSettingsForm();
    value.sync(gateway.snapshot);
    return value;
  }

  test('未配置时按所选套餐回填缺省地址、模型与高级参数档位', () async {
    gateway.configured = false;
    final value = form();

    expect(value.selectedProviderId, 'openai');
    expect(value.selectedConnectionId, 'official');
    expect(value.customModel, isFalse);
    expect(value.baseUrlController.text, 'https://api.openai.com/v1');
    expect(value.modelController.text, 'gpt-4.1-mini');
    expect(value.temperatureController.text, '0.7');
    expect(value.timeoutController.text, '60');
    // Key 永不回显：未配置时保持空草稿。
    expect(value.apiKeyController.text, isEmpty);
  });

  test('已配置时回填保存值：地址、模型、temperature 与超时', () async {
    gateway.configured = true;
    final value = form();

    expect(value.baseUrlController.text, 'https://api.example.com/v1');
    expect(value.modelController.text, 'chat-model');
    expect(value.temperatureController.text, '0.7');
    expect(value.timeoutController.text, '60');
  });

  testWidgets('获焦字段在同步时保留草稿，未获焦字段照常覆盖', (tester) async {
    final value = ProviderSettingsForm();
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
    value.baseUrlController.text = 'https://my-draft.example.com/v1';
    await tester.pump();
    expect(value.baseUrlFocusNode.hasFocus, isTrue, reason: '前置：字段已获焦');

    value.sync(_configuredSettings());

    expect(
      value.baseUrlController.text,
      'https://my-draft.example.com/v1',
      reason: '获焦编辑中的草稿被同步冲掉了',
    );
    // 未获焦的模型字段照常跟随已保存值。
    expect(value.modelController.text, 'chat-model');
  });

  test('同一份设置重复同步是幂等的，不重置用户的选择与草稿', () {
    gateway.configured = false;
    final settings = gateway.snapshot;
    final value = ProviderSettingsForm();
    value.sync(settings);
    value.selectModel(customModelValue);
    value.modelController.text = 'my-private-model';

    value.sync(settings);

    expect(value.modelController.text, 'my-private-model');
    expect(value.customModel, isTrue);
  });

  test('切换提供商落到该商第一个套餐，并应用其地址与模型', () async {
    final value = form();

    value.selectProvider('anthropic');

    expect(value.selectedProviderId, 'anthropic');
    expect(value.selectedConnectionId, 'official');
    expect(value.baseUrlController.text, 'https://api.anthropic.com/v1');
    expect(value.modelController.text, 'claude-sonnet-5');
    expect(value.customModel, isFalse);
  });

  test('切换套餐应用该套餐地址；自定义模型清空名称等待输入', () async {
    final value = form();
    value.selectProvider('deepseek');

    value.selectConnection('anthropic');
    expect(value.baseUrlController.text, 'https://api.deepseek.com/anthropic');

    value.selectModel(customModelValue);
    expect(value.customModel, isTrue);
    expect(value.modelController.text, isEmpty);

    value.selectModel('deepseek-v4-flash');
    expect(value.customModel, isFalse);
    expect(value.modelController.text, 'deepseek-v4-flash');
  });

  test('校验驳回非数值 temperature / 超时，并给出人话且不触达网关', () async {
    final value = form();
    value.temperatureController.text = 'warm';

    final reported = <String>[];
    final draft = value.readDraftOrReport(reported.add);

    expect(draft, isNull);
    expect(reported, ['请检查 temperature 和超时时间。']);
    expect(gateway.saveCalls, 0);
  });

  test('校验驳回空白服务地址或模型名称', () async {
    final value = form();
    value.baseUrlController.text = '   ';

    final reported = <String>[];
    final draft = value.readDraftOrReport(reported.add);

    expect(draft, isNull);
    expect(reported, ['请填写服务地址和模型名称。']);
  });

  test('保存编排：合法草稿带着所选套餐的协议与 Key 交给视图模型', () async {
    gateway.configured = false;
    final value = form();
    value.selectProvider('anthropic');
    value.apiKeyController.text = '  sk-secret  ';

    final saved = await value.save(viewModel, report: (_) {});

    expect(saved, isTrue);
    expect(gateway.saveCalls, 1);
    expect(gateway.savedDrafts.single.provider, ProviderKind.anthropic);
    expect(gateway.savedDrafts.single.baseUrl, 'https://api.anthropic.com/v1');
    expect(gateway.savedDrafts.single.model, 'claude-sonnet-5');
    expect(gateway.savedDrafts.single.temperature, 0.7);
    expect(gateway.savedDrafts.single.timeoutSeconds, 60);
    // Key 在领域内去除首尾空白后上送。
    expect(gateway.savedDrafts.single.apiKey, 'sk-secret');
    // 保存成功后 Key 草稿即刻清空，不留明文在输入框。
    expect(value.apiKeyController.text, isEmpty);
  });

  test('保存编排：草稿不合法时不触达网关、不误报保存成功', () async {
    final value = form();
    value.temperatureController.text = 'warm';

    final reported = <String>[];
    final saved = await value.save(viewModel, report: reported.add);

    expect(saved, isFalse);
    expect(reported, ['请检查 temperature 和超时时间。']);
    expect(gateway.saveCalls, 0);
  });

  test('保存编排：网关失败时返回失败，Key 草稿保留待重试', () async {
    gateway.failSave = true;
    final value = form();
    value.apiKeyController.text = 'sk-secret';

    final saved = await value.save(viewModel, report: (_) {});

    expect(saved, isFalse);
    expect(viewModel.errorMessage, isNotNull);
    expect(value.apiKeyController.text, 'sk-secret');
  });

  test('保存编排：保存成功后网关回执落进视图模型', () async {
    gateway.configured = false;
    final value = form();
    value.modelController.text = 'gpt-5.2';

    await value.save(viewModel, report: (_) {});

    // 保存返回的新设置由视图模型持有，供页面下一次同步消费。
    expect(viewModel.settings?.model, 'gpt-5.2');
    expect(viewModel.settings?.configured, isTrue);
  });
}

ProviderSettings _configuredSettings() => const ProviderSettings(
  configured: true,
  keySet: true,
  provider: ProviderKind.openAiCompatible,
  baseUrl: 'https://api.example.com/v1',
  model: 'chat-model',
  temperature: 0.7,
  timeoutSeconds: 60,
);

final class _RecordingProviderGateway implements ProviderSettingsGateway {
  bool configured = false;
  bool failSave = false;
  final savedDrafts = <ProviderSettingsDraft>[];
  int saveCalls = 0;

  void reset() {
    configured = false;
    failSave = false;
    savedDrafts.clear();
    saveCalls = 0;
  }

  ProviderSettings get snapshot => ProviderSettings(
    configured: configured,
    keySet: configured,
    provider: configured ? ProviderKind.openAiCompatible : null,
    baseUrl: configured ? 'https://api.example.com/v1' : null,
    model: configured ? 'chat-model' : null,
    temperature: configured ? 0.7 : null,
    timeoutSeconds: configured ? 60 : null,
  );

  @override
  Future<ProviderSettings> read() async => snapshot;

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) async {
    saveCalls += 1;
    if (failSave) {
      throw const ProviderSettingsGatewayException('模型设置暂时不可用，请稍后重试。');
    }
    savedDrafts.add(draft);
    configured = true;
    return ProviderSettings(
      configured: true,
      keySet: draft.apiKey != null,
      provider: draft.provider,
      baseUrl: draft.baseUrl,
      model: draft.model,
      temperature: draft.temperature,
      timeoutSeconds: draft.timeoutSeconds,
    );
  }

  @override
  Future<ProviderSettings> forgetApiKey() async {
    configured = true;
    return ProviderSettings(
      configured: true,
      keySet: false,
      provider: ProviderKind.openAiCompatible,
      baseUrl: 'https://api.example.com/v1',
      model: 'chat-model',
      temperature: 0.7,
      timeoutSeconds: 60,
    );
  }

  @override
  Future<ProviderTestResult> testConnection(
    ProviderSettingsDraft draft,
  ) async => const ProviderTestResult(
    succeeded: true,
    status: ProviderTestStatus.success,
    message: '连接成功，栖语可以使用这个模型。',
  );
}
