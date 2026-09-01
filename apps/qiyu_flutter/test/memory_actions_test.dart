import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/memory/memory_actions.dart';
import 'package:qiyu_flutter/features/memory/memory_client.dart';
import 'package:qiyu_flutter/features/memory/memory_view_model.dart';

void main() {
  group('MemoryActionPlan 可用性矩阵（唯一一份）', () {
    test('普通条目：修正、暂停使用、不再提起、删除在场，揭示与两种解除不在场', () {
      const plan = MemoryActionPlan(
        state: MemoryItemActionState(control: null, masked: false, editable: true),
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
        state: MemoryItemActionState(control: MemoryControlStatus.frozen, masked: false, editable: true),
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
        state: MemoryItemActionState(control: MemoryControlStatus.banned, masked: false, editable: true),
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
      expect(plan.confirmationOf(MemoryAction.ban), MemoryActionConfirmation.ban);
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
        const MemoryActionResult(status: MemoryActionStatus.success, message: '好了。'),
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
        const MemoryActionResult(status: MemoryActionStatus.success, message: '好了。'),
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

  Future<MemoryActionResult> _held(String call) {
    calls.add(call);
    final pending = hold;
    if (pending != null) {
      return pending.future;
    }
    return Future.value(
      const MemoryActionResult(status: MemoryActionStatus.success, message: '好了。'),
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
  Future<MemoryItemDetail?> fetchItemDetail(String id) async => null;

  @override
  Future<MemoryActionResult> unfreezeItem(String id) => _held('unfreeze:$id');

  @override
  Future<MemoryActionResult> unbanItem(String id) => _held('unban:$id');

  @override
  Future<MemoryDeleteImpact?> previewDelete(String id) async => null;
}
