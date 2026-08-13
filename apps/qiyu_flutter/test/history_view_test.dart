import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/history/history_client.dart';
import 'package:qiyu_flutter/features/history/history_view_model.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_client.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

void main() {
  testWidgets(
    'history lists sessions by day with previews, counts, and unavailable hints',
    (tester) async {
      final historyGateway = _FakeHistoryGateway(_testListing());
      final historyViewModel = HistoryViewModel(
        historyGateway,
        onSessionDeleted: (_) {},
        autoStart: false,
      );
      await historyViewModel.refresh();
      await tester.pumpWidget(
        QiyuApp(
          viewModel: _chatViewModel(),
          historyViewModel: historyViewModel,
          onboardingViewModel: await _onboardingViewModel(),
        ),
      );
      await _enterChatFromHome(tester);

      await tester.tap(find.byKey(const Key('open-history')));
      await tester.pumpAndSettle();

      expect(find.text('历史'), findsOneWidget);
      expect(find.text('今天'), findsOneWidget);
      expect(find.text('昨天'), findsOneWidget);
      expect(find.text('今天想说的事'), findsOneWidget);
      expect(find.text('昨天的事'), findsOneWidget);
      expect(find.textContaining('4 条消息'), findsOneWidget);
      expect(find.textContaining('2 条消息'), findsOneWidget);
      expect(find.byKey(const Key('resume-latest-session')), findsOneWidget);
      expect(find.textContaining('2026-08-10-001.md'), findsOneWidget);
      expect(find.textContaining('不影响其他历史记录'), findsOneWidget);

      await tester.tap(find.byKey(const Key('history-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-go-chat')), findsOneWidget);
    },
  );

  testWidgets('opening a session shows its full text read-only', (
    tester,
  ) async {
    final historyViewModel = HistoryViewModel(
      _FakeHistoryGateway(_testListing()),
      onSessionDeleted: (_) {},
      autoStart: false,
    );
    await historyViewModel.refresh();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: _chatViewModel(),
        historyViewModel: historyViewModel,
        onboardingViewModel: await _onboardingViewModel(),
      ),
    );
    await _enterChatFromHome(tester);
    await tester.tap(find.byKey(const Key('open-history')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('history-session-tile-session-yesterday')),
    );
    await tester.pumpAndSettle();

    expect(find.text('会话详情'), findsOneWidget);
    expect(find.text('昨天的第一句'), findsOneWidget);
    expect(find.text('嗯'), findsOneWidget);
    expect(find.byKey(const Key('chat-input')), findsNothing);
    expect(find.byKey(const Key('chat-send')), findsNothing);

    await tester.tap(find.byKey(const Key('history-session-back')));
    await tester.pumpAndSettle();
    expect(find.text('历史'), findsOneWidget);

    await tester.tap(find.byKey(const Key('history-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-go-chat')), findsOneWidget);
  });

  testWidgets(
    'deleting a session requires explicit confirmation and resets the chat when current',
    (tester) async {
      final chatGateway = _FakeChatGateway();
      final chatViewModel = _chatViewModel(chatGateway);
      await chatViewModel.initialize();
      final historyGateway = _FakeHistoryGateway(_testListing());
      final historyViewModel = HistoryViewModel(
        historyGateway,
        onSessionDeleted: chatViewModel.discardSession,
        autoStart: false,
      );
      await historyViewModel.refresh();
      await tester.pumpWidget(
        QiyuApp(
          viewModel: chatViewModel,
          historyViewModel: historyViewModel,
          onboardingViewModel: await _onboardingViewModel(),
        ),
      );
      await _enterChatFromHome(tester);
      await tester.tap(find.byKey(const Key('open-history')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('delete-session-session-yesterday')),
      );
      await tester.pumpAndSettle();
      expect(find.text('删除这段会话？'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cancel-delete')));
      await tester.pumpAndSettle();
      expect(historyGateway.deletedSessionIds, isEmpty);
      expect(
        find.byKey(const Key('history-session-tile-session-yesterday')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('delete-session-session-today')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-delete')));
      await tester.pumpAndSettle();

      expect(historyGateway.deletedSessionIds, ['session-today']);
      expect(
        find.byKey(const Key('history-session-tile-session-today')),
        findsNothing,
      );
      expect(chatGateway.restoreCalls.last, isNull);
      expect(chatViewModel.messages, isEmpty);

      await tester.tap(find.byKey(const Key('history-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-go-chat')), findsOneWidget);
    },
  );

  testWidgets('resume button returns to the chat and only for the latest session', (
    tester,
  ) async {
    final historyViewModel = HistoryViewModel(
      _FakeHistoryGateway(_testListing()),
      onSessionDeleted: (_) {},
      autoStart: false,
    );
    await historyViewModel.refresh();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: _chatViewModel(),
        historyViewModel: historyViewModel,
        onboardingViewModel: await _onboardingViewModel(),
      ),
    );
    await _enterChatFromHome(tester);
    await tester.tap(find.byKey(const Key('open-history')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('resume-latest-session')), findsOneWidget);
    await tester.tap(find.byKey(const Key('resume-latest-session')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat-input')), findsOneWidget);

    await tester.tap(find.byKey(const Key('go-home')));
    await tester.pumpAndSettle();
  });

  testWidgets('history errors offer a retry without losing the page', (
    tester,
  ) async {
    final historyGateway = _FakeHistoryGateway(
      _testListing(),
      fetchError: const HistoryGatewayException('历史记录暂时不可用。'),
    );
    final historyViewModel = HistoryViewModel(
      historyGateway,
      onSessionDeleted: (_) {},
      autoStart: false,
    );
    await historyViewModel.refresh();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: _chatViewModel(),
        historyViewModel: historyViewModel,
        onboardingViewModel: await _onboardingViewModel(),
      ),
    );
    await _enterChatFromHome(tester);
    await tester.tap(find.byKey(const Key('open-history')));
    await tester.pumpAndSettle();

    expect(find.text('历史记录暂时不可用。'), findsOneWidget);
    historyGateway.fetchError = null;
    await tester.tap(find.byKey(const Key('retry-history')));
    await tester.pumpAndSettle();

    expect(find.text('今天想说的事'), findsOneWidget);

    await tester.tap(find.byKey(const Key('history-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-go-chat')), findsOneWidget);
  });
}

LocalChatViewModel _chatViewModel([_FakeChatGateway? gateway]) =>
    LocalChatViewModel(
      gateway ?? _FakeChatGateway(),
      hostConnectionProbe: _FakeHostConnectionProbe([true]),
      autoStart: false,
    );

Future<OnboardingViewModel> _onboardingViewModel() async {
  final viewModel = OnboardingViewModel(
    _FakeOnboardingGateway(),
    _FixedProviderSettingsGateway(),
    autoStart: false,
  );
  await viewModel.initialize();
  return viewModel;
}

Future<void> _enterChatFromHome(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('home-go-chat')));
  await tester.pumpAndSettle();
}

final class _FakeOnboardingGateway implements OnboardingGateway {
  @override
  Future<OnboardingState> read() async =>
      const OnboardingState(completed: true);

  @override
  Future<void> complete() async {}
}

final class _FixedProviderSettingsGateway implements ProviderSettingsGateway {
  @override
  Future<ProviderSettings> read() async =>
      const ProviderSettings(configured: false, keySet: false);

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) =>
      throw UnimplementedError();

  @override
  Future<ProviderSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<ProviderTestResult> testConnection(ProviderSettingsDraft draft) =>
      throw UnimplementedError();
}

String _localDate(DateTime value) =>
    '${value.year}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

HistoryListing _testListing() {
  final now = DateTime.now();
  final today = _localDate(now);
  final yesterday = _localDate(now.subtract(const Duration(days: 1)));
  return HistoryListing(
    latestSessionId: 'session-today',
    days: [
      HistoryDay(
        date: today,
        sessions: [
          HistorySessionSummary(
            sessionId: 'session-today',
            segment: 1,
            startedAt: now.subtract(const Duration(hours: 1)),
            updatedAt: now.subtract(const Duration(minutes: 30)),
            turnCount: 4,
            preview: '今天想说的事',
          ),
        ],
      ),
      HistoryDay(
        date: yesterday,
        sessions: [
          HistorySessionSummary(
            sessionId: 'session-yesterday',
            segment: 1,
            startedAt: now.subtract(const Duration(days: 1, hours: 2)),
            updatedAt: now.subtract(const Duration(days: 1, hours: 1)),
            turnCount: 2,
            preview: '昨天的事',
          ),
        ],
      ),
    ],
    unavailable: const [
      UnavailableHistoryEntry(
        name: '2026-08-10-001.md',
        message: '这个会话文件暂时无法读取，不影响其他历史记录。',
      ),
    ],
  );
}

final class _FakeHistoryGateway implements HistoryGateway {
  _FakeHistoryGateway(this._listing, {this.fetchError});

  HistoryListing _listing;
  Object? fetchError;
  final deletedSessionIds = <String>[];

  @override
  Future<HistoryListing> fetchHistory() async {
    final error = fetchError;
    if (error != null) {
      throw error;
    }
    return _listing;
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    deletedSessionIds.add(sessionId);
    final days = <HistoryDay>[];
    String? latest;
    for (final day in _listing.days) {
      final remaining = day.sessions
          .where((session) => session.sessionId != sessionId)
          .toList();
      if (remaining.isEmpty) {
        continue;
      }
      days.add(HistoryDay(date: day.date, sessions: remaining));
    }
    if (_listing.latestSessionId == sessionId && days.isNotEmpty) {
      latest = days.first.sessions.first.sessionId;
    } else {
      latest = _listing.latestSessionId;
    }
    _listing = HistoryListing(
      latestSessionId: latest,
      days: days,
      unavailable: _listing.unavailable,
    );
  }
}

final class _FakeChatGateway implements StreamingLocalChatGateway {
  final List<String?> restoreCalls = [];
  var _nullRestores = 0;

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async {
    restoreCalls.add(sessionId);
    if (sessionId == 'session-yesterday') {
      return const LocalChatSnapshot(
        sessionId: 'session-yesterday',
        messages: [
          LocalChatMessage(
            requestId: 'old-1',
            speaker: LocalChatSpeaker.user,
            text: '昨天的第一句',
          ),
          LocalChatMessage(
            requestId: 'old-1',
            speaker: LocalChatSpeaker.qiyu,
            text: '嗯',
            source: ReplySource.local,
          ),
        ],
      );
    }
    if (sessionId == null) {
      _nullRestores += 1;
      if (_nullRestores == 1) {
        return const LocalChatSnapshot(
          sessionId: 'session-today',
          messages: [
            LocalChatMessage(
              requestId: 'today-1',
              speaker: LocalChatSpeaker.user,
              text: '今天的第一句',
            ),
            LocalChatMessage(
              requestId: 'today-1',
              speaker: LocalChatSpeaker.qiyu,
              text: '在',
              source: ReplySource.local,
            ),
          ],
        );
      }
      return const LocalChatSnapshot(sessionId: 'session-new', messages: []);
    }
    return const LocalChatSnapshot(sessionId: 'session-today', messages: []);
  }

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {}

  @override
  Future<bool> cancel(String requestId) async => true;
}

final class _FakeHostConnectionProbe implements HostConnectionProbe {
  _FakeHostConnectionProbe(this._results);

  final List<bool> _results;
  var _index = 0;

  @override
  Future<bool> isHostAvailable() async {
    final result = _results[_index];
    if (_index < _results.length - 1) {
      _index += 1;
    }
    return result;
  }
}
