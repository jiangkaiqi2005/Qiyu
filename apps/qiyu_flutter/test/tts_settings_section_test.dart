import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/settings/provider_catalog.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_section.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_view_model.dart';

/// 语音朗读领域表单的单元测试：协议缺省值、同步（含 extraParams 的
/// JSON 编排）、音色与语速选择态、校验与保存编排都在 [TtsSettingsForm]
/// 内。
void main() {
  final gateway = _RecordingTtsGateway();
  late TtsSettingsViewModel viewModel;

  setUp(() {
    gateway.reset();
    viewModel = TtsSettingsViewModel(gateway, autoStart: false);
  });

  TtsSettingsForm form() {
    final value = TtsSettingsForm();
    value.sync(gateway.snapshot);
    return value;
  }

  test('未配置时按当前协议回填缺省地址、模型、首个音色预设与默认语速', () {
    final value = form();

    expect(value.provider, TtsServiceKind.openAiCompatible);
    expect(value.baseUrlController.text, isEmpty);
    expect(value.modelController.text, isEmpty);
    expect(value.voiceController.text, 'alloy');
    expect(value.speed, isNull);
    expect(value.extraParamsController.text, isEmpty);
    expect(value.voiceDropdownValue, 'alloy');
    expect(value.showCustomVoiceField, isFalse);
    expect(value.apiKeyController.text, isEmpty);
  });

  test('未配置的豆包协议回填火山端点、Resource-Id 与豆包首档音色', () {
    final value = form();
    value.selectProvider('volc_tts');

    expect(
      value.baseUrlController.text,
      'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
    );
    expect(value.modelController.text, 'seed-tts-2.0');
    expect(value.voiceController.text, 'zh_female_vv_uranus_bigtts');
  });

  test('已配置时回填保存值：协议、地址、模型、自定义音色、语速与 extraParams', () {
    gateway.configured = true;
    final value = form();

    expect(value.provider, TtsServiceKind.volcTts);
    expect(value.baseUrlController.text, 'https://tts.example/v3');
    expect(value.modelController.text, 'tts-model');
    // 保存值不在当前协议预设目录里：按自定义音色态呈现并亮出输入框。
    expect(value.voiceController.text, 'my-voice-id');
    expect(value.voiceDropdownValue, customVoiceValue);
    expect(value.showCustomVoiceField, isTrue);
    expect(value.speed, 1.25);
    expect(
      value.extraParamsController.text,
      const JsonEncoder.withIndent('  ').convert({
        'audio_params': {'sample_rate': 16000},
      }),
    );
  });

  testWidgets('获焦字段在同步时保留草稿，未获焦字段照常覆盖', (tester) async {
    final value = TtsSettingsForm();
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
    value.baseUrlController.text = 'https://my-draft.example/v1';
    await tester.pump();
    expect(value.baseUrlFocusNode.hasFocus, isTrue, reason: '前置：字段已获焦');

    value.sync(gateway.snapshotWithConfigured());

    expect(
      value.baseUrlController.text,
      'https://my-draft.example/v1',
      reason: '获焦编辑中的草稿被同步冲掉了',
    );
    expect(value.modelController.text, 'tts-model');
  });

  test('同一份设置重复同步是幂等的，不重置输入中的草稿', () {
    final settings = gateway.snapshot;
    final value = TtsSettingsForm();
    value.sync(settings);
    value.baseUrlController.text = 'https://my-draft.example/v1';

    value.sync(settings);

    expect(value.baseUrlController.text, 'https://my-draft.example/v1');
  });

  test('选择预设音色落名，「输入其他音色 ID」切自定义态并清空等待输入', () {
    final value = form();

    value.selectVoice('echo');
    expect(value.voiceController.text, 'echo');
    expect(value.showCustomVoiceField, isFalse);

    value.selectVoice(customVoiceValue);
    expect(value.voiceController.text, isEmpty);
    expect(value.voiceDropdownValue, customVoiceValue);
    expect(value.showCustomVoiceField, isTrue);
  });

  test('校验驳回空白服务地址或模型名称，并给出人话且不触达网关', () async {
    final value = form();
    value.baseUrlController.text = '   ';

    final reported = <String>[];
    final draft = value.readDraftOrReport(reported.add);

    expect(draft, isNull);
    expect(reported, ['请填写语音合成服务地址和模型名称。']);
    expect(gateway.saveCalls, 0);
  });

  test('校验驳回非法 JSON 与非对象 JSON 的自定义高级参数', () async {
    final value = form();
    value.baseUrlController.text = 'https://api.example.com/v1';
    value.modelController.text = 'tts-1';

    final reported = <String>[];
    value.extraParamsController.text = '{oops';
    expect(
      value.readDraftOrReport(reported.add),
      isNull,
      reason: '语法错误要驳回',
    );
    expect(reported.single, '自定义高级参数 JSON 格式不正确，请检查语法。');

    reported.clear();
    value.extraParamsController.text = '[1, 2, 3]';
    expect(
      value.readDraftOrReport(reported.add),
      isNull,
      reason: '非 JSON 对象要驳回',
    );
    expect(reported.single, '自定义高级参数必须是 JSON 对象。');
    expect(gateway.saveCalls, 0);
  });

  test('保存编排：合法草稿带着音色、语速与 extraParams 交给视图模型', () async {
    final value = form();
    value.baseUrlController.text = '  https://api.example.com/v1  ';
    value.modelController.text = 'tts-1';
    value.voiceController.text = 'alloy';
    value.selectSpeed(1.5);
    value.extraParamsController.text = '{"response_format": "mp3"}';
    value.apiKeyController.text = '  sk-tts  ';

    final saved = await value.save(viewModel, report: (_) {});

    expect(saved, isTrue);
    final draft = gateway.savedDrafts.single;
    expect(draft.baseUrl, 'https://api.example.com/v1');
    expect(draft.model, 'tts-1');
    expect(draft.voice, 'alloy');
    expect(draft.speed, 1.5);
    expect(draft.extraParams, {'response_format': 'mp3'});
    expect(draft.apiKey, 'sk-tts');
    // 保存成功后 Key 草稿即刻清空，不留明文在输入框。
    expect(value.apiKeyController.text, isEmpty);
  });

  test('保存编排：空白 Key 等价于不换 Key（存 null）', () async {
    final value = form();
    value.baseUrlController.text = 'https://api.example.com/v1';
    value.modelController.text = 'tts-1';
    value.apiKeyController.text = '   ';

    await value.save(viewModel, report: (_) {});

    expect(gateway.savedDrafts.single.apiKey, isNull);
  });

  test('保存编排：草稿不合法时不触达网关、不误报保存成功', () async {
    final value = form();
    value.baseUrlController.text = 'https://api.example.com/v1';
    value.modelController.text = 'tts-1';
    value.extraParamsController.text = '{oops';

    final reported = <String>[];
    final saved = await value.save(viewModel, report: reported.add);

    expect(saved, isFalse);
    expect(reported, ['自定义高级参数 JSON 格式不正确，请检查语法。']);
    expect(gateway.saveCalls, 0);
  });

  test('保存编排：网关失败时返回失败，Key 草稿保留待重试', () async {
    gateway.failSave = true;
    final value = form();
    value.baseUrlController.text = 'https://api.example.com/v1';
    value.modelController.text = 'tts-1';
    value.apiKeyController.text = 'sk-tts';

    final saved = await value.save(viewModel, report: (_) {});

    expect(saved, isFalse);
    expect(viewModel.errorMessage, isNotNull);
    expect(value.apiKeyController.text, 'sk-tts');
  });
}

final class _RecordingTtsGateway implements TtsSettingsGateway {
  bool configured = false;
  bool failSave = false;
  final savedDrafts = <TtsSettingsDraft>[];
  int saveCalls = 0;

  void reset() {
    configured = false;
    failSave = false;
    savedDrafts.clear();
    saveCalls = 0;
  }

  TtsSettings get snapshot => TtsSettings(
    configured: configured,
    keySet: configured,
    provider: configured ? TtsServiceKind.volcTts : TtsServiceKind.openAiCompatible,
    baseUrl: configured ? 'https://tts.example/v3' : null,
    model: configured ? 'tts-model' : null,
    voice: configured ? 'my-voice-id' : null,
    speed: configured ? 1.25 : null,
    extraParams: configured
        ? {
            'audio_params': {'sample_rate': 16000},
          }
        : null,
  );

  TtsSettings snapshotWithConfigured() {
    configured = true;
    return snapshot;
  }

  @override
  Future<TtsSettings> read() async => snapshot;

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) async {
    saveCalls += 1;
    if (failSave) {
      throw const ProviderSettingsException('语音朗读设置暂时不可用，请稍后重试。');
    }
    savedDrafts.add(draft);
    return TtsSettings(
      configured: true,
      keySet: draft.apiKey != null,
      provider: draft.provider,
      baseUrl: draft.baseUrl,
      model: draft.model,
      voice: draft.voice,
      speed: draft.speed,
      extraParams: draft.extraParams,
    );
  }

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) async => snapshot;

  @override
  Future<TtsSettings> forgetApiKey() async {
    configured = true;
    return TtsSettings(
      configured: true,
      keySet: false,
      provider: TtsServiceKind.openAiCompatible,
      baseUrl: 'https://api.example.com/v1',
      model: 'tts-1',
    );
  }

  @override
  Future<TtsConnectionTest> testConnection(
    TtsSettingsDraft draft,
  ) async => const TtsConnectionTest(succeeded: true, message: '连接成功。');
}
