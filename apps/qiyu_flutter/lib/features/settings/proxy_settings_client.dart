import '../baseline/host_api_gateway.dart';

/// 出站代理设置域的 HTTP 面：地址与端口不是凭据，快照原样回显；
/// 代理没有凭据字段（代理认证本期不做），因此该域没有「永不回显」
/// 的敏感项。
final class ProxySettings {
  const ProxySettings({
    required this.configured,
    required this.enabled,
    required this.host,
    required this.port,
  });

  factory ProxySettings.fromJson(Map<String, Object?> json) => ProxySettings(
    configured: json['configured']! as bool,
    enabled: json['enabled']! as bool,
    host: json['host']! as String,
    port: json['port']! as int,
  );

  final bool configured;
  final bool enabled;
  final String host;
  final int port;
}

final class ProxySettingsDraft {
  const ProxySettingsDraft({
    required this.enabled,
    required this.host,
    required this.port,
  });

  final bool enabled;
  final String host;
  final int port;

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'host': host,
    'port': port,
  };
}

final class ProxySettingsGatewayException
    implements Exception, UserFacingException {
  const ProxySettingsGatewayException(this.message);

  @override
  final String message;

  @override
  String toString() => message;
}

abstract interface class ProxySettingsGateway {
  Future<ProxySettings> read();

  Future<ProxySettings> save(ProxySettingsDraft draft);
}

final class HttpProxySettingsGateway extends HostApiGateway
    implements ProxySettingsGateway {
  HttpProxySettingsGateway({super.client, super.baseUri});

  @override
  Object errorFor(String message) => ProxySettingsGatewayException(message);

  @override
  String get unavailableMessage => '代理设置暂时不可用，请稍后重试。';

  @override
  Future<ProxySettings> read() =>
      getJson('/api/provider/proxy', ProxySettings.fromJson);

  @override
  Future<ProxySettings> save(ProxySettingsDraft draft) => putJson(
    '/api/provider/proxy',
    draft.toJson(),
    ProxySettings.fromJson,
  );
}
