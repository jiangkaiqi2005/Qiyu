import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import '../baseline/host_api_gateway.dart';

enum LocalChatSpeaker { user, qiyu }

typedef LocalChatEventKind = ChatDeliveryEventKind;

typedef LocalChatDeliveryEvent = ChatDeliveryEvent;

final class LocalChatMessage {
  const LocalChatMessage({
    required this.requestId,
    required this.speaker,
    required this.text,
    this.source,
    this.fallbackReason,
    this.deliveryIndex,
  });

  final String requestId;
  final LocalChatSpeaker speaker;
  final String text;
  final ReplySource? source;
  final FallbackReason? fallbackReason;

  /// 该栖语交付段在 requestId 内的序号（轮内召回的 bubble 2 是第二段）。
  /// 纯运行时标注：不序列化，历史恢复的消息没有它（朗读只对新交付
  /// 的回复触发，与气泡的「正在朗读」指示共用。
  final int? deliveryIndex;

  factory LocalChatMessage.fromJson(Map<String, Object?> json) {
    final source = json['source'] as String?;
    final fallbackReason = json['fallbackReason'] as String?;
    return LocalChatMessage(
      requestId: json['requestId']! as String,
      speaker: LocalChatSpeaker.values.byName(json['speaker']! as String),
      text: json['text']! as String,
      source: source == null ? null : ReplySource.values.byName(source),
      fallbackReason: fallbackReason == null
          ? null
          : FallbackReason.fromWireName(fallbackReason),
    );
  }
}

final class LocalChatSnapshot {
  const LocalChatSnapshot({required this.sessionId, required this.messages});

  factory LocalChatSnapshot.fromJson(Map<String, Object?> json) {
    final turns = json['turns']! as List<Object?>;
    return LocalChatSnapshot(
      sessionId: json['sessionId']! as String,
      messages: turns
          .map(
            (turn) => LocalChatMessage.fromJson(turn! as Map<String, Object?>),
          )
          .toList(),
    );
  }

  final String sessionId;
  final List<LocalChatMessage> messages;
}

final class LocalChatExchange {
  const LocalChatExchange({
    required this.sessionId,
    required this.requestId,
    required this.messages,
    required this.source,
    this.fallbackReason,
  });

  factory LocalChatExchange.fromJson(Map<String, Object?> json) =>
      LocalChatExchange(
        sessionId: json['sessionId']! as String,
        requestId: json['requestId']! as String,
        messages: (json['messages']! as List<Object?>).cast<String>(),
        source: ReplySource.values.byName(json['source']! as String),
        fallbackReason: json['fallbackReason'] == null
            ? null
            : FallbackReason.fromWireName(json['fallbackReason']! as String),
      );

  final String sessionId;
  final String requestId;
  final List<String> messages;
  final ReplySource source;
  final FallbackReason? fallbackReason;
}

final class LocalChatGatewayException
    implements Exception, UserFacingException {
  const LocalChatGatewayException(this.message);

  @override
  final String message;

  @override
  String toString() => message;
}

abstract interface class LocalChatGateway {
  Future<LocalChatSnapshot> restore({String? sessionId});

  Future<LocalChatExchange> send({
    required String requestId,
    required String text,
    String? sessionId,
  });
}

abstract interface class StreamingLocalChatGateway {
  Future<LocalChatSnapshot> restore({String? sessionId});

  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  });

  Future<bool> cancel(String requestId);

  /// 语音转写：把浏览器录音字节交给本机程序云端转写，返回识别文本。
  /// 失败（含「没有识别到语音」）抛 [LocalChatGatewayException]，
  /// message 已是面向用户的人话。
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  });
}

/// 语音朗读的独立小接口（不往 StreamingLocalChatGateway 塞方法）：
/// 朗读可单独注入与测试，聊天 fake 不被迫实现。
abstract interface class ChatSpeechGateway {
  /// 朗读一条已完整交付并落盘的栖语交付段：Host 按 (requestId,
  /// deliveryIndex) 从 session 取文字合成，返回 mp3 字节（只在内存）。
  Future<Uint8List> speak({
    required String requestId,
    required int deliveryIndex,
    String? sessionId,
  });
}

final class HttpLocalChatGateway extends HostApiGateway
    implements LocalChatGateway, StreamingLocalChatGateway, ChatSpeechGateway {
  HttpLocalChatGateway({super.client, super.baseUri});

  @override
  Object errorFor(String message) => LocalChatGatewayException(message);

  @override
  String get unavailableMessage => '本机聊天暂时不可用，请稍后重试。';

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async {
    await ensureBootstrap();
    final uri = resolve('/api/chat/session').replace(
      queryParameters: sessionId == null ? null : {'sessionId': sessionId},
    );
    final response = await httpClient.get(uri);
    return LocalChatSnapshot.fromJson(decodeSuccess(response));
  }

  @override
  Future<LocalChatExchange> send({
    required String requestId,
    required String text,
    String? sessionId,
  }) async {
    String? acceptedSessionId;
    List<String>? messages;
    ReplySource? source;
    FallbackReason? fallbackReason;
    await for (final event in deliver(
      requestId: requestId,
      text: text,
      sessionId: sessionId,
    )) {
      acceptedSessionId = event.sessionId ?? acceptedSessionId;
      messages = event.messages ?? messages;
      source = event.source ?? source;
      fallbackReason = event.fallbackReason ?? fallbackReason;
    }
    if (acceptedSessionId == null || messages == null || source == null) {
      throw const LocalChatGatewayException('回复未完成，可以重新发送。');
    }
    return LocalChatExchange(
      sessionId: acceptedSessionId,
      requestId: requestId,
      messages: messages,
      source: source,
      fallbackReason: fallbackReason,
    );
  }

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {
    final request = http.Request('POST', resolve('/api/chat'));
    request.headers.addAll({
      ...await csrfHeaders(),
      'content-type': 'application/json',
      'accept': 'application/x-ndjson',
    });
    request.body = jsonEncode({
      'requestId': requestId,
      'text': text,
      'sessionId': ?sessionId,
    });
    final response = await httpClient.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw LocalChatGatewayException(_decodeErrorMessage(body));
    }
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.trim().isEmpty) {
        continue;
      }
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, Object?>) {
        throw const LocalChatGatewayException('本机程序返回了无法读取的内容。');
      }
      final event = LocalChatDeliveryEvent.fromJson(decoded);
      if (event.kind == LocalChatEventKind.error) {
        throw LocalChatGatewayException(event.text ?? '本机聊天暂时不可用，请稍后重试。');
      }
      yield event;
    }
  }

  @override
  Future<bool> cancel(String requestId) async {
    final response = await httpClient.post(
      resolve('/api/chat/cancel'),
      headers: {...await csrfHeaders(), 'content-type': 'application/json'},
      body: jsonEncode({'requestId': requestId}),
    );
    final json = decodeSuccess(response);
    return json['cancelled'] == true;
  }

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async {
    final response = await httpClient.post(
      resolve('/api/chat/transcribe'),
      headers: {...await csrfHeaders(), 'content-type': mimeType},
      body: audio,
    );
    final json = decodeSuccess(response);
    return json['text'] as String? ?? '';
  }

  @override
  Future<Uint8List> speak({
    required String requestId,
    required int deliveryIndex,
    String? sessionId,
  }) async {
    final response = await httpClient.post(
      resolve('/api/chat/speak'),
      headers: await csrfHeaders(),
      body: jsonEncode({
        'requestId': requestId,
        'deliveryIndex': deliveryIndex,
        'sessionId': ?sessionId,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LocalChatGatewayException(_decodeErrorMessage(response.body));
    }
    return response.bodyBytes;
  }
}

String _decodeErrorMessage(String body) {
  try {
    final json = jsonDecode(body) as Map<String, Object?>;
    return json['message'] as String? ?? '本机聊天暂时不可用，请稍后重试。';
  } on Object {
    return '本机聊天暂时不可用，请稍后重试。';
  }
}
