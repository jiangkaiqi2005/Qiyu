import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'provider_config.dart';
import 'speech_audio_download.dart';
import 'tts_gateway.dart';

/// 千问语音合成（qwen_tts）网关：阿里云百炼 DashScope 的多模态接口。
/// 与千问识别同端点：地址栏填完整端点，不做后缀拼接。非流式合成——
/// POST 完响应只给一个 24 小时有效的公网音频地址，再经下载通道取回
/// 完整音频字节，两个请求拿到一个完整文件。ADR 0002 的整段合成语义
/// 不变：音频只在内存流转，Host 不落盘。
///
/// 流式合成（票二）：同一端点加 `X-DashScope-SSE: enable` 请求头，
/// 中间块的 `output.audio.data` 即 base64 音频段，逐块转音频事件；
/// 最后一块 `data` 为空串并给出完整音频 URL、`finish_reason` 变
/// `stop`。型号决定 API 家族（ADR 0015）：`qwen3-tts-flash` 走 HTTP
/// SSE 流式（设置页提示流式型号名）；`qwen-audio-3.1-tts-next` 官方
/// 标注 Non-streaming，不用于流式场景（ADR 0018 修订记录）。
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
    final body = _requestBody(config: config, text: text);
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
  }) => guardTtsAudioStream(() async* {
    config.validate();
    final key = requireTtsApiKey(apiKey);
    final uri = Uri.parse(config.baseUrl.trim());
    ensureTtsOutboundAllowed(uri);
    final response = await postTtsBytes(
      httpClient: httpClient,
      uri: uri,
      headers: {
        'authorization': 'Bearer $key',
        'content-type': 'application/json',
        // 官方流式开关：中间块即 base64 音频段（与整段同一请求体）。
        'X-DashScope-SSE': 'enable',
      },
      body: utf8.encode(_requestBody(config: config, text: text)),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errorBytes = await consumeTtsBytesResponse(response);
      throw fromTtsModelFailure(
        providerStatusFailure(
          response.statusCode,
          latin1.decode(errorBytes, allowInvalid: true),
          serviceLabel: '语音合成服务',
        ),
      );
    }
    var produced = false;
    var finished = false;
    // 一路流的协商采样率：带头（WAV 片段）的块读回头里的值并沿用给
    // 后续裸块——播放端只按首块初始化，一路流内不会变。
    int? streamSampleRate;
    await for (final line in response.body
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      final payload = _sseDataPayload(line);
      if (payload == null) {
        continue;
      }
      final audio = _extractStreamAudio(payload);
      if (audio.finished) {
        finished = true;
        break;
      }
      final data = audio.data;
      if (data == null || data.isEmpty) {
        continue;
      }
      final normalized = _normalizeChunk(_decodeBase64(data));
      // 先接采样率再跳空片段：只有容器头没有 data 的片段也带着协商
      // 采样率，丢了它整路流的标注就错（后续裸块经 ??= 沿用它）。
      streamSampleRate ??= normalized.sampleRate;
      if (normalized.pcm.isEmpty) {
        continue;
      }
      produced = true;
      yield VoiceAudioChunk(
        bytes: normalized.pcm,
        sampleRate: streamSampleRate ?? qwenTtsPcmSampleRate,
      );
    }
    if (!finished) {
      // 没见到 finish_reason=stop（或等价的收束块）就断流：半截音频
      // 不能用，与豆包结束码同律。
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务返回的音频不完整。',
      );
    }
    if (!produced) {
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务没有返回音频。',
      );
    }
  });

  /// 请求体：整段与流式同一形状（官方明示流式与非流式响应结构相同）。
  String _requestBody({required TtsConfig config, required String text}) {
    final voice = config.voice?.trim();
    final input = <String, Object?>{
      'text': text,
      // 用户没填音色时用协议缺省（官方示例音色，与设置页缺省同源）。
      'voice': voice == null || voice.isEmpty ? qwenTtsDefaultVoice : voice,
      'language_type': 'Chinese',
    };
    final extra = config.extraParams;
    return jsonEncode({
      'model': config.model.trim(),
      // 高级参数深合并进 input：千问的 instructions 类字段就在 input 下
      // （换 instruct 模型时传指令控制）。
      'input': extra == null ? input : mergeTtsExtraIntoInput(input, extra),
    });
  }

  /// SSE 行 → data 载荷：容忍官方两种常见帧形态（`data: {...}` 与裸
  /// JSON 行），跳过空行、注释与 id/event/retry 等帧字段。解析不出
  /// JSON 对象的行返回 null（帧字段不参与业务判定）。
  static Map<String, Object?>? _sseDataPayload(String rawLine) {
    var line = rawLine.trim();
    if (line.isEmpty || line.startsWith(':')) {
      return null;
    }
    if (line.startsWith('data:')) {
      line = line.substring('data:'.length).trim();
      if (line.isEmpty) {
        return null;
      }
    }
    final lower = line.toLowerCase();
    for (final field in ['id:', 'event:', 'retry:']) {
      if (lower.startsWith(field)) {
        return null;
      }
    }
    try {
      final parsed = jsonDecode(line);
      return parsed is Map<String, Object?> ? parsed : null;
    } on Object {
      return null;
    }
  }

  /// 从一个 SSE 块取音频段与收束信号：`output.audio.data` 是 base64
  /// 音频段；`finish_reason` 为 `stop`（或等价的「data 空 + url 在」）
  /// 即收束。
  static ({String? data, bool finished}) _extractStreamAudio(
    Map<String, Object?> payload,
  ) {
    final output = payload['output'];
    if (output is! Map<String, Object?>) {
      return (data: null, finished: false);
    }
    final audio = output['audio'];
    if (audio is! Map<String, Object?>) {
      return (data: null, finished: false);
    }
    final data = audio['data'];
    final finishReason = audio['finish_reason'];
    final url = audio['url'];
    final finished =
        finishReason == 'stop' ||
        (url is String && url.isNotEmpty && (data is! String || data.isEmpty));
    return (
      data: data is String ? data : null,
      finished: finished,
    );
  }

  static Uint8List _decodeBase64(String data) {
    try {
      return base64.decode(data);
    } on Object {
      throw const TtsGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音合成服务返回的内容无法解析。',
      );
    }
  }

  /// 把一个 SSE 音频段归一成裸 PCM（票二）：DashScope 文档未载明中间块
  /// 的音频格式（只称「Base64 编码的音频片段」，唯一线索是完整音频 URL
  /// 为 .wav），请求侧也没有格式参数。块带 RIFF/WAVE 头就按块遍历定位
  /// `fmt `/`data` 两个子块（**不按固定 44 字节**——带 LIST 等扩展块时
  /// data 不在固定偏移，固定剥会剥错），剥掉容器只留裸样本，并读回
  /// fmt 里的协商采样率；裸 PCM 块不以 RIFF 开头，原样通过。
  ///
  /// 返回的 pcm 可能为空（只有容器头没有 data 的片段），sampleRate 仍
  /// 会带回——调用方据此统一一路流的采样率标注。
  static ({Uint8List pcm, int? sampleRate}) _normalizeChunk(Uint8List bytes) {
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
      'tts qwen chunk carries wav header without data block '
      '(len=${bytes.length})',
    );
    return (pcm: Uint8List(0), sampleRate: sampleRate);
  }
}

/// 千问 SSE 音频段的协商采样率：DashScope 实时/流式通道的 PCM 基准
/// （24kHz 单声道 16-bit，官方 SDK 的 PCM_24000HZ_MONO_16BIT 同源）。
/// 播放端按语音块事件携带的采样率初始化，这里只作块上的标注值。
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
