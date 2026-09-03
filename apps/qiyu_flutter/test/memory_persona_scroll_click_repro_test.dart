// 复现回路（诊断用）：记忆中心「关于你」往下滚之后，全站点击失效。
// 走真实路由表与壳，平台压到 Windows 桌面档（真实使用形态）。

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/memory/memory_client.dart';
import 'package:qiyu_flutter/features/memory/memory_view_model.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';

void main() {
  Future<void> pumpMemoryCenter(WidgetTester tester, MemoryOverview overview) async {
    final viewModel = MemoryCenterViewModel(
      _FakeMemoryGateway(overview),
      autoStart: false,
    );
    await viewModel.refresh();
    await tester.pumpWidget(
      ChangeNotifierProvider<MemoryCenterViewModel>.value(
        value: viewModel,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          routerConfig: GoRouter(routes: qiyuRoutes(), initialLocation: '/memory'),
          builder: (context, child) => Theme(
            data: qiyuDarkTheme(reduceMotion: false),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('鼠标滚轮滚过「关于你」之后，其余按钮仍可点击', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    try {
      await pumpMemoryCenter(tester, _scrollablePersonaOverview());
      await tester.tap(find.byKey(const Key('memory-tab-persona')));
      await tester.pumpAndSettle();
      expect(find.text('画像结论 1'), findsOneWidget);

      final list = find
          .descendant(of: find.byType(TabBarView), matching: find.byType(ListView))
          .first;
      final center = tester.getCenter(list);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: center);
      addTearDown(mouse.removePointer);

      final positionBefore = tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)).first,
          )
          .position
          .pixels;
      for (var i = 0; i < 8; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(position: center, scrollDelta: const Offset(0, 100)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      final positionAfter = tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)).first,
          )
          .position
          .pixels;
      expect(
        positionAfter,
        greaterThan(positionBefore),
        reason: '前提：滚轮确实把「关于你」的列表滚下去了',
      );

      // 滚动之后点「长期印象」：必须切得过去。
      final longtermCenter =
          tester.getCenter(find.byKey(const Key('memory-tab-longterm')));
      await mouse.moveTo(longtermCenter);
      await tester.pump();
      await mouse.down(longtermCenter);
      await tester.pump(const Duration(milliseconds: 60));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.text('长期印象条目'), findsOneWidget, reason: '滚动后点击应仍有效');

      // 滚动之后点画像根卡：必须进得了详情。先把它滚回视口内再点击。
      await tester.tap(find.byKey(const Key('memory-tab-persona')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('memory-root-root-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('memory-root-root-3')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('memory-item-back')), findsOneWidget, reason: '卡片点击应仍有效');
    } finally {
      debugDefaultTargetPlatformOverride = null;
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('触摸拖动滚过「关于你」之后，其余按钮仍可点击', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    try {
      await pumpMemoryCenter(tester, _scrollablePersonaOverview());
      await tester.tap(find.byKey(const Key('memory-tab-persona')));
      await tester.pumpAndSettle();

      final list = find
          .descendant(of: find.byType(TabBarView), matching: find.byType(ListView))
          .first;
      await tester.drag(list, const Offset(0, -500));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('memory-tab-longterm')));
      await tester.pumpAndSettle();
      expect(find.text('长期印象条目'), findsOneWidget, reason: '滚动后点击应仍有效');
    } finally {
      debugDefaultTargetPlatformOverride = null;
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('悬停刷新按钮后再滚动列表，其余按钮仍可点击', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    try {
      await pumpMemoryCenter(tester, _scrollablePersonaOverview());
      await tester.tap(find.byKey(const Key('memory-tab-persona')));
      await tester.pumpAndSettle();

      final list = find
          .descendant(of: find.byType(TabBarView), matching: find.byType(ListView))
          .first;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: tester.getCenter(find.byKey(const Key('refresh-memory'))),
      );
      addTearDown(mouse.removePointer);
      // 悬停足够久，让 tooltip 浮出（真实用户滚轮前多半正停在某个按钮上）。
      await tester.pump(const Duration(seconds: 2));

      final center = tester.getCenter(list);
      await mouse.moveTo(center);
      for (var i = 0; i < 8; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(position: center, scrollDelta: const Offset(0, 100)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('memory-tab-longterm')));
      await tester.pumpAndSettle();
      expect(find.text('长期印象条目'), findsOneWidget, reason: '滚动后点击应仍有效');
    } finally {
      debugDefaultTargetPlatformOverride = null;
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('恢复横幅展开后滚动，其余按钮仍可点击', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    try {
      await pumpMemoryCenter(tester, _recoveryBannerOverview());
      expect(find.byKey(const Key('memory-recovery-banner')), findsOneWidget);

      await tester.tap(find.byKey(const Key('memory-recovery-banner')));
      await tester.pumpAndSettle();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(640, 500));
      addTearDown(mouse.removePointer);
      for (var i = 0; i < 8; i++) {
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(640, 500),
            scrollDelta: Offset(0, 100),
          ),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('memory-tab-persona')));
      await tester.pumpAndSettle();
      expect(find.text('性格表达'), findsOneWidget, reason: '滚动后 tab 点击应仍有效');
    } finally {
      debugDefaultTargetPlatformOverride = null;
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('悬停卡片操作按钮时滚动列表，其余按钮仍可点击', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    try {
      await pumpMemoryCenter(tester, _scrollablePersonaOverview());
      await tester.tap(find.byKey(const Key('memory-tab-persona')));
      await tester.pumpAndSettle();

      final list = find
          .descendant(of: find.byType(TabBarView), matching: find.byType(ListView))
          .first;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: tester.getCenter(find.byKey(const Key('memory-action-root-1-freeze'))),
      );
      addTearDown(mouse.removePointer);
      // 悬停足够久，让卡片操作按钮的 tooltip 浮出。
      await tester.pump(const Duration(seconds: 2));

      final center = tester.getCenter(list);
      for (var i = 0; i < 8; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(position: center, scrollDelta: const Offset(0, 100)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('memory-tab-longterm')));
      await tester.pumpAndSettle();
      expect(find.text('长期印象条目'), findsOneWidget, reason: '滚动后点击应仍有效');
    } finally {
      debugDefaultTargetPlatformOverride = null;
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('拖动滚动条滑块之后，其余按钮仍可点击', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    try {
      await pumpMemoryCenter(tester, _scrollablePersonaOverview());
      await tester.tap(find.byKey(const Key('memory-tab-persona')));
      await tester.pumpAndSettle();

      final list = find
          .descendant(of: find.byType(TabBarView), matching: find.byType(ListView))
          .first;
      final rect = tester.getRect(list);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: rect.center);
      addTearDown(mouse.removePointer);
      // 先滚一下让滚动条浮出。
      for (var i = 0; i < 3; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(position: rect.center, scrollDelta: const Offset(0, 100)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump();

      // 拖动右缘的滚动条滑块往下。
      final thumbTop = Offset(rect.right - 4, rect.top + 40);
      await mouse.moveTo(thumbTop);
      await tester.pump();
      await mouse.down(thumbTop);
      await mouse.moveBy(const Offset(0, 120));
      await tester.pump(const Duration(milliseconds: 50));
      await mouse.moveBy(const Offset(0, 120));
      await tester.pump(const Duration(milliseconds: 50));
      await mouse.up();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('memory-tab-longterm')));
      await tester.pumpAndSettle();
      expect(find.text('长期印象条目'), findsOneWidget, reason: '拖滚动条后点击应仍有效');
    } finally {
      debugDefaultTargetPlatformOverride = null;
      await tester.binding.setSurfaceSize(null);
    }
  });
}

MemoryOverview _recoveryBannerOverview() {
  final overview = _scrollablePersonaOverview();
  return MemoryOverview(
    generatedAt: overview.generatedAt,
    recent: overview.recent,
    longTerm: overview.longTerm,
    persona: overview.persona,
    relationship: overview.relationship,
    recovery: MemoryRecoverySection(
      healthy: false,
      quarantinedFiles: 1,
      findings: [
        MemoryRecoveryFindingCard(
          layer: '长期印象',
          kind: 'corrupt',
          outcome: MemoryRecoveryOutcome.pending,
          evidence: '无有效 Dream 备份',
          loss: '长期印象内容',
          quarantined: true,
        ),
      ],
    ),
  );
}

MemoryOverview _scrollablePersonaOverview() {
  final roots = [
    for (var i = 1; i <= 80; i++)
      MemoryPersonaRootCard(
        id: 'root-$i',
        claim: '画像结论 $i',
        masked: false,
        control: null,
        middleCount: 1,
        leafCount: 2,
        earliestEvidence: '2026-07-01',
        latestEvidence: '2026-07-20',
      ),
  ];
  return MemoryOverview(
    generatedAt: DateTime.parse('2026-08-30T13:00:00.000Z'),
    recent: MemoryRecentSection(days: []),
    longTerm: const MemoryLongTermSection(
      present: true,
      readable: true,
      organizedAt: null,
      groups: [
        MemoryLongTermGroup(
          section: '人与关系',
          items: [
            MemoryLongTermItem(
              id: 'lt-1',
              content: '长期印象条目',
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
          roots: roots,
          unrooted: const [],
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
}

final class _FakeMemoryGateway implements MemoryGateway {
  _FakeMemoryGateway(this._overview);

  final MemoryOverview _overview;

  @override
  Future<MemoryOverview> fetchOverview() async => _overview;

  @override
  Future<MemoryItemDetail?> fetchItemDetail(String id) async =>
      const PersonaRootDetail(
        branch: 'expression',
        branchTitle: '性格表达',
        claim: '详情占位',
        masked: false,
        control: null,
        middles: [],
      );

  @override
  Future<MemoryActionResult> editItem(String id, String text) async => _ok();

  @override
  Future<MemoryActionResult> freezeItem(String id) async => _ok();

  @override
  Future<MemoryActionResult> unfreezeItem(String id) async => _ok();

  @override
  Future<MemoryActionResult> banItem(String id) async => _ok();

  @override
  Future<MemoryActionResult> unbanItem(String id) async => _ok();

  @override
  Future<MemoryDeleteImpact?> previewDelete(String id) async => null;

  @override
  Future<MemoryActionResult> deleteItem(String id) async => _ok();

  @override
  Future<MemoryActionResult> revealItem(String id, {String field = 'content'}) async =>
      _ok();

  MemoryActionResult _ok() => const MemoryActionResult(
    status: MemoryActionStatus.success,
    message: '好了。',
  );
}
