import '../baseline/host_api_gateway.dart';

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

final class HistoryGatewayException
    implements Exception, UserFacingException {
  const HistoryGatewayException(this.message);

  @override
  final String message;

  @override
  String toString() => message;
}

abstract interface class HistoryGateway {
  Future<HistoryListing> fetchHistory();

  Future<void> deleteSession(String sessionId);
}

final class HttpHistoryGateway extends HostApiGateway
    implements HistoryGateway {
  HttpHistoryGateway({super.client, super.baseUri});

  @override
  Object errorFor(String message) => HistoryGatewayException(message);

  @override
  String get unavailableMessage => '历史记录暂时不可用，请稍后重试。';

  @override
  Future<HistoryListing> fetchHistory() async {
    await ensureBootstrap();
    final response = await httpClient.get(resolve('/api/history'));
    return HistoryListing.fromJson(decodeSuccess(response));
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    final response = await httpClient.delete(
      resolve('/api/history/sessions/$sessionId'),
      headers: await csrfHeaders(),
    );
    decodeSuccess(response);
  }
}
