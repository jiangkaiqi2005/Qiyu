import 'dart:convert';

import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'provider_config.dart';
import 'stt_gateway.dart';

/// 千问语音识别（qwen_asr）网关：阿里云百炼 DashScope 的多模态接口。
/// 地址栏填完整端点，两种形状都不做后缀拼接；形状由地址路径里是否带
/// `/compatible-mode/` 唯一确定（业务空间专属域名走兼容形状），用户不
/// 需要理解两种形状的区别。录音经浏览器转 16k WAV 后 base64 编 data
/// URL 上送，固定中文识别（asr_options.language）并关掉文本规整
/// （enable_itn）。响应带 request_id 时写本机诊断（与豆包 logid 同律）。
final class QwenAsrGateway implements SttTranscriptionGateway {
  const QwenAsrGateway(this.httpClient);

  final ProviderHttpClient httpClient;

  @override
  Future<String> transcribe({
    required SttConfig config,
    required String? apiKey,
    required List<int> audio,
    required String mimeType,
    String? locale,
  }) async {
    config.validate();
    final key = requireSttApiKey(apiKey);
    final uri = Uri.parse(config.baseUrl.trim());
    // STT 是新增出网路径：出网前统一过 SSRF 校验（聊天 Provider 不走）。
    ensureSttOutboundAllowed(uri);
    // 形状只判定一次：请求体与响应提取共用同一结论，不再各自解析地址。
    final compatible = _usesCompatibleShape(uri);
    final body = jsonEncode(
      _requestBody(
        config: config,
        audio: audio,
        mimeType: mimeType,
        compatible: compatible,
      ),
    );

    final response = await postSttText(
      httpClient: httpClient,
      uri: uri,
      headers: {
        'authorization': 'Bearer $key',
        'content-type': 'application/json',
      },
      body: utf8.encode(body),
    );
    // 请求标识先进诊断（错误响应同样带），再按状态码分类。
    _logRequestId(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw fromSttModelFailure(
        providerStatusFailure(
          response.statusCode,
          response.body,
          serviceLabel: '语音服务',
        ),
      );
    }
    return _parseTranscriptionText(response.body, compatible: compatible);
  }
}

/// 形状分派：地址路径里带 `/compatible-mode/` 的走兼容形状，其余走
/// DashScope 原生多模态形状。路径中间带该片段（如 /api/compatible-mode/v1）
/// 同样算兼容。
bool _usesCompatibleShape(Uri uri) => uri.path.contains('/compatible-mode/');

/// 识别参数：固定中文、关文本规整（睡前中文场景要原样的口语文本），
/// 两种形状各有一份同名字段，共用同一份字面量。
const _asrOptions = <String, Object?>{
  'language': 'zh',
  'enable_itn': false,
};

Map<String, Object?> _requestBody({
  required SttConfig config,
  required List<int> audio,
  required String mimeType,
  required bool compatible,
}) {
  final data = 'data:${mimeType.trim()};base64,${base64Encode(audio)}';
  if (compatible) {
    return {
      'model': config.model.trim(),
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'input_audio',
              'input_audio': {'data': data},
            },
          ],
        },
      ],
      'asr_options': _asrOptions,
    };
  }
  return {
    'model': config.model.trim(),
    'input': {
      'messages': [
        {
          'role': 'user',
          'content': [
            {'audio': data},
          ],
        },
      ],
    },
    'parameters': {
      'asr_options': _asrOptions,
    },
  };
}

/// 容忍解码：非 JSON（错误页、断流）返回 null，由调用方按原始 body 走
/// 状态码分类或解析失败。
Map<String, Object?>? _decodeObject(String body) {
  try {
    final decoded = jsonDecode(body);
    return decoded is Map<String, Object?> ? decoded : null;
  } on Object {
    return null;
  }
}

/// 官方接入建议：记录 request_id 便于排查（只进本机诊断，不带正文）。
void _logRequestId(String body) {
  final requestId = _decodeObject(body)?['request_id'];
  if (requestId is String && requestId.isNotEmpty) {
    stderrDiagnostics('stt qwen request_id: $requestId');
  }
}

/// 文本提取按请求形状绑定：地址唯一确定了形状，响应就该落在同一条路径上，
/// 不跨形状猜。兼容形状取 choices[0].message.content，原生形状取
/// output.choices[0].message.content[0].text；取不到一律按解析失败。
String _parseTranscriptionText(String body, {required bool compatible}) {
  final decoded = _decodeObject(body);
  final text = decoded == null ? null : _extractText(decoded, compatible);
  if (text == null) {
    throw const SttGatewayException(
      kind: ModelFailureKind.contentParsing,
      message: '语音服务返回的内容无法解析。',
    );
  }
  return text;
}

String? _extractText(Map<String, Object?> decoded, bool compatible) {
  final choices = compatible ? decoded['choices'] : (decoded['output'] is Map<String, Object?>
      ? (decoded['output'] as Map<String, Object?>)['choices']
      : null);
  if (choices is! List<Object?> || choices.isEmpty) {
    return null;
  }
  final first = choices.first;
  if (first is! Map<String, Object?>) {
    return null;
  }
  final message = first['message'];
  if (message is! Map<String, Object?>) {
    return null;
  }
  final content = message['content'];
  // 兼容形状的 content 是整段文本；原生形状是分块列表，取首块 text。
  if (compatible) {
    return content is String ? content : null;
  }
  if (content is! List<Object?>) {
    return null;
  }
  for (final item in content) {
    if (item is Map<String, Object?> && item['text'] is String) {
      return item['text'] as String;
    }
  }
  return null;
}
