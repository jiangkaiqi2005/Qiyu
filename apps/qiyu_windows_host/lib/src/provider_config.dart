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

  String get credentialScope =>
      '${kind.wireName}|${normalizeProviderBaseUri(baseUrl)}';

  /// 旧版作用域字符串：历史上 Uri.replace(query: '', fragment: '') 的
  /// 序列化会在地址尾部残留「?#」尾巴。凭据管理器按 scope 精确匹配，
  /// 纯旧安装（Key 只存过凭据管理器）的条目挂在这套旧 scope 下；
  /// 凭据回退读取与孤儿清理都要兼容它。
  String get legacyCredentialScope {
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

/// 可选 Key 字段的解析：非字符串忽略、空白归一为 null。
String? _optionalKey(Object? value) =>
    value is String ? ProviderConfig.normalizeKey(value) : null;

/// 服务地址的规范化：去掉路径末尾斜杠、丢弃 query 与 fragment。
/// Key 作用域比较与端点拼接共用同一口径。（用构造重建而非
/// replace(query: '')：后者会在地址上残留「?#」尾巴。）
Uri normalizeProviderBaseUri(String baseUrl) {
  final uri = Uri.parse(baseUrl.trim());
  return Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path.replaceFirst(RegExp(r'/+$'), ''),
  );
}

/// 语音转写（STT）的协议类型：配置里的 wire 名与网关分派共用。
/// 缺省 openai_compatible：不带 provider 字段的存量配置照常工作。
enum SttProviderKind {
  openAiCompatible('openai_compatible'),
  volcSeedAsr('volc_seed_asr');

  const SttProviderKind(this.wireName);

  final String wireName;

  static SttProviderKind fromWireName(String value) => values.firstWhere(
    (kind) => kind.wireName == value,
    orElse: () => throw const ProviderConfigException('不支持这个语音服务协议。'),
  );

  /// 该协议允许的服务地址 scheme（配置校验与出网前 SSRF 校验共用）。
  bool allows(String scheme) => switch (this) {
    SttProviderKind.openAiCompatible => scheme == 'http' || scheme == 'https',
    SttProviderKind.volcSeedAsr => scheme == 'ws' || scheme == 'wss',
  };
}

/// 语音转写（STT）服务配置：provider.json 顶层的可选 `stt` 段。
final class SttConfig {
  const SttConfig({
    required this.baseUrl,
    required this.model,
    this.provider = SttProviderKind.openAiCompatible,
    this.apiKey,
  });

  factory SttConfig.fromJson(Map<String, Object?> json) {
    // provider 字段缺失按缺省协议：不带它的存量配置照常工作。
    final provider = switch (json['provider']) {
      null => SttProviderKind.openAiCompatible,
      final String value => SttProviderKind.fromWireName(value),
      _ => throw const ProviderConfigException('语音服务配置无法读取。'),
    };
    return SttConfig(
      provider: provider,
      baseUrl: json['baseUrl']! as String,
      model: json['model']! as String,
      // 与聊天段同律：兼容 apiKey 与 API_KEY 两种手写法，空白视为未设置。
      apiKey: _optionalKey(json['apiKey'] ?? json['API_KEY']),
    );
  }

  final SttProviderKind provider;
  final String baseUrl;
  final String model;

  /// 本机 provider.json 的 stt 段里保存的 API Key（明文）。与聊天 Key
  /// 同律：不进 toJson()，HTTP 快照绝不携带明文。
  final String? apiKey;

  SttConfig withApiKey(String? apiKey) => SttConfig(
    provider: provider,
    baseUrl: baseUrl,
    model: model,
    apiKey: apiKey,
  );

  /// Key 的沿用作用域看协议与规范化后的服务地址：换协议（如 OpenAI
  /// 兼容换豆包）与换地址一样，都不沿用旧服务商的 Key。
  String get credentialScope =>
      '${provider.wireName}|${normalizeProviderBaseUri(baseUrl)}';

  Map<String, Object?> toJson() => {
    'provider': provider.wireName,
    'baseUrl': baseUrl,
    'model': model,
  };

  void validate() {
    final uri = Uri.tryParse(baseUrl.trim());
    final label = switch (provider) {
      SttProviderKind.openAiCompatible => '语音服务地址必须是有效的 HTTP 地址。',
      SttProviderKind.volcSeedAsr => '语音服务地址必须是有效的 WebSocket 地址。',
    };
    if (uri == null || !uri.hasAuthority || !provider.allows(uri.scheme)) {
      throw ProviderConfigException(label);
    }
    if (model.trim().isEmpty) {
      throw const ProviderConfigException('请填写语音服务的模型名称。');
    }
  }
}

abstract interface class ProviderConfigRepository {
  Future<ProviderConfig?> load();

  Future<void> save(ProviderConfig config);
}

abstract interface class SttConfigRepository {
  Future<SttConfig?> loadStt();

  Future<void> saveStt(SttConfig config);
}

final class JsonProviderConfigRepository
    implements ProviderConfigRepository, SttConfigRepository {
  const JsonProviderConfigRepository({
    required this.filePath,
    this.writer = const IoAtomicTextWriter(),
  });

  final String filePath;
  final AtomicTextWriter writer;

  @override
  Future<ProviderConfig?> load() async {
    final json = await _readRawMap(orThrow: true);
    if (json == null) {
      return null;
    }
    // 聊天字段一个都没有（例如只配了 stt 段）视为未配置而不是文件损坏；
    // 残缺一半则继续解析，让具体缺口以「无法读取」暴露。
    const chatKeys = [
      'provider',
      'baseUrl',
      'model',
      'temperature',
      'timeoutSeconds',
    ];
    if (!chatKeys.any(json.containsKey)) {
      return null;
    }
    try {
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
    // 段级保存：只替换聊天 Provider 字段，保留 stt 段与其他未知键；
    // 损坏到读不出 JSON 的文件本就无从保留，按整体覆盖处理。
    final json = await _readRawMap(orThrow: false) ?? <String, Object?>{};
    json
      ..remove('API_KEY')
      ..addAll(config.toJson());
    if (config.apiKey case final key?) {
      json['apiKey'] = key;
    } else {
      json.remove('apiKey');
    }
    await _writeFile(json);
  }

  @override
  Future<SttConfig?> loadStt() async {
    final json = await _readRawMap(orThrow: true);
    if (json == null) {
      return null;
    }
    final section = json['stt'];
    if (section == null) {
      return null;
    }
    // 损坏的 stt 段只影响语音输入，不影响聊天配置。
    if (section is! Map<String, Object?>) {
      throw const ProviderConfigException('语音服务配置无法读取。');
    }
    try {
      final config = SttConfig.fromJson(section);
      config.validate();
      return config;
    } on ProviderConfigException {
      rethrow;
    } on Object catch (error) {
      throw ProviderConfigException('语音服务配置无法读取。', error);
    }
  }

  @override
  Future<void> saveStt(SttConfig config) async {
    config.validate();
    final json = await _readRawMap(orThrow: false) ?? <String, Object?>{};
    json['stt'] = {...config.toJson(), 'apiKey': ?config.apiKey};
    await _writeFile(json);
  }

  /// 读取整份 provider.json；文件不存在返回 null。`orThrow` 为 true 时
  /// JSON 损坏抛「无法读取」（读路径要如实暴露损坏），为 false 时返回
  /// null（写路径无从保留损坏内容，交由调用方整体重建）。
  Future<Map<String, Object?>?> _readRawMap({required bool orThrow}) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return null;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('provider config must be an object');
      }
      return decoded;
    } on Object catch (error) {
      if (orThrow) {
        throw ProviderConfigException('本地模型配置无法读取。', error);
      }
      return null;
    }
  }

  Future<void> _writeFile(Map<String, Object?> json) async {
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
