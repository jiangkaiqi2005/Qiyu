import 'dart:convert';

import 'model_gateway.dart';
import 'provider_config.dart';
import 'stt_gateway.dart';

/// 自定义转写服务（custom）网关：面向「普通 HTTP POST、multipart 表单、
/// Bearer 类鉴权」的第三方转写服务。POST 用户填写的完整地址（不拼后缀），
/// 表单与 OpenAI 兼容档逐字一致（file 字段带文件名与 content-type、model、
/// language=zh），高级参数作额外表单字段。响应两种形态：json_path（点号
/// 路径取文本，缺省 text，不支持数组下标）与 sse（逐行 data 事件拼字）。
/// 鉴权头可配：配置存整行头名，留空回落默认 Authorization: Bearer，
/// 不允许无鉴权出网。失败分类与文案沿用既有转写通道（语音服务）。
final class CustomSttGateway implements SttTranscriptionGateway {
  const CustomSttGateway(this.httpClient);

  final ProviderHttpClient httpClient;

  @override
  Future<String> transcribe({
    required SttConfig config,
    required String? apiKey,
    required List<int> audio,
    required String mimeType,
  }) async {
    config.validate();
    final key = requireSttApiKey(apiKey);
    final uri = Uri.parse(config.baseUrl.trim());
    // 自定义档同属新增出网路径：出网前统一过 SSRF 校验（聊天 Provider 不走）。
    ensureSttOutboundAllowed(uri);
    final boundary = newSttBoundary();
    final response = await postSttText(
      httpClient: httpClient,
      uri: uri,
      headers: {
        ..._authHeaders(config.authHeader, key),
        'content-type': 'multipart/form-data; boundary=$boundary',
      },
      body: buildSttMultipartBody(
        boundary: boundary,
        config: config,
        audio: audio,
        mimeType: mimeType,
        extraParams: config.extraParams,
      ),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw fromSttModelFailure(
        providerStatusFailure(
          response.statusCode,
          response.body,
          serviceLabel: '语音服务',
        ),
      );
    }
    return switch (config.responseShape) {
      SttResponseShape.jsonPath => _parseJsonPathText(
        response.body,
        config.responseField,
      ),
      SttResponseShape.sse => _parseSseText(response.body),
    };
  }
}

/// 鉴权头拼接：配置存整行头名（如 `Authorization: Bearer`、`X-Api-Key`），
/// 冒号前是头名、冒号后是 scheme 前缀；无冒号时整行都是头名、Key 直送。
/// 留空（含纯空白）回落缺省 [sttCustomDefaultAuthHeader]——语音流量不允许
/// 无鉴权出网。缺省与用户填写的值走同一条拼接口径，头名与前缀的字面量
/// 因此只在常量里出现一次。头名统一小写：HTTP 头名大小写不敏感，与既有
/// 网关同口径。
Map<String, String> _authHeaders(String? authHeader, String key) {
  final line = authHeader?.trim() ?? '';
  return _composeAuthHeader(
    line.isEmpty ? sttCustomDefaultAuthHeader : line,
    key,
  );
}

Map<String, String> _composeAuthHeader(String line, String key) {
  final separator = line.indexOf(':');
  final name =
      (separator == -1 ? line : line.substring(0, separator)).trim();
  final prefix = separator == -1 ? '' : line.substring(separator + 1).trim();
  return {
    name.toLowerCase(): prefix.isEmpty ? key : '$prefix $key',
  };
}

/// json_path 形态：点号路径逐层取文本，路径空白回落缺省 text。路径中途
/// 撞见非对象（含数组下标：List 不是 Map）或落点不是字符串，一律按解析
/// 失败给人话——响应文本在数组下标的服务是本期范围外，不静默取错值。
String _parseJsonPathText(String body, String field) {
  final Map<String, Object?> decoded;
  try {
    final value = jsonDecode(body);
    if (value is! Map<String, Object?>) {
      throw const FormatException('response must be an object');
    }
    decoded = value;
  } on Object {
    throw _contentParsingFailure;
  }
  final path = field.trim();
  final segments = path.isEmpty ? const ['text'] : path.split('.');
  Object? current = decoded;
  for (final segment in segments) {
    if (current is! Map<String, Object?>) {
      throw _contentParsingFailure;
    }
    current = current[segment];
  }
  if (current is! String) {
    throw _contentParsingFailure;
  }
  return current;
}

/// sse 形态：逐行 data 事件，载荷即增量文本，按序拼成全文；空行与
/// [DONE] 终止标记跳过。载荷裹 JSON 的服务选 json_path 形态（整段响应
/// 一次取），本形态不做 JSON 猜解。载荷只按 SSE 规范剥一个前导空格：
/// delta 的首尾空白可能是服务端有意的分词内容，不能整段 trim 掉。
String _parseSseText(String body) {
  final buffer = StringBuffer();
  for (final rawLine in const LineSplitter().convert(body)) {
    // CRLF 行尾的 \r 先剥掉（LineSplitter 只按 \n 断行），其余原样保留。
    final line = rawLine.endsWith('\r')
        ? rawLine.substring(0, rawLine.length - 1)
        : rawLine;
    if (!line.trimLeft().startsWith('data:')) {
      continue;
    }
    var payload = line.substring(line.indexOf('data:') + 5);
    if (payload.startsWith(' ')) {
      payload = payload.substring(1);
    }
    if (payload.isEmpty || payload.trim() == '[DONE]') {
      continue;
    }
    buffer.write(payload);
  }
  return buffer.toString();
}

const _contentParsingFailure = SttGatewayException(
  kind: ModelFailureKind.contentParsing,
  message: '语音服务返回的内容无法解析。',
);
