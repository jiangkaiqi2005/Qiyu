import 'embedding_settings_client.dart';
import 'keyed_settings_view_model.dart';
import 'provider_settings_client.dart' show ProviderTestResult;

/// 记忆召回设置的视图模型：与模型服务域共用
/// [TestableKeyedSettingsViewModel] 的加载/保存/遗忘/测试状态机，错误
/// 与测试结果都以人话呈现；这里只留记忆召回域自己的网关与兜底文案。
final class EmbeddingSettingsViewModel
    extends
        TestableKeyedSettingsViewModel<
          EmbeddingSettings,
          EmbeddingSettingsDraft,
          ProviderTestResult
        > {
  EmbeddingSettingsViewModel(this._gateway, {super.autoStart});

  final EmbeddingSettingsGateway _gateway;

  @override
  String get errorFallback => '记忆召回设置暂时不可用，请稍后重试。';

  @override
  Future<EmbeddingSettings> readSettings() => _gateway.read();

  @override
  Future<EmbeddingSettings> saveSettings(EmbeddingSettingsDraft draft) =>
      _gateway.save(draft);

  @override
  Future<EmbeddingSettings> forgetKeySettings() => _gateway.forgetApiKey();

  @override
  Future<ProviderTestResult> runConnectionTest(EmbeddingSettingsDraft draft) =>
      _gateway.testConnection(draft);
}
