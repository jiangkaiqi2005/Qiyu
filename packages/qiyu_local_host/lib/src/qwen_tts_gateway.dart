import 'dart:convert';
import 'dart:typed_data';

import 'model_gateway.dart';
import 'provider_config.dart';
import 'speech_audio_download.dart';
import 'tts_gateway.dart';

/// 千问语音合成（qwen_tts）网关：阿里云百炼 DashScope 的多模态接口。
/// 与千问识别同端点：地址栏填完整端点，不做后缀拼接。非流式合成——
/// POST 完响应只给一个 24 小时有效的公网音频地址，再经下载通道取回
/// 完整音频字节，两个请求拿到一个完整文件。ADR 0002 的整段合成语义
/// 不变：音频只在内存流转，Host 不落盘。
final class QwenTtsGateway implements TtsSynthesisGateway {
  const QwenTtsGateway(this.httpClient);

  final ProviderBytesHttpClient httpClient;

  @override
  Future<List<int>> synthesize({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async {
    config.validate();
    final key = requireTtsApiKey(apiKey);
    final uri = Uri.parse(config.baseUrl.trim());
    // TTS 是新增出网路径：出网前统一过 SSRF 校验（与 STT 共用判定）。
    ensureTtsOutboundAllowed(uri);
    final voice = config.voice?.trim();
    final input = <String, Object?>{
      'text': text,
      // 用户没填音色时用协议缺省（官方示例音色，与设置页缺省同源）。
      'voice': voice == null || voice.isEmpty ? qwenTtsDefaultVoice : voice,
      'language_type': 'Chinese',
    };
    final extra = config.extraParams;
    final body = jsonEncode({
      'model': config.model.trim(),
      // 高级参数深合并进 input：千问的 instructions 类字段就在 input 下
      // （换 instruct 模型时传指令控制）。
      'input': extra == null ? input : _mergeExtraIntoInput(input, extra),
    });
    final response = await postTtsBytes(
      httpClient: httpClient,
      uri: uri,
      headers: {
        'authorization': 'Bearer $key',
        'content-type': 'application/json',
      },
      body: utf8.encode(body),
    );
    final bytes = await consumeTtsBytesResponse(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // 错误体是文本 JSON：latin1 保留字节可读性，只用于错误分类。
      throw fromTtsModelFailure(
        providerStatusFailure(
          response.statusCode,
          latin1.decode(bytes, allowInvalid: true),
          serviceLabel: '语音合成服务',
        ),
      );
    }
    // 响应只给音频地址：经下载通道取回完整音频字节（地址缺失、无效或
    // 下载失败由下载通道按现有分类说人话）。
    return downloadSpeechAudioBytes(
      httpClient: httpClient,
      url: _extractAudioUrl(bytes),
    );
  }
}

/// 深合并：extraParams 合进基础 input——同名字段两边都是对象时逐层
/// 合并，其余以 extraParams 为准（用户在高级参数里显式写的值优先，
/// 厂商自有参数由此兜住）。
Map<String, Object?> _mergeExtraIntoInput(
  Map<String, Object?> input,
  Map<String, Object?> extra,
) {
  final merged = Map<String, Object?>.from(input);
  for (final entry in extra.entries) {
    final current = merged[entry.key];
    final value = entry.value;
    if (current is Map && value is Map) {
      merged[entry.key] = _mergeExtraIntoInput(
        current.cast<String, Object?>(),
        value.cast<String, Object?>(),
      );
    } else {
      merged[entry.key] = value;
    }
  }
  return merged;
}

/// 从非流式响应里取音频地址：output.audio.url。容忍解码——非 JSON、
/// 形状不符或字段类型不对一律返回 null，由下载通道按「没有返回有效的
/// 音频地址」说人话。
String? _extractAudioUrl(Uint8List body) {
  final Map<String, Object?> decoded;
  try {
    final parsed = jsonDecode(utf8.decode(body, allowMalformed: true));
    if (parsed is! Map<String, Object?>) {
      return null;
    }
    decoded = parsed;
  } on Object {
    return null;
  }
  final output = decoded['output'];
  if (output is! Map<String, Object?>) {
    return null;
  }
  final audio = output['audio'];
  if (audio is! Map<String, Object?>) {
    return null;
  }
  final url = audio['url'];
  return url is String ? url : null;
}
