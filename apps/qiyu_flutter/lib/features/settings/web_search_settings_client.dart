import '../baseline/host_api_gateway.dart';

final class WebSearchSettings {
  const WebSearchSettings({required this.configured, required this.keySet});

  factory WebSearchSettings.fromJson(Map<String, Object?> json) =>
      WebSearchSettings(
        configured: json['configured']! as bool,
        keySet: json['keySet']! as bool,
      );

  final bool configured;
  final bool keySet;
}

final class WebSearchSettingsDraft {
  const WebSearchSettingsDraft({this.apiKey});

  final String? apiKey;

  Map<String, Object?> toJson() => {'apiKey': ?apiKey};
}

final class WebSearchSettingsGatewayException
    implements Exception, UserFacingException {
  const WebSearchSettingsGatewayException(this.message);

  @override
  final String message;

  @override
  String toString() => message;
}

abstract interface class WebSearchSettingsGateway {
  Future<WebSearchSettings> read();

  Future<WebSearchSettings> save(WebSearchSettingsDraft draft);

  Future<WebSearchSettings> forgetApiKey();
}

final class HttpWebSearchSettingsGateway extends HostApiGateway
    implements WebSearchSettingsGateway {
  HttpWebSearchSettingsGateway({super.client, super.baseUri});

  @override
  Object errorFor(String message) =>
      WebSearchSettingsGatewayException(message);

  @override
  String get unavailableMessage => '联网搜索设置暂时不可用，请稍后重试。';

  @override
  Future<WebSearchSettings> read() =>
      getJson('/api/provider/web-search', WebSearchSettings.fromJson);

  @override
  Future<WebSearchSettings> save(WebSearchSettingsDraft draft) => putJson(
    '/api/provider/web-search',
    draft.toJson(),
    WebSearchSettings.fromJson,
  );

  @override
  Future<WebSearchSettings> forgetApiKey() =>
      deleteJson('/api/provider/web-search/key', WebSearchSettings.fromJson);
}
