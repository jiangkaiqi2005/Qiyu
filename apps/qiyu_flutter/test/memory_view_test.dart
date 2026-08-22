import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/memory/backup_client.dart';
import 'package:qiyu_flutter/features/memory/backup_platform.dart';
import 'package:qiyu_flutter/features/memory/backup_view.dart';
import 'package:qiyu_flutter/features/memory/memory_client.dart';
import 'package:qiyu_flutter/features/memory/memory_view_model.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_client.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_view_model.dart';

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
      expect(memoryGateway.calls, everyElement(startsWith('fetch')));

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
      await tester.tap(find.byKey(const Key('memory-root-middle-middle-1')));
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
      await tester.tap(find.byKey(const Key('memory-day-entry-entry-9')));
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

  testWidgets(
    'revisiting a day already on the stack falls back instead of nesting deeper',
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

      // 走到 条目 → 这一天 → 条目 的环：从条目详情再点「查看这一天的记录」。
      await tester.tap(find.byKey(const Key('memory-tab-persona')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('memory-root-root-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('memory-root-middle-middle-1')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('memory-leaf-expression-2026-07-10-day-leaf-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('memory-day-entry-entry-9')));
      await tester.pumpAndSettle();
      expect(find.text('当时的摘录'), findsOneWidget);

      // 目标日期已在返回栈里：回退到那一层，而不是再叠一层新页面。
      await tester.tap(find.byKey(const Key('memory-item-day')));
      await tester.pumpAndSettle();
      expect(find.text('2026年7月10日'), findsOneWidget);

      // 回退次数与栈深一致（根 → 理解 → 这一天），不再无限嵌套。
      var backs = 0;
      while (backs < 6 &&
          find.byKey(const Key('memory-back')).evaluate().isEmpty) {
        await tester.tap(find.byKey(const Key('memory-item-back')));
        await tester.pumpAndSettle();
        backs += 1;
      }
      expect(backs, 3);
      await tester.tap(find.byKey(const Key('memory-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-go-memory')), findsOneWidget);
    },
  );

  testWidgets(
    'memory center back returns to the page it was opened from',
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
          providerSettingsViewModel: await _providerSettingsViewModel(),
          sttSettingsViewModel: SttSettingsViewModel(
            const _FixedSttSettingsGateway(),
            autoStart: false,
          ),
          settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
        ),
      );
      await tester.pumpAndSettle();

      // 设置 → 本地数据 → 记忆中心：返回键回到设置页而不是首页。
      await tester.tap(find.byKey(const Key('home-go-settings')));
      await tester.pumpAndSettle();
      final settingsScrollable = find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('settings-memory-center')),
        200,
        scrollable: settingsScrollable,
        maxScrolls: 20,
      );
      await tester.ensureVisible(find.byKey(const Key('settings-memory-center')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-memory-center')));
      await tester.pumpAndSettle();
      expect(find.text('最近发生'), findsOneWidget);

      await tester.tap(find.byKey(const Key('memory-back')));
      await tester.pumpAndSettle();
      // 回到设置页（保持离开时的滚动位置），而不是首页。
      expect(find.text('本地数据'), findsOneWidget);
    },
  );

  testWidgets('stale item ids resolve to an honest gone state', (tester) async {
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
    await tester.tap(find.byKey(const Key('memory-root-middle-middle-1')));
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
    expect(find.textContaining('13812345678'), findsNothing);
    expect(find.textContaining('这条内容涉及私密信息，暂不直接展示。'), findsWidgets);

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

  testWidgets('editing an entry saves the correction as a user statement', (
    tester,
  ) async {
    final gateway = _FakeMemoryGateway(_fullOverview());
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

    await tester.tap(find.byKey(const Key('memory-actions-entry-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修正'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('memory-edit-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('memory-edit-field')),
      '这周在准备一场辩论赛',
    );
    await tester.tap(find.byKey(const Key('memory-edit-save')));
    await tester.pumpAndSettle();

    expect(gateway.actionCalls, contains('edit:entry-1:这周在准备一场辩论赛'));
    // 成功后总览刷新，界面立即反映修正。
    expect(
      gateway.calls.where((call) => call == 'fetchOverview').length,
      greaterThanOrEqualTo(2),
    );
    expect(find.byKey(const Key('memory-action-result')), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-go-memory')), findsOneWidget);
  });

  testWidgets('freeze applies immediately, ban needs confirmation', (
    tester,
  ) async {
    final gateway = _FakeMemoryGateway(_fullOverview());
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

    // 冻结直接生效，不需要确认。
    await tester.tap(find.byKey(const Key('memory-actions-entry-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('暂停使用'));
    await tester.pumpAndSettle();
    expect(gateway.actionCalls, contains('freeze:entry-1'));

    // 禁提必须确认；取消不产生动作。
    await tester.tap(find.byKey(const Key('memory-actions-entry-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不再提起'));
    await tester.pumpAndSettle();
    expect(find.text('不再提起这条记忆？'), findsOneWidget);
    await tester.tap(find.text('先不用'));
    await tester.pumpAndSettle();
    expect(gateway.actionCalls, isNot(contains('ban:entry-1')));

    await tester.tap(find.byKey(const Key('memory-actions-entry-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不再提起'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-ban-confirm')));
    await tester.pumpAndSettle();
    expect(gateway.actionCalls, contains('ban:entry-1'));

    await tester.tap(find.byKey(const Key('memory-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-go-memory')), findsOneWidget);
  });

  testWidgets('delete previews the exact impact before executing', (
    tester,
  ) async {
    final gateway = _FakeMemoryGateway(_fullOverview());
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

    await tester.tap(find.byKey(const Key('memory-actions-entry-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // 影响范围先于删除呈现，表述准确不含糊。
    expect(gateway.actionCalls, contains('preview:entry-1'));
    expect(find.text('将删除这条记忆：测试内容'), findsOneWidget);
    expect(find.text('原始对话记录保留。'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-delete-confirm')));
    await tester.pumpAndSettle();
    expect(gateway.actionCalls, contains('delete:entry-1'));

    await tester.tap(find.byKey(const Key('memory-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-go-memory')), findsOneWidget);
  });

  testWidgets('persona items can be controlled but never edited', (
    tester,
  ) async {
    final gateway = _FakeMemoryGateway(_fullOverview());
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

    await tester.tap(find.byKey(const Key('memory-actions-root-1')));
    await tester.pumpAndSettle();
    // 画像只能通过对话纠正：菜单里没有修正入口。
    expect(find.text('修正'), findsNothing);
    await tester.tap(find.text('暂停使用'));
    await tester.pumpAndSettle();
    expect(gateway.actionCalls, contains('freeze:root-1'));

    await tester.tap(find.byKey(const Key('memory-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-go-memory')), findsOneWidget);
  });

  testWidgets('state pack rows stay read-only', (tester) async {
    final gateway = _FakeMemoryGateway(_fullOverview());
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
    await tester.tap(find.byKey(const Key('memory-tab-relationship')));
    await tester.pumpAndSettle();

    // 相处方式/近期变化是状态包投影：不是控制对象，没有操作入口。
    expect(find.byKey(const Key('memory-actions-rel-1')), findsNothing);
    expect(find.byKey(const Key('memory-actions-rel-2')), findsNothing);
    // 共同过往属于长期印象，仍可操作。
    expect(find.byKey(const Key('memory-actions-lt-2')), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-go-memory')), findsOneWidget);
  });

  testWidgets('recovery findings show an honest banner with details', (
    tester,
  ) async {
    final gateway = _FakeMemoryGateway(_recoveryOverview());
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

    // 受影响范围、恢复结果与仍无法恢复的内容都诚实呈现。
    expect(find.byKey(const Key('memory-recovery-banner')), findsOneWidget);
    expect(find.text('部分记忆文件出现过损坏'), findsOneWidget);
    await tester.tap(find.byKey(const Key('memory-recovery-banner')));
    await tester.pumpAndSettle();
    expect(find.textContaining('长期印象内容'), findsOneWidget);
    expect(find.textContaining('从文件内完整对话块 2 段抢救'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-go-memory')), findsOneWidget);
  });

  testWidgets('healthy recovery section stays invisible', (tester) async {
    final gateway = _FakeMemoryGateway(_fullOverview());
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

    expect(find.byKey(const Key('memory-recovery-banner')), findsNothing);

    await tester.tap(find.byKey(const Key('memory-back')));
    await tester.pumpAndSettle();
  });

  testWidgets('masked detail content reveals once and re-masks on timeout', (
    tester,
  ) async {
    final gateway = _FakeMemoryGateway(_maskedEntryOverview());
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
    await tester.tap(find.byKey(const Key('memory-entry-entry-masked')));
    await tester.pumpAndSettle();

    // 默认遮罩：原文不出现。
    expect(find.text('揭示出的原文'), findsNothing);
    expect(find.byKey(const Key('memory-reveal-content')), findsOneWidget);

    // 明确揭示后才展示原文。
    await tester.tap(find.byKey(const Key('memory-reveal-content')));
    await tester.pumpAndSettle();
    expect(gateway.actionCalls, contains('reveal:entry-masked:content'));
    expect(find.text('揭示出的原文'), findsOneWidget);

    // 超时自动重新遮罩。
    await tester.pump(const Duration(seconds: 21));
    await tester.pumpAndSettle();
    expect(find.text('揭示出的原文'), findsNothing);

    await tester.tap(find.byKey(const Key('memory-item-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-go-memory')), findsOneWidget);
  });

  testWidgets('masked persona root and day summary offer a reveal entry', (
    tester,
  ) async {
    final gateway = _FakeMemoryGateway(_maskedPersonaOverview());
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

    // 画像根详情：遮罩主张有临时查看入口，揭示后展示原文。
    await tester.tap(find.byKey(const Key('memory-tab-persona')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-root-root-masked')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memory-reveal-claim')), findsOneWidget);
    await tester.tap(find.byKey(const Key('memory-reveal-claim')));
    await tester.pumpAndSettle();
    expect(gateway.actionCalls, contains('reveal:root-masked:claim'));
    expect(find.text('揭示出的原文'), findsOneWidget);
    await tester.tap(find.byKey(const Key('memory-item-back')));
    await tester.pumpAndSettle();

    // 某一天的详情：遮罩小结同样有临时查看入口，请求 summary 字段。
    await tester.tap(find.byKey(const Key('memory-tab-recent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-entry-entry-m2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-item-day')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memory-reveal-summary')), findsOneWidget);
    await tester.tap(find.byKey(const Key('memory-reveal-summary')));
    await tester.pumpAndSettle();
    expect(gateway.actionCalls, contains('reveal:day-masked:summary'));
    expect(find.text('揭示出的原文'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-item-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-item-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-go-memory')), findsOneWidget);
  });

  testWidgets('action entries stay disabled while an action is in flight', (
    tester,
  ) async {
    final gateway = _FakeMemoryGateway(_fullOverview());
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

    // 冻结动作挂起期间：菜单禁用，避免重复触发。
    gateway.holdFreeze = Completer<MemoryActionResult>();
    await tester.tap(find.byKey(const Key('memory-actions-entry-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('暂停使用'));
    await tester.pumpAndSettle();
    expect(gateway.actionCalls, contains('freeze:entry-1'));

    PopupMenuButton<Object?> actionMenu() =>
        tester.widget<PopupMenuButton<Object?>>(
          find.byWidgetPredicate(
            (widget) => widget is PopupMenuButton<Object?>,
          ),
        );
    expect(actionMenu().enabled, isFalse);

    // 完成后：结果三态呈现，入口恢复可用。
    gateway.holdFreeze!.complete(
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已暂停使用这条记忆。',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memory-action-result')), findsOneWidget);
    expect(actionMenu().enabled, isTrue);

    await tester.tap(find.byKey(const Key('memory-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-go-memory')), findsOneWidget);
  });

  testWidgets('memory page opens the backup dialog with honest platform state', (
    tester,
  ) async {
    final memoryViewModel = MemoryCenterViewModel(
      _FakeMemoryGateway(_fullOverview()),
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

    await tester.tap(find.byKey(const Key('memory-backup')));
    await tester.pumpAndSettle();
    expect(find.text('备份与恢复'), findsOneWidget);
    expect(find.byKey(const Key('backup-export')), findsOneWidget);
    // 测试环境没有浏览器文件能力：如实说明，不假装可用。
    expect(find.textContaining('当前环境不支持选择文件'), findsOneWidget);
    await tester.tap(find.byKey(const Key('backup-close')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('memory-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-go-memory')), findsOneWidget);
  });

  testWidgets('backup import previews differences and only writes after confirm', (
    tester,
  ) async {
    final backupGateway = _FakeBackupGateway();
    final memoryViewModel = MemoryCenterViewModel(
      _FakeMemoryGateway(_fullOverview()),
      autoStart: false,
    );
    await memoryViewModel.refresh();
    await _pumpBackupDialog(
      tester,
      memoryViewModel: memoryViewModel,
      gateway: backupGateway,
      platform: _FakeBackupPlatform(
        picked: Uint8List.fromList(utf8.encode('备份字节')),
      ),
    );

    await tester.tap(find.byKey(const Key('backup-import-pick')));
    await tester.pumpAndSettle();

    // 预览：差异计数、控制合并说明与逐条归类。
    expect(find.byKey(const Key('backup-preview')), findsOneWidget);
    expect(find.textContaining('新增 1'), findsOneWidget);
    expect(find.textContaining('替换 1'), findsOneWidget);
    expect(find.textContaining('冲突 1'), findsOneWidget);
    expect(find.textContaining('不可恢复 1'), findsOneWidget);
    expect(find.textContaining('并集'), findsOneWidget);
    expect(
      find.textContaining('冲突：sessions/2026/08/2026-08-05-001.md'),
      findsOneWidget,
    );
    // 跳过项同样逐条可见，不是只有一个计数。
    expect(find.textContaining('跳过：open-loops.md'), findsOneWidget);
    expect(backupGateway.importCalls, 0);

    await tester.ensureVisible(find.byKey(const Key('backup-import-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('backup-import-confirm')));
    await tester.pumpAndSettle();
    expect(backupGateway.importCalls, 1);
    expect(find.textContaining('导入完成'), findsOneWidget);
    expect(find.textContaining('记忆控制已按并集合并'), findsOneWidget);
  });

  testWidgets('cancelling an import preview writes nothing', (tester) async {
    final backupGateway = _FakeBackupGateway();
    final memoryViewModel = MemoryCenterViewModel(
      _FakeMemoryGateway(_fullOverview()),
      autoStart: false,
    );
    await memoryViewModel.refresh();
    await _pumpBackupDialog(
      tester,
      memoryViewModel: memoryViewModel,
      gateway: backupGateway,
      platform: _FakeBackupPlatform(
        picked: Uint8List.fromList(utf8.encode('备份字节')),
      ),
    );

    await tester.tap(find.byKey(const Key('backup-import-pick')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('backup-preview')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('backup-import-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('backup-import-cancel')));
    await tester.pumpAndSettle();
    expect(backupGateway.importCalls, 0);
    expect(backupGateway.previewCalls, 1);
    expect(find.byKey(const Key('backup-import-pick')), findsOneWidget);
  });

  testWidgets('an invalid backup is rejected with the honest reason', (
    tester,
  ) async {
    final backupGateway = _FakeBackupGateway()
      ..previewError = const BackupGatewayException(
        '备份版本与当前栖语不兼容，已拒绝。',
      );
    final memoryViewModel = MemoryCenterViewModel(
      _FakeMemoryGateway(_fullOverview()),
      autoStart: false,
    );
    await memoryViewModel.refresh();
    await _pumpBackupDialog(
      tester,
      memoryViewModel: memoryViewModel,
      gateway: backupGateway,
      platform: _FakeBackupPlatform(
        picked: Uint8List.fromList(utf8.encode('坏备份')),
      ),
    );

    await tester.tap(find.byKey(const Key('backup-import-pick')));
    await tester.pumpAndSettle();
    expect(find.textContaining('不兼容'), findsOneWidget);
    expect(find.byKey(const Key('backup-preview')), findsNothing);
    expect(backupGateway.importCalls, 0);
  });

  testWidgets('rollback restores the pre-import snapshot after confirmation', (
    tester,
  ) async {
    final backupGateway = _FakeBackupGateway();
    final memoryViewModel = MemoryCenterViewModel(
      _FakeMemoryGateway(_fullOverview()),
      autoStart: false,
    );
    await memoryViewModel.refresh();
    await _pumpBackupDialog(
      tester,
      memoryViewModel: memoryViewModel,
      gateway: backupGateway,
      platform: _FakeBackupPlatform(),
    );

    expect(find.textContaining('最近快照'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('backup-rollback')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('backup-rollback')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('backup-rollback-confirm')), findsOneWidget);

    await tester.tap(find.byKey(const Key('backup-rollback-go')));
    await tester.pumpAndSettle();
    expect(backupGateway.rollbackCalls, 1);
    expect(find.textContaining('已恢复到导入之前'), findsOneWidget);
  });
}

Future<void> _pumpBackupDialog(
  WidgetTester tester, {
  required MemoryCenterViewModel memoryViewModel,
  required BackupGateway gateway,
  required BackupPlatform platform,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<MemoryCenterViewModel>.value(
      value: memoryViewModel,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => ElevatedButton(
                key: const Key('open-backup'),
                onPressed: () => unawaited(
                  showBackupDialog(
                    context,
                    gateway: gateway,
                    platform: platform,
                  ),
                ),
                child: const Text('打开备份'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('open-backup')));
  await tester.pumpAndSettle();
}

MemoryOverview _maskedEntryOverview() => MemoryOverview(
  generatedAt: DateTime.parse('2026-08-17T13:00:00.000Z'),
  recent: MemoryRecentSection(
    days: [
      MemoryDayCard(
        id: 'day-1',
        date: _localDate(DateTime.now()),
        summary: null,
        summaryMasked: false,
        finalized: true,
        finalizedAt: null,
        entries: [
          MemoryEntryCard(
            id: 'entry-masked',
            kind: 'memory',
            content: null,
            masked: true,
            control: null,
            at: DateTime.now().subtract(const Duration(hours: 1)),
            hasEvidence: false,
          ),
        ],
      ),
    ],
  ),
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

/// 画像根与当日小结被遮罩的总览：原文字段为 null，揭示入口仍要
/// 在详情页可达。
MemoryOverview _maskedPersonaOverview() => MemoryOverview(
  generatedAt: DateTime.parse('2026-08-17T13:00:00.000Z'),
  recent: MemoryRecentSection(
    days: [
      MemoryDayCard(
        id: 'day-masked',
        date: _localDate(DateTime.now()),
        summary: null,
        summaryMasked: true,
        finalized: true,
        finalizedAt: null,
        entries: [
          MemoryEntryCard(
            id: 'entry-m2',
            kind: 'memory',
            content: '一条普通记录',
            masked: false,
            control: null,
            at: DateTime.now().subtract(const Duration(hours: 1)),
            hasEvidence: false,
          ),
        ],
      ),
    ],
  ),
  longTerm: MemoryLongTermSection(
    present: false,
    readable: true,
    organizedAt: null,
    groups: [],
  ),
  persona: MemoryPersonaSection(
    branches: [
      MemoryPersonaBranchCard(
        wire: 'identity',
        title: '身份事实',
        readable: true,
        roots: const [
          MemoryPersonaRootCard(
            id: 'root-masked',
            claim: null,
            masked: true,
            control: null,
            middleCount: 0,
            leafCount: 0,
            earliestEvidence: null,
            latestEvidence: null,
          ),
        ],
        unrooted: const [],
      ),
    ],
  ),
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

Future<ProviderSettingsViewModel> _providerSettingsViewModel() async {
  final viewModel = ProviderSettingsViewModel(
    _FixedProviderSettingsGateway(),
    autoStart: false,
  );
  await viewModel.initialize();
  return viewModel;
}

final class _FakeSettingsGateway implements SettingsGateway {
  @override
  Future<ExperiencePreferences> readPreferences() async =>
      ExperiencePreferences(developerMode: false);

  @override
  Future<ExperiencePreferences> savePreferences({
    required bool developerMode,
  }) async => ExperiencePreferences(developerMode: developerMode);

  @override
  Future<MemoryControlsOverview> readMemoryControls() async =>
      const MemoryControlsOverview(
        readable: true,
        frozen: [],
        banned: [],
        deletedCount: 0,
      );

  @override
  Future<ClearPreview> readClearPreview() async => const ClearPreview(
    memoryDirectory: 'C:/qiyu-test/memories',
    sessionCount: 0,
    episodeDayCount: 0,
    frozenCount: 0,
    bannedCount: 0,
    deletedCount: 0,
    snapshotCount: 0,
    providerConfigured: false,
    keySet: false,
  );

  @override
  Future<void> clearData() async {}

  @override
  Future<DiagnosticsSnapshot> readDiagnostics() async => DiagnosticsSnapshot(
    generatedAt: DateTime(2026, 8, 19),
    memoryDirectory: 'C:/qiyu-test/memories',
    recentRequests: const [],
    finalization: const FinalizationHealth(
      today: '2026-08-19',
      todayFinalized: false,
      pendingDays: 0,
      unreadableDays: 0,
    ),
    dream: const DreamHealth(),
    fileHealth: const {},
  );
}

/// 恢复状态呈现用总览（ticket 21）：受影响范围、采用证据与恢复结果
/// 诚实可见，绝不显示虚假成功。
MemoryOverview _recoveryOverview() => MemoryOverview(
  generatedAt: DateTime.parse('2026-08-17T13:00:00.000Z'),
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
  recovery: MemoryRecoverySection(
    healthy: false,
    quarantinedFiles: 2,
    findings: [
      MemoryRecoveryFindingCard(
        layer: '长期印象',
        kind: 'corrupt',
        outcome: 'pending',
        evidence: '无有效 Dream 备份',
        loss: '长期印象内容',
        quarantined: true,
      ),
      MemoryRecoveryFindingCard(
        layer: '原始会话（2026-08-05 第 1 段）',
        kind: 'incomplete',
        outcome: 'partial',
        evidence: '从文件内完整对话块 2 段抢救',
        loss: '未完整解析的对话块',
        quarantined: true,
      ),
    ],
  ),
);

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
            id: 'lt-1',
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
        id: 'rel-1',
        content: '可以自然提起说过的事',
        masked: false,
        control: null,
      ),
    ],
    probes: [],
    recentChanges: [
      MemoryLongTermItem(
        id: 'rel-2',
        content: '聊得比平时深一些',
        masked: false,
        control: null,
      ),
    ],
    sharedPast: [
      MemoryLongTermItem(
        id: 'lt-2',
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
            id: 'lt-frozen',
            content: '冻结的印象',
            masked: false,
            control: MemoryControlStatus.frozen,
          ),
          MemoryLongTermItem(
            id: 'lt-banned',
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
  final actionCalls = <String>[];

  /// 动作结果注入：缺省一律成功。
  MemoryActionResult actionResult = const MemoryActionResult(
    status: MemoryActionStatus.success,
    message: '好了。',
  );
  MemoryDeleteImpact? previewImpact = const MemoryDeleteImpact(
    lines: ['将删除这条记忆：测试内容', '原始对话记录保留。'],
    sessionsKept: true,
  );

  /// 非 null 时冻结动作挂起在它上面，用于观察执行中的忙碌态。
  Completer<MemoryActionResult>? holdFreeze;

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
  Future<MemoryActionResult> editItem(String id, String text) async {
    actionCalls.add('edit:$id:$text');
    return actionResult;
  }

  @override
  Future<MemoryActionResult> freezeItem(String id) async {
    actionCalls.add('freeze:$id');
    final hold = holdFreeze;
    if (hold != null) {
      return hold.future;
    }
    return actionResult;
  }

  @override
  Future<MemoryActionResult> unfreezeItem(String id) async {
    actionCalls.add('unfreeze:$id');
    return actionResult;
  }

  @override
  Future<MemoryActionResult> banItem(String id) async {
    actionCalls.add('ban:$id');
    return actionResult;
  }

  @override
  Future<MemoryActionResult> unbanItem(String id) async {
    actionCalls.add('unban:$id');
    return actionResult;
  }

  @override
  Future<MemoryDeleteImpact?> previewDelete(String id) async {
    actionCalls.add('preview:$id');
    return previewImpact;
  }

  @override
  Future<MemoryActionResult> deleteItem(String id) async {
    actionCalls.add('delete:$id');
    return actionResult;
  }

  @override
  Future<MemoryActionResult> revealItem(
    String id, {
    String field = 'content',
  }) async {
    actionCalls.add('reveal:$id:$field');
    return const MemoryActionResult(
      status: MemoryActionStatus.success,
      message: '仅本次展示。',
      text: '揭示出的原文',
    );
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
      'entry-masked' => EpisodeEntryDetail(
        date: '2026-08-17',
        dayId: 'day-1',
        entryKind: 'memory',
        content: null,
        masked: true,
        control: null,
        at: DateTime.parse('2026-08-17T12:00:00.000Z'),
        evidence: null,
        evidenceMasked: false,
        sessionId: null,
        daySummary: null,
        finalized: true,
      ),
      'entry-m2' => EpisodeEntryDetail(
        date: _localDate(DateTime.now()),
        dayId: 'day-masked',
        entryKind: 'memory',
        content: '一条普通记录',
        masked: false,
        control: null,
        at: DateTime.now().subtract(const Duration(hours: 1)),
        evidence: null,
        evidenceMasked: false,
        sessionId: null,
        daySummary: null,
        finalized: true,
      ),
      // 遮罩时原文字段为 null，只有遮罩标记：揭示入口必须仍在。
      'day-masked' => MemoryDayDetail(
        date: _localDate(DateTime.now()),
        summary: null,
        summaryMasked: true,
        finalized: true,
        finalizedAt: null,
        entries: const [],
      ),
      'root-masked' => const PersonaRootDetail(
        branch: 'identity',
        branchTitle: '身份事实',
        claim: null,
        masked: true,
        control: null,
        middles: [],
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

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '语音测试转写';
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

final class _FakeBackupGateway implements BackupGateway {
  BackupGatewayException? previewError;
  int previewCalls = 0;
  int importCalls = 0;
  int rollbackCalls = 0;

  @override
  Future<({Uint8List bytes, String fileName})> exportBundle() async => (
    bytes: Uint8List.fromList(utf8.encode('zip')),
    fileName: 'qiyu-backup-test.zip',
  );

  @override
  Future<BackupPreview> previewBundle(Uint8List bundle) async {
    previewCalls += 1;
    final error = previewError;
    if (error != null) {
      throw error;
    }
    return BackupPreview(
      generatedAt: DateTime.parse('2026-08-19T12:00:00Z'),
      controlsMerge: 'union',
      counts: const {
        'added': 1,
        'replaced': 1,
        'conflict': 1,
        'skipped': 2,
        'unrecoverable': 1,
      },
      items: const [
        BackupPreviewItem(
          path: 'long-memory.md',
          category: BackupItemCategory.added,
        ),
        BackupPreviewItem(
          path: 'daily-state.md',
          category: BackupItemCategory.replaced,
        ),
        BackupPreviewItem(
          path: 'sessions/2026/08/2026-08-05-001.md',
          category: BackupItemCategory.conflict,
          note: '本机已有同名原始会话，保留本机版本',
        ),
        BackupPreviewItem(
          path: 'sessions/2026/08/2026-08-06-001.md',
          category: BackupItemCategory.unrecoverable,
          note: '备份中的会话结构无法识别，未导入',
        ),
        BackupPreviewItem(
          path: 'open-loops.md',
          category: BackupItemCategory.skipped,
        ),
        BackupPreviewItem(
          path: 'episodes/index.md',
          category: BackupItemCategory.skipped,
        ),
      ],
    );
  }

  @override
  Future<BackupImportResult> importBundle(Uint8List bundle) async {
    importCalls += 1;
    return const BackupImportResult(
      added: 1,
      replaced: 1,
      skipped: 2,
      conflicts: 1,
      unrecoverable: 1,
      controlsMerged: true,
      snapshotId: 'snapshot-1',
    );
  }

  @override
  Future<List<BackupSnapshotInfo>> snapshots() async => [
    BackupSnapshotInfo(
      id: 'snapshot-1',
      createdAt: DateTime.parse('2026-08-19T12:00:00Z'),
      fileCount: 3,
    ),
  ];

  @override
  Future<BackupRollbackResult> rollback({String? snapshotId}) async {
    rollbackCalls += 1;
    return const BackupRollbackResult(
      snapshotId: 'snapshot-1',
      restoredFiles: 3,
      safetySnapshotId: 'snapshot-2',
    );
  }
}

final class _FakeBackupPlatform implements BackupPlatform {
  _FakeBackupPlatform({this.picked});

  final Uint8List? picked;
  int downloads = 0;

  @override
  bool get supported => true;

  @override
  Future<bool> downloadBackup(String fileName, Uint8List bytes) async {
    downloads += 1;
    return true;
  }

  @override
  Future<Uint8List?> pickBackupFile() async => picked;
}

final class _FixedSttSettingsGateway implements SttSettingsGateway {
  const _FixedSttSettingsGateway();

  @override
  Future<SttSettings> read() async =>
      const SttSettings(configured: false, keySet: false);

  @override
  Future<SttSettings> save(SttSettingsDraft draft) async => SttSettings(
    configured: true,
    keySet: draft.apiKey != null,
    baseUrl: draft.baseUrl,
    model: draft.model,
  );

  @override
  Future<SttSettings> forgetApiKey() async =>
      const SttSettings(configured: false, keySet: false);

  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) async =>
      const ProviderTestResult(
        succeeded: true,
        status: ProviderTestStatus.success,
        message: '连接成功，语音输入可以使用。',
      );
}
