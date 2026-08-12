import 'dart:convert';

import 'package:http/http.dart' as http;

final class HistorySessionSummary {
  const HistorySessionSummary({
    required this.sessionId,
    required this.segment,
    required this.startedAt,
    required this.updatedAt,
    required this.turnCount,
    required this.preview,
  });

  factory HistorySessionSummary.fromJson(Map<String, Object?> json) =>
      HistorySessionSummary(
        sessionId: json['sessionId']! as String,
        segment: json['segment']! as int,
        startedAt: DateTime.parse(json['startedAt']! as String),
        updatedAt: DateTime.parse(json['updatedAt']! as String),
        turnCount: json['turnCount']! as int,
        preview: json['preview']! as String,
      );

  final String sessionId;
  final int segment;
  final DateTime startedAt;
  final DateTime updatedAt;
  final int turnCount;
  final String preview;
}

final class HistoryDay {
  const HistoryDay({required this.date, required this.sessions});

  factory HistoryDay.fromJson(Map<String, Object?> json) => HistoryDay(
    date: json['date']! as String,
    sessions: (json['sessions']! as List<Object?>)
        .map(
          (session) =>
              HistorySessionSummary.fromJson(session! as Map<String, Object?>),
        )
        .toList(),
  );

  final String date;
  final List<HistorySessionSummary> sessions;
}

final class UnavailableHistoryEntry {
  const UnavailableHistoryEntry({required this.name, required this.message});

  factory UnavailableHistoryEntry.fromJson(Map<String, Object?> json) =>
      UnavailableHistoryEntry(
        name: json['name']! as String,
        message: json['message']! as String,
      );

  final String name;
  final String message;
}

final class HistoryListing {
  const HistoryListing({
    required this.latestSessionId,
    required this.days,
    required this.unavailable,
  });

  factory HistoryListing.fromJson(Map<String, Object?> json) => HistoryListing(
    latestSessionId: json['latestSessionId'] as String?,
    days: (json['days']! as List<Object?>)
        .map((day) => HistoryDay.fromJson(day! as Map<String, Object?>))
        .toList(),
    unavailable: (json['unavailable']! as List<Object?>)
        .map(
          (entry) =>
              UnavailableHistoryEntry.fromJson(entry! as Map<String, Object?>),
        )
        .toList(),
  );

  final String? latestSessionId;
  final List<HistoryDay> days;
  final List<UnavailableHistoryEntry> unavailable;
}

final class HistoryGatewayException implements Exception {
  const HistoryGatewayException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class HistoryGateway {
  Future<HistoryListing> fetchHistory();

  Future<void> deleteSession(String sessionId);
}

final class HttpHistoryGateway implements HistoryGateway {
  HttpHistoryGateway({http.Client? client, Uri? baseUri})
    : _client = client ?? http.Client(),
      _baseUri = baseUri ?? Uri.base;

  final http.Client _client;
  final Uri _baseUri;
  String? _csrfToken;

  @override
  Future<HistoryListing> fetchHistory() async {
    await _ensureBootstrap();
    final response = await _client.get(_baseUri.resolve('/api/history'));
    return HistoryListing.fromJson(_decodeSuccess(response));
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    await _ensureBootstrap();
    final response = await _client.delete(
      _baseUri.resolve('/api/history/sessions/$sessionId'),
      headers: {'x-qiyu-csrf': _csrfToken!},
    );
    _decodeSuccess(response);
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
      throw const HistoryGatewayException('本机程序返回了无法读取的内容。');
    }
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw HistoryGatewayException(
      json?['message'] as String? ?? '历史记录暂时不可用，请稍后重试。',
    );
  }
  return json!;
}
