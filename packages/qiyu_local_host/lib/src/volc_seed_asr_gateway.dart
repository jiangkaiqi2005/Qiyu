import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'provider_config.dart';
import 'provider_web_socket.dart';
import 'stt_gateway.dart';

/// 豆包流式语音识别（volc_seed_asr）网关：火山方舟 Agent Plan 的 sauc
/// 大模型 WebSocket 二进制协议（官方「接入语音模型」文档与示例代码，
/// docs.volcengine.com/docs/82379/2516286）。请求帧全部带 4 字节大端
/// 序列号（full request 从 1 起，音频分片递增，末分片取负值）；响应帧
/// 按 header_size 与 flags 动态偏移解析；错误只映射允许列表文案。
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
    final key = requireSttApiKey(apiKey);
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
    } on WebSocketException catch (error) {
      final status = error.httpStatusCode;
      if (status != null && status != HttpStatus.switchingProtocols) {
        throw _fromModelFailure(
          providerStatusFailure(status, '', serviceLabel: '语音服务'),
        );
      }
      throw const SttGatewayException(
        kind: ModelFailureKind.network,
        message: '无法连接语音服务。',
      );
    } on Object catch (error) {
      // 只打异常类型不打消息：消息可能嵌着用户输入（Key/地址/模型名）。
      stderrDiagnostics('stt unclassified exception: ${error.runtimeType}');
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
    final requestId = _newRequestId();
    final connection = await connector.connect(
      uri: uri,
      headers: {
        'X-Api-Key': key,
        // 模型名称字段填 Resource-Id（如 volc.seedasr.sauc.duration）。
        'X-Api-Resource-Id': config.model.trim(),
        'X-Api-Request-Id': requestId,
        // 官方示例要求：连接与请求各自唯一 UUID，这里同值即可。
        'X-Api-Connect-Id': requestId,
        // 官方鉴权规范的固定值：整段音频一次性上送（非实时流），序号恒为 -1。
        'X-Api-Sequence': '-1',
      },
    );
    try {
      return await _runSession(connection, audio);
    } finally {
      await connection.close();
    }
  }

  /// 一次完整会话：发 full request 并等服务端确认，随后连发音频分片
  /// （最后一片就是负序号末包），持续消费服务端响应直到最终包。
  Future<String> _runSession(
    ProviderWebSocketConnection connection,
    List<int> audio,
  ) async {
    final responses = StreamIterator<List<int>>(connection.messages);
    try {
      final text = StringBuffer();

      connection.send(_fullClientRequestFrame(sequence: 1));
      var sequence = 2;
      // 官方示例在发送音频前等待 full request 的服务端确认帧。
      if (!await _advance(responses, text)) {
        return text.toString();
      }

      final chunks = _audioChunks(audio);
      for (var index = 0; index < chunks.length; index += 1) {
        final isLast = index == chunks.length - 1;
        // 末分片取负序号；官方示例没有空补包，只有空音频才单发末包。
        connection.send(
          _audioOnlyFrame(
            chunks[index],
            sequence: isLast ? -sequence : sequence,
            last: isLast,
          ),
        );
        sequence += 1;
      }
      if (chunks.isEmpty) {
        connection.send(
          _audioOnlyFrame(const [], sequence: -sequence, last: true),
        );
      }

      while (await _advance(responses, text)) {}
      return text.toString();
    } finally {
      // 必须显式取消订阅：非广播流的 close() 会一直等一个未取消的
      // listener，不取消的话上层 await close() 永远挂起。
      await responses.cancel();
    }
  }

  /// 消费一条服务端消息。返回是否应继续等待（最终包、错误与连接结束
  /// 都返回 false，错误已在内部抛出）。
  Future<bool> _advance(
    StreamIterator<List<int>> responses,
    StringBuffer text,
  ) async {
    if (!await responses.moveNext()) {
      throw const SttGatewayException(
        kind: ModelFailureKind.network,
        message: '语音服务连接中断。',
      );
    }
    return _applyServerFrame(responses.current, text);
  }
}

/// 协议常量：通用帧头 byte0（version 1 + header size 1）与各消息类型。
/// 请求帧全部带正/负序列号（flags 位 0），与官方 Python 示例一致。
const _volcProtocolVersionHeader = 0x11;
const _volcFullRequestFlags = 0x11; // type 0001 + POS_SEQUENCE 0001
const _volcJsonGzipBytes = 0x11; // serialization JSON(0001) + compression gzip(0001)
const _volcAudioGzipBytes = 0x01; // serialization none(0000) + compression gzip(0001)
const _volcAudioFlags = 0x21; // type 0010 + POS_SEQUENCE 0001
const _volcAudioLastFlags = 0x23; // type 0010 + NEG_WITH_SEQUENCE 0011
const _volcChunkSize = 6400;

/// full client request 沿用官方音频参数，并显式请求 full 全量结果。
Uint8List _fullClientRequestFrame({required int sequence}) {
  final payload = utf8.encode(
    jsonEncode({
      'user': {'uid': 'qiyu'},
      'audio': {
        'format': 'wav',
        'codec': 'raw',
        'rate': 16000,
        'bits': 16,
        'channel': 1,
      },
      'request': {
        'model_name': 'bigmodel',
        'result_type': 'full',
        'enable_itn': true,
        'enable_punc': true,
        'enable_ddc': true,
        'show_utterances': true,
        'enable_nonstream': false,
      },
    }),
  );
  return _sequencedFrame(
    _volcFullRequestFlags,
    _volcJsonGzipBytes,
    sequence,
    gzip.encode(payload),
  );
}

Uint8List _audioOnlyFrame(
  List<int> chunk, {
  required int sequence,
  required bool last,
}) => _sequencedFrame(
  last ? _volcAudioLastFlags : _volcAudioFlags,
  _volcAudioGzipBytes,
  sequence,
  gzip.encode(chunk),
);

/// 带序列号的通用帧：4 字节头 + 大端 i32 序列号 + 大端 u32 payload
/// 长度 + payload。
Uint8List _sequencedFrame(
  int typeFlags,
  int serializationCompression,
  int sequence,
  List<int> payload,
) {
  return (BytesBuilder(copy: false)
        ..add([
          _volcProtocolVersionHeader,
          typeFlags,
          serializationCompression,
          0x00,
        ])
        ..add(_int32Bytes(sequence))
        ..add(_uint32Bytes(payload.length))
        ..add(payload))
      .takeBytes();
}

/// 整段音频（含 WAV 文件头）按约 200ms（6400 字节）切片；空音频返回
/// 空列表，由调用方单发一个负序号末包。
List<List<int>> _audioChunks(List<int> audio) => [
  for (var start = 0; start < audio.length; start += _volcChunkSize)
    audio.sublist(start, min(start + _volcChunkSize, audio.length)),
];

/// 解析一帧服务端消息，按官方 ResponseParser 的动态偏移规则：
/// header_size = byte0 低 4 位 × 4 字节；flags 位 0 跳 4 字节序列号，
/// 位 2 跳 4 字节 event；server response 再读 u32 长度，error 读
/// i32 错误码 + u32 消息长度。解析失败一律按解析失败处理，不透出
/// 原始字节。
bool _applyServerFrame(List<int> frame, StringBuffer text) {
  SttGatewayException parsingFailure() => const SttGatewayException(
    kind: ModelFailureKind.contentParsing,
    message: '语音服务返回的内容无法解析。',
  );
  if (frame.length < 4) {
    throw parsingFailure();
  }
  final headerSize = (frame[0] & 0x0F) * 4;
  if (frame.length < headerSize + 4) {
    throw parsingFailure();
  }
  final flags = frame[1] & 0x0F;
  var offset = headerSize;
  void skip(int count) {
    if (offset + count > frame.length) {
      throw parsingFailure();
    }
    offset += count;
  }

  if (flags & 0x01 != 0) {
    skip(4); // 正/负序列号
  }
  if (flags & 0x04 != 0) {
    skip(4); // event 字段（TTS 协议族事件，出现时跳过即可）
  }
  final isLast = flags & 0x02 != 0;

  switch (frame[1] >> 4) {
    case 0x9: // server response：u32 payload 长度 + JSON（是否 gzip 由
      // compression 位决定——真机确认帧实测为无压缩明文 JSON）。
      skip(4);
      final payloadSize = _readUint32(frame, offset - 4);
      if (offset + payloadSize > frame.length) {
        throw parsingFailure();
      }
      final payload = _decompress(
        frame.sublist(offset, offset + payloadSize),
        frame[2] & 0x0F,
      );
      Object decoded;
      try {
        decoded = jsonDecode(utf8.decode(payload));
      } on Object {
        throw parsingFailure();
      }
      if (decoded is! Map<String, Object?>) {
        throw parsingFailure();
      }
      // 明确请求 full：每帧是当前全量快照，后续帧可修订之前的文字。
      // 官方字段表是 list、示例是对象；列表只在同一帧内拼合。
      final snapshot = StringBuffer();
      var hasText = false;
      final result = decoded['result'];
      final items = result is List<Object?> ? result : [result];
      for (final item in items) {
        if (item is Map<String, Object?>) {
          final chunk = item['text'];
          if (chunk is String) {
            hasText = true;
            snapshot.write(chunk);
          }
        }
      }
      // 确认/进度帧的空结果不抹去已收到的文本；明确的最终空文本仍
      // 交给上层按「没有识别到语音」处理，不能回退到过时的中间结果。
      if (snapshot.isNotEmpty || (isLast && hasText)) {
        text
          ..clear()
          ..write(snapshot);
      }
      return !isLast;
    case 0xF: // error：i32 错误码 + u32 消息长度 + UTF-8 消息。
      if (offset + 8 > frame.length) {
        throw parsingFailure();
      }
      final code = _readInt32(frame, offset);
      _volcErrorOutcome(code);
      return false;
    default:
      throw parsingFailure();
  }
}

/// error 帧错误码到允许列表文案的映射：对外只出中文人话，服务端原始
/// 消息（可能含敏感内容）绝不透出。
void _volcErrorOutcome(int code) {
  switch (code) {
    // 空音频：与 OpenAI 空文本同一分支（调用方收到空串，正式转写报
    // 「没有识别到语音」，连接测试算成功）。
    case 45000002:
      return;
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

/// 按 compression 位解出 payload：0x01 gzip 解压，0x00 原样返回。
List<int> _decompress(List<int> payload, int compression) {
  if (compression == 0x01) {
    return gzip.decode(payload);
  }
  return payload;
}

Uint8List _uint32Bytes(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);

Uint8List _int32Bytes(int value) => _uint32Bytes(value & 0xFFFFFFFF);

int _readUint32(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _readInt32(List<int> bytes, int offset) {
  final raw = _readUint32(bytes, offset);
  return raw >= 0x80000000 ? raw - 0x100000000 : raw;
}

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
    SttGatewayException(
      kind: failure.kind, message: failure.message,
      serviceError: failure.serviceError,
    );
