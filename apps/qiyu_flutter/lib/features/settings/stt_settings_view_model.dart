import 'keyed_settings_view_model.dart';
import 'provider_settings_client.dart' show ProviderTestResult;
import 'stt_settings_client.dart';

/// 语音识别设置的视图模型：与模型服务域共用
/// [TestableKeyedSettingsViewModel] 的加载/保存/遗忘/测试状态机，错误
/// 与测试结果都以人话呈现；这里只留语音识别域自己的网关与兜底文案。
final class SttSettingsViewModel
    extends
        TestableKeyedSettingsViewModel<
          SttSettings,
          SttSettingsDraft,
          ProviderTestResult
        > {
  SttSettingsViewModel(this._gateway, {super.autoStart});

  final SttSettingsGateway _gateway;

  @override
  String get errorFallback => '语音设置暂时不可用，请稍后重试。';

  @override
  Future<SttSettings> readSettings() => _gateway.read();

  @override
  Future<SttSettings> saveSettings(SttSettingsDraft draft) =>
      _gateway.save(draft);

  @override
  Future<SttSettings> forgetKeySettings() => _gateway.forgetApiKey();

  @override
  Future<ProviderTestResult> runConnectionTest(SttSettingsDraft draft) =>
      _gateway.testConnection(draft);
}
