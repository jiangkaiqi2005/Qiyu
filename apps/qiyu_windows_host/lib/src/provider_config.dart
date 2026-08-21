import 'dart:convert';
import 'dart:io';

import 'markdown_memory_repository.dart';

enum ProviderKind {
  openAiCompatible('openai_compatible'),
  anthropic('anthropic'),
  ollama('ollama');

  const ProviderKind(this.wireName);

  final String wireName;

  static ProviderKind fromWireName(String value) => values.firstWhere(
    (kind) => kind.wireName == value,
    orElse: () => throw const ProviderConfigException('不支持这个模型服务。'),
  );
}

final class ProviderConfig {
  const ProviderConfig({
    required this.kind,
    required this.baseUrl,
    required this.model,
    required this.temperature,
    required this.timeoutSeconds,
    this.apiKey,
  });

  factory ProviderConfig.fromJson(Map<String, Object?> json) => ProviderConfig(
    kind: ProviderKind.fromWireName(json['provider']! as String),
    baseUrl: json['baseUrl']! as String,
    model: json['model']! as String,
    temperature: (json['temperature']! as num).toDouble(),
    timeoutSeconds: json['timeoutSeconds']! as int,
    // 用户可直接编辑本文件更换 Key：兼容 apiKey 与 API_KEY 两种写法。
    apiKey: _optionalKey(json['apiKey'] ?? json['API_KEY']),
  );

  /// 空白 Key 归一为 null：文件手改与 UI 保存共用同一条规则。
  static String? normalizeKey(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static String? _optionalKey(Object? value) =>
      value is String ? normalizeKey(value) : null;

  final ProviderKind kind;
  final String baseUrl;
  final String model;
  final double temperature;
  final int timeoutSeconds;

  /// 本机 provider.json 里保存的 API Key（明文）。属于凭据而非配置
  /// 身份：不参与相等判断，也不进 toJson()——设置快照经 HTTP 返回
  /// 时绝不能携带明文 Key。
  final String? apiKey;

  ProviderConfig withApiKey(String? apiKey) => ProviderConfig(
    kind: kind,
    baseUrl: baseUrl,
    model: model,
    temperature: temperature,
    timeoutSeconds: timeoutSeconds,
    apiKey: apiKey,
  );

  String get credentialScope {
    final uri = Uri.parse(baseUrl.trim());
    final normalizedPath = uri.path.replaceFirst(RegExp(r'/+$'), '');
    return '${kind.wireName}|${uri.replace(path: normalizedPath, query: '', fragment: '')}';
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'provider': kind.wireName,
    'baseUrl': baseUrl,
    'model': model,
    'temperature': temperature,
    'timeoutSeconds': timeoutSeconds,
  };

  void validate() {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const ProviderConfigException('模型服务地址必须是有效的 HTTP 地址。');
    }
    if (model.trim().isEmpty) {
      throw const ProviderConfigException('请填写模型名称。');
    }
    if (!temperature.isFinite || temperature < 0 || temperature > 2) {
      throw const ProviderConfigException('temperature 必须在 0 到 2 之间。');
    }
    if (timeoutSeconds < 1 || timeoutSeconds > 600) {
      throw const ProviderConfigException('超时时间必须在 1 到 600 秒之间。');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ProviderConfig &&
      other.kind == kind &&
      other.baseUrl == baseUrl &&
      other.model == model &&
      other.temperature == temperature &&
      other.timeoutSeconds == timeoutSeconds;

  @override
  int get hashCode =>
      Object.hash(kind, baseUrl, model, temperature, timeoutSeconds);
}

final class ProviderConfigException implements Exception {
  const ProviderConfigException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

abstract interface class ProviderConfigRepository {
  Future<ProviderConfig?> load();

  Future<void> save(ProviderConfig config);
}

final class JsonProviderConfigRepository implements ProviderConfigRepository {
  const JsonProviderConfigRepository({
    required this.filePath,
    this.writer = const IoAtomicTextWriter(),
  });

  final String filePath;
  final AtomicTextWriter writer;

  @override
  Future<ProviderConfig?> load() async {
    final file = File(filePath);
    if (!await file.exists()) {
      return null;
    }
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      final config = ProviderConfig.fromJson(json);
      config.validate();
      return config;
    } on ProviderConfigException {
      rethrow;
    } on Object catch (error) {
      throw ProviderConfigException('本地模型配置无法读取。', error);
    }
  }

  @override
  Future<void> save(ProviderConfig config) async {
    config.validate();
    // Key 只在这里并入落盘 JSON：toJson() 供设置快照复用，必须保持
    // 不含明文 Key。
    final json = {...config.toJson(), 'apiKey': ?config.apiKey};
    try {
      await writer.replace(
        filePath,
        '${const JsonEncoder.withIndent('  ').convert(json)}\n',
      );
    } on Object catch (error) {
      throw ProviderConfigException('本地模型配置无法保存。', error);
    }
  }
}
