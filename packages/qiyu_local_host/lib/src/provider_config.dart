import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// 是否混入可见 ASCII（0x21–0x7E）之外的字符：空格、控制符、DEL、中文、
/// 零宽字符等粘贴事故。语音转写与语音合成的地址、模型名、音色与 API
/// Key 都只应是可见 ASCII（trim 只去首尾，中间的脏字符一律是粘贴事故），
/// 否则 dart:io 写 HTTP 头时会抛未分类异常。放在这里而不是各网关：
/// 网关与服务层都依赖本文件，反向依赖会形成循环 import。
bool containsNonVisibleAscii(String value) =>
    value.runes.any((r) => r < 0x21 || r > 0x7E);

/// 语音服务出网前的统一 SSRF 校验（转写与合成共用）：scheme 限
/// ws/wss/http/https；host 拒绝环回、私有、保留、组播与链路本地地址。
/// 返回拒绝原因（人话文案），允许出网返回 null；各自网关负责包装成
/// 本通道的异常类型。边界：聊天 Provider（模型对话）出网不走这条
/// 校验——Ollama 本机部署（如 localhost:11434）是 AGENTS 明确支持的
/// 产品功能，而语音服务始终是云端第三方，不允许被指向内网。
String? speechOutboundRefusalReason(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' &&
      scheme != 'https' &&
      scheme != 'ws' &&
      scheme != 'wss') {
    return '语音服务地址必须是有效的 HTTP 或 WebSocket 地址。';
  }
  final host = uri.host.toLowerCase();
  if (host.isEmpty || host == 'localhost' || host.endsWith('.localhost')) {
    return '语音服务地址不允许指向本机或内网。';
  }
  final address = InternetAddress.tryParse(host);
  // 域名字面量无法静态判定（DNS 解析后的内网 IP 由系统网络层路由），
  // 这里只拦字面量形态的内网地址。
  if (address != null && !_isPublicInternetAddress(address.rawAddress)) {
    return '语音服务地址不允许指向本机或内网。';
  }
  return null;
}

/// 字面量 IP 是否为公网单播地址（按原始网络字节序判断）。
bool _isPublicInternetAddress(Uint8List raw) {
  if (raw.length == 4) {
    return _isPublicIpv4(raw);
  }
  if (raw.length == 16) {
    return _isPublicIpv6(raw);
  }
  return false;
}

bool _isPublicIpv4(Uint8List b) {
  final a0 = b[0];
  final a1 = b[1];
  if (a0 == 0) return false; // 0.0.0.0/8 保留
  if (a0 == 10) return false; // 10/8 私有
  if (a0 == 100 && a1 >= 64 && a1 <= 127) return false; // 100.64/10 CGNAT
  if (a0 == 127) return false; // 环回
  if (a0 == 169 && a1 == 254) return false; // 169.254/16 链路本地
  if (a0 == 172 && a1 >= 16 && a1 <= 31) return false; // 172.16/12 私有
  if (a0 == 192 && a1 == 168) return false; // 192.168/16 私有
  if (a0 >= 224) return false; // 224/4 组播 + 240/4 保留（含广播）
  return true;
}

bool _isPublicIpv6(Uint8List b) {
  var zeroPrefix = 0;
  while (zeroPrefix < 16 && b[zeroPrefix] == 0) {
    zeroPrefix += 1;
  }
  if (zeroPrefix == 16) return false; // :: 未指定
  if (zeroPrefix == 15 && b[15] == 1) return false; // ::1 环回
  // IPv4 映射地址 ::ffff:a.b.c.d：按内嵌 IPv4 再判。
  if (zeroPrefix == 10 && b[10] == 0xFF && b[11] == 0xFF) {
    return _isPublicIpv4(Uint8List.sublistView(b, 12, 16));
  }
  if ((b[0] & 0xFE) == 0xFC) return false; // fc00::/7 唯一本地
  if (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) return false; // fe80::/10 链路本地
  if (b[0] == 0xFF) return false; // ff00::/8 组播
  return true;
}

/// 语音两段配置（转写/合成）共享的前半校验：地址脏字符→URI+scheme→
/// 模型名空→模型名脏字符四连检；scheme 白名单用各协议现成的 allows
/// 判定，全部人话文案按服务标签逐字拼装。
void _validateSpeechEndpoint({
  required String baseUrl,
  required String model,
  required String serviceLabel,
  required bool Function(String scheme) allows,
  required String schemeFailureMessage,
}) {
  // 粘贴事故优先拦截：地址里的脏字符会让 dart:io 写头时抛未分类异常，
  // 用户只能看到黑盒 internal 错误，这里换成可定位的人话文案。与 URI
  // 解析同口径用 trim 后的值：首尾空格按既有 trim 规则放过，只拦
  // trim 去不掉的中间脏字符。
  if (containsNonVisibleAscii(baseUrl.trim())) {
    throw ProviderConfigException(
      '$serviceLabel地址里混入了中文或看不见的字符，请重新复制粘贴。',
    );
  }
  final uri = Uri.tryParse(baseUrl.trim());
  if (uri == null || !uri.hasAuthority || !allows(uri.scheme)) {
    throw ProviderConfigException(schemeFailureMessage);
  }
  if (model.trim().isEmpty) {
    throw ProviderConfigException('请填写$serviceLabel的模型名称。');
  }
  if (containsNonVisibleAscii(model.trim())) {
    throw ProviderConfigException(
      '$serviceLabel的模型名称里混入了中文或看不见的字符，请重新填写。',
    );
  }
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
    final schemeFailureMessage = switch (provider) {
      SttProviderKind.openAiCompatible => '语音服务地址必须是有效的 HTTP 地址。',
      SttProviderKind.volcSeedAsr => '语音服务地址必须是有效的 WebSocket 地址。',
    };
    _validateSpeechEndpoint(
      baseUrl: baseUrl,
      model: model,
      serviceLabel: '语音服务',
      allows: provider.allows,
      schemeFailureMessage: schemeFailureMessage,
    );
  }
}

/// 语音合成的协议类型：配置里的 wire 名与网关分派共用。缺省
/// openai_compatible：不带 provider 字段的存量配置照常工作。
/// 豆包协议（volc_tts）走订阅专属 HTTP 端点，同为 HTTP(S)。
enum TtsProviderKind {
  openAiCompatible('openai_compatible'),
  volcTts('volc_tts');

  const TtsProviderKind(this.wireName);

  final String wireName;

  static TtsProviderKind fromWireName(String value) => values.firstWhere(
    (kind) => kind.wireName == value,
    orElse: () => throw const ProviderConfigException('不支持这个语音合成服务协议。'),
  );

  /// 该协议允许的服务地址 scheme（配置校验与出网前 SSRF 校验共用）。
  bool allows(String scheme) => scheme == 'http' || scheme == 'https';
}

/// 豆包语音合成的订阅专属 HTTP 端点（设置页缺省值）：一次性发送文本、
/// 返回 chunked 逐行 JSON 音频。地址本身就是完整端点，不做后缀拼接。
const volcTtsDefaultEndpoint =
    'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional';

/// 豆包语音合成 2.0 的 Resource-Id（模型名称字段缺省值）。
const volcTtsDefaultResourceId = 'seed-tts-2.0';

/// 语音合成（TTS）服务配置：provider.json 顶层的可选 `tts` 段。
/// [speed] 为空表示用服务缺省语速；[autoSpeak] 是聊天页朗读开关的
/// 持久化位（缺省开：配了就自动读）。
final class TtsConfig {
  const TtsConfig({
    required this.baseUrl,
    required this.model,
    this.provider = TtsProviderKind.openAiCompatible,
    this.apiKey,
    this.voice,
    this.speed,
    this.autoSpeak = true,
    this.extraParams,
  });

  factory TtsConfig.fromJson(Map<String, Object?> json) {
    // provider 字段缺失按缺省协议：不带它的存量配置照常工作。
    final provider = switch (json['provider']) {
      null => TtsProviderKind.openAiCompatible,
      final String value => TtsProviderKind.fromWireName(value),
      _ => throw const ProviderConfigException('语音合成服务配置无法读取。'),
    };
    final voice = json['voice'];
    if (voice != null && voice is! String) {
      throw const ProviderConfigException('语音合成服务配置无法读取。');
    }
    final rawSpeed = json['speed'];
    if (rawSpeed != null && rawSpeed is! num) {
      throw const ProviderConfigException('语音合成服务配置无法读取。');
    }
    final rawAutoSpeak = json['autoSpeak'];
    if (rawAutoSpeak != null && rawAutoSpeak is! bool) {
      throw const ProviderConfigException('语音合成服务配置无法读取。');
    }
    final rawExtra = json['extraParams'] ?? json['extra_params'];
    if (rawExtra != null && rawExtra is! Map) {
      throw const ProviderConfigException('语音合成服务配置无法读取。');
    }
    final extraParams = rawExtra is Map
        ? Map<String, Object?>.from(
            rawExtra.map((k, v) => MapEntry(k.toString(), v)),
          )
        : null;
    return TtsConfig(
      provider: provider,
      baseUrl: json['baseUrl']! as String,
      model: json['model']! as String,
      // 与聊天段同律：兼容 apiKey 与 API_KEY 两种手写法，空白视为未设置。
      apiKey: _optionalKey(json['apiKey'] ?? json['API_KEY']),
      voice: voice as String?,
      speed: rawSpeed is num ? rawSpeed.toDouble() : null,
      autoSpeak: rawAutoSpeak is bool ? rawAutoSpeak : true,
      extraParams: extraParams,
    );
  }

  final TtsProviderKind provider;
  final String baseUrl;
  final String model;

  /// 音色 ID（如 alloy、zh_female_…_bigtts）：空表示用协议缺省音色。
  final String? voice;

  /// 语速倍率：空表示用服务缺省；合法区间覆盖各家协议（网关层再夹
  /// 到本协议允许的窄区间）。
  final double? speed;

  /// 聊天页「自动朗读」开关：随配置存本机（刷新、重启都记住）。
  final bool autoSpeak;

  /// 自定义高级参数（深合并入请求体）。
  final Map<String, Object?>? extraParams;

  /// 本机 provider.json 的 tts 段里保存的 API Key（明文）。与聊天 Key
  /// 同律：不进 toJson()，HTTP 快照绝不携带明文。
  final String? apiKey;

  TtsConfig withApiKey(String? apiKey) => TtsConfig(
    provider: provider,
    baseUrl: baseUrl,
    model: model,
    apiKey: apiKey,
    voice: voice,
    speed: speed,
    autoSpeak: autoSpeak,
    extraParams: extraParams,
  );

  /// Key 的沿用作用域看协议与规范化后的服务地址：换协议与换地址
  /// 一样，都不沿用旧服务商的 Key。
  String get credentialScope =>
      '${provider.wireName}|${normalizeProviderBaseUri(baseUrl)}';

  Map<String, Object?> toJson() => {
    'provider': provider.wireName,
    'baseUrl': baseUrl,
    'model': model,
    if (voice != null && voice!.trim().isNotEmpty) 'voice': voice,
    if (speed != null) 'speed': speed,
    'autoSpeak': autoSpeak,
    if (extraParams != null && extraParams!.isNotEmpty)
      'extraParams': extraParams,
  };

  void validate() {
    _validateSpeechEndpoint(
      baseUrl: baseUrl,
      model: model,
      serviceLabel: '语音合成服务',
      allows: provider.allows,
      schemeFailureMessage: '语音合成服务地址必须是有效的 HTTP 地址。',
    );
    if (voice != null && containsNonVisibleAscii(voice!.trim())) {
      throw const ProviderConfigException('音色里混入了中文或看不见的字符，请重新填写。');
    }
    if (speed != null && (!speed!.isFinite || speed! < 0.25 || speed! > 4)) {
      throw const ProviderConfigException('语速必须在 0.25 到 4 之间。');
    }
    if (extraParams != null) {
      for (final key in extraParams!.keys) {
        if (key.trim().isEmpty) {
          throw const ProviderConfigException('自定义高级参数格式不正确。');
        }
      }
    }
  }
}

abstract interface class ProviderConfigRepository {
  Future<ProviderConfig?> load();

  Future<void> save(ProviderConfig config);
}

final class WebSearchConfig {
  const WebSearchConfig({required this.apiKey});

  final String apiKey;

  void validate() {
    if (apiKey.trim().isEmpty) {
      throw const ProviderConfigException('请填写 ANYSEARCH_API_KEY。');
    }
  }
}

abstract interface class WebSearchConfigRepository {
  Future<WebSearchConfig?> loadWebSearch();

  Future<void> saveWebSearch(WebSearchConfig? config);
}

/// 出站代理配置（ticket 08）：provider.json 顶层的可选 `proxy` 段，
/// 作用于模型网关的 OpenAI 兼容／Anthropic 出站。只承载地址与端口，
/// 没有凭据字段（代理认证本期不做，因此无需要保密、禁止回显的代理
/// 凭据）；启用与否由 [enabled] 表达。
final class ProxyConfig {
  const ProxyConfig({required this.enabled, required this.host, required this.port});

  /// 段的 JSON 解码：字段缺失或类型不对抛 [ProviderConfigException]。
  /// 「残缺按未配置处理」的兜底不在本构造——加载路径由
  /// `JsonProviderConfigRepository.loadProxy` 捕获后返回 null（fail
  /// toward direct），保存路径在 saveProxy 前经 [validate] 把残缺档
  /// 挡在落盘之前。
  factory ProxyConfig.fromJson(Map<String, Object?> json) {
    final enabled = json['enabled'];
    final host = json['host'];
    final port = json['port'];
    if (enabled is! bool || host is! String || port is! int) {
      throw const ProviderConfigException('代理配置无法读取。');
    }
    return ProxyConfig(enabled: enabled, host: host, port: port);
  }

  final bool enabled;
  final String host;
  final int port;

  /// [port] 为 0 表示「未填端口」（仅允许出现在关闭态＋空地址的组合，
  /// 见 [validate]）。
  bool get isEmptyOff => !enabled && host.trim().isEmpty && port == 0;

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'host': host,
    'port': port,
  };

  void validate() {
    final trimmedHost = host.trim();
    if (isEmptyOff) {
      return;
    }
    if (enabled && trimmedHost.isEmpty) {
      throw const ProviderConfigException('请填写代理地址。');
    }
    if (trimmedHost.isNotEmpty) {
      if (containsNonVisibleAscii(trimmedHost)) {
        throw const ProviderConfigException(
          '代理地址里混入了中文或看不见的字符，请重新填写。',
        );
      }
      if (trimmedHost.contains('/') ||
          trimmedHost.contains(' ') ||
          trimmedHost.contains('@') ||
          trimmedHost.toLowerCase().startsWith('http://') ||
          trimmedHost.toLowerCase().startsWith('https://')) {
        throw const ProviderConfigException(
          '代理地址填主机名或 IP 即可，不带 http:// 前缀与路径。',
        );
      }
      // 端口有独立字段：地址里再带冒号只允许 IPv6 字面量（裸 `::1`
      // 或 `[::1]` 括号形态都合法）。`1.2.3.4:8080` 这类「IP:端口」
      // 会把 findProxy 串写畸形、拖到请求期才失败，在保存口拒绝。
      if (trimmedHost.contains(':')) {
        final bare = trimmedHost.startsWith('[') && trimmedHost.endsWith(']')
            ? trimmedHost.substring(1, trimmedHost.length - 1)
            : trimmedHost;
        final address = InternetAddress.tryParse(bare);
        if (address == null || address.type != InternetAddressType.IPv6) {
          throw const ProviderConfigException(
            '代理地址请填主机名或 IP，端口单独填。',
          );
        }
      }
    }
    if (port < 0 || port > 65535) {
      throw const ProviderConfigException('代理端口必须在 0 到 65535 之间。');
    }
    if (enabled && (port < 1 || port > 65535)) {
      throw const ProviderConfigException('请填写 1 到 65535 之间的代理端口。');
    }
  }
}

abstract interface class ProxyConfigRepository {
  Future<ProxyConfig?> loadProxy();

  Future<void> saveProxy(ProxyConfig? config);
}

abstract interface class SttConfigRepository {
  Future<SttConfig?> loadStt();

  Future<void> saveStt(SttConfig config);
}

abstract interface class TtsConfigRepository {
  Future<TtsConfig?> loadTts();

  Future<void> saveTts(TtsConfig config);
}

final class JsonProviderConfigRepository
    implements
        ProviderConfigRepository,
        SttConfigRepository,
        TtsConfigRepository,
        WebSearchConfigRepository,
        ProxyConfigRepository {
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
  Future<SttConfig?> loadStt() => _loadSpeechSection(
    'stt',
    '语音服务配置无法读取。',
    (section) {
      final config = SttConfig.fromJson(section);
      config.validate();
      return config;
    },
  );

  @override
  Future<void> saveStt(SttConfig config) async {
    config.validate();
    await _saveSection('stt', {...config.toJson(), 'apiKey': ?config.apiKey});
  }

  @override
  Future<TtsConfig?> loadTts() => _loadSpeechSection(
    'tts',
    '语音合成服务配置无法读取。',
    (section) {
      final config = TtsConfig.fromJson(section);
      config.validate();
      return config;
    },
  );

  @override
  Future<void> saveTts(TtsConfig config) async {
    config.validate();
    await _saveSection('tts', {...config.toJson(), 'apiKey': ?config.apiKey});
  }

  /// 语音两段（stt/tts）共享的段级加载：读原始 map→取段→段类型检查→
  /// parse（fromJson+validate）→异常包装，段键与人话文案各段自带。
  /// 顶层 load() 因聊天键的前置判定不同保持独立。
  Future<T?> _loadSpeechSection<T extends Object>(
    String sectionKey,
    String failureMessage,
    T Function(Map<String, Object?> section) parse,
  ) async {
    final json = await _readRawMap(orThrow: true);
    if (json == null) {
      return null;
    }
    final section = json[sectionKey];
    if (section == null) {
      return null;
    }
    // 损坏的段只影响本段功能，不影响其他配置。
    if (section is! Map<String, Object?>) {
      throw ProviderConfigException(failureMessage);
    }
    try {
      return parse(section);
    } on ProviderConfigException {
      rethrow;
    } on Object catch (error) {
      throw ProviderConfigException(failureMessage, error);
    }
  }

  /// 子段共用的段级保存：读整份配置→只替换或删除本段→一次原子写回。
  /// [sectionJson] 非空时替换本段，为空时移除本段键——「删除子段」与
  /// 「把字段写成 null」不是一回事，各保存方保留自己的载荷构造与校验。
  Future<void> _saveSection(
    String sectionKey,
    Map<String, Object?>? sectionJson,
  ) async {
    final json = await _readRawMap(orThrow: false) ?? <String, Object?>{};
    if (sectionJson == null) {
      json.remove(sectionKey);
    } else {
      json[sectionKey] = sectionJson;
    }
    await _writeFile(json);
  }

  @override
  Future<WebSearchConfig?> loadWebSearch() async {
    final json = await _readRawMap(orThrow: true);
    if (json == null || json['webSearch'] == null) {
      return null;
    }
    final section = json['webSearch'];
    if (section is! Map<String, Object?>) {
      return null;
    }
    final rawApiKey = section['apiKey'];
    if (rawApiKey is! String) {
      return null;
    }
    final apiKey = ProviderConfig.normalizeKey(rawApiKey);
    if (apiKey == null) {
      return null;
    }
    return WebSearchConfig(apiKey: apiKey);
  }

  @override
  Future<void> saveWebSearch(WebSearchConfig? config) async {
    config?.validate();
    // 空配置（遗忘 Key）传达的是删除本段，不是写一个空段或 null 值。
    await _saveSection(
      'webSearch',
      config == null ? null : {'apiKey': config.apiKey.trim()},
    );
  }

  @override
  Future<ProxyConfig?> loadProxy() async {
    final json = await _readRawMap(orThrow: true);
    if (json == null || json['proxy'] == null) {
      return null;
    }
    final section = json['proxy'];
    if (section is! Map<String, Object?>) {
      return null;
    }
    try {
      return ProxyConfig.fromJson(section);
    } on ProviderConfigException {
      // 段残缺按未配置处理：代理静默回到关闭态，不影响其余配置。
      return null;
    }
  }

  @override
  Future<void> saveProxy(ProxyConfig? config) async {
    config?.validate();
    // 关闭态仍是一个完整的 disabled 段（保留 host、port）；只有空配置才删除本段。
    await _saveSection('proxy', config?.toJson());
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
