import 'provider_config.dart';

final class WebSearchSettingsSnapshot {
  const WebSearchSettingsSnapshot({required this.keySet});

  final bool keySet;

  bool get configured => keySet;

  Map<String, Object?> toJson() => {'configured': configured, 'keySet': keySet};
}

final class WebSearchSettingsService {
  const WebSearchSettingsService(this.repository);

  final WebSearchConfigRepository repository;

  Future<WebSearchSettingsSnapshot> read() async {
    final config = await repository.loadWebSearch();
    return WebSearchSettingsSnapshot(keySet: config != null);
  }

  Future<WebSearchSettingsSnapshot> save({String? apiKey}) async {
    final trimmed = apiKey?.trim();
    // 单段保存同样进共享事务：与聊天、语音的读改写彼此串行。
    if (trimmed != null && trimmed.isNotEmpty) {
      await repository.runTransaction(
        () => repository.saveWebSearch(WebSearchConfig(apiKey: trimmed)),
      );
    }
    return read();
  }

  Future<WebSearchSettingsSnapshot> forgetApiKey() async {
    await repository.runTransaction(() => repository.saveWebSearch(null));
    return read();
  }
}
