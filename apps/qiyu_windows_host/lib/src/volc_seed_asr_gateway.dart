import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'model_gateway.dart';
import 'provider_config.dart';
import 'provider_web_socket.dart';
import 'stt_gateway.dart';

/// 豆包流式语音识别（volc_seed_asr）网关：火山引擎 sauc 大模型 WebSocket
/// 二进制协议（docs.volcengine.com/docs/6561/1354869，帧错即断连，字节
/// 严格照协议）。音频按约 6400 字节 gzip 分块连发，收到最终包（flags
/// 0011）后拼接全部识别文本返回。
final class VolcSeedAsrGateway {
  VolcSeedAsrGateway(this.connector, {this.timeout = sttRequestTimeout});

  final ProviderWebSocketConnector connector;

  /// 总超时预算：含建连、全部音频发送与等待最终包。
  final Duration timeout;

  Future<String> transcribe({
    required SttConfig config,
    required String? apiKey,
    required List<int> audio,
    required String mimeType,
  }) async {
    config.validate();
    final key = apiKey?.trim();
    if (key == null || key.isEmpty) {
      throw const SttGatewayException(
        kind: ModelFailureKind.authentication,
        message: '还没有保存语音服务的 API Key。',
      );
    }
    try {
      return await _exchange(config: config, key: key, audio: audio).timeout(
        timeout,
      );
    } on SttGatewayException {
      rethrow;
    } on TimeoutException {
      throw const SttGatewayException(
        kind: ModelFailureKind.timeout,
        message: '连接语音服务超时。',
      );
    } on HandshakeException {
      throw const SttGatewayException(
        kind: ModelFailureKind.tls,
        message: '语音服务的 TLS 安全连接失败。',
      );
    } on SocketException catch (error) {
      throw _fromModelFailure(
        providerSocketFailure(error, serviceLabel: '语音服务'),
      );
    } on WebSocketException {
      throw const SttGatewayException(
        kind: ModelFailureKind.network,
        message: '无法连接语音服务。',
      );
    } on Object {
      throw const SttGatewayException(
        kind: ModelFailureKind.internal,
        message: '本机程序内部出错。',
      );
    }
  }

  Future<String> _exchange({
    required SttConfig config,
    required String key,
    required List<int> audio,
  }) async {
    final uri = Uri.parse(config.baseUrl.trim());
    // STT 是新增出网路径：出网前统一过 SSRF 校验（聊天 Provider 不走）。
    ensureSttOutboundAllowed(uri);
    final connection = await connector.connect(
      uri: uri,
      headers: {
        'X-Api-Key': key,
        // 模型名称字段填 Resource-Id（如 volc.seedasr.sauc.duration）。
        'X-Api-Resource-Id': config.model.trim(),
        'X-Api-Request-Id': _newRequestId(),
      },
    );
    // 先订阅再发送：响应帧绝不因发送时序丢失。
    final result = _awaitFinalResponse(connection);
    try {
      connection.send(_fullClientRequestFrame());
      for (final chunk in _audioChunks(audio)) {
        connection.send(_audioOnlyFrame(chunk, last: false));
      }
      // 末包标记必须发送：payload 是 gzip 后的空音频块。
      connection.send(_audioOnlyFrame(const [], last: true));
      return await result;
    } finally {
      await connection.close();
    }
  }

  /// 逐帧消费服务端响应，最终包（或空音频 error 码）时返回拼接文本；
  /// 连接在最终包前结束按网络中断处理。
  Future<String> _awaitFinalResponse(ProviderWebSocketConnection connection) {
    final text = StringBuffer();
    return () async {
      await for (final frame in connection.messages) {
        if (_applyServerFrame(frame, text) != _VolcFrameOutcome.more) {
          return text.toString();
        }
      }
      throw const SttGatewayException(
        kind: ModelFailureKind.network,
        message: '语音服务连接中断。',
      );
    }();
  }
}

/// 服务端单帧的处理结果。
enum _VolcFrameOutcome { more, finalPacket, emptyAudio }

/// 协议常量：通用帧头 byte0（version 1 + header size 4）与各消息类型。
const _volcProtocolVersionHeader = 0x11;
const _volcFullRequestFlags = 0x10; // type 0001 flags 0000（无 sequence）
const _volcJsonGzipBytes = 0x11; // serialization JSON(0001) + compression gzip(0001)
const _volcAudioGzipBytes = 0x01; // serialization none(0000) + compression gzip(0001)
const _volcAudioFlags = 0x20; // type 0010 flags 0000
const _volcAudioLastFlags = 0x22; // type 0010 flags 0010（末包）
const _volcChunkSize = 6400;

/// 官方建议的音频分块大小（字节）。
Uint8List _fullClientRequestFrame() {
  final payload = utf8.encode(
    jsonEncode({
      'user': {'uid': 'qiyu'},
      'audio': {
        'format': 'wav',
        'rate': 16000,
        'bits': 16,
        'channel': 1,
        // 流式输入模式（bigmodel_nostream）支持且建议固定中文。
        'language': 'zh-CN',
      },
      'request': {
        'model_name': 'bigmodel',
        'enable_punc': true,
        'result_type': 'full',
      },
    }),
  );
  return _frame(_volcFullRequestFlags, _volcJsonGzipBytes, gzip.encode(payload));
}

Uint8List _audioOnlyFrame(List<int> chunk, {required bool last}) =>
    _frame(
      last ? _volcAudioLastFlags : _volcAudioFlags,
      _volcAudioGzipBytes,
      gzip.encode(chunk),
    );

/// 通用帧：4 字节头 + 大端 u32 payload 长度 + payload。
Uint8List _frame(int typeFlags, int serializationCompression, List<int> payload) {
  return (BytesBuilder(copy: false)
        ..add([_volcProtocolVersionHeader, typeFlags, serializationCompression, 0x00])
        ..add(_uint32Bytes(payload.length))
        ..add(payload))
      .takeBytes();
}

/// 整段音频（含 WAV 文件头）按协议块大小切分；空音频返回空列表，
/// 由调用方至少补发末包标记。
List<List<int>> _audioChunks(List<int> audio) => [
  for (var start = 0; start < audio.length; start += _volcChunkSize)
    audio.sublist(start, min(start + _volcChunkSize, audio.length)),
];

/// 解析一帧服务端消息：server response（type 1001）追加识别文本并区分
/// 是否最终包；error 帧（type 1111）按错误码映射。不符合帧形状、解压
/// 或 JSON 失败一律按解析失败处理。
_VolcFrameOutcome _applyServerFrame(List<int> frame, StringBuffer text) {
  SttGatewayException parsingFailure() => const SttGatewayException(
    kind: ModelFailureKind.contentParsing,
    message: '语音服务返回的内容无法解析。',
  );
  if (frame.length < 8) {
    throw parsingFailure();
  }
  switch (frame[1] >> 4) {
    case 0x9: // server response：头 + u32 sequence + u32 长度 + gzip(JSON)。
      if (frame.length < 12) {
        throw parsingFailure();
      }
      final payloadSize = _readUint32(frame, 8);
      const payloadStart = 12;
      if (payloadStart + payloadSize > frame.length) {
        throw parsingFailure();
      }
      final payload = frame.sublist(payloadStart, payloadStart + payloadSize);
      Object decoded;
      try {
        decoded = jsonDecode(utf8.decode(gzip.decode(payload)));
      } on Object {
        throw parsingFailure();
      }
      if (decoded is! Map<String, Object?>) {
        throw parsingFailure();
      }
      // 官方示例里 result 是对象（text 字段）；字段表标注 list，两种都兼容。
      final result = decoded['result'];
      if (result is Map<String, Object?>) {
        final chunk = result['text'];
        if (chunk is String) {
          text.write(chunk);
        }
      } else if (result is List<Object?>) {
        for (final item in result) {
          if (item is Map<String, Object?>) {
            final chunk = item['text'];
            if (chunk is String) {
              text.write(chunk);
            }
          }
        }
      }
      // flags 位 1（0x02）标记最终包。
      return (frame[1] & 0x02) != 0
          ? _VolcFrameOutcome.finalPacket
          : _VolcFrameOutcome.more;
    case 0xF: // error：头 + u32 code + u32 消息长度 + UTF-8 消息。
      if (frame.length < 12) {
        throw parsingFailure();
      }
      final code = _readUint32(frame, 4);
      return _volcErrorOutcome(code);
    default:
      throw parsingFailure();
  }
}

/// error 帧错误码到允许列表文案的映射：对外只出中文人话，服务端原始
/// 消息（可能含敏感内容）绝不透出。
_VolcFrameOutcome _volcErrorOutcome(int code) {
  switch (code) {
    // 空音频：与 OpenAI 空文本同一分支（返回已拼接的空文本，正式转写
    // 由服务层报「没有识别到语音」，连接测试算成功）。
    case 45000002:
      return _VolcFrameOutcome.emptyAudio;
    // 请求参数无效 / 音频格式不正确：豆包读不了这段音频。
    case 45000001:
    case 45000151:
      throw const SttGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '语音服务无法读取这段音频。',
      );
    case 55000031:
      throw const SttGatewayException(
        kind: ModelFailureKind.rateLimited,
        message: '语音服务繁忙，请稍后再试。',
      );
    default:
      throw const SttGatewayException(
        kind: ModelFailureKind.provider,
        message: '语音服务拒绝了这次请求。',
      );
  }
}

Uint8List _uint32Bytes(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);

int _readUint32(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

final _requestIdRandom = Random.secure();

/// X-Api-Request-Id 用随机 UUID v4。
String _newRequestId() {
  final bytes = List<int>.generate(16, (_) => _requestIdRandom.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3F) | 0x80; // RFC 4122 variant
  final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

SttGatewayException _fromModelFailure(ModelGatewayException failure) =>
    SttGatewayException(kind: failure.kind, message: failure.message);
