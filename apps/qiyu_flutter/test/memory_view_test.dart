import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
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
import 'package:qiyu_flutter/features/memory/memory_view.dart';
import 'package:qiyu_flutter/features/memory/memory_view_model.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_client.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_view_model.dart';
import 'package:qiyu_flutter/theme/qiyu_icons.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

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

  testWidgets('记忆四区 tab 带 §4 定案图标，选中态取中性档不显紫', (
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

    // §4 定案选型：时钟 / 山形 / 单人 / 双人，图标与文字并存。
    const sectionIcons = <String, IconData>{
      'memory-tab-recent': QiyuIcons.schedule,
      'memory-tab-longterm': QiyuIcons.landscape,
      'memory-tab-persona': QiyuIcons.person,
      'memory-tab-relationship': QiyuIcons.groups,
    };
    for (final entry in sectionIcons.entries) {
      final tab = tester.widget<Tab>(find.byKey(Key(entry.key)));
      expect((tab.icon! as Icon).icon, entry.value, reason: entry.key);
      expect(
        find.descendant(
          of: find.byKey(Key(entry.key)),
          matching: find.byIcon(entry.value),
        ),
        findsOneWidget,
        reason: '${entry.key} 的字形没有真的画出来',
      );
    }

    // 取色不在页面自写：指示器与两态文字色一律由主题层的中性档供给。
    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.indicator, isNull);
    expect(tabBar.labelColor, isNull);
    expect(tabBar.unselectedLabelColor, isNull);
    final indicator =
        Theme.of(
          tester.element(find.byType(TabBar)),
        ).tabBarTheme.indicator!
        as UnderlineTabIndicator;
    expect(indicator.borderSide.color, QiyuColors.indicatorNeutral);
    expect(indicator.borderSide.color, isNot(QiyuColors.accentBright));

    Color labelColor(String key) => DefaultTextStyle.of(
      tester.element(
        find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text)),
      ),
    ).style.color!;

    Color glyphColor(IconData icon) =>
        IconTheme.of(tester.element(find.byIcon(icon))).color!;

    // 选中＝近白 ink，未选中＝次要 muted；两态都不是紫（§8「选中态全站中性」）。
    expect(labelColor('memory-tab-recent'), QiyuColors.ink);
    expect(glyphColor(QiyuIcons.schedule), QiyuColors.ink);
    expect(labelColor('memory-tab-longterm'), QiyuColors.muted);
    expect(glyphColor(QiyuIcons.landscape), QiyuColors.muted);

    await tester.tap(find.byKey(const Key('memory-tab-longterm')));
    await tester.pumpAndSettle();
    expect(labelColor('memory-tab-longterm'), QiyuColors.ink);
    expect(glyphColor(QiyuIcons.landscape), QiyuColors.ink);
    expect(labelColor('memory-tab-recent'), QiyuColors.muted);
    expect(glyphColor(QiyuIcons.schedule), QiyuColors.muted);
    expect(
      [
        labelColor('memory-tab-recent'),
        labelColor('memory-tab-longterm'),
        glyphColor(QiyuIcons.schedule),
        glyphColor(QiyuIcons.landscape),
      ],
      isNot(contains(QiyuColors.accentBright)),
    );

    await tester.tap(find.byKey(const Key('memory-back')));
    await tester.pumpAndSettle();
  });

  testWidgets('四区 tab 的横滚容器不留滚动条，纵向内容区的滚动条不受牵连', (
    tester,
  ) async {
    // 必须把平台按到桌面档再测，且在建树之前生效——触屏档下框架本来就不给纵向
    // 容器画滚动条，那时「TabBar 里没有滚动条」是一条怎么都成立的空断言。
    // 用 try/finally 而不是 addTearDown 复位：框架的 debug 变量不变量检查跑在
    // teardown 之前，漏一次就会把整条用例判失败。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
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

      // 去掉的是绘制层，不是滚动能力：横滚容器不再套滚动条控件。
      expect(
        find.descendant(
          of: find.byType(TabBar),
          matching: find.byType(Scrollbar),
        ),
        findsNothing,
        reason: '§8：横向滚动容器不留浏览器滚动控件',
      );
      // 规范只要求去掉横滚的滚动条。整页套上去会把纵向的一起摘掉，所以同档平台下
      // 纵向内容区必须还画得出来——这条对照守的就是那个作用域边界。
      expect(
        find.descendant(
          of: find.byType(TabBarView),
          matching: find.byType(Scrollbar),
        ),
        findsWidgets,
        reason: '纵向内容区的滚动条被牵连摘掉了，说明去滚动条套到了整页上',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

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

    // 操作常驻：直接点条目上的修正按钮，不再需要先点开菜单。
    await tester.tap(find.byKey(const Key('memory-action-entry-1-edit')));
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
    await tester.tap(find.byKey(const Key('memory-action-entry-1-freeze')));
    await tester.pumpAndSettle();
    expect(gateway.actionCalls, contains('freeze:entry-1'));

    // 禁提必须确认；取消不产生动作。
    await tester.tap(find.byKey(const Key('memory-action-entry-1-ban')));
    await tester.pumpAndSettle();
    expect(find.text('不再提起这条记忆？'), findsOneWidget);
    await tester.tap(find.text('先不用'));
    await tester.pumpAndSettle();
    expect(gateway.actionCalls, isNot(contains('ban:entry-1')));

    await tester.tap(find.byKey(const Key('memory-action-entry-1-ban')));
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

    await tester.tap(find.byKey(const Key('memory-action-entry-1-delete')));
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

    // 画像只能通过对话纠正：常驻按钮里没有修正这一颗。
    expect(find.byKey(const Key('memory-action-root-1-edit')), findsNothing);
    await tester.tap(find.byKey(const Key('memory-action-root-1-freeze')));
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

  testWidgets('记忆条目操作常驻在条目上，按钮与该条目的状态一一对应', (
    tester,
  ) async {
    await _pumpMemoryCenter(tester, _fullOverview());

    // 不再有任何「点开才看得到」的操作菜单（design-system §8 补充约定）。
    expect(find.bySubtype<PopupMenuButton<Object?>>(), findsNothing);

    // 普通条目：修正 / 暂停使用 / 不再提起 / 删除四颗同时在场。
    for (final action in ['edit', 'freeze', 'ban', 'delete']) {
      expect(
        find.byKey(Key('memory-action-entry-1-$action')),
        findsOneWidget,
        reason: '缺少常驻的 $action 按钮',
      );
    }
    // 未遮罩、未冻结、未禁提：不该出现揭示与两种解除。
    for (final absent in ['reveal', 'unfreeze', 'unban']) {
      expect(
        find.byKey(Key('memory-action-entry-1-$absent')),
        findsNothing,
        reason: '$absent 不适用于这条条目，不该多发',
      );
    }

    // 画像条目：只能通过对话纠正，常驻按钮里没有修正这一颗。
    await tester.tap(find.byKey(const Key('memory-tab-persona')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memory-action-root-1-edit')), findsNothing);
    for (final action in ['freeze', 'ban', 'delete']) {
      expect(
        find.byKey(Key('memory-action-root-1-$action')),
        findsOneWidget,
        reason: '画像条目缺少 $action 控制权',
      );
    }
  });

  testWidgets('敏感与已冻结、已禁提条目只给当下可用的动作，点了就走到', (
    tester,
  ) async {
    final gateway = await _pumpMemoryCenter(tester, _markedOverview());

    // 遮罩条目：有临时查看，没有修正——不揭示原文就不能改。
    expect(
      find.byKey(const Key('memory-action-entry-sensitive-reveal')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('memory-action-entry-sensitive-edit')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const Key('memory-action-entry-sensitive-reveal')),
    );
    await tester.pumpAndSettle();
    expect(gateway.actionCalls, contains('reveal:entry-sensitive:content'));
    expect(find.byKey(const Key('memory-reveal-dialog')), findsOneWidget);
    expect(find.text('揭示出的原文'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    // 列表侧不落揭示状态：关掉对话框就重新遮罩。
    expect(find.text('揭示出的原文'), findsNothing);

    await tester.tap(find.byKey(const Key('memory-tab-longterm')));
    await tester.pumpAndSettle();
    // 已冻结：只有恢复使用，不再提供暂停或禁提。
    expect(
      find.byKey(const Key('memory-action-lt-frozen-unfreeze')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('memory-action-lt-frozen-freeze')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('memory-action-lt-frozen-ban')),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('memory-action-lt-frozen-unfreeze')));
    await tester.pumpAndSettle();
    expect(gateway.actionCalls, contains('unfreeze:lt-frozen'));

    // 已禁提：只有解除禁提，且解除直接生效、不再要确认。
    expect(
      find.byKey(const Key('memory-action-lt-banned-unban')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('memory-action-lt-banned-ban')),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('memory-action-lt-banned-unban')));
    await tester.pumpAndSettle();
    expect(gateway.actionCalls, contains('unban:lt-banned'));
    expect(find.text('不再提起这条记忆？'), findsNothing);
  });

  testWidgets('常驻操作按钮常态是中性次要色，悬停才提亮且不显紫', (
    tester,
  ) async {
    await _pumpMemoryCenter(tester, _fullOverview());
    const freeze = Key('memory-action-entry-1-freeze');

    Color glyphColor() => IconTheme.of(
      tester.element(
        find.descendant(
          of: find.byKey(freeze),
          matching: find.byIcon(QiyuIcons.ac_unit),
        ),
      ),
    ).color!;

    // 未悬停：压成 §2 的次要字档，在场但不抢读。
    expect(glyphColor(), QiyuColors.muted);

    // 指针悬停：前景提到 ink（§8「次要色、悬停提亮」），底色仍是中性淡白。
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(freeze)));
    await tester.pumpAndSettle();
    expect(glyphColor(), QiyuColors.ink);
    expect(glyphColor(), isNot(QiyuColors.accentBright));

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(glyphColor(), QiyuColors.muted);
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

  testWidgets(
    'legacy report with stale and full outcome and zero quarantine does not show damage banner',
    (tester) async {
      // 模拟旧版 Host 返回的 JSON：healthy 字段可能因旧逻辑为 false，但全部 finding 为 full 且无隔离
      final legacyJson = {
        'generatedAt': '2026-08-25T11:44:36.000Z',
        'recent': {'days': []},
        'longTerm': {
          'present': false,
          'readable': true,
          'organizedAt': null,
          'groups': [],
        },
        'persona': {'branches': []},
        'relationship': {
          'present': false,
          'stage': null,
          'since': null,
          'confirmed': [],
          'probes': [],
          'recentChanges': [],
          'sharedPast': [],
        },
        'recovery': {
          'healthy': false, // 旧版 Host 将有 finding 误标为 false
          'quarantinedFiles': 0,
          'findings': [
            {
              'layer': '每日索引（2026-08）',
              'kind': 'stale',
              'outcome': 'full',
              'evidence': '从当月有效每日记录重建',
              'loss': null,
              'quarantined': false,
            },
          ],
        },
      };

      final overview = MemoryOverview.fromJson(legacyJson);
      final gateway = _FakeMemoryGateway(overview);
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
      expect(find.text('部分记忆文件出现过损坏'), findsNothing);

      await tester.tap(find.byKey(const Key('memory-back')));
      await tester.pumpAndSettle();
    },
  );

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

    // 冻结动作挂起期间：这一条目上的常驻按钮全部禁用，避免重复触发。
    const entryActions = ['edit', 'freeze', 'ban', 'delete'];
    IconButton actionButton(String name) => tester.widget<IconButton>(
      find.byKey(Key('memory-action-entry-1-$name')),
    );

    gateway.holdFreeze = Completer<MemoryActionResult>();
    await tester.tap(find.byKey(const Key('memory-action-entry-1-freeze')));
    await tester.pumpAndSettle();
    expect(gateway.actionCalls, contains('freeze:entry-1'));
    for (final name in entryActions) {
      expect(
        actionButton(name).onPressed,
        isNull,
        reason: '动作执行中 $name 按钮不得可点',
      );
    }

    // 完成后：结果三态呈现，每一颗按钮都恢复可用。
    gateway.holdFreeze!.complete(
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已暂停使用这条记忆。',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memory-action-result')), findsOneWidget);
    for (final name in entryActions) {
      expect(
        actionButton(name).onPressed,
        isNotNull,
        reason: '动作完成后 $name 按钮应恢复可用',
      );
    }

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

  testWidgets('窄屏页头让开三条杠：「记忆」标题不被浮层压住', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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

    // 窄屏没有常驻侧边栏：从三条杠打开抽屉，再由抽屉进记忆中心。
    await tester.tap(find.byKey(const Key('nav-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-go-memory')));
    await tester.pumpAndSettle();

    // 这一页在窄屏撤掉了自己的返回箭头，页头必须自己让开浮在左上角的三条杠。
    // 「记忆」两个字页内出现两次（18 的标题与 12 的小标签），按字阶取标题那一个。
    final menu = tester.getRect(find.byKey(const Key('nav-menu-button')));
    expect(
      tester
              .getTopLeft(
                find.descendant(
                  of: find.byType(MemoryView),
                  matching: find.byWidgetPredicate(
                    (widget) =>
                        widget is Text &&
                        widget.data == '记忆' &&
                        widget.style?.fontSize == QiyuType.titleSize,
                  ),
                ),
              )
              .dx,
      greaterThanOrEqualTo(menu.right),
      reason: '「记忆」标题的左边界不得落在三条杠的命中区里',
    );
  });

  testWidgets('窄屏下条目操作按钮全部在场且点得到', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gateway = await _pumpMemoryCenter(
      tester,
      _fullOverview(),
      viaDrawer: true,
    );

    // 四颗常驻按钮都必须在视口之内：收了菜单才挤得下的旧假设已经不成立。
    for (final action in ['edit', 'freeze', 'ban', 'delete']) {
      final finder = find.byKey(Key('memory-action-entry-1-$action'));
      expect(finder, findsOneWidget, reason: '窄屏缺少 $action 按钮');
      final rect = tester.getRect(finder);
      expect(rect.right, lessThanOrEqualTo(400));
      expect(rect.left, greaterThanOrEqualTo(0));
    }

    // 最右那颗（删除）真的可点：确认框弹得出来，说明没被裁出命中区。
    await tester.tap(find.byKey(const Key('memory-action-entry-1-delete')));
    await tester.pumpAndSettle();
    expect(find.text('删除这条记忆？'), findsOneWidget);
    await tester.tap(find.text('先不用'));
    await tester.pumpAndSettle();
    expect(gateway.actionCalls, isNot(contains('delete:entry-1')));
  });

  testWidgets('极窄窗口叠加放大字号：条目头部不溢出，时间与按钮全部在场', (
    tester,
  ) async {
    // 上面那条只测到 400 逻辑像素且不放大字号；条目头部右侧是「时间 + 四颗
    // 常驻按钮」的固定宽度簇，窗口再窄一档、字再大一档就撞上 ticket 24 立下的
    // 「小窗/字号放大绝不产生 RenderFlex 溢出」不变量。溢出会作为布局异常把本条
    // 用例直接判红，不需要额外断言兜着。
    const width = 300.0;
    tester.view.physicalSize = const Size(width, 800);
    tester.view.devicePixelRatio = 1;
    // 本仓 Flutter 版本的注入点是 textScaleFactor（TextScaler 由它派生）。
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pumpMemoryCenter(tester, _fullOverview(), viaDrawer: true);

    // 信息一律不许丢：换行只准改变排法，不准收起时间戳或任何一颗按钮。
    // 条目时间取的是「现在减一小时」的时:分，按形状定位而不是按字面量。
    final tile = find.byKey(const Key('memory-entry-entry-1'));
    final stamp = find.descendant(
      of: tile,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            RegExp(r'^\d{2}:\d{2}$').hasMatch(widget.data ?? ''),
      ),
    );
    expect(stamp, findsOneWidget, reason: '极窄窗口下条目时间不许被藏掉');
    // 先确认字号真的放大到这一页上，否则这条用例退化成普通窄屏、什么也没测到。
    expect(
      MediaQuery.textScalerOf(tester.element(stamp)).scale(100),
      140,
      reason: 'textScaleFactor 注入没落到条目所在的 MediaQuery 上',
    );
    final stampRect = tester.getRect(stamp);
    expect(stampRect.left, greaterThanOrEqualTo(0));
    expect(stampRect.right, lessThanOrEqualTo(width));
    expect(
      stampRect.bottom,
      lessThanOrEqualTo(800),
      reason: '放大字号后条目头部顶出视口下沿',
    );

    for (final action in ['edit', 'freeze', 'ban', 'delete']) {
      final finder = find.byKey(Key('memory-action-entry-1-$action'));
      expect(finder, findsOneWidget, reason: '极窄窗口缺少 $action 按钮');
      final rect = tester.getRect(finder);
      expect(
        rect.right,
        lessThanOrEqualTo(width),
        reason: '$action 按钮被裁出视口右侧',
      );
      expect(
        rect.left,
        greaterThanOrEqualTo(0),
        reason: '$action 按钮被推出视口左缘',
      );
      expect(
        rect.bottom,
        lessThanOrEqualTo(800),
        reason: '$action 按钮换行后落到视口之外',
      );
    }

    // 四区条目用的是同一个常驻操作簇，逐区核一遍：TabBar 是横滚容器，
    // 极窄窗口下标签本身要滚出来才点得到。
    for (final tab in ['longterm', 'persona', 'relationship']) {
      final tabFinder = find.byKey(Key('memory-tab-$tab'));
      await tester.ensureVisible(tabFinder);
      await tester.pumpAndSettle();
      await tester.tap(tabFinder);
      await tester.pumpAndSettle();
      for (final element in find.byType(IconButton).evaluate()) {
        final box = element.renderObject! as RenderBox;
        final rect = box.localToGlobal(Offset.zero) & box.size;
        final key = (element.widget as IconButton).key.toString();
        expect(
          rect.right,
          lessThanOrEqualTo(width),
          reason: '$tab 区 $key 被裁出视口右侧',
        );
        expect(
          rect.left,
          greaterThanOrEqualTo(0),
          reason: '$tab 区 $key 被推出视口左缘',
        );
      }
    }
  });

  testWidgets('宽屏下条目头部保持芯片在左、时间与操作贴右', (tester) async {
    // 头部从 Row 换成两簇 Wrap 之后，宽屏必须仍然把信息放左、时间与常驻操作
    // 放同一行并贴右边界。贴不到右边说明外层没撑满整行宽（Wrap 的主轴尺寸会
    // 收缩到内容宽度）。簇之间新留的 8px 呼吸位是有意的，不在「与原来一致」之列。
    await _pumpMemoryCenter(tester, _fullOverview());
    final tile = find.byKey(const Key('memory-entry-entry-1'));
    final stamp = find.descendant(
      of: tile,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            RegExp(r'^\d{2}:\d{2}$').hasMatch(widget.data ?? ''),
      ),
    );
    final tileRect = tester.getRect(tile);
    final stampRect = tester.getRect(stamp);
    final deleteRect = tester.getRect(
      find.byKey(const Key('memory-action-entry-1-delete')),
    );
    // 状态芯片是 lib 内私有组件，按它的文字定位：entry-1 的 kind 是 memory，
    // 芯片标签就是「记忆」，在这条条目子树里唯一。
    final kindChip = tester.getRect(
      find.descendant(of: tile, matching: find.text('记忆')),
    );
    // 最右那颗按钮贴到卡片内容区的右边界：条目左右内边距 16，按钮盒之外还包着
    // QiyuFocusRingScope 常驻的焦点环留白（左右各 3，实测差值 16+2×3）。
    expect(
      deleteRect.right,
      closeTo(tileRect.right - 16 - 2 * QiyuLayout.focusRingOffset, 1),
      reason: '操作簇没有贴右，外层 Wrap 没撑满整行宽',
    );
    expect(deleteRect.left, greaterThan(stampRect.right));
    expect(deleteRect.center.dy, closeTo(stampRect.center.dy, 1));
    // 芯片贴左：卡片左边界 + 16 内边距 + 芯片自身 8 内边距（余量给字形与描边）。
    expect(
      kindChip.left,
      inInclusiveRange(tileRect.left + 23, tileRect.left + 30),
    );
    expect(kindChip.center.dy, closeTo(stampRect.center.dy, 1));

    // 相邻两颗的左边缘距离必须只等于「一颗的固有宽度 + 两侧焦点环留白」：
    // QiyuFocusRingScope 各留 3，改造前后的 Row 都是这一处 6px，不是新添的。
    // Wrap 的 spacing 只有落成 0 才守得住这条，一旦照搬外层簇间的 8px，差值
    // 立刻多出 8、四颗凭空撑宽 24px——只断 findsOneWidget 测不出这一条。
    final slots = [
      for (final action in ['edit', 'freeze', 'ban', 'delete'])
        tester.getRect(find.byKey(Key('memory-action-entry-1-$action'))),
    ];
    final slotWidth = slots.first.width;
    final slotStride = slotWidth + 2 * QiyuLayout.focusRingOffset;
    for (var i = 1; i < slots.length; i++) {
      expect(
        slots[i].width,
        closeTo(slotWidth, 0.01),
        reason: '第 $i 颗按钮的宽度与前一颗不一致，x 距离的基准不可用',
      );
      expect(
        slots[i].left - slots[i - 1].left,
        closeTo(slotStride, 0.01),
        reason: '相邻两颗按钮之间多出焦点环之外的空隙，常驻操作簇凭空变宽',
      );
    }
  });

  testWidgets('常驻操作按钮带无障碍语义标签，不只有 hover 才看得见的 tooltip', (
    tester,
  ) async {
    // 记忆控制权「随时看得见」的承诺不许只兑现给鼠标用户：触屏没有 hover，
    // 而实测 IconButton 的 tooltip 只进语义节点的 tooltip 属性、label 是空的，
    // 所以动作名必须显式带进语义树。这里开语义树实测，不靠推测。
    await _pumpMemoryCenter(tester, _fullOverview());
    final handle = tester.ensureSemantics();
    try {
      for (final (action, label) in [
        ('edit', '修正'),
        ('freeze', '暂停使用'),
        ('ban', '不再提起'),
        ('delete', '删除'),
      ]) {
        // 标签合在按钮外层的 MergeSemantics 节点上，且只有汇成 SemanticsData
        // 才读得到：节点自身的 label 在合并情况下仍是空的。
        final data = tester
            .getSemantics(
              find.ancestor(
                of: find.byKey(Key('memory-action-entry-1-$action')),
                matching: find.byType(MergeSemantics),
              ),
            )
            .getSemanticsData();
        expect(
          data.label,
          label,
          reason: '$action 按钮没把「$label」带进语义标签，触屏读不到动作名',
        );
        expect(
          data.tooltip,
          label,
          reason: '$action 按钮的 tooltip 属性没带上动作名',
        );
        expect(data.flagsCollection.isButton, isTrue);
      }
    } finally {
      handle.dispose();
    }
  });

  testWidgets('动作结果横幅只走中性底，失败态换成 danger 前景字', (
    tester,
  ) async {
    final gateway = await _pumpMemoryCenter(tester, _fullOverview());

    // 读页面上真正的那一份：底取 SnackBar 内部 Material 的 color，字色取合并
    // 主题样式之后落在 RichText span 上的那一个——两处都不看 widget 上写了什么。
    Color bannerFill() => tester
        .widget<Material>(
          find.descendant(
            of: find.byKey(const Key('memory-action-result')),
            matching: find.byType(Material),
          ),
        )
        .color!;
    Color bannerForeground() {
      final richText = tester.widget<RichText>(
        find.descendant(
          of: find.byKey(const Key('memory-action-result')),
          matching: find.byType(RichText),
        ),
      );
      return (richText.text as TextSpan).style!.color!;
    }

    // 冻结是直接执行的动作：一条用例就能把三态里两态的着色纪律钉住。
    Future<void> show(MemoryActionStatus status) async {
      gateway.actionResult = MemoryActionResult(
        status: status,
        message: '结果横幅文案。',
      );
      await tester.tap(find.byKey(const Key('memory-action-entry-1-freeze')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('memory-action-result')), findsOneWidget);
    }

    Future<void> dismiss() async {
      await tester.pump(const Duration(seconds: 5)); // 轻提示到期收起
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('memory-action-result')), findsNothing);
    }

    // 失败态：危险字档当前景，底仍是主题默认的中性 panel（§2 只有 danger
    // 一档危险色，且它是字档不是底色；决策日志第五轮 #12）。
    await show(MemoryActionStatus.failed);
    expect(bannerFill(), QiyuColors.panel);
    expect(bannerForeground(), QiyuColors.danger);
    await dismiss();

    // 部分完成不是破坏性操作，不借危险红，也不另起一档琥珀底：三态的分别
    // 由文案承担，视觉只给危险位上色。
    await show(MemoryActionStatus.partial);
    expect(bannerFill(), QiyuColors.panel);
    expect(bannerForeground(), isNot(QiyuColors.danger));
    expect(bannerForeground(), QiyuColors.ink);
    await dismiss();
  });
}

/// 进入记忆中心：注入桩网关并走完「首页 → 记忆」这一段导航，返回该网关
/// 供用例查调用记录。窄屏没有常驻侧边栏，[viaDrawer] 为真时先开抽屉再进；
/// 侧边栏与抽屉同时渲染同一批标签，所以入口一律按 Key 定位。
Future<_FakeMemoryGateway> _pumpMemoryCenter(
  WidgetTester tester,
  MemoryOverview overview, {
  bool viaDrawer = false,
}) async {
  final gateway = _FakeMemoryGateway(overview);
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
  if (viaDrawer) {
    await tester.tap(find.byKey(const Key('nav-menu-button')));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const Key('home-go-memory')));
  await tester.pumpAndSettle();
  return gateway;
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
        outcome: MemoryRecoveryOutcome.pending,
        evidence: '无有效 Dream 备份',
        loss: '长期印象内容',
        quarantined: true,
      ),
      MemoryRecoveryFindingCard(
        layer: '原始会话（2026-08-05 第 1 段）',
        kind: 'incomplete',
        outcome: MemoryRecoveryOutcome.partial,
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
