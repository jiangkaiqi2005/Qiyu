import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/history/history_client.dart';
import 'package:qiyu_flutter/features/history/history_view.dart';
import 'package:qiyu_flutter/features/history/history_view_model.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/theme/qiyu_icons.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'support/shared_fakes.dart';
import 'support/test_dates.dart';

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
      await _settleMergedPage(tester);

      await tester.tap(find.byKey(const Key('open-history')));
      await tester.pumpAndSettle();

      // 「历史」这个词侧边栏导航项也在渲染，整树取即歧义 → 限定在本页子树。
      expect(_historyPageTitle(), findsOneWidget);
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
      // 历史从聊天页 push 进入：返回键回到聊天页而不是首页。
      expect(find.byKey(const Key('open-history')), findsOneWidget);
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
    await _settleMergedPage(tester);
    await tester.tap(find.byKey(const Key('open-history')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('history-session-tile-session-yesterday')),
    );
    await tester.pumpAndSettle();

    expect(find.text('会话详情'), findsOneWidget);
    expect(find.text('昨天的第一句'), findsOneWidget);
    expect(find.text('嗯'), findsOneWidget);
    // 只读回看页整页可选择：拖动即可选中复制。
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.byKey(const Key('chat-input')), findsNothing);
    expect(find.byKey(const Key('chat-send')), findsNothing);

    await tester.tap(find.byKey(const Key('history-session-back')));
    await tester.pumpAndSettle();
    expect(_historyPageTitle(), findsOneWidget);

    await tester.tap(find.byKey(const Key('history-back')));
    await tester.pumpAndSettle();
    // 历史从聊天页 push 进入：返回键回到聊天页而不是首页。
    expect(find.byKey(const Key('open-history')), findsOneWidget);
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
      await _settleMergedPage(tester);
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

      await tester.tap(find.byKey(const Key('delete-session-session-today')));
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
      // 历史从聊天页 push 进入：返回键回到聊天页而不是首页。
      expect(find.byKey(const Key('open-history')), findsOneWidget);
    },
  );

  testWidgets(
    'resume button returns to the chat and only for the latest session',
    (tester) async {
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
      await _settleMergedPage(tester);
      await tester.tap(find.byKey(const Key('open-history')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('resume-latest-session')), findsOneWidget);
      await tester.tap(find.byKey(const Key('resume-latest-session')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('chat-input')), findsOneWidget);

      // 桌面已不设「回合一页」入口（2026-08-31 二次裁定）：`go-home` 键只保留
      // 在窄屏抽屉品牌槽上，切到窄视口走抽屉完成同一动作；抽屉收回，落回
      // 合一页仍可聊。
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pump();
      await tester.tap(find.byKey(const Key('nav-menu-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('go-home')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('nav-history')),
        findsNothing,
        reason: '抽屉收回',
      );
      expect(find.byKey(const Key('chat-input')), findsOneWidget);
    },
  );

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
    await _settleMergedPage(tester);
    await tester.tap(find.byKey(const Key('open-history')));
    await tester.pumpAndSettle();

    expect(find.text('历史记录暂时不可用。'), findsOneWidget);
    historyGateway.fetchError = null;
    await tester.tap(find.byKey(const Key('retry-history')));
    await tester.pumpAndSettle();

    expect(find.text('今天想说的事'), findsOneWidget);

    await tester.tap(find.byKey(const Key('history-back')));
    await tester.pumpAndSettle();
    // 历史从聊天页 push 进入：返回键回到聊天页而不是首页。
    expect(find.byKey(const Key('open-history')), findsOneWidget);
  });

  testWidgets('窄屏页头让开三条杠：标题左边界不被浮层命中区压住', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    await _settleMergedPage(tester);
    await tester.tap(find.byKey(const Key('open-history')));
    await tester.pumpAndSettle();

    // 窄屏的三条杠是浮在内容之上的层，且本页此时不摆自己的返回箭头：
    // 页头必须自己让开它的横向占位，标题才不会压在它下面。
    final menu = tester.getRect(find.byKey(const Key('nav-menu-button')));
    expect(menu.right, greaterThan(0), reason: '窄屏左上角才有三条杠');
    expect(
      tester.getTopLeft(_historyPageTitle()).dx,
      greaterThanOrEqualTo(menu.right),
      reason: '「历史」标题的左边界不得落在三条杠的命中区里',
    );
  });

  testWidgets('会话卡片带 §8 的 line 发丝描边', (tester) async {
    // §8 组件 8「卡片 / 面板 — panel 底 + line 发丝描边」此前只停在主题层，
    // 页面覆盖 shape 时又把边换成了 none。这里断的是**画出来**的那条边。
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
    await _settleMergedPage(tester);
    await tester.tap(find.byKey(const Key('open-history')));
    await tester.pumpAndSettle();

    final card = tester.widget<Material>(
      find.descendant(
        of: find.byKey(const Key('history-session-tile-session-today')),
        // 卡片自己那层 Material：卡内的文字按钮另有 Material 层，按 type 区分。
        matching: find.byWidgetPredicate(
          (widget) => widget is Material && widget.type == MaterialType.card,
        ),
      ),
    );
    final side = (card.shape! as OutlinedBorder).side;
    expect(side, isNot(BorderSide.none), reason: '普通模式下卡片没有描边');
    expect(side.width, QiyuLine.hairline);
    expect(side.color.toARGB32(), QiyuColors.line.toARGB32());
  });

  testWidgets('日期分组小标题取次要色档，不是主文字色', (tester) async {
    // Spec Decision 13。此前这一处读 textTheme.titleSmall，而字阶表没有登记那一
    // 档，落的是 Material 3 默认的 onSurface 近白——主文字色当小标题用会抢读。
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
    await _settleMergedPage(tester);
    await tester.tap(find.byKey(const Key('open-history')));
    await tester.pumpAndSettle();

    final header = tester.widget<RichText>(
      find.descendant(of: find.text('今天'), matching: find.byType(RichText)),
    );
    final style = (header.text as TextSpan).style!;
    expect(
      style.color?.toARGB32(),
      QiyuColors.muted.toARGB32(),
      reason: '日分组标题不是次要字档',
    );
    expect(style.color?.toARGB32(), isNot(QiyuColors.ink.toARGB32()));
    // 字号同时锁在已登记的次要档上：退回未登记的 titleSmall 会连带把字号换回 14。
    expect(style.fontSize, QiyuType.secondarySize);
  });

  testWidgets('删除图标静置次要色、悬停提亮且不显紫', (tester) async {
    // Spec Decision 13「删除图标常驻次要色」+ §8 组件 7「悬停轻提亮」。此前这颗
    // 按钮不消费主题档，静置 muted 只来自全局 iconTheme，悬停根本不提亮。
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
    await _settleMergedPage(tester);
    await tester.tap(find.byKey(const Key('open-history')));
    await tester.pumpAndSettle();

    const deleteButton = Key('delete-session-session-today');
    Color glyphColor() => IconTheme.of(
      tester.element(
        find.descendant(
          of: find.byKey(deleteButton),
          matching: find.byIcon(QiyuIcons.delete),
        ),
      ),
    ).color!;

    expect(glyphColor(), QiyuColors.muted);
    expect(glyphColor(), isNot(QiyuColors.accentBright));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(deleteButton)));
    await tester.pumpAndSettle();
    expect(glyphColor(), QiyuColors.ink, reason: '悬停不提亮：这颗按钮没接上主题层的安静档');
    expect(glyphColor(), isNot(QiyuColors.accentBright));

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(glyphColor(), QiyuColors.muted);
  });

  testWidgets('删除按钮带无障碍语义标签，读屏动作名不依赖 hover', (tester) async {
    // `test/accessibility_test.dart` 的探针用例已钉住事实：IconButton 的 tooltip
    // 只落在语义节点的 tooltip 属性上，label 是空的，而触屏没有 hover。这颗删除
    // 入口此前只有 tooltip，读屏器念不出动作名；现在动作名显式进语义树，并汇在
    // 按钮那一个节点上。
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
    await _settleMergedPage(tester);
    await tester.tap(find.byKey(const Key('open-history')));
    await tester.pumpAndSettle();

    final handle = tester.ensureSemantics();
    try {
      // 标签合在按钮外层的 MergeSemantics 节点上，且只有汇成 SemanticsData
      // 才读得到：节点自身的 label 在合并情况下仍是空的。
      const deleteButton = Key('delete-session-session-today');
      final data = tester
          .getSemantics(
            find.ancestor(
              of: find.byKey(deleteButton),
              matching: find.byType(MergeSemantics),
            ),
          )
          .getSemanticsData();
      expect(data.label, '删除这段会话', reason: '删除入口没把动作名带进语义标签，触屏读不到');
      expect(data.tooltip, '删除这段会话', reason: 'tooltip 与语义标签各写了一份');
      expect(data.flagsCollection.isButton, isTrue);
      // 读屏按 label 查要能命中这一颗。`find.bySemanticsLabel` 匹配的是带
      // `semanticLabel` 的那个 Semantics 控件（由 Icon 生成，在按钮子树内），
      // 而历史列表每段会话都有一颗同名按钮，所以限定在本颗的子树里查、不数全树。
      expect(
        find.descendant(
          of: find.byKey(deleteButton),
          matching: find.bySemanticsLabel('删除这段会话'),
        ),
        findsOneWidget,
        reason: '读屏按语义标签查不到这颗删除按钮，动作名只剩 hover 才看得见',
      );
    } finally {
      handle.dispose();
    }
  });
}

LocalChatViewModel _chatViewModel([_FakeChatGateway? gateway]) =>
    LocalChatViewModel(
      gateway ?? _FakeChatGateway(),
      hostConnectionProbe: FakeHostConnectionProbe(const [true]),
      autoStart: false,
    );

Future<OnboardingViewModel> _onboardingViewModel() async {
  final viewModel = OnboardingViewModel(
    FakeOnboardingGateway(completed: true),
    FixedProviderSettingsGateway(),
    autoStart: false,
  );
  await viewModel.initialize();
  return viewModel;
}

/// 历史列表页自己的标题：桌面导航壳的侧边栏同样渲染「历史」这个导航文案，
/// 整树 `find.text` 命中两处即歧义（按 Key / 页面范围定位的既有约定）。
Finder _historyPageTitle() =>
    find.descendant(of: find.byType(HistoryView), matching: find.text('历史'));

/// 合一页（design-system §5）没有「从首页进对话」这一跳，`home-go-chat` 现在
/// 只是输入容器的定位键：这里做的只是推进到稳定态，不触发任何导航。
Future<void> _settleMergedPage(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('home-go-chat')));
  await tester.pumpAndSettle();
}

HistoryListing _testListing() {
  final now = DateTime.now();
  final today = localDate(now);
  final yesterday = localDate(now.subtract(const Duration(days: 1)));
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

  @override
  Future<bool> stopVoice(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '语音测试转写';
}
