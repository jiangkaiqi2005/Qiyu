import 'keyed_settings_view_model.dart';
import 'web_search_settings_client.dart';

/// 联网搜索设置的视图模型：与模型服务域共用 [KeyedSettingsViewModel]
/// 的加载/保存/遗忘钥匙状态机；本域没有连接测试位、保存无校验，不
/// 背上测试契约。
final class WebSearchSettingsViewModel
    extends KeyedSettingsViewModel<WebSearchSettings, WebSearchSettingsDraft> {
  WebSearchSettingsViewModel(this._gateway, {super.autoStart});

  final WebSearchSettingsGateway _gateway;

  @override
  String get errorFallback => '联网搜索设置暂时不可用，请稍后重试。';

  @override
  Future<WebSearchSettings> readSettings() => _gateway.read();

  @override
  Future<WebSearchSettings> saveSettings(WebSearchSettingsDraft draft) =>
      _gateway.save(draft);

  @override
  Future<WebSearchSettings> forgetKeySettings() => _gateway.forgetApiKey();
}
