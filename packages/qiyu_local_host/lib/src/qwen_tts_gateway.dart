import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'provider_config.dart';
import 'speech_audio_download.dart';
import 'tts_gateway.dart';

/// 千问语音合成（qwen_tts）HTTP 网关：阿里云百炼 3.1 SpeechSynthesizer 端点
/// （CosyVoice 家族）。非流式合成——POST 完响应只给一个 24 小时有效的公网
/// 音频地址，再经下载通道取回完整音频字节；流式接口按 E1 降级成句子级整段。
final class QwenTtsGateway
    implements TtsSynthesisGateway, TtsStreamSynthesisGateway {
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
    final body = _maasRequestBody(config: config, text: text);
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

  @override
  Stream<VoiceAudioChunk> synthesizeStream({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) =>
      _maasWholeSegmentStream(
        config: config,
        apiKey: apiKey,
        text: text,
      );

  /// 3.1 新形状的流式接口（E1 降级）：本句整段合成收成一个完整容器块。
  /// 不套 [guardTtsAudioStream] 的外层空闲计时——首块要等合成 POST 与
  /// 下载跳两跳串行才到，外层按单跳预算计时会把合法慢两跳（如
  /// 40s+40s）提前砍掉；两跳各自的 60s 预算与异常分类已在出网调用
  /// （[postTtsBytes]/[downloadSpeechAudioBytes] 共用的 guardTtsOutbound
  /// 与响应消费）内生效，这里没有需要额外兜的裸异常面。
  Stream<VoiceAudioChunk> _maasWholeSegmentStream({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async* {
    final audio = await synthesize(config: config, apiKey: apiKey, text: text);
    yield VoiceAudioChunk(
      bytes: Uint8List.fromList(audio),
      mimeType: voiceWholeContainerMime,
    );
  }

  /// 3.1 请求体（官方 SpeechSynthesizer 端点，CosyVoice 家族）：
  /// input 带 text/voice/format/sample_rate。高级参数按既有千问档
  /// 合并语义深合并进 input——官方新增字段（如 CosyVoice 的
  /// instruction）由此透传，用户显式写的 format/sample_rate 覆盖缺省。
  String _maasRequestBody({required TtsConfig config, required String text}) {
    final voice = config.voice?.trim();
    final fallbackVoice = qwenTtsDefaultVoiceForModel(config.model);
    final input = <String, Object?>{
      'text': text,
      'voice': voice == null || voice.isEmpty ? fallbackVoice : voice,
      'format': 'wav',
      'sample_rate': qwenTtsPcmSampleRate,
    };
    final extra = config.extraParams;
    return jsonEncode({
      'model': config.model.trim(),
      'input': extra == null ? input : mergeTtsExtraIntoInput(input, extra),
    });
  }
}

/// 把一段可能带 RIFF/WAVE 容器头的音频字节归一成裸 PCM（千问 WS 推理通道共用）：
/// 块带 RIFF/WAVE 头就按块遍历定位 fmt/data 两个子块剥掉容器只留裸样本，
/// 并读回 fmt 里的协商采样率；裸 PCM 块不以 RIFF 开头，原样通过。
///
/// 返回的 pcm 可能为空（只有容器头没有 data 的片段），sampleRate 仍会
/// 带回——调用方据此统一一路流的采样率标注。
({Uint8List pcm, int? sampleRate}) qwenTtsNormalizeWavChunk(Uint8List bytes) {
  if (bytes.length < 12) {
    return (pcm: bytes, sampleRate: null);
  }
  final riff = ascii.decode(bytes.sublist(0, 4), allowInvalid: true);
  final wave = ascii.decode(bytes.sublist(8, 12), allowInvalid: true);
  if (riff != 'RIFF' || wave != 'WAVE') {
    return (pcm: bytes, sampleRate: null);
  }
  int? sampleRate;
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = ascii.decode(
      bytes.sublist(offset, offset + 4),
      allowInvalid: true,
    );
    final size = ByteData.sublistView(
      bytes,
      offset + 4,
      offset + 8,
    ).getUint32(0, Endian.little);
    final bodyStart = offset + 8;
    if (id == 'fmt ' && bodyStart + 8 <= bytes.length) {
      sampleRate = ByteData.sublistView(
        bytes,
        bodyStart + 4,
        bodyStart + 8,
      ).getUint32(0, Endian.little);
    }
    if (id == 'data') {
      // data 块可能被截断（流式分块的边界是任意的）：以实际到达为准。
      final end = bodyStart + size > bytes.length
          ? bytes.length
          : bodyStart + size;
      return (
        pcm: Uint8List.view(
          bytes.buffer,
          bytes.offsetInBytes + bodyStart,
          end - bodyStart,
        ),
        sampleRate: sampleRate,
      );
    }
    // 块按 2 字节对齐：奇数长度后有一个填充字节。
    offset = bodyStart + size + (size.isOdd ? 1 : 0);
  }
  // 有 RIFF 头但没有 data 块（纯容器头片段）：只把采样率带回去。
  stderrDiagnostics(
    'tts qwen chunk carries wav header without data block (len=${bytes.length})',
  );
  return (pcm: Uint8List(0), sampleRate: sampleRate);
}

/// qwen_tts 档的形状分派：地址主机含 `maas.aliyuncs.com` 走 3.1 官方
/// SpeechSynthesizer 形状（CosyVoice 家族请求体）。
bool qwenTtsUsesMaasShape(Uri uri) =>
    uri.host.toLowerCase().contains('maas.aliyuncs.com');

/// qwen_tts 档的 WS 推理分派：地址 scheme 为 ws/wss 走 DashScope 经典
/// SpeechSynthesizer WS 推理协议（`/api-ws/v1/inference` 事件流）。
bool qwenTtsUsesWsInference(String baseUrl) {
  final uri = Uri.tryParse(baseUrl.trim());
  if (uri == null) {
    return false;
  }
  final scheme = uri.scheme.toLowerCase();
  return scheme == 'ws' || scheme == 'wss';
}

/// 千问 3.1 语音合成模型的默认音色：官方首推女声（3.1 引擎层只认 3.1 专属音色）。
const qwenTts31DefaultVoice = 'longanhuan_v3.1';

/// 根据型号获取千问 3.1 语音合成默认音色。
String qwenTtsDefaultVoiceForModel(String model) => qwenTtsDefaultVoice;

/// 千问音频段的协商采样率：PCM 基准（24kHz 单声道 16-bit）。
const qwenTtsPcmSampleRate = 24000;

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
