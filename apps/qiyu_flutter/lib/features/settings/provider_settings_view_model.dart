import 'keyed_settings_view_model.dart';
import 'provider_settings_client.dart';

/// 模型服务设置的视图模型：加载/保存/遗忘钥匙/连接测试的状态机在
/// [TestableKeyedSettingsViewModel] 统一编排，错误与测试结果以人话
/// 呈现；这里只留模型域自己的网关与兜底文案。
final class ProviderSettingsViewModel
    extends
        TestableKeyedSettingsViewModel<
          ProviderSettings,
          ProviderSettingsDraft,
          ProviderTestResult
        > {
  ProviderSettingsViewModel(this._gateway, {super.autoStart});

  final ProviderSettingsGateway _gateway;

  @override
  String get errorFallback => '模型设置暂时不可用，请稍后重试。';

  @override
  Future<ProviderSettings> readSettings() => _gateway.read();

  @override
  Future<ProviderSettings> saveSettings(ProviderSettingsDraft draft) =>
      _gateway.save(draft);

  @override
  Future<ProviderSettings> forgetKeySettings() => _gateway.forgetApiKey();

  @override
  Future<ProviderTestResult> runConnectionTest(ProviderSettingsDraft draft) =>
      _gateway.testConnection(draft);
}
