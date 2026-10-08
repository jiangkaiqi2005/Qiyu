import 'embedding_settings_client.dart';
import 'keyed_settings_view_model.dart';
import 'provider_settings_client.dart' show ProviderTestResult;

/// 记忆召回设置的视图模型：与模型服务域共用
/// [TestableKeyedSettingsViewModel] 的加载/保存/遗忘/测试状态机，错误
/// 与测试结果都以人话呈现；这里只留记忆召回域自己的网关与兜底文案，
/// 以及票 03 的启用/停用/重建操作与可见期轻刷新。
final class EmbeddingSettingsViewModel
    extends
        TestableKeyedSettingsViewModel<
          EmbeddingSettings,
          EmbeddingSettingsDraft,
          ProviderTestResult
        > {
  EmbeddingSettingsViewModel(this._gateway, {super.autoStart});

  final EmbeddingSettingsGateway _gateway;

  bool _toggling = false;
  bool _rebuilding = false;

  /// 启用/停用互斥位。
  bool get toggling => _toggling;

  /// 重建/重试进行中。
  bool get rebuilding => _rebuilding;

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

  /// 显式启用：Host 触发后台索引构建；成功后以返回快照为准。
  Future<void> enable() => _toggle(() => _gateway.enable());

  /// 显式停用：召回回到旧目录路径。
  Future<void> disable() => _toggle(() => _gateway.disable());

  /// 明确重建/重试。
  Future<void> rebuild() async {
    if (_rebuilding) {
      return;
    }
    _rebuilding = true;
    errorMessage = null;
    notifyListeners();
    await runSettingsAction(() => _gateway.rebuild());
    _rebuilding = false;
    notifyListeners();
  }

  Future<void> _toggle(Future<EmbeddingSettings> Function() action) async {
    if (_toggling) {
      return;
    }
    _toggling = true;
    errorMessage = null;
    notifyListeners();
    await runSettingsAction(action);
    _toggling = false;
    notifyListeners();
  }
}
