import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'markdown_memory_repository.dart';

enum ProviderKind {
  openAiCompatible('openai_compatible'),
  anthropic('anthropic'),
  ollama('ollama'),

  /// Omni 实时对话档（ADR 0026，T02）：qwen3.8-omni-flash-realtime 经
  /// DashScope Realtime WebSocket 直接听说文字与语音，独立于 Chat
  /// Completions 协议（spec:17——不把实时型号填进聊天接口当作接入）。
  qwenOmniRealtime('qwen_omni_realtime');

  const ProviderKind(this.wireName);

  final String wireName;

  static ProviderKind fromWireName(String value) => values.firstWhere(
    (kind) => kind.wireName == value,
    orElse: () => throw const ProviderConfigException('不支持这个模型服务。'),
  );
}

/// 请求超时的允许上限（秒）：配置校验与后台整理调用期限共用这一边界，
/// 单处改动两处生效，不各写一遍。
const maxConfiguredTimeoutSeconds = 600;

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

  /// 换一个期限的副本（其余字段原样）：后台整理调用在出网时按后台
  /// 期限放宽，聊天链路始终用配置里的原值。
  ProviderConfig withTimeoutSeconds(int timeoutSeconds) => ProviderConfig(
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
    // scheme 白名单按档区分：聊天三档仍是 HTTP(S)；Omni 实时档走
    // WebSocket（T01 实测端点 wss://dashscope.aliyuncs.com/api-ws/v1/
    // realtime，型号以 query 参数携带，由网关拼装）。
    final schemeAllowed = switch (kind) {
      ProviderKind.qwenOmniRealtime =>
        uri != null && (uri.scheme == 'ws' || uri.scheme == 'wss'),
      _ => uri != null && (uri.scheme == 'http' || uri.scheme == 'https'),
    };
    if (uri == null || !uri.hasAuthority || !schemeAllowed) {
      throw switch (kind) {
        ProviderKind.qwenOmniRealtime => const ProviderConfigException(
          '实时模型服务地址必须是有效的 WebSocket 地址。',
        ),
        _ => const ProviderConfigException('模型服务地址必须是有效的 HTTP 地址。'),
      };
    }
    if (model.trim().isEmpty) {
      throw const ProviderConfigException('请填写模型名称。');
    }
    if (!temperature.isFinite || temperature < 0 || temperature > 2) {
      throw const ProviderConfigException('temperature 必须在 0 到 2 之间。');
    }
    if (timeoutSeconds < 1 || timeoutSeconds > maxConfiguredTimeoutSeconds) {
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
/// 千问（qwen_asr）走 DashScope 多模态接口，自定义（custom）走用户
/// 填写的完整地址（普通 HTTP POST + multipart 表单），同为 HTTP(S)。
enum SttProviderKind {
  openAiCompatible('openai_compatible'),
  volcSeedAsr('volc_seed_asr'),
  qwenAsr('qwen_asr'),
  custom('custom');

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
    SttProviderKind.qwenAsr => scheme == 'http' || scheme == 'https',
    SttProviderKind.custom => scheme == 'http' || scheme == 'https',
  };
}

/// 千问语音识别的 DashScope 多模态端点（设置页缺省值）：地址本身就是
/// 完整端点，请求体按原生形状直接 POST，不做后缀拼接。
const qwenAsrDefaultEndpoint =
    'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation';

/// 千问语音识别的模型名称缺省值（设置页缺省值）。
const qwenAsrDefaultModel = 'qwen3-asr-flash';

/// 自定义转写档的响应形态：配置里的 wire 名与设置页下拉共用。
enum SttResponseShape {
  /// JSON 字段路径：整段响应按点号路径取文本（缺省 text，不支持数组下标）。
  jsonPath('json_path'),

  /// SSE 流式：逐行 data 事件，载荷即增量文本，按序拼成全文。
  sse('sse');

  const SttResponseShape(this.wireName);

  final String wireName;

  static SttResponseShape fromWireName(String value) => values.firstWhere(
    (shape) => shape.wireName == value,
    orElse: () =>
        throw const ProviderConfigException('不支持这个转写响应形态。'),
  );
}

/// 自定义转写档的鉴权头缺省值（整行头名）：留空即按它发，不允许无鉴权出网。
const sttCustomDefaultAuthHeader = 'Authorization: Bearer';

/// 自定义转写档的响应字段缺省值：JSON 字段路径形态下取顶层 text。
const sttCustomDefaultResponseField = 'text';

/// 自定义转写档不允许用作鉴权头的保留头名（小写比较）：content-type 由
/// 网关自己写（撞名会静默覆盖鉴权头、无鉴权出网），content-length 等由
/// dart:io 自管（撞名写出畸形请求）。都在保存前拦成人话。
const sttReservedAuthHeaderNames = <String>{
  'content-type',
  'content-length',
  'host',
  'transfer-encoding',
  'connection',
};

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

/// 语音转写（STT）服务配置：provider.json 顶层的可选 `stt`段。
/// 自定义档（custom）另有三个旋钮：[authHeader] 整行鉴权头名、
/// [responseShape] 响应形态、[responseField] 字段名/路径，均带缺省值，
/// 只在 custom 档校验与落盘；[extraParams] 高级参数作 multipart 额外
/// 表单字段，同样只对 custom 档落盘（其余档请求形状固定，千问的识别
/// 参数也固定，写了没有消费方）。
final class SttConfig {
  const SttConfig({
    required this.baseUrl,
    required this.model,
    this.provider = SttProviderKind.openAiCompatible,
    this.apiKey,
    this.authHeader,
    this.responseShape = SttResponseShape.jsonPath,
    this.responseField = sttCustomDefaultResponseField,
    this.extraParams,
  });

  factory SttConfig.fromJson(Map<String, Object?> json) {
    // provider 字段缺失按缺省协议：不带它的存量配置照常工作。
    final provider = switch (json['provider']) {
      null => SttProviderKind.openAiCompatible,
      final String value => SttProviderKind.fromWireName(value),
      _ => throw const ProviderConfigException('语音服务配置无法读取。'),
    };
    final rawExtra = json['extraParams'] ?? json['extra_params'];
    if (rawExtra != null && rawExtra is! Map) {
      throw const ProviderConfigException('语音服务配置无法读取。');
    }
    final rawAuthHeader = json['authHeader'];
    if (rawAuthHeader != null && rawAuthHeader is! String) {
      throw const ProviderConfigException('语音服务配置无法读取。');
    }
    final rawResponseField = json['responseField'];
    if (rawResponseField != null && rawResponseField is! String) {
      throw const ProviderConfigException('语音服务配置无法读取。');
    }
    return SttConfig(
      provider: provider,
      baseUrl: json['baseUrl']! as String,
      model: json['model']! as String,
      // 与聊天段同律：兼容 apiKey 与 API_KEY 两种手写法，空白视为未设置。
      apiKey: _optionalKey(json['apiKey'] ?? json['API_KEY']),
      authHeader: rawAuthHeader as String?,
      responseShape: switch (json['responseShape']) {
        null => SttResponseShape.jsonPath,
        final String value => SttResponseShape.fromWireName(value),
        _ => throw const ProviderConfigException('语音服务配置无法读取。'),
      },
      responseField: rawResponseField as String? ?? sttCustomDefaultResponseField,
      // 高级参数与合成侧同型：兼容 extraParams 与 extra_params 两种写法。
      extraParams: rawExtra is Map
          ? Map<String, Object?>.from(
              rawExtra.map((k, v) => MapEntry(k.toString(), v)),
            )
          : null,
    );
  }

  final SttProviderKind provider;
  final String baseUrl;
  final String model;

  /// 本机 provider.json 的 stt 段里保存的 API Key（明文）。与聊天 Key
  /// 同律：不进 toJson()，HTTP 快照绝不携带明文。
  final String? apiKey;

  /// 自定义档的鉴权头（整行头名，如 `Authorization: Bearer`、`X-Api-Key`）：
  /// 空表示按缺省 Bearer 发，不允许无鉴权出网。
  final String? authHeader;

  /// 自定义档的响应形态：缺省 JSON 字段路径。
  final SttResponseShape responseShape;

  /// 自定义档的响应字段名/路径（点号路径）：缺省 text。
  final String responseField;

  /// 自定义档的高级参数：multipart 上传时作额外表单字段。
  final Map<String, Object?>? extraParams;

  SttConfig withApiKey(String? apiKey) => SttConfig(
    provider: provider,
    baseUrl: baseUrl,
    model: model,
    apiKey: apiKey,
    authHeader: authHeader,
    responseShape: responseShape,
    responseField: responseField,
    extraParams: extraParams,
  );

  /// Key 的沿用作用域看协议与规范化后的服务地址：换协议（如 OpenAI
  /// 兼容换豆包）与换地址一样，都不沿用旧服务商的 Key。
  String get credentialScope =>
      '${provider.wireName}|${normalizeProviderBaseUri(baseUrl)}';

  Map<String, Object?> toJson() => {
    'provider': provider.wireName,
    'baseUrl': baseUrl,
    'model': model,
    // 旋钮与高级参数只在自定义档落盘：切到别的档时不把残留写回去。
    if (provider == SttProviderKind.custom) ...{
      if (authHeader != null && authHeader!.trim().isNotEmpty)
        'authHeader': authHeader,
      'responseShape': responseShape.wireName,
      'responseField': responseField,
      if (extraParams != null && extraParams!.isNotEmpty)
        'extraParams': extraParams,
    },
  };

  void validate() {
    final schemeFailureMessage = switch (provider) {
      SttProviderKind.openAiCompatible => '语音服务地址必须是有效的 HTTP 地址。',
      SttProviderKind.volcSeedAsr => '语音服务地址必须是有效的 WebSocket 地址。',
      // 千问与自定义同为 HTTP 档：与 OpenAI 兼容共用同一句地址话术。
      SttProviderKind.qwenAsr => '语音服务地址必须是有效的 HTTP 地址。',
      SttProviderKind.custom => '语音服务地址必须是有效的 HTTP 地址。',
    };
    _validateSpeechEndpoint(
      baseUrl: baseUrl,
      model: model,
      serviceLabel: '语音服务',
      allows: provider.allows,
      schemeFailureMessage: schemeFailureMessage,
    );
    // 旋钮只在自定义档校验：鉴权头按「头名: 前缀」拆开分别过可见 ASCII
    // 脏字符检（"Authorization: Bearer" 的冒号空格是合法分隔，整行检会
    // 误伤），还不能撞保留头名（content-type 撞名会被网关自己写的头静默
    // 覆盖，请求无鉴权出网），也要有头名——": Bearer" 这种粘贴事故会让
    // dart:io 写出空头名，请求期才炸未分类异常，保存前拦成人话。
    if (provider == SttProviderKind.custom) {
      final header = authHeader?.trim();
      if (header != null && header.isNotEmpty) {
        final separator = header.indexOf(':');
        final name =
            (separator == -1 ? header : header.substring(0, separator)).trim();
        final prefix =
            separator == -1 ? '' : header.substring(separator + 1).trim();
        if (containsNonVisibleAscii(name) || containsNonVisibleAscii(prefix)) {
          throw const ProviderConfigException(
            '鉴权头里混入了中文或看不见的字符，请重新填写。',
          );
        }
        if (sttReservedAuthHeaderNames.contains(name.toLowerCase())) {
          throw const ProviderConfigException(
            '鉴权头不能使用 Content-Type、Content-Length 这类保留头名，请重新填写。',
          );
        }
        if (name.isEmpty) {
          throw const ProviderConfigException(
            '鉴权头格式不正确，请填写如 Authorization: Bearer 的头名。',
          );
        }
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
}

/// 语音合成的协议类型：配置里的 wire 名与网关分派共用。缺省
/// openai_compatible：不带 provider 字段的存量配置照常工作。
/// 豆包协议（volc_tts）走订阅专属 HTTP 端点，千问协议（qwen_tts）走
/// DashScope 多模态端点，自定义协议（custom）走用户填写的完整地址
/// （普通 HTTP POST + JSON），同为 HTTP(S)。
enum TtsProviderKind {
  openAiCompatible('openai_compatible'),
  volcTts('volc_tts'),
  qwenTts('qwen_tts'),
  custom('custom');

  const TtsProviderKind(this.wireName);

  final String wireName;

  static TtsProviderKind fromWireName(String value) => values.firstWhere(
    (kind) => kind.wireName == value,
    orElse: () => throw const ProviderConfigException('不支持这个语音合成服务协议。'),
  );

  /// 该协议允许的服务地址 scheme（配置校验与出网前 SSRF 校验共用）。
  /// 除千问朗读档外恒为 http/https：即使传输选了 WebSocket 双向（票三），
  /// 用户在地址栏填的仍是 HTTP 端点，WS 地址由 Host 按协议派生、单独过
  /// speechOutboundRefusalReason，不经过配置校验。千问朗读档例外（票 07，
  /// ADR 0020 补篇）：地址即用户填的完整 WS 推理端点（ws/wss 直接可辨
  /// 形状），不经 Host 派生，配置校验按地址 scheme 放行。
  bool allows(String scheme) => switch (this) {
    TtsProviderKind.qwenTts =>
      scheme == 'http' || scheme == 'https' || scheme == 'ws' || scheme == 'wss',
    _ => scheme == 'http' || scheme == 'https',
  };
}

/// 自定义合成档的响应形态：配置里的 wire 名与设置页下拉共用。
enum TtsResponseShape {
  /// 裸音频字节：响应体原样当音频（缺省形态）。
  rawBytes('raw_bytes'),

  /// JSON 字段：整段响应按字段名取，值是 base64 或 http(s) 音频地址。
  jsonField('json_field'),

  /// 逐行 JSON：每行一个 JSON 对象，字段里的 base64 按序拼接。
  jsonLines('json_lines');

  const TtsResponseShape(this.wireName);

  final String wireName;

  static TtsResponseShape fromWireName(String value) => values.firstWhere(
    (shape) => shape.wireName == value,
    orElse: () =>
        throw const ProviderConfigException('不支持这个合成响应形态。'),
  );
}

/// 自定义合成档的鉴权头缺省值（整行头名）：留空即按它发，不允许无鉴权
/// 出网。与 STT 侧同名常量同值同义（转写与合成两档各一份，按段自洽）。
const ttsCustomDefaultAuthHeader = 'Authorization: Bearer';

/// 自定义合成档的响应字段缺省值：JSON 字段与逐行 JSON 两种形态都取
/// 顶层 data。
const ttsCustomDefaultResponseField = 'data';

/// 自定义合成档不允许用作鉴权头的保留头名（小写比较）：content-type 由
/// 网关自己写（撞名会静默覆盖鉴权头、无鉴权出网），content-length 等由
/// dart:io 自管（撞名写出畸形请求）。与 STT 侧同集合同理由，按段各一
/// 份（两段配置各自校验，改一处不该静默改另一处）。
const ttsReservedAuthHeaderNames = <String>{
  'content-type',
  'content-length',
  'host',
  'transfer-encoding',
  'connection',
};

/// 豆包语音合成的订阅专属 HTTP 端点（设置页缺省值）：一次性发送文本、
/// 返回 chunked 逐行 JSON 音频。地址本身就是完整端点，不做后缀拼接。
const volcTtsDefaultEndpoint =
    'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional';

/// 豆包语音合成 2.0 的 Resource-Id（模型名称字段缺省值）。
const volcTtsDefaultResourceId = 'seed-tts-2.0';

/// 千问语音合成的 DashScope 端点（设置页缺省值）：与千问识别同端点，
/// 地址本身就是完整端点，请求体直接 POST，不做后缀拼接。
///
/// 与 Flutter `tts_settings_client.dart` 同名常量双源同值（设置层按 HTTP
/// 镜像防御旧版 Host，不与宿主包编译期耦合）：改动需两边同步。
const qwenTtsDefaultEndpoint =
    'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation';

/// 千问语音合成的模型名称缺省值（设置页缺省值；与 Flutter 侧同名常量
/// 双源同值，改动需两边同步）。
const qwenTtsDefaultModel = 'qwen3-tts-flash';

/// 千问语音合成的音色缺省值（官方示例音色，设置页缺省值）。音色是自由
/// 输入框：任何千问音色 ID 都能填，暂无预设目录。与 Flutter 侧同名常量
/// 双源同值（改动需两边同步）；本包内网关空音色回落也用它，单处真相。
const qwenTtsDefaultVoice = 'Cherry';

/// 语音合成的传输方式（票三）：只归豆包档（volc_tts）——HTTP 分块
/// （缺省，票二的逐行分块通道）或 WebSocket 双向（边出文本边合成的
/// 连续供给）。千问档继续型号驱动（型号名以 -realtime 结尾走 WS），
/// 自定义档不动。设置页只对豆包档露出下拉；WS 地址由 Host 从 baseUrl
/// 派生，baseUrl 本身始终只允许 http/https。
enum TtsTransport {
  httpChunk('http_chunk'),
  wsBidirection('ws_bidirection');

  const TtsTransport(this.wireName);

  final String wireName;

  static TtsTransport fromWireName(String value) => values.firstWhere(
    (transport) => transport.wireName == value,
    orElse: () =>
        throw const ProviderConfigException('语音合成服务配置无法读取。'),
  );
}

/// 语音合成（TTS）服务配置：provider.json 顶层的可选 `tts` 段。
/// [speed] 为空表示用服务缺省语速；[autoSpeak] 是聊天页朗读开关的
/// 持久化位（缺省开：配了就自动读）。自定义档（custom）另有三个旋钮：
/// [authHeader] 整行鉴权头名、[responseShape] 响应形态、[responseField]
/// 字段名，均带缺省值，只在 custom 档校验与落盘（其余档请求形状固定）。
final class TtsConfig {
  const TtsConfig({
    required this.baseUrl,
    required this.model,
    this.provider = TtsProviderKind.openAiCompatible,
    this.apiKey,
    this.voice,
    this.speed,
    this.autoSpeak = true,
    this.authHeader,
    this.responseShape = TtsResponseShape.rawBytes,
    this.responseField = ttsCustomDefaultResponseField,
    this.extraParams,
    this.transport = TtsTransport.httpChunk,
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
    final rawAuthHeader = json['authHeader'];
    if (rawAuthHeader != null && rawAuthHeader is! String) {
      throw const ProviderConfigException('语音合成服务配置无法读取。');
    }
    final rawResponseField = json['responseField'];
    if (rawResponseField != null && rawResponseField is! String) {
      throw const ProviderConfigException('语音合成服务配置无法读取。');
    }
    // 传输方式字段缺失按缺省 HTTP 分块：存量配置照常工作。
    final transport = switch (json['transport']) {
      null => TtsTransport.httpChunk,
      final String value => TtsTransport.fromWireName(value),
      _ => throw const ProviderConfigException('语音合成服务配置无法读取。'),
    };
    return TtsConfig(
      provider: provider,
      baseUrl: json['baseUrl']! as String,
      model: json['model']! as String,
      // 与聊天段同律：兼容 apiKey 与 API_KEY 两种手写法，空白视为未设置。
      apiKey: _optionalKey(json['apiKey'] ?? json['API_KEY']),
      voice: voice as String?,
      speed: rawSpeed is num ? rawSpeed.toDouble() : null,
      autoSpeak: rawAutoSpeak is bool ? rawAutoSpeak : true,
      authHeader: rawAuthHeader as String?,
      responseShape: switch (json['responseShape']) {
        null => TtsResponseShape.rawBytes,
        final String value => TtsResponseShape.fromWireName(value),
        _ => throw const ProviderConfigException('语音合成服务配置无法读取。'),
      },
      responseField: rawResponseField as String? ?? ttsCustomDefaultResponseField,
      // 高级参数与合成侧同型：兼容 extraParams 与 extra_params 两种写法。
      extraParams: extraParams,
      transport: transport,
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

  /// 自定义档的鉴权头（整行头名，如 `Authorization: Bearer`、`X-Api-Key`）：
  /// 空表示按缺省 Bearer 发，不允许无鉴权出网。
  final String? authHeader;

  /// 自定义档的响应形态：缺省裸音频字节。
  final TtsResponseShape responseShape;

  /// 自定义档的响应字段名：JSON 字段与逐行 JSON 两种形态共用，缺省 data。
  final String responseField;

  /// 自定义高级参数（深合并入请求体）。
  final Map<String, Object?>? extraParams;

  /// 传输方式（票三）：只对豆包档有意义——HTTP 分块（缺省）或 WebSocket
  /// 双向连续供给。其余档恒为缺省值（千问按型号驱动、自定义档不动），
  /// 也不落盘。WS 地址由 Host 按协议从 baseUrl 派生，不经过本字段校验。
  final TtsTransport transport;

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
    authHeader: authHeader,
    responseShape: responseShape,
    responseField: responseField,
    extraParams: extraParams,
    transport: transport,
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
    // 旋钮与高级参数只在自定义档落盘：切到别的档时不把残留写回去
    // （extraParams 三档本就消费，落盘口径不动）。传输方式只对豆包档
    // 落盘：其余档恒为缺省值，写回去只会让文件多出一个没人读的字段。
    if (provider == TtsProviderKind.volcTts) 'transport': transport.wireName,
    if (provider == TtsProviderKind.custom) ...{
      if (authHeader != null && authHeader!.trim().isNotEmpty)
        'authHeader': authHeader,
      'responseShape': responseShape.wireName,
      'responseField': responseField,
    },
    if (extraParams != null && extraParams!.isNotEmpty)
      'extraParams': extraParams,
  };

  void validate() {
    // scheme 话术按档分开：千问朗读档收 ws/wss（票 07），其余档仍是
    // 纯 HTTP 档，各说各的允许 scheme。
    final schemeFailureMessage = provider == TtsProviderKind.qwenTts
        ? '语音合成服务地址必须是有效的 HTTP 或 WebSocket 地址。'
        : '语音合成服务地址必须是有效的 HTTP 地址。';
    _validateSpeechEndpoint(
      baseUrl: baseUrl,
      model: model,
      serviceLabel: '语音合成服务',
      allows: provider.allows,
      schemeFailureMessage: schemeFailureMessage,
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
    // 旋钮只在自定义档校验：鉴权头按「头名: 前缀」拆开分别过可见 ASCII
    // 脏字符检（"Authorization: Bearer" 的冒号空格是合法分隔，整行检会
    // 误伤），还不能撞保留头名（content-type 撞名会被网关自己写的头静默
    // 覆盖，请求无鉴权出网），也要有头名——": Bearer" 这种粘贴事故会让
    // dart:io 写出空头名，请求期才炸未分类异常，保存前拦成人话。与
    // 转写自定义档同律同话术。
    if (provider == TtsProviderKind.custom) {
      final header = authHeader?.trim();
      if (header != null && header.isNotEmpty) {
        final separator = header.indexOf(':');
        final name =
            (separator == -1 ? header : header.substring(0, separator)).trim();
        final prefix =
            separator == -1 ? '' : header.substring(separator + 1).trim();
        if (containsNonVisibleAscii(name) || containsNonVisibleAscii(prefix)) {
          throw const ProviderConfigException(
            '鉴权头里混入了中文或看不见的字符，请重新填写。',
          );
        }
        if (ttsReservedAuthHeaderNames.contains(name.toLowerCase())) {
          throw const ProviderConfigException(
            '鉴权头不能使用 Content-Type、Content-Length 这类保留头名，请重新填写。',
          );
        }
        if (name.isEmpty) {
          throw const ProviderConfigException(
            '鉴权头格式不正确，请填写如 Authorization: Bearer 的头名。',
          );
        }
      }
    }
  }
}

/// provider.json 共享读改写事务的排队入口。聊天、语音转写、语音合成、
/// 联网搜索与代理五类设置共用同一份文件，「读取现值 → 决定 Key 去留
/// → 写回 → 旧凭据清理」的完整流程必须经 [runTransaction] 排队执行：
/// 只有事务内的读取才能看到前一个事务的写回，锁外读到的旧值、旧 Key
/// 一律不得带回事务内使用。同一仓储实例上的事务彼此串行，单个事务
/// 失败（含写回失败）只影响自身，队列照常放行后续事务。
abstract interface class ProviderConfigTransactionQueue {
  Future<T> runTransaction<T>(Future<T> Function() action);
}

abstract interface class ProviderConfigRepository
    implements ProviderConfigTransactionQueue {
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

abstract interface class WebSearchConfigRepository
    implements ProviderConfigTransactionQueue {
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

abstract interface class ProxyConfigRepository
    implements ProviderConfigTransactionQueue {
  Future<ProxyConfig?> loadProxy();

  Future<void> saveProxy(ProxyConfig? config);
}

abstract interface class SttConfigRepository
    implements ProviderConfigTransactionQueue {
  Future<SttConfig?> loadStt();

  Future<void> saveStt(SttConfig config);
}

abstract interface class TtsConfigRepository
    implements ProviderConfigTransactionQueue {
  Future<TtsConfig?> loadTts();

  Future<void> saveTts(TtsConfig config);
}

/// provider.json 的 JSON 仓储：五个仓储接口共用同一份文件。保存类
/// 方法实现「读整份 → 只改本段 → 原子写回」，但排队边界在
/// [runTransaction]——调用方必须把「读取现值 → 决定 Key 去留 → 写回
/// → 旧凭据清理」的整段流程包进共享事务，在事务外直接保存会失去与
/// 其他段的串行保障。全部设置服务共享同一仓储实例（组合根装配保
/// 证）；队列只在实例内串行，不提供跨进程互斥。
final class JsonProviderConfigRepository
    implements
        ProviderConfigRepository,
        SttConfigRepository,
        TtsConfigRepository,
        WebSearchConfigRepository,
        ProxyConfigRepository {
  JsonProviderConfigRepository({
    required this.filePath,
    this.writer = const IoAtomicTextWriter(),
  });

  final String filePath;
  final AtomicTextWriter writer;

  /// 共享读改写队列的队尾：每个事务等前一个事务完全结束（成功或失
  /// 败）后才开始，错误不在队列里传播——写回失败只拒绝自己的调用方，
  /// 队列照常放行后续事务。事务内不得再开启事务：同一实例上的嵌套
  /// 调用会自等死锁，需要连带的多段操作应写进同一个事务动作。
  Future<void> _transactionTail = Future.value();

  @override
  Future<T> runTransaction<T>(Future<T> Function() action) {
    final result = _transactionTail.then((_) => action());
    _transactionTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

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
    // 入参恒非空：语音段只替换、不删除，不走助手的删除分支。
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
    // 入参恒非空：语音段只替换、不删除，不走助手的删除分支。
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
  /// null（写路径无从保留损坏内容，交由调用方整体重建）。带 BOM 的文
  /// 件先剥 BOM 再解析：手动编辑过的假性损坏不算损坏，写路径才能保
  /// 住 stt/tts 等其余段与 Key。
  Future<Map<String, Object?>?> _readRawMap({required bool orThrow}) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return null;
    }
    try {
      final decoded = jsonDecode(stripUtf8Bom(await file.readAsString()));
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
