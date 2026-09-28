import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import '../baseline/host_api_gateway.dart';
import 'chat_delivery_assembly.dart';

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
    this.serviceError,
    this.deliveryIndex,
    this.incomplete = false,
    this.at,
  });

  final String requestId;
  final LocalChatSpeaker speaker;
  final String text;
  final ReplySource? source;
  final FallbackReason? fallbackReason;
  final ServiceErrorCategory? serviceError;

  /// 该栖语交付段在 requestId 内的序号（轮内召回的 bubble 2 是第二段）。
  /// 纯运行时标注：不序列化，历史恢复的消息没有它（朗读只对新交付
  /// 的回复触发，与气泡的「正在朗读」指示共用。
  final int? deliveryIndex;

  /// 协议失败留下的半句（票一）：模型没有正常说完，内容如实。只在
  /// 直播流的 message 事件上携带，不落盘——刷新或恢复后这条标记不再
  /// 出现（半句文本本身照常保留）。
  final bool incomplete;

  /// 消息时刻（Host 落盘的客观时刻，wire 格式 UTC ISO8601）。恢复的
  /// 消息取 Host 权威值；直播流的新消息由视图模型用前端时钟预显、
  /// 刷新或恢复后被 Host 值覆盖（预显的取舍见视图模型的
  /// `_previewMoment`）。
  final DateTime? at;

  factory LocalChatMessage.fromJson(Map<String, Object?> json) {
    final source = json['source'] as String?;
    final fallbackReason = json['fallbackReason'] as String?;
    final rawAt = json['at'] as String?;
    return LocalChatMessage(
      requestId: json['requestId']! as String,
      speaker: LocalChatSpeaker.values.byName(json['speaker']! as String),
      text: json['text']! as String,
      source: source == null ? null : ReplySource.values.byName(source),
      fallbackReason: fallbackReason == null
          ? null
          : FallbackReason.fromWireName(fallbackReason),
      serviceError: json['serviceError'] == null
          ? null
          : ServiceErrorCategory.fromWireName(json['serviceError'] as String),
      at: rawAt == null ? null : DateTime.tryParse(rawAt),
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
    this.serviceError,
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
        serviceError: json['serviceError'] == null
            ? null
            : ServiceErrorCategory.fromWireName(json['serviceError'] as String),
      );

  final String sessionId;
  final String requestId;
  final List<String> messages;
  final ReplySource source;
  final FallbackReason? fallbackReason;
  final ServiceErrorCategory? serviceError;
}

final class LocalChatGatewayException
    implements Exception, UserFacingException {
  const LocalChatGatewayException(this.message, {this.code});

  @override
  final String message;
  final String? code;

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

  /// 停止信号（票二）：前端停播时通知 Host 作废该轮在途的分句合成，
  /// 不白烧 Provider 配额。与 [cancel] 分开——停止针对语音，不撤回
  /// 已交付的文字。
  Future<bool> stopVoice(String requestId);

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
  /// deliveryIndex) 从 session 取文字合成，返回完整音频字节（PCM 档
  /// 已包 WAV 头，其余档容器由服务定义；只在内存，播放端按字节嗅探）。
  Future<Uint8List> speak({
    required String requestId,
    required int deliveryIndex,
    String? sessionId,
  });
}

final class HttpLocalChatGateway extends HostApiGateway
    implements LocalChatGateway, StreamingLocalChatGateway, ChatSpeechGateway {
  HttpLocalChatGateway({
    super.client,
    super.baseUri,
    this.localeSource,
  });

  final String Function()? localeSource;

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
    final assembly = ChatDeliveryAssembly(requestId: requestId);
    try {
      await for (final event in deliver(
        requestId: requestId,
        text: text,
        sessionId: sessionId,
      )) {
        assembly.add(event);
        if (assembly.end != null) break;
      }
      assembly.close();
    } on Object catch (error) {
      assembly.fail();
      if (!assembly.hasCompleted) {
        if (error is FormatException) {
          throw const LocalChatGatewayException('回复未完成，可以重新发送。');
        }
        rethrow;
      }
    }
    if (!assembly.hasCompleted) {
      throw const LocalChatGatewayException('回复未完成，可以重新发送。');
    }
    final last = assembly.completed.last;
    return LocalChatExchange(
      sessionId: assembly.sessionId!,
      requestId: requestId,
      messages: assembly.completed
          .expand((delivery) => delivery.messages)
          .toList(),
      source: last.source,
      fallbackReason: last.fallbackReason,
      serviceError: last.serviceError,
    );
  }

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
    String? locale,
  }) async* {
    final request = http.Request('POST', resolve('/api/chat'));
    request.headers.addAll({
      ...await csrfHeaders(),
      'content-type': 'application/json',
      'accept': 'application/x-ndjson',
    });
    final effectiveLocale = locale ?? localeSource?.call();
    request.body = jsonEncode({
      'requestId': requestId,
      'text': text,
      'sessionId': ?sessionId,
      'locale': ?effectiveLocale,
    });
    final response = await httpClient.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw LocalChatGatewayException(
        _decodeErrorMessage(body),
        code: _decodeErrorCode(body),
      );
    }
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.trim().isEmpty) {
        continue;
      }
      final LocalChatDeliveryEvent event;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, Object?>) {
          throw const FormatException('Invalid chat event');
        }
        event = LocalChatDeliveryEvent.fromJson(decoded);
      } on FormatException {
        throw const LocalChatGatewayException('本机程序返回了无法读取的内容。');
      }
      if (event.kind == LocalChatEventKind.error) {
        throw LocalChatGatewayException(
          event.text!,
          code: event.fallbackReason?.wireName,
        );
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
  Future<bool> stopVoice(String requestId) async {
    final response = await httpClient.post(
      resolve('/api/chat/voice-stop'),
      headers: {...await csrfHeaders(), 'content-type': 'application/json'},
      body: jsonEncode({'requestId': requestId}),
    );
    final json = decodeSuccess(response);
    return json['stopped'] == true;
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
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LocalChatGatewayException(
        _decodeErrorMessage(response.body),
        code: _decodeErrorCode(response.body),
      );
    }
    final json = jsonDecode(response.body) as Map<String, Object?>;
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
        'turnIndex': deliveryIndex,
        'sessionId': ?sessionId,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LocalChatGatewayException(
        _decodeErrorMessage(response.body),
        code: _decodeErrorCode(response.body),
      );
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

String? _decodeErrorCode(String body) {
  try {
    final json = jsonDecode(body) as Map<String, Object?>;
    return json['code'] as String?;
  } on Object {
    return null;
  }
}
