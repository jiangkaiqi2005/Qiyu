import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/memory/memory_client.dart';
import 'package:qiyu_flutter/features/memory/memory_view_model.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_client.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';

void main() {
  testWidgets(
    'home offers a memory entry and the center loads all four sections',
    (tester) async {
      final memoryGateway = _FakeMemoryGateway(_fullOverview());
      final memoryViewModel = MemoryCenterViewModel(
        memoryGateway,
        autoStart: false,
      );
      await memoryViewModel.refresh();
      await tester.pumpWidget(
        QiyuApp(
          viewModel: _chatViewModel(),
          onboardingViewModel: await _onboardingViewModel(),
          memoryViewModel: memoryViewModel,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('home-go-memory')));
      await tester.pumpAndSettle();

      expect(find.text('记忆'), findsWidgets);
      // 四区导航只用用户语言，不暴露内部实现术语。
      expect(find.text('最近发生'), findsOneWidget);
      expect(find.text('长期印象'), findsOneWidget);
      expect(find.text('关于你'), findsOneWidget);
      expect(find.text('我们的关系'), findsOneWidget);
      expect(find.textContaining('PersonaTree'), findsNothing);
      expect(find.textContaining('long-memory'), findsNothing);
      expect(find.textContaining('episode'), findsNothing);

      // 最近发生：内容、时间、状态与证据入口。
      expect(find.text('今天'), findsWidgets);
      expect(find.text('用户说这周在准备演讲'), findsOneWidget);
      expect(find.text('记忆'), findsWidgets);
      expect(find.text('有摘录'), findsOneWidget);
      expect(find.text('整理中'), findsWidgets);

      // 长期印象。
      await tester.tap(find.byKey(const Key('memory-tab-longterm')));
      await tester.pumpAndSettle();
      expect(find.text('人与关系'), findsOneWidget);
      expect(find.text('用户和家人关系亲近'), findsOneWidget);
      expect(find.textContaining('最近一次深度整理'), findsOneWidget);

      // 关于你：根主张与证据跨度。
      await tester.tap(find.byKey(const Key('memory-tab-persona')));
      await tester.pumpAndSettle();
      expect(find.text('性格表达'), findsOneWidget);
      expect(find.text('用户尴尬时倾向自嘲'), findsOneWidget);
      expect(find.textContaining('2 条证据'), findsOneWidget);

      // 我们的关系：阶段、相处方式与共同过往。
      await tester.tap(find.byKey(const Key('memory-tab-relationship')));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前阶段：熟悉'), findsOneWidget);
      expect(find.text('可以自然提起说过的事'), findsOneWidget);
      expect(find.text('共同过往'), findsOneWidget);
      expect(find.text('一起聊到过深夜'), findsOneWidget);

      // 只读红线：整轮浏览只触发读取调用。
      expect(memoryGateway.calls, isNotEmpty);
      expect(
        memoryGateway.calls,
        everyElement(startsWith('fetch')),
      );

      await tester.tap(find.byKey(const Key('memory-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-go-chat')), findsOneWidget);
    },
  );

  testWidgets(
    'evidence drills from a conclusion to summaries, days and the session',
    (tester) async {
      final memoryGateway = _FakeMemoryGateway(_fullOverview());
      final memoryViewModel = MemoryCenterViewModel(
        memoryGateway,
        autoStart: false,
      );
      await memoryViewModel.refresh();
      final chatGateway = _FakeChatGateway();
      await tester.pumpWidget(
        QiyuApp(
          viewModel: _chatViewModel(chatGateway),
          onboardingViewModel: await _onboardingViewModel(),
          memoryViewModel: memoryViewModel,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-go-memory')));
      await tester.pumpAndSettle();

      // 结论 → 支持它的理解。
      await tester.tap(find.byKey(const Key('memory-tab-persona')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('memory-root-root-1')));
      await tester.pumpAndSettle();
      expect(memoryGateway.detailCalls, contains('root-1'));
      expect(find.text('支持它的理解'), findsOneWidget);
      expect(find.text('被关注时常用玩笑降低郑重感'), findsOneWidget);

      // 理解 → 逐条证据（含冲突标识）。
      await tester.tap(
        find.byKey(const Key('memory-root-middle-middle-1')),
      );
      await tester.pumpAndSettle();
      expect(memoryGateway.detailCalls, contains('middle-1'));
      expect(find.text('证据'), findsOneWidget);
      expect(find.text('被认真夸奖后马上自嘲'), findsOneWidget);
      expect(find.text('冲突'), findsOneWidget);

      // 证据 → 当天记录 → 条目详情 → 当时的对话。
      await tester.tap(
        find.byKey(const Key('memory-leaf-expression-2026-07-10-day-leaf-1')),
      );
      await tester.pumpAndSettle();
      expect(memoryGateway.detailCalls, contains('day-leaf-1'));
      expect(find.text('2026年7月10日'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('memory-day-entry-entry-9')),
      );
      await tester.pumpAndSettle();
      expect(find.text('当时的摘录'), findsOneWidget);
      expect(find.text('周四有个演讲'), findsOneWidget);
      await tester.tap(find.byKey(const Key('memory-item-session')));
      await tester.pumpAndSettle();
      expect(chatGateway.restoreCalls, contains('session-9'));
      expect(find.text('那天聊到的原话'), findsOneWidget);

      // 逐层返回首页，保持测试间路由状态干净。
      await tester.tap(find.byKey(const Key('history-session-back')));
      await tester.pumpAndSettle();
      for (var depth = 0; depth < 4; depth += 1) {
        await tester.tap(find.byKey(const Key('memory-item-back')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('memory-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-go-memory')), findsOneWidget);
    },
  );

  testWidgets('stale item ids resolve to an honest gone state', (
    tester,
  ) async {
    final memoryGateway = _FakeMemoryGateway(_fullOverview());
    final memoryViewModel = MemoryCenterViewModel(
      memoryGateway,
      autoStart: false,
    );
    await memoryViewModel.refresh();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: _chatViewModel(),
        onboardingViewModel: await _onboardingViewModel(),
        memoryViewModel: memoryViewModel,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-go-memory')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-tab-persona')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-root-root-1')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('memory-root-middle-middle-1')),
    );
    await tester.pumpAndSettle();

    // 指向已不存在日期的叶：诚实说明，不编造内容。
    await tester.tap(
      find.byKey(const Key('memory-leaf-expression-2026-07-16-day-gone')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memory-item-gone')), findsOneWidget);

    // 逐层返回首页，保持测试间路由状态干净。
    for (var depth = 0; depth < 3; depth += 1) {
      await tester.tap(find.byKey(const Key('memory-item-back')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const Key('memory-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-go-memory')), findsOneWidget);
  });

  testWidgets('empty sections stay honest without invented content', (
    tester,
  ) async {
    final memoryViewModel = MemoryCenterViewModel(
      _FakeMemoryGateway(_emptyOverview()),
      autoStart: false,
    );
    await memoryViewModel.refresh();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: _chatViewModel(),
        onboardingViewModel: await _onboardingViewModel(),
        memoryViewModel: memoryViewModel,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-go-memory')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('memory-empty-recent')), findsOneWidget);
    expect(find.textContaining('还没有最近的记录'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-tab-longterm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memory-empty-longterm')), findsOneWidget);
    expect(find.textContaining('还没有形成长期印象'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-tab-persona')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memory-empty-persona')), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-tab-relationship')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memory-empty-relationship')), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-go-memory')), findsOneWidget);
  });

  testWidgets('sensitive entries are masked and statuses stay quiet', (
    tester,
  ) async {
    final memoryViewModel = MemoryCenterViewModel(
      _FakeMemoryGateway(_markedOverview()),
      autoStart: false,
    );
    await memoryViewModel.refresh();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: _chatViewModel(),
        onboardingViewModel: await _onboardingViewModel(),
        memoryViewModel: memoryViewModel,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-go-memory')));
    await tester.pumpAndSettle();

    // 敏感条目默认遮罩：原文不出现在界面任何地方。
    expect(
      find.textContaining('13812345678'),
      findsNothing,
    );
    expect(
      find.textContaining('这条内容涉及私密信息，暂不直接展示。'),
      findsWidgets,
    );

    // 冻结与禁提标识安静地挂在条目上。
    await tester.tap(find.byKey(const Key('memory-tab-longterm')));
    await tester.pumpAndSettle();
    expect(find.text('已冻结'), findsOneWidget);
    expect(find.text('已禁提'), findsOneWidget);

    // 冲突与待复核标识。
    await tester.tap(find.byKey(const Key('memory-tab-persona')));
    await tester.pumpAndSettle();
    expect(find.text('有冲突证据'), findsOneWidget);
    expect(find.text('待稳定事实'), findsWidgets);

    await tester.tap(find.byKey(const Key('memory-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-go-memory')), findsOneWidget);
  });

  testWidgets('item load failures stay distinct from stale ids', (
    tester,
  ) async {
    final gateway = _FakeMemoryGateway(
      _fullOverview(),
      detailError: const MemoryGatewayException('boom'),
    );
    final memoryViewModel = MemoryCenterViewModel(gateway, autoStart: false);
    await memoryViewModel.refresh();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: _chatViewModel(),
        onboardingViewModel: await _onboardingViewModel(),
        memoryViewModel: memoryViewModel,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-go-memory')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-tab-persona')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-root-root-1')));
    await tester.pumpAndSettle();

    // 网络/Host 错误与「条目已变化」分开呈现，可重试。
    expect(find.byKey(const Key('memory-item-error')), findsOneWidget);
    gateway.detailError = null;
    await tester.tap(find.byKey(const Key('memory-item-retry')));
    await tester.pumpAndSettle();
    expect(find.text('支持它的理解'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-item-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-go-memory')), findsOneWidget);
  });

  testWidgets('memory errors offer a retry without losing the page', (
    tester,
  ) async {
    final gateway = _FakeMemoryGateway(
      _fullOverview(),
      fetchError: const MemoryGatewayException('记忆中心暂时不可用。'),
    );
    final memoryViewModel = MemoryCenterViewModel(gateway, autoStart: false);
    await memoryViewModel.refresh();
    await tester.pumpWidget(
      QiyuApp(
        viewModel: _chatViewModel(),
        onboardingViewModel: await _onboardingViewModel(),
        memoryViewModel: memoryViewModel,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-go-memory')));
    await tester.pumpAndSettle();

    expect(find.text('记忆中心暂时不可用。'), findsOneWidget);
    gateway.fetchError = null;
    await tester.tap(find.byKey(const Key('retry-memory')));
    await tester.pumpAndSettle();

    expect(find.text('用户说这周在准备演讲'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-go-memory')), findsOneWidget);
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

MemoryOverview _fullOverview() => MemoryOverview(
  generatedAt: DateTime.parse('2026-08-17T13:00:00.000Z'),
  recent: MemoryRecentSection(
    days: [
      MemoryDayCard(
        id: 'day-1',
        date: _localDate(DateTime.now()),
        summary: '聊了演讲准备',
        summaryMasked: false,
        finalized: false,
        finalizedAt: null,
        entries: [
          MemoryEntryCard(
            id: 'entry-1',
            kind: 'memory',
            content: '用户说这周在准备演讲',
            masked: false,
            control: null,
            at: DateTime.now().subtract(const Duration(hours: 1)),
            hasEvidence: true,
          ),
        ],
      ),
    ],
  ),
  longTerm: MemoryLongTermSection(
    present: true,
    readable: true,
    organizedAt: DateTime.parse('2026-08-16T14:00:00.000Z'),
    groups: [
      MemoryLongTermGroup(
        section: '人与关系',
        items: const [
          MemoryLongTermItem(
            content: '用户和家人关系亲近',
            masked: false,
            control: null,
          ),
        ],
      ),
    ],
  ),
  persona: MemoryPersonaSection(
    branches: [
      MemoryPersonaBranchCard(
        wire: 'expression',
        title: '性格表达',
        readable: true,
        roots: const [
          MemoryPersonaRootCard(
            id: 'root-1',
            claim: '用户尴尬时倾向自嘲',
            masked: false,
            control: null,
            middleCount: 1,
            leafCount: 2,
            earliestEvidence: '2026-07-10',
            latestEvidence: '2026-07-16',
          ),
        ],
        unrooted: const [],
      ),
    ],
  ),
  relationship: const MemoryRelationshipSection(
    present: true,
    stage: '熟悉',
    since: '2026-08-01',
    confirmed: [
      MemoryLongTermItem(
        content: '可以自然提起说过的事',
        masked: false,
        control: null,
      ),
    ],
    probes: [],
    recentChanges: [
      MemoryLongTermItem(
        content: '聊得比平时深一些',
        masked: false,
        control: null,
      ),
    ],
    sharedPast: [
      MemoryLongTermItem(
        content: '一起聊到过深夜',
        masked: false,
        control: null,
      ),
    ],
  ),
);

final MemoryOverview _emptyOverviewValue = MemoryOverview(
  generatedAt: DateTime(2026),
  recent: MemoryRecentSection(days: []),
  longTerm: MemoryLongTermSection(
    present: false,
    readable: true,
    organizedAt: null,
    groups: [],
  ),
  persona: MemoryPersonaSection(branches: []),
  relationship: MemoryRelationshipSection(
    present: false,
    stage: null,
    since: null,
    confirmed: [],
    probes: [],
    recentChanges: [],
    sharedPast: [],
  ),
);

MemoryOverview _emptyOverview() => _emptyOverviewValue;

MemoryOverview _markedOverview() => MemoryOverview(
  generatedAt: DateTime.parse('2026-08-17T13:00:00.000Z'),
  recent: MemoryRecentSection(
    days: [
      MemoryDayCard(
        id: 'day-1',
        date: '2026-08-17',
        summary: null,
        summaryMasked: false,
        finalized: true,
        finalizedAt: null,
        entries: [
          MemoryEntryCard(
            id: 'entry-sensitive',
            kind: 'memory',
            content: null,
            masked: true,
            control: null,
            at: _sensitiveEntryAt,
            hasEvidence: false,
          ),
        ],
      ),
    ],
  ),
  longTerm: const MemoryLongTermSection(
    present: true,
    readable: true,
    organizedAt: null,
    groups: [
      MemoryLongTermGroup(
        section: '人与关系',
        items: [
          MemoryLongTermItem(
            content: '冻结的印象',
            masked: false,
            control: MemoryControlStatus.frozen,
          ),
          MemoryLongTermItem(
            content: '禁提的印象',
            masked: false,
            control: MemoryControlStatus.banned,
          ),
        ],
      ),
    ],
  ),
  persona: MemoryPersonaSection(
    branches: [
      MemoryPersonaBranchCard(
        wire: 'identity',
        title: '身份事实',
        readable: true,
        roots: const [],
        unrooted: const [
          MemoryPersonaMiddleCard(
            id: 'middle-pending',
            type: '待稳定事实',
            claim: '用户是中学老师',
            masked: false,
            control: null,
            formedOn: '2026-07-10',
            reviewedOn: '2026-07-10',
            leafCount: 1,
            hasConflict: true,
          ),
        ],
      ),
    ],
  ),
  relationship: const MemoryRelationshipSection(
    present: false,
    stage: null,
    since: null,
    confirmed: [],
    probes: [],
    recentChanges: [],
    sharedPast: [],
  ),
);

final _sensitiveEntryAt = DateTime(2026, 8, 17, 12);

String _localDate(DateTime value) =>
    '${value.year}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

final class _FakeMemoryGateway implements MemoryGateway {
  _FakeMemoryGateway(this._overview, {this.fetchError, this.detailError});

  final MemoryOverview _overview;
  Object? fetchError;
  Object? detailError;
  final calls = <String>[];
  final detailCalls = <String>[];

  @override
  Future<MemoryOverview> fetchOverview() async {
    calls.add('fetchOverview');
    final error = fetchError;
    if (error != null) {
      throw error;
    }
    return _overview;
  }

  @override
  Future<MemoryItemDetail?> fetchItemDetail(String id) async {
    calls.add('fetchItemDetail:$id');
    final error = detailError;
    if (error != null) {
      throw error;
    }
    detailCalls.add(id);
    return switch (id) {
      'root-1' => const PersonaRootDetail(
        branch: 'expression',
        branchTitle: '性格表达',
        claim: '用户尴尬时倾向自嘲',
        masked: false,
        control: null,
        middles: [
          MemoryPersonaMiddleCard(
            id: 'middle-1',
            type: '重复模式',
            claim: '被关注时常用玩笑降低郑重感',
            masked: false,
            control: null,
            formedOn: '2026-07-16',
            reviewedOn: '2026-07-16',
            leafCount: 2,
            hasConflict: true,
          ),
        ],
      ),
      'middle-1' => const PersonaMiddleDetail(
        branch: 'expression',
        branchTitle: '性格表达',
        type: '重复模式',
        claim: '被关注时常用玩笑降低郑重感',
        masked: false,
        control: null,
        formedOn: '2026-07-16',
        reviewedOn: '2026-07-16',
        rootClaim: '用户尴尬时倾向自嘲',
        leaves: [
          MemoryPersonaLeafCard(
            dayId: 'day-leaf-1',
            date: '2026-07-10',
            nature: '行为观察',
            relation: 'support',
            summary: '被认真夸奖后马上自嘲',
            masked: false,
            control: null,
          ),
          MemoryPersonaLeafCard(
            dayId: 'day-gone',
            date: '2026-07-16',
            nature: '行为观察',
            relation: 'conflict',
            summary: '这次认真道谢了',
            masked: false,
            control: null,
          ),
        ],
      ),
      'day-leaf-1' => MemoryDayDetail(
        date: '2026-07-10',
        summary: '聊了被夸奖的反应',
        summaryMasked: false,
        finalized: true,
        finalizedAt: null,
        entries: [
          MemoryEntryCard(
            id: 'entry-9',
            kind: 'memory',
            content: '被夸时用玩笑卸力',
            masked: false,
            control: null,
            at: _sensitiveEntryAt,
            hasEvidence: true,
          ),
        ],
      ),
      'entry-9' => EpisodeEntryDetail(
        date: '2026-07-10',
        dayId: 'day-leaf-1',
        entryKind: 'memory',
        content: '被夸时用玩笑卸力',
        masked: false,
        control: null,
        at: DateTime.parse('2026-07-10T14:00:00.000Z'),
        evidence: '周四有个演讲',
        evidenceMasked: false,
        sessionId: 'session-9',
        daySummary: '聊了被夸奖的反应',
        finalized: true,
      ),
      _ => null,
    };
  }
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

final class _FakeChatGateway implements StreamingLocalChatGateway {
  final restoreCalls = <String?>[];

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async {
    restoreCalls.add(sessionId);
    if (sessionId == 'session-9') {
      return const LocalChatSnapshot(
        sessionId: 'session-9',
        messages: [
          LocalChatMessage(
            requestId: 'old-9',
            speaker: LocalChatSpeaker.user,
            text: '那天聊到的原话',
          ),
        ],
      );
    }
    return const LocalChatSnapshot(sessionId: 'session-new', messages: []);
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
