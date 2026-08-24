import 'dart:convert';

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

final class WebSearchSettingsException
    implements Exception, UserFacingException {
  const WebSearchSettingsException(this.message);

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
  Object errorFor(String message) => WebSearchSettingsException(message);

  @override
  String get unavailableMessage => '联网搜索设置暂时不可用，请稍后重试。';

  @override
  Future<WebSearchSettings> read() async {
    await ensureBootstrap();
    final response = await httpClient.get(resolve('/api/provider/web-search'));
    return WebSearchSettings.fromJson(decodeSuccess(response));
  }

  @override
  Future<WebSearchSettings> save(WebSearchSettingsDraft draft) async {
    final response = await httpClient.put(
      resolve('/api/provider/web-search'),
      headers: await modifyingHeaders(),
      body: jsonEncode(draft.toJson()),
    );
    return WebSearchSettings.fromJson(decodeSuccess(response));
  }

  @override
  Future<WebSearchSettings> forgetApiKey() async {
    final response = await httpClient.delete(
      resolve('/api/provider/web-search/key'),
      headers: await modifyingHeaders(),
    );
    return WebSearchSettings.fromJson(decodeSuccess(response));
  }
}
