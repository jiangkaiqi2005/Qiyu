import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_section.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/settings_section_shell.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_section.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_section.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_view_model.dart';

/// 表单骨架的跨域一致性测试：「保存即清 Key 不沿用旧凭据」的语义只在
/// 壳层 [SettingsCredentialForm] 写一份，三个凭据域（模型连接、语音朗读、
/// 语音输入）继承后走同一实现。这里在领域 seam 上对每个域验证同一组
/// 断言——任一域若脱开骨架另抄一份保存编排，对应断言即翻红。
void main() {
  group('凭据表单骨架：保存即清 Key 三域同实现', () {
    test('模型连接：成功即清、失败保留、卸载后不再触碰', () async {
      final gateway = _RecordingProviderGateway();
      final viewModel = ProviderSettingsViewModel(gateway, autoStart: false);
      final form = ProviderSettingsForm();

      // 已保存设置同步进表单：Key 永不回显，草稿保持为空。
      form.sync(gateway.configuredSnapshot);
      expect(form.apiKeyController.text, isEmpty);

      // 保存成功：草稿带着 Key 交给网关，明文不留在输入框。
      form.baseUrlController.text = 'https://api.example.com/v1';
      form.modelController.text = 'chat-model';
      form.apiKeyController.text = ' sk-secret ';
      expect(await form.save(viewModel, report: (_) {}), isTrue);
      expect(gateway.savedDrafts.single.apiKey, 'sk-secret');
      expect(form.apiKeyController.text, isEmpty);

      // 保存失败：草稿保留待重试。
      gateway.failSave = true;
      form.apiKeyController.text = 'sk-secret';
      expect(await form.save(viewModel, report: (_) {}), isFalse);
      expect(form.apiKeyController.text, 'sk-secret');

      // 页面卸载后保存收尾止步：不再触碰已释放的 Key 输入框。
      form.dispose();
      gateway.failSave = false;
      expect(await form.save(viewModel, report: (_) {}), isTrue);
    });

    test('语音朗读：成功即清、失败保留、卸载后不再触碰', () async {
      final gateway = _RecordingTtsGateway();
      final viewModel = TtsSettingsViewModel(
        gateway,
        playerPlatform: _StubPlayer(),
        autoStart: false,
      );
      final form = TtsSettingsForm();

      form.sync(gateway.configuredSnapshot);
      expect(form.apiKeyController.text, isEmpty);

      form.baseUrlController.text = 'https://tts.example.com/v1';
      form.modelController.text = 'cosyvoice-v2';
      form.apiKeyController.text = ' sk-secret ';
      expect(await form.save(viewModel, report: (_) {}), isTrue);
      expect(gateway.savedDrafts.single.apiKey, 'sk-secret');
      expect(form.apiKeyController.text, isEmpty);

      gateway.failSave = true;
      form.apiKeyController.text = 'sk-secret';
      expect(await form.save(viewModel, report: (_) {}), isFalse);
      expect(form.apiKeyController.text, 'sk-secret');

      form.dispose();
      gateway.failSave = false;
      expect(await form.save(viewModel, report: (_) {}), isTrue);
    });

    test('语音输入：成功即清、失败保留、卸载后不再触碰', () async {
      final gateway = _RecordingSttGateway();
      final viewModel = SttSettingsViewModel(gateway, autoStart: false);
      final form = SttSettingsForm();

      form.sync(gateway.configuredSnapshot);
      expect(form.apiKeyController.text, isEmpty);

      form.baseUrlController.text = 'https://stt.example.com/v1';
      form.modelController.text = 'fun-asr';
      form.apiKeyController.text = ' sk-secret ';
      expect(await form.save(viewModel, report: (_) {}), isTrue);
      expect(gateway.savedDrafts.single.apiKey, 'sk-secret');
      expect(form.apiKeyController.text, isEmpty);

      gateway.failSave = true;
      form.apiKeyController.text = 'sk-secret';
      expect(await form.save(viewModel, report: (_) {}), isFalse);
      expect(form.apiKeyController.text, 'sk-secret');

      form.dispose();
      gateway.failSave = false;
      expect(await form.save(viewModel, report: (_) {}), isTrue);
    });
  });
}

final class _RecordingProviderGateway implements ProviderSettingsGateway {
  bool failSave = false;
  final savedDrafts = <ProviderSettingsDraft>[];

  ProviderSettings get configuredSnapshot => const ProviderSettings(
    configured: true,
    keySet: true,
    provider: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.example.com/v1',
    model: 'chat-model',
    temperature: 0.7,
    timeoutSeconds: 60,
  );

  @override
  Future<ProviderSettings> read() async => configuredSnapshot;

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) async {
    if (failSave) {
      throw const ProviderSettingsGatewayException('模型设置暂时不可用，请稍后重试。');
    }
    savedDrafts.add(draft);
    return configuredSnapshot;
  }

  @override
  Future<ProviderSettings> forgetApiKey() async => configuredSnapshot;

  @override
  Future<ProviderTestResult> testConnection(
    ProviderSettingsDraft draft,
  ) async => const ProviderTestResult(
    succeeded: true,
    status: ProviderTestStatus.success,
    message: '连接成功，栖语可以使用这个模型。',
  );
}

final class _RecordingTtsGateway implements TtsSettingsGateway {
  bool failSave = false;
  final savedDrafts = <TtsSettingsDraft>[];

  TtsSettings get configuredSnapshot =>
      const TtsSettings(configured: true, keySet: true);

  @override
  Future<TtsSettings> read() async => configuredSnapshot;

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) async {
    if (failSave) {
      throw const ProviderSettingsGatewayException('语音设置暂时不可用，请稍后重试。');
    }
    savedDrafts.add(draft);
    return configuredSnapshot;
  }

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) async => configuredSnapshot;

  @override
  Future<TtsSettings> forgetApiKey() async => configuredSnapshot;

  @override
  Future<TtsConnectionTest> testConnection(
    TtsSettingsDraft draft,
  ) async => const TtsConnectionTest(succeeded: true, message: '连接成功');
}

final class _RecordingSttGateway implements SttSettingsGateway {
  bool failSave = false;
  final savedDrafts = <SttSettingsDraft>[];

  SttSettings get configuredSnapshot =>
      const SttSettings(configured: true, keySet: true);

  @override
  Future<SttSettings> read() async => configuredSnapshot;

  @override
  Future<SttSettings> save(SttSettingsDraft draft) async {
    if (failSave) {
      throw const ProviderSettingsGatewayException('语音设置暂时不可用，请稍后重试。');
    }
    savedDrafts.add(draft);
    return configuredSnapshot;
  }

  @override
  Future<SttSettings> forgetApiKey() async => configuredSnapshot;

  @override
  Future<ProviderTestResult> testConnection(
    SttSettingsDraft draft,
  ) async => const ProviderTestResult(
    succeeded: true,
    status: ProviderTestStatus.success,
    message: '连接成功，栖语可以使用这个模型。',
  );
}

final class _StubPlayer implements VoicePlayerPlatform {
  @override
  bool get supported => true;

  @override
  double getInitialVolume() => 1;

  @override
  void saveVolume(double volume) {}

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
    double volume = 1,
  }) async => null;
}
