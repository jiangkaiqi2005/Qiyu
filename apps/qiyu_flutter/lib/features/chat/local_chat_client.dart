import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

enum LocalChatSpeaker { user, qiyu }

final class LocalChatMessage {
  const LocalChatMessage({
    required this.requestId,
    required this.speaker,
    required this.text,
    this.source,
    this.fallbackReason,
  });

  final String requestId;
  final LocalChatSpeaker speaker;
  final String text;
  final ReplySource? source;
  final FallbackReason? fallbackReason;

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

final class LocalChatGatewayException implements Exception {
  const LocalChatGatewayException(this.message);

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

final class HttpLocalChatGateway implements LocalChatGateway {
  HttpLocalChatGateway({http.Client? client, Uri? baseUri})
    : _client = client ?? http.Client(),
      _baseUri = baseUri ?? Uri.base;

  final http.Client _client;
  final Uri _baseUri;
  String? _csrfToken;

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async {
    await _ensureBootstrap();
    final uri = _baseUri
        .resolve('/api/chat/session')
        .replace(
          queryParameters: sessionId == null ? null : {'sessionId': sessionId},
        );
    final response = await _client.get(uri);
    return LocalChatSnapshot.fromJson(_decodeSuccess(response));
  }

  @override
  Future<LocalChatExchange> send({
    required String requestId,
    required String text,
    String? sessionId,
  }) async {
    await _ensureBootstrap();
    final response = await _client.post(
      _baseUri.resolve('/api/chat'),
      headers: {'content-type': 'application/json', 'x-qiyu-csrf': _csrfToken!},
      body: jsonEncode({
        'requestId': requestId,
        'text': text,
        'sessionId': ?sessionId,
      }),
    );
    return LocalChatExchange.fromJson(_decodeSuccess(response));
  }

  Future<void> _ensureBootstrap() async {
    if (_csrfToken != null) {
      return;
    }
    final response = await _client.get(_baseUri.resolve('/api/bootstrap'));
    final json = _decodeSuccess(response);
    _csrfToken = json['csrfToken']! as String;
  }
}

Map<String, Object?> _decodeSuccess(http.Response response) {
  Map<String, Object?>? json;
  try {
    json = jsonDecode(response.body) as Map<String, Object?>;
  } on Object {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      throw const LocalChatGatewayException('本机程序返回了无法读取的内容。');
    }
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw LocalChatGatewayException(
      json?['message'] as String? ?? '本机聊天暂时不可用，请稍后重试。',
    );
  }
  return json!;
}
