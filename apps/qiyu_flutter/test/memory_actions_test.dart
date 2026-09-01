import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/memory/memory_actions.dart';
import 'package:qiyu_flutter/features/memory/memory_client.dart';
import 'package:qiyu_flutter/features/memory/memory_view.dart';
import 'package:qiyu_flutter/features/memory/memory_view_model.dart';

void main() {
  group('MemoryActionPlan 可用性矩阵（唯一一份）', () {
    test('普通条目：修正、暂停使用、不再提起、删除在场，揭示与两种解除不在场', () {
      const plan = MemoryActionPlan(
        state: MemoryItemActionState(
          control: null,
          masked: false,
          editable: true,
        ),
      );
      expect(plan.offeredActions, const [
        MemoryAction.edit,
        MemoryAction.freeze,
        MemoryAction.ban,
        MemoryAction.delete,
      ]);
      expect(plan.enabled(MemoryAction.edit), isTrue);
      expect(plan.enabled(MemoryAction.delete), isTrue);
    });

    test('遮罩条目：临时查看在场、修正退场（不揭示原文就不能改）', () {
      const plan = MemoryActionPlan(
        state: MemoryItemActionState(control: null, masked: true),
      );
      expect(plan.offeredActions, const [
        MemoryAction.reveal,
        MemoryAction.freeze,
        MemoryAction.ban,
        MemoryAction.delete,
      ]);
      expect(plan.offered(MemoryAction.edit), isFalse);
    });

    test('已冻结条目：只给恢复使用，不再提供暂停或禁提', () {
      const plan = MemoryActionPlan(
        state: MemoryItemActionState(
          control: MemoryControlStatus.frozen,
          masked: false,
          editable: true,
        ),
      );
      expect(plan.offeredActions, const [
        MemoryAction.edit,
        MemoryAction.unfreeze,
        MemoryAction.delete,
      ]);
      expect(plan.offered(MemoryAction.freeze), isFalse);
      expect(plan.offered(MemoryAction.ban), isFalse);
    });

    test('已禁提条目：只给解除禁提，不再提供暂停使用', () {
      const plan = MemoryActionPlan(
        state: MemoryItemActionState(
          control: MemoryControlStatus.banned,
          masked: false,
          editable: true,
        ),
      );
      expect(plan.offeredActions, const [
        MemoryAction.edit,
        MemoryAction.unban,
        MemoryAction.delete,
      ]);
      expect(plan.offered(MemoryAction.freeze), isFalse);
      expect(plan.offered(MemoryAction.ban), isFalse);
    });

    test('画像与状态包条目不提供修正，控制权与删除照常', () {
      const plan = MemoryActionPlan(
        state: MemoryItemActionState(control: null, masked: false),
      );
      expect(plan.offered(MemoryAction.edit), isFalse);
      expect(plan.offered(MemoryAction.freeze), isTrue);
      expect(plan.offered(MemoryAction.ban), isTrue);
      expect(plan.offered(MemoryAction.delete), isTrue);
    });

    test('未遮罩条目不提供临时查看', () {
      const plan = MemoryActionPlan(
        state: MemoryItemActionState(control: null, masked: false),
      );
      expect(plan.offered(MemoryAction.reveal), isFalse);
    });

    test('写入动作挂起时在场按钮一律灰掉，可用性本身不变', () {
      const busy = MemoryActionPlan(
        state: MemoryItemActionState(control: null, masked: true),
        busy: true,
      );
      for (final action in busy.offeredActions) {
        expect(busy.enabled(action), isFalse, reason: action.name);
        expect(busy.offered(action), isTrue, reason: action.name);
      }
    });

    test('确认要求：禁提与删除要确认，冻结、解除与揭示直接生效', () {
      const plan = MemoryActionPlan(
        state: MemoryItemActionState(control: null, masked: false),
      );
      expect(
        plan.confirmationOf(MemoryAction.ban),
        MemoryActionConfirmation.ban,
      );
      expect(
        plan.confirmationOf(MemoryAction.delete),
        MemoryActionConfirmation.delete,
      );
      for (final action in const [
        MemoryAction.edit,
        MemoryAction.reveal,
        MemoryAction.freeze,
        MemoryAction.unfreeze,
        MemoryAction.unban,
      ]) {
        expect(
          plan.confirmationOf(action),
          MemoryActionConfirmation.none,
          reason: action.name,
        );
      }
    });
  });

  group('MemoryActionRunner 上下文存活防护', () {
    testWidgets('发起界面存活时动作完成：结果横幅照常出现', (tester) async {
      final gateway = _HoldGateway();
      final viewModel = MemoryCenterViewModel(gateway, autoStart: false);
      await _pumpRunnerHarness(tester, viewModel);

      await tester.tap(find.byKey(const Key('fire-freeze')));
      await tester.pump();
      expect(gateway.calls, contains('freeze:e1'));

      gateway.hold?.complete(
        const MemoryActionResult(
          status: MemoryActionStatus.success,
          message: '好了。',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('memory-action-result')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('发起界面销毁后动作完成：不挂横幅、不触碰已卸载的上下文', (tester) async {
      final gateway = _HoldGateway();
      final viewModel = MemoryCenterViewModel(gateway, autoStart: false);
      await _pumpRunnerHarness(tester, viewModel);

      await tester.tap(find.byKey(const Key('fire-freeze')));
      await tester.pump();
      expect(gateway.calls, contains('freeze:e1'));

      // 发起动作的那层界面随整棵树销毁；迟到结果不得再触碰它的上下文。
      await tester.pumpWidget(const SizedBox.shrink());
      gateway.hold?.complete(
        const MemoryActionResult(
          status: MemoryActionStatus.success,
          message: '好了。',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('memory-action-result')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('发起界面销毁后揭示完成：原文不落地、也不抛错', (tester) async {
      final gateway = _HoldGateway();
      final viewModel = MemoryCenterViewModel(gateway, autoStart: false);
      await _pumpRunnerHarness(tester, viewModel);

      await tester.tap(find.byKey(const Key('fire-reveal')));
      await tester.pump();
      expect(gateway.calls, contains('reveal:e1:content'));

      await tester.pumpWidget(const SizedBox.shrink());
      gateway.hold?.complete(
        const MemoryActionResult(
          status: MemoryActionStatus.success,
          message: '仅本次展示。',
          text: '揭示出的原文',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('揭示出的原文'), findsNothing);
      expect(find.byKey(const Key('memory-action-result')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('列表与详情一致性：同一份计划、同一执行器', () {
    // 同屏挂两侧：左边是列表条目同款的 [MemoryActionButtons]，右边是
    // 真实详情页 [MemoryItemView]，同一 itemId、同一记忆状态。可用性
    // 与确认流程的一致性由两处都取共享 [MemoryActionPlan] 与
    // [runMemoryAction] 保证，这里的用例把这个承诺逐颗锁住。
    Finder listAction(String name) => find.descendant(
      of: find.byKey(const Key('consistency-list')),
      matching: find.byKey(Key('memory-action-e1-$name')),
    );

    /// 详情侧作用域 key 随状态变化（`consistency-detail-<tag>`）：
    /// 同一挂具换状态重挂时必须换 key 强制重建 State，否则
    /// [MemoryItemView] 复用旧 State 不重新拉取详情，旧状态会污染
    /// 下一段断言。
    String detailTag = '';

    Finder detailAction(String name) => find.descendant(
      of: find.byKey(Key('consistency-detail-$detailTag')),
      matching: find.byKey(Key('memory-action-e1-$name')),
    );

    Future<void> pumpBothSides(
      WidgetTester tester,
      _HoldGateway gateway,
      MemoryCenterViewModel viewModel, {
      required String stateTag,
      required MemoryControlStatus? control,
      required bool masked,
    }) async {
      detailTag = stateTag;
      gateway.detail = EpisodeEntryDetail(
        date: '2026-02-01',
        dayId: 'day-1',
        entryKind: 'user',
        content: '原话内容',
        masked: masked,
        control: control,
        at: DateTime(2026, 2, 1, 21, 30),
        evidence: null,
        evidenceMasked: false,
        sessionId: null,
        daySummary: null,
        finalized: true,
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<MemoryCenterViewModel>.value(
          value: viewModel,
          child: MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  Expanded(
                    child: ListView(
                      children: [
                        MemoryActionButtons(
                          key: const Key('consistency-list'),
                          itemId: 'e1',
                          control: control,
                          masked: masked,
                          editable: true,
                          currentText: '原话内容',
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: MemoryItemView(
                      key: Key('consistency-detail-$stateTag'),
                      itemId: 'e1',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    void expectOffered(
      WidgetTester tester, {
      required List<String> offered,
      required List<String> absent,
    }) {
      for (final name in offered) {
        expect(listAction(name), findsOneWidget, reason: '列表侧 $name');
        expect(detailAction(name), findsOneWidget, reason: '详情侧 $name');
        expect(
          tester.widget<IconButton>(listAction(name)).onPressed,
          isNotNull,
          reason: '列表侧 $name 可点',
        );
        expect(
          tester.widget<TextButton>(detailAction(name)).onPressed,
          isNotNull,
          reason: '详情侧 $name 可点',
        );
      }
      for (final name in absent) {
        expect(listAction(name), findsNothing, reason: '列表侧 $name');
        expect(detailAction(name), findsNothing, reason: '详情侧 $name');
      }
    }

    testWidgets('普通条目：两侧同键在场同可点，禁提与删除弹同一份确认，冻结直接生效', (tester) async {
      final gateway = _HoldGateway();
      final viewModel = MemoryCenterViewModel(gateway, autoStart: false);
      await pumpBothSides(
        tester,
        gateway,
        viewModel,
        stateTag: 'normal',
        control: null,
        masked: false,
      );
      expectOffered(
        tester,
        offered: const ['edit', 'freeze', 'ban', 'delete'],
        absent: const ['reveal', 'unfreeze', 'unban'],
      );

      // 冻结两侧都直接生效，不弹任何确认对话框。
      await tester.tap(listAction('freeze'));
      await tester.pumpAndSettle();
      expect(gateway.calls, contains('freeze:e1'));
      expect(find.byKey(const Key('memory-ban-confirm')), findsNothing);
      expect(find.byKey(const Key('memory-delete-confirm')), findsNothing);
      await tester.tap(detailAction('freeze'));
      await tester.pumpAndSettle();
      expect(gateway.calls.where((call) => call == 'freeze:e1'), hasLength(2));

      // 禁提：两侧都先弹同一确认对话框；列表侧取消不落盘，详情侧确认才执行。
      await tester.tap(listAction('ban'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('memory-ban-confirm')), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '先不用'));
      await tester.pumpAndSettle();
      expect(gateway.calls, isNot(contains('ban:e1')));

      await tester.tap(detailAction('ban'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('memory-ban-confirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('memory-ban-confirm')));
      await tester.pumpAndSettle();
      expect(gateway.calls, contains('ban:e1'));

      // 删除：两侧都先弹同一影响范围预览，确认后才执行。
      gateway.deleteImpact = const MemoryDeleteImpact(
        lines: ['最近发生里的 1 条记录'],
        sessionsKept: true,
      );
      await tester.tap(listAction('delete'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('memory-delete-confirm')), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '先不用'));
      await tester.pumpAndSettle();
      expect(gateway.calls, isNot(contains('delete:e1')));

      await tester.tap(detailAction('delete'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('memory-delete-confirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('memory-delete-confirm')));
      await tester.pumpAndSettle();
      expect(gateway.calls, contains('delete:e1'));
    });

    testWidgets('已冻结与已禁提条目：两侧都只给当下可用的动作，可点状态一致', (tester) async {
      final gateway = _HoldGateway();
      final viewModel = MemoryCenterViewModel(gateway, autoStart: false);

      await pumpBothSides(
        tester,
        gateway,
        viewModel,
        stateTag: 'frozen',
        control: MemoryControlStatus.frozen,
        masked: false,
      );
      expectOffered(
        tester,
        offered: const ['edit', 'unfreeze', 'delete'],
        absent: const ['freeze', 'ban', 'unban', 'reveal'],
      );
      await tester.tap(detailAction('unfreeze'));
      await tester.pumpAndSettle();
      expect(gateway.calls, contains('unfreeze:e1'));

      await pumpBothSides(
        tester,
        gateway,
        viewModel,
        stateTag: 'banned',
        control: MemoryControlStatus.banned,
        masked: false,
      );
      expectOffered(
        tester,
        offered: const ['edit', 'unban', 'delete'],
        absent: const ['freeze', 'ban', 'unfreeze', 'reveal'],
      );
      await tester.tap(listAction('unban'));
      await tester.pumpAndSettle();
      expect(gateway.calls, contains('unban:e1'));
    });

    testWidgets('遮罩条目：修正两侧都退场，揭示列表在动作组、详情在字段旁且走同一执行器', (tester) async {
      final gateway = _HoldGateway()..revealText = '揭示出的原文';
      final viewModel = MemoryCenterViewModel(gateway, autoStart: false);
      await pumpBothSides(
        tester,
        gateway,
        viewModel,
        stateTag: 'masked',
        control: null,
        masked: true,
      );

      // 修正退场（不揭示原文就不能改）：两侧一致。
      expect(listAction('edit'), findsNothing);
      expect(detailAction('edit'), findsNothing);

      // 控制与删除照常，两侧同键同可点。
      expectOffered(
        tester,
        offered: const ['freeze', 'ban', 'delete'],
        absent: const ['unfreeze', 'unban', 'edit'],
      );

      // 揭示的呈现差异是有意的：列表侧给动作组里的一颗
      // memory-action-e1-reveal，详情侧不给这颗，揭示入口在敏感字段旁
      // （memory-reveal-content）。两处都走同一执行器：点详情侧入口后
      // 原文写回本页临时揭示状态，与列表侧一次性对话框同一份流程。
      expect(listAction('reveal'), findsOneWidget);
      expect(detailAction('reveal'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(Key('consistency-detail-$detailTag')),
          matching: find.byKey(const Key('memory-reveal-content')),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(Key('consistency-detail-$detailTag')),
          matching: find.byKey(const Key('memory-reveal-content')),
        ),
      );
      await tester.pumpAndSettle();
      expect(gateway.calls, contains('reveal:e1:content'));
      expect(find.text('揭示出的原文'), findsOneWidget);
    });

    testWidgets('写入挂起期间：在场按钮两侧同时灰掉，可用性本身都不变', (tester) async {
      final gateway = _HoldGateway();
      final viewModel = MemoryCenterViewModel(gateway, autoStart: false);
      await pumpBothSides(
        tester,
        gateway,
        viewModel,
        stateTag: 'normal',
        control: null,
        masked: false,
      );

      gateway.hold = Completer<MemoryActionResult>();
      await tester.tap(listAction('freeze'));
      await tester.pump();
      expect(gateway.calls, contains('freeze:e1'));
      for (final name in const ['edit', 'freeze', 'ban', 'delete']) {
        expect(listAction(name), findsOneWidget, reason: '列表侧 $name 仍在场');
        expect(detailAction(name), findsOneWidget, reason: '详情侧 $name 仍在场');
        expect(
          tester.widget<IconButton>(listAction(name)).onPressed,
          isNull,
          reason: '列表侧 $name 灰掉',
        );
        expect(
          tester.widget<TextButton>(detailAction(name)).onPressed,
          isNull,
          reason: '详情侧 $name 灰掉',
        );
      }

      gateway.hold!.complete(
        const MemoryActionResult(
          status: MemoryActionStatus.success,
          message: '好了。',
        ),
      );
      await tester.pumpAndSettle();
      for (final name in const ['edit', 'freeze', 'ban', 'delete']) {
        expect(
          tester.widget<IconButton>(listAction(name)).onPressed,
          isNotNull,
          reason: '列表侧 $name 恢复可点',
        );
        expect(
          tester.widget<TextButton>(detailAction(name)).onPressed,
          isNotNull,
          reason: '详情侧 $name 恢复可点',
        );
      }
    });

    testWidgets('写入挂起期间：详情字段旁揭示入口与列表侧揭示按钮同步灰掉', (tester) async {
      final gateway = _HoldGateway()..revealText = '揭示出的原文';
      final viewModel = MemoryCenterViewModel(gateway, autoStart: false);
      await pumpBothSides(
        tester,
        gateway,
        viewModel,
        stateTag: 'masked',
        control: null,
        masked: true,
      );
      final detailReveal = find.descendant(
        of: find.byKey(Key('consistency-detail-$detailTag')),
        matching: find.byKey(const Key('memory-reveal-content')),
      );
      expect(tester.widget<TextButton>(detailReveal).onPressed, isNotNull);

      // 揭示只取一次原文、不置忙碌态，busy 由写入动作驱动：挂起一个
      // 冻结，两侧揭示入口应按同一份计划的 busy 规则同步灰掉。
      gateway.hold = Completer<MemoryActionResult>();
      await tester.tap(listAction('freeze'));
      await tester.pump();
      expect(gateway.calls, contains('freeze:e1'));
      expect(
        tester.widget<IconButton>(listAction('reveal')).onPressed,
        isNull,
        reason: '列表侧揭示按钮 busy 灰掉',
      );
      expect(
        tester.widget<TextButton>(detailReveal).onPressed,
        isNull,
        reason: '详情字段旁揭示入口 busy 灰掉',
      );

      gateway.hold!.complete(
        const MemoryActionResult(
          status: MemoryActionStatus.success,
          message: '好了。',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<IconButton>(listAction('reveal')).onPressed,
        isNotNull,
        reason: '列表侧揭示按钮恢复可点',
      );
      expect(
        tester.widget<TextButton>(detailReveal).onPressed,
        isNotNull,
        reason: '详情字段旁揭示入口恢复可点',
      );
    });
  });
}

/// 执行器最小挂具：一个按钮分别以冻结与揭示动作调用 [runMemoryAction]。
Future<void> _pumpRunnerHarness(
  WidgetTester tester,
  MemoryCenterViewModel viewModel,
) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<MemoryCenterViewModel>.value(
      value: viewModel,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  key: const Key('fire-freeze'),
                  onPressed: () => unawaited(
                    runMemoryAction(
                      context,
                      action: MemoryAction.freeze,
                      itemId: 'e1',
                    ),
                  ),
                  child: const Text('冻结'),
                ),
                TextButton(
                  key: const Key('fire-reveal'),
                  onPressed: () => unawaited(
                    runMemoryAction(
                      context,
                      action: MemoryAction.reveal,
                      itemId: 'e1',
                    ),
                  ),
                  child: const Text('揭示'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// 挂起式桩网关：动作停在 [hold] 上，供用例控制「结果晚于界面销毁到达」。
final class _HoldGateway implements MemoryGateway {
  final calls = <String>[];
  Completer<MemoryActionResult>? hold;

  /// 详情页与删除预览的可配置返回：一致性挂具用同一份记忆状态同时
  /// 喂列表侧与详情侧。
  MemoryItemDetail? detail;
  MemoryDeleteImpact? deleteImpact;

  /// 揭示结果带出的原文；null 表示揭示成功但没有原文（不落揭示态）。
  String? revealText;

  Future<MemoryActionResult> _held(String call) {
    calls.add(call);
    final pending = hold;
    if (pending != null) {
      return pending.future;
    }
    return Future.value(
      MemoryActionResult(
        status: MemoryActionStatus.success,
        message: call.startsWith('reveal:') ? '仅本次展示。' : '好了。',
        text: call.startsWith('reveal:') ? revealText : null,
      ),
    );
  }

  @override
  Future<MemoryActionResult> freezeItem(String id) => _held('freeze:$id');

  @override
  Future<MemoryActionResult> revealItem(
    String id, {
    String field = 'content',
  }) => _held('reveal:$id:$field');

  @override
  Future<MemoryActionResult> banItem(String id) => _held('ban:$id');

  @override
  Future<MemoryActionResult> deleteItem(String id) => _held('delete:$id');

  @override
  Future<MemoryActionResult> editItem(String id, String text) =>
      _held('edit:$id:$text');

  @override
  Future<MemoryOverview> fetchOverview() async => MemoryOverview(
    generatedAt: DateTime(2026),
    recent: const MemoryRecentSection(days: []),
    longTerm: const MemoryLongTermSection(
      present: false,
      readable: true,
      organizedAt: null,
      groups: [],
    ),
    persona: const MemoryPersonaSection(branches: []),
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

  @override
  Future<MemoryItemDetail?> fetchItemDetail(String id) async => detail;

  @override
  Future<MemoryActionResult> unfreezeItem(String id) => _held('unfreeze:$id');

  @override
  Future<MemoryActionResult> unbanItem(String id) => _held('unban:$id');

  @override
  Future<MemoryDeleteImpact?> previewDelete(String id) async => deleteImpact;
}
