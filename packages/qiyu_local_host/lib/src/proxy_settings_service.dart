import 'cleartext_policy.dart';
import 'provider_config.dart';

/// 代理设置的读取快照：地址与端口不是凭据，随快照原样回显供设置页
/// 回显；代理没有凭据字段（代理认证本期不做），因此快照没有任何
/// 需要保密的内容。
final class ProxySettingsSnapshot {
  const ProxySettingsSnapshot({
    required this.enabled,
    required this.host,
    required this.port,
  });

  final bool enabled;
  final String host;
  final int port;

  bool get configured => enabled;

  Map<String, Object?> toJson() => {
    'configured': configured,
    'enabled': enabled,
    'host': host,
    'port': port,
  };
}

/// 出站代理设置（ticket 08）：provider.json `proxy` 段的读写与「当前
/// 是否启用代理」的判定。语义与联网搜索设置域同构：走既有配置仓库
/// 的段级保存，快照不含敏感内容。
final class ProxySettingsService {
  const ProxySettingsService(this.repository);

  final ProxyConfigRepository repository;

  Future<ProxySettingsSnapshot> read() async {
    final config = await repository.loadProxy();
    return ProxySettingsSnapshot(
      enabled: config?.enabled ?? false,
      host: config?.host ?? '',
      port: config?.port ?? 0,
    );
  }

  Future<ProxySettingsSnapshot> save({
    required bool enabled,
    required String host,
    required int port,
  }) async {
    final config = ProxyConfig(enabled: enabled, host: host, port: port);
    config.validate();
    await repository.saveProxy(config);
    return read();
  }

  /// 模型网关出网时取当次生效的代理规则：未配置或未启用返回 null
  /// （直连）。每次请求现读现判，保存后下一条请求即生效。
  Future<ProxyRules?> loadRules() async {
    final config = await repository.loadProxy();
    if (config == null || !config.enabled) {
      return null;
    }
    return ProxyRules(host: config.host.trim(), port: config.port);
  }
}
