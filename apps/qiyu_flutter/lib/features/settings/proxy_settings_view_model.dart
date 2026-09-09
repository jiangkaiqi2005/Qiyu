import 'keyed_settings_view_model.dart';
import 'proxy_settings_client.dart';

/// 出站代理设置的视图模型：与各设置域共用 [KeyedSettingsViewModel] 的
/// 加载/保存状态机。代理没有可遗忘的凭据（地址端口随快照回显），基
/// 类的遗忘钥匙位在本域永远不出现在界面上，[forgetKeySettings] 仅为
/// 满足基类形状的占位实现。
final class ProxySettingsViewModel
    extends KeyedSettingsViewModel<ProxySettings, ProxySettingsDraft> {
  ProxySettingsViewModel(this._gateway, {super.autoStart});

  final ProxySettingsGateway _gateway;

  @override
  String get errorFallback => '代理设置暂时不可用，请稍后重试。';

  @override
  Future<ProxySettings> readSettings() => _gateway.read();

  @override
  Future<ProxySettings> saveSettings(ProxySettingsDraft draft) =>
      _gateway.save(draft);

  @override
  Future<ProxySettings> forgetKeySettings() => _gateway.read();
}
