import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/history/history_client.dart';
import 'package:qiyu_flutter/features/history/history_view_model.dart';
import 'package:qiyu_flutter/features/memory/memory_client.dart';
import 'package:qiyu_flutter/features/memory/memory_view_model.dart';
import 'package:qiyu_flutter/features/onboarding/first_meeting_view.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_client.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/web_search_settings_client.dart';
import 'package:qiyu_flutter/features/settings/web_search_settings_view_model.dart';
import 'package:qiyu_flutter/features/shell/qiyu_shell.dart';

void main() {
  testWidgets('keyboard alone navigates from home into the chat', (
    tester,
  ) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();
    await _goHome(tester);

    // 纯键盘主流程（ticket 24）：Tab 移到第一个入口，Enter 激活。
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat-input')), findsOneWidget);
  });

  testWidgets(
    'enter sends while shift+enter and control+enter insert newlines',
    (tester) async {
      final chatGateway = _FakeChatGateway();
      await tester.pumpWidget(await _app(chatGateway: chatGateway));
      await tester.pumpAndSettle();
      await _goHome(tester);
      await tester.tap(find.byKey(const Key('home-go-chat')));
      await tester.pumpAndSettle();

      final input = find.byKey(const Key('chat-input'));

      await tester.enterText(input, '第一行');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(chatGateway.sentTexts, isEmpty);
      expect(tester.widget<TextField>(input).controller!.text, contains('\n'));

      await tester.enterText(input, '第二行');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(chatGateway.sentTexts, isEmpty);
      expect(tester.widget<TextField>(input).controller!.text, contains('\n'));

      await tester.enterText(input, '今晚睡不着');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(chatGateway.sentTexts, ['今晚睡不着']);
      expect(find.text('今晚睡不着'), findsOneWidget);
    },
  );

  testWidgets('escape closes the delete dialog without deleting', (
    tester,
  ) async {
    final historyGateway = _FakeHistoryGateway();
    await tester.pumpWidget(await _app(historyGateway: historyGateway));
    await tester.pumpAndSettle();
    await _goHome(tester);
    await tester.tap(find.byKey(const Key('home-go-history')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('delete-session-session-9')));
    await tester.pumpAndSettle();
    expect(find.text('删除这段会话？'), findsOneWidget);

    // 键盘返回行为（ticket 24）：Esc 关闭对话框且不执行危险操作。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('删除这段会话？'), findsNothing);
    expect(historyGateway.deleted, isEmpty);
  });

  for (final size in const [
    Size(960, 600),
    Size(1366, 768),
    Size(1920, 1080),
  ]) {
    testWidgets('first-run pages stay usable at ${size.width.toInt()}x'
        '${size.height.toInt()}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        await _app(
          chatGateway: _FakeChatGateway(
            restored: const LocalChatSnapshot(
              sessionId: 'session-1',
              messages: [
                LocalChatMessage(
                  requestId: 'r-1',
                  speaker: LocalChatSpeaker.user,
                  text: '我回来了',
                ),
                LocalChatMessage(
                  requestId: 'r-1',
                  speaker: LocalChatSpeaker.qiyu,
                  text: '嗯，坐吧。',
                  source: ReplySource.local,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _goHome(tester);
      expect(tester.takeException(), isNull);
      // 本用例的网关恢复出的会话已带消息：合一页此时直接落在「已有消息」
      // 状态（空态问候位只在今天还没聊过时出现），断言消息流首条已渲染。
      expect(find.byKey(const Key('chat-message-0')), findsOneWidget);

      await tester.tap(find.byKey(const Key('home-go-chat')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('我回来了'), findsOneWidget);

      await tester.tap(find.byKey(const Key('open-history')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('history-session-tile-session-9')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('history-back')));
      await tester.pumpAndSettle();
      // 历史是从聊天页 push 进来的：返回键回到聊天页而不是首页。
      expect(find.byKey(const Key('open-history')), findsOneWidget);
      await tester.tap(find.byKey(const Key('go-home')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-go-memory')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('memory-tab-recent')), findsOneWidget);

      await tester.tap(find.byKey(const Key('memory-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-go-settings')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('模型连接'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const Key('settings-privacy')),
        200,
        scrollable: _verticalScrollable(),
        maxScrolls: 20,
      );
      await tester.ensureVisible(find.byKey(const Key('settings-privacy')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-privacy')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('隐私与边界'), findsWidgets);

      await tester.tap(find.byKey(const Key('privacy-back')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('developer-mode-switch')),
        200,
        scrollable: _verticalScrollable(),
        maxScrolls: 20,
      );
      await tester.ensureVisible(
        find.byKey(const Key('developer-mode-switch')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('developer-mode-switch')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('settings-diagnostics')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-diagnostics')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('开发者诊断'), findsOneWidget);
    });
  }

  testWidgets('150% text scaling keeps home and first meeting scrollable', (
    tester,
  ) async {
    // 首页与初见页是仅有的非列表整页：字号放大后必须可滚动不溢出。
    await _pumpScaled(tester, _homeWithChatViewModel(), scale: 1.5);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('home-go-settings')), findsOneWidget);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final onboarding = OnboardingViewModel(
      _FakeOnboardingGateway(completed: false),
      _FixedProviderGateway(configured: false),
      autoStart: false,
    );
    await onboarding.initialize();
    await _pumpScaled(
      tester,
      ChangeNotifierProvider.value(
        value: onboarding,
        child: const FirstMeetingView(),
      ),
      scale: 2.0,
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('first-meeting-greeting')), findsOneWidget);
  });

  testWidgets('150% text scaling keeps chat and settings free of overflow', (
    tester,
  ) async {
    final chatViewModel = LocalChatViewModel(
      _FakeChatGateway(
        restored: const LocalChatSnapshot(
          sessionId: 'session-1',
          messages: [
            LocalChatMessage(
              requestId: 'r-1',
              speaker: LocalChatSpeaker.user,
              text: '今天有点累',
            ),
            LocalChatMessage(
              requestId: 'r-1',
              speaker: LocalChatSpeaker.qiyu,
              text: '嗯，早点歇着。',
              source: ReplySource.local,
            ),
          ],
        ),
      ),
      hostConnectionProbe: _FixedProbe(),
      autoStart: false,
    );
    await chatViewModel.initialize();
    await _pumpScaled(
      tester,
      ChangeNotifierProvider.value(
        value: chatViewModel,
        child: const LocalChatView(),
      ),
      scale: 1.5,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('今天有点累'), findsOneWidget);

    final providerViewModel = ProviderSettingsViewModel(
      _FixedProviderGateway(configured: false),
      autoStart: false,
    );
    await providerViewModel.initialize();
    final settingsViewModel = SettingsViewModel(_FakeSettingsGateway());
    await _pumpScaled(
      tester,
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: providerViewModel),
          ChangeNotifierProvider.value(
            value: SttSettingsViewModel(
              const _FixedSttSettingsGateway(),
              autoStart: false,
            ),
          ),
          ChangeNotifierProvider.value(
            value: TtsSettingsViewModel(
              const _FixedTtsSettingsGateway(),
              autoStart: false,
            ),
          ),
          ChangeNotifierProvider.value(
            value: WebSearchSettingsViewModel(
              const _FixedWebSearchSettingsGateway(),
              autoStart: false,
            ),
          ),
          ChangeNotifierProvider.value(value: settingsViewModel),
        ],
        child: const ProviderSettingsView(),
      ),
      scale: 1.5,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('200% 字阶下导航壳与合一页不溢出（§9 深底留余量）', (
    tester,
  ) async {
    // 侧边栏（240px）与抽屉（约视口 2/3）是全站最窄的两块排版，2.0 字阶最先
    // 撑破的就是它们；合一页的页头条与空态问候同在这一档受检。
    // 断的是「没有溢出异常」这个可观察结果，不去数树里有几层。
    for (final page in [
      _homeWithChatViewModel(),
      await _mergedHomeWithSession(),
    ]) {
      await _pumpScaled(tester, page, scale: 2.0, size: const Size(1200, 800));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '桌面侧边栏 + 合一页');
      expect(find.byKey(const Key('nav-history')), findsOneWidget);
    }

    // 窄屏：抽屉展开后，同一批导航文案要在约 2/3 视口宽里排。
    await _pumpScaled(
      tester,
      await _mergedHomeWithSession(),
      scale: 2.0,
      size: const Size(420, 900),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-menu-button')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '窄屏抽屉展开');
    expect(find.byKey(const Key('nav-history')), findsOneWidget);
  });

  testWidgets(
    'messages carry speaker semantics and streaming is a live region',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final chatGateway = _StreamingChatGateway();
        await tester.pumpWidget(await _app(chatGateway: chatGateway));
        await tester.pumpAndSettle();
        await _goHome(tester);
        await tester.tap(find.byKey(const Key('home-go-chat')));
        await tester.pumpAndSettle();

        // 历史消息带说话人标签：屏幕阅读器分得清谁在说（ticket 24）。
        expect(find.bySemanticsLabel(RegExp('你说')), findsWidgets);
        expect(find.bySemanticsLabel(RegExp('栖语说')), findsWidgets);

        // 发起一次回复：状态标签节点是 live region，状态变化可被播报；
        // live region 不含逐 delta 增长的正文，避免每个增量重读全文。
        await tester.enterText(find.byKey(const Key('chat-input')), '在吗');
        await tester.tap(find.byKey(const Key('chat-send')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        final statusNode = tester.getSemantics(find.bySemanticsLabel('栖语在想'));
        expect(statusNode.flagsCollection.isLiveRegion, isTrue);

        chatGateway.add(
          const LocalChatDeliveryEvent(
            kind: LocalChatEventKind.delta,
            requestId: 'stream-1',
            text: '在的。',
          ),
        );
        chatGateway.add(
          const LocalChatDeliveryEvent(
            kind: LocalChatEventKind.message,
            requestId: 'stream-1',
            messages: ['在的。'],
          ),
        );
        chatGateway.add(
          const LocalChatDeliveryEvent(
            kind: LocalChatEventKind.state,
            requestId: 'stream-1',
            source: ReplySource.local,
          ),
        );
        chatGateway.add(
          const LocalChatDeliveryEvent(
            kind: LocalChatEventKind.done,
            requestId: 'stream-1',
          ),
        );
        await chatGateway.close();
        await tester.pumpAndSettle();
        expect(find.text('在的。'), findsOneWidget);
      } finally {
        // 断言失败也要释放，避免句柄泄漏连带影响下一个用例。
        handle.dispose();
      }
    },
  );

  testWidgets('high contrast mode outlines blocks that rely on fill color', (
    tester,
  ) async {
    // 负例：普通模式不加多余边框；正例：高对比模式（如 Windows 强制
    // 颜色）下依赖底色区分的块级容器要有可见边框（ticket 24 验收 4）。
    // 主体是用户水滴气泡：定稿要求它「无描边、靠面色 bubble-user 与背景
    // 拉开层次」（design-system §7），正是只靠面色区分的块。
    BoxDecoration bubbleDecoration(WidgetTester tester) {
      final bubble = tester.widget<Container>(
        find.descendant(
          of: find.byKey(const Key('chat-message-0')),
          matching: find.byType(Container),
        ),
      );
      return bubble.decoration! as BoxDecoration;
    }

    await _pumpScaled(tester, await _mergedHomeWithSession(), scale: 1.0);
    await tester.pumpAndSettle();
    expect(
      bubbleDecoration(tester).border,
      Border.fromBorderSide(BorderSide.none),
    );

    await _pumpHighContrast(tester, await _mergedHomeWithSession());
    await tester.pumpAndSettle();
    expect(
      bubbleDecoration(tester).border!.top,
      isNot(BorderSide.none),
      reason: '高对比模式下靠面色分层的水滴气泡必须给出可见边界',
    );
  });

  testWidgets('reduced motion keeps streaming text and completion feedback', (
    tester,
  ) async {
    // 关闭动画（尊重系统减少动态效果设置）不得影响流式文本与完成
    // 反馈。应用没有自定义动画、不读取 disableAnimations，此测试锁的
    // 是行为约束：无论默认过渡是否播放，发送与完成反馈都照常出现。
    final chatViewModel = LocalChatViewModel(
      _FakeChatGateway(),
      hostConnectionProbe: _FixedProbe(),
      autoStart: false,
    );
    await chatViewModel.initialize();
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(1366, 768),
            disableAnimations: true,
          ),
          child: ChangeNotifierProvider.value(
            value: chatViewModel,
            child: const LocalChatView(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('chat-input')), '睡了吗');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    // 完成反馈与正文在关闭动画时照常出现。
    expect(find.text('睡了吗'), findsOneWidget);
    expect(find.text('咋了'), findsOneWidget);
  });
}

// ---------- 装配 ----------

Future<Widget> _app({
  StreamingLocalChatGateway? chatGateway,
  _FakeHistoryGateway? historyGateway,
}) async {
  final chat = chatGateway ?? _FakeChatGateway();
  final chatViewModel = LocalChatViewModel(
    chat,
    hostConnectionProbe: _FixedProbe(),
    autoStart: false,
  );
  await chatViewModel.initialize();
  final onboarding = OnboardingViewModel(
    _FakeOnboardingGateway(completed: true),
    _FixedProviderGateway(configured: true),
    autoStart: false,
  );
  await onboarding.initialize();
  final providerViewModel = ProviderSettingsViewModel(
    _FixedProviderGateway(configured: true),
    autoStart: false,
  );
  await providerViewModel.initialize();
  return QiyuApp(
    viewModel: chatViewModel,
    providerSettingsViewModel: providerViewModel,
    sttSettingsViewModel: SttSettingsViewModel(
      const _FixedSttSettingsGateway(),
      autoStart: false,
    ),
    ttsSettingsViewModel: TtsSettingsViewModel(
      const _FixedTtsSettingsGateway(),
      autoStart: false,
    ),
    onboardingViewModel: onboarding,
    historyViewModel: HistoryViewModel(
      historyGateway ?? _FakeHistoryGateway(),
      onSessionDeleted: (_) {},
    ),
    memoryViewModel: MemoryCenterViewModel(_FakeMemoryGateway()),
    settingsViewModel: SettingsViewModel(_FakeSettingsGateway()),
  );
}

/// 全局 GoRouter 跨用例保留栈：每个用例先强制回到首页。
Future<void> _goHome(WidgetTester tester) async {
  final context = tester.element(find.byType(Scaffold).first);
  GoRouter.of(context).go('/');
  await tester.pumpAndSettle();
}

/// 设置页自己的纵向滚动区：桌面导航壳的侧边栏同样是纵向可滚容器，按「所有
/// 纵向 Scrollable」取会命中两个，`scrollUntilVisible` 因此要求唯一。
/// 按 Key 取这一页的列表，再取它自己的 `Scrollable`（前序第一个）。
Finder _verticalScrollable() => find
    .descendant(
      of: find.byKey(const Key('settings-scroll')),
      matching: find.byType(Scrollable),
    )
    .first;

/// 合一页的空状态即首页，仍依赖应用级的聊天 view model（问候与入口
/// 副标题按当前会话状态切换），因此外壳与对话视图一起泵。
Widget _homeWithChatViewModel() => ChangeNotifierProvider.value(
  value: LocalChatViewModel(
    _FakeChatGateway(),
    hostConnectionProbe: _FixedProbe(),
    autoStart: false,
  ),
  child: const QiyuShell(child: LocalChatView()),
);

/// 带历史的合一页：高对比用例要在消息流里取用户气泡（靠面色区分的块）。
Future<Widget> _mergedHomeWithSession() async {
  final chatViewModel = LocalChatViewModel(
    _FakeChatGateway(
      restored: const LocalChatSnapshot(
        sessionId: 'session-1',
        messages: [
          LocalChatMessage(
            requestId: 'r-1',
            speaker: LocalChatSpeaker.user,
            text: '我回来了',
          ),
          LocalChatMessage(
            requestId: 'r-1',
            speaker: LocalChatSpeaker.qiyu,
            text: '嗯，坐吧。',
            source: ReplySource.local,
          ),
        ],
      ),
    ),
    hostConnectionProbe: _FixedProbe(),
    autoStart: false,
  );
  await chatViewModel.initialize();
  return ChangeNotifierProvider.value(
    value: chatViewModel,
    child: const QiyuShell(child: LocalChatView()),
  );
}

/// 按高对比模式泵入单页（验证强制颜色等场景下的边框兜底）。
Future<void> _pumpHighContrast(WidgetTester tester, Widget child) async {
  const size = Size(960, 600);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: size, highContrast: true),
        child: SafeArea(child: child),
      ),
    ),
  );
}

/// 按给定字号缩放泵入单页（页面级响应式验证用）。
Future<void> _pumpScaled(
  WidgetTester tester,
  Widget child, {
  double scale = 1.5,
  Size size = const Size(960, 600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
        child: SafeArea(child: child),
      ),
    ),
  );
}

// ---------- 假网关 ----------

final class _FakeChatGateway implements StreamingLocalChatGateway {
  _FakeChatGateway({
    this.restored = const LocalChatSnapshot(
      sessionId: 'session-1',
      messages: [],
    ),
  });

  final LocalChatSnapshot restored;
  final List<String> sentTexts = [];

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async => restored;

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '语音测试转写';

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {
    sentTexts.add(text);
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.accepted,
      requestId: requestId,
      sessionId: restored.sessionId,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.waiting,
      requestId: requestId,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.delta,
      requestId: requestId,
      text: '咋了',
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.message,
      requestId: requestId,
      messages: const ['咋了'],
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.state,
      requestId: requestId,
      source: ReplySource.local,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.done,
      requestId: requestId,
    );
  }
}

final class _StreamingChatGateway implements StreamingLocalChatGateway {
  final _controller = StreamController<LocalChatDeliveryEvent>();
  final _restored = const LocalChatSnapshot(
    sessionId: 'session-1',
    messages: [
      LocalChatMessage(
        requestId: 'r-0',
        speaker: LocalChatSpeaker.user,
        text: '之前的话',
      ),
      LocalChatMessage(
        requestId: 'r-0',
        speaker: LocalChatSpeaker.qiyu,
        text: '嗯，我记得。',
        source: ReplySource.local,
      ),
    ],
  );

  void add(LocalChatDeliveryEvent event) => _controller.add(event);
  Future<void> close() => _controller.close();

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async => _restored;

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '语音测试转写';

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.accepted,
      requestId: requestId,
      sessionId: _restored.sessionId,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.waiting,
      requestId: requestId,
    );
    yield* _controller.stream;
  }
}

final DateTime _knownTime = DateTime(2026, 8, 19, 22, 10);

final class _FakeHistoryGateway implements HistoryGateway {
  final List<String> deleted = [];

  @override
  Future<HistoryListing> fetchHistory() async => HistoryListing(
    latestSessionId: 'session-9',
    days: [
      HistoryDay(
        date: '2026-08-19',
        sessions: [
          HistorySessionSummary(
            sessionId: 'session-9',
            segment: 1,
            startedAt: _knownTime,
            updatedAt: _knownTime,
            turnCount: 4,
            preview: '聊了些近况',
          ),
        ],
      ),
    ],
    unavailable: const [],
  );

  @override
  Future<void> deleteSession(String sessionId) async {
    deleted.add(sessionId);
  }
}

final class _FakeMemoryGateway implements MemoryGateway {
  @override
  Future<MemoryOverview> fetchOverview() async => MemoryOverview(
    generatedAt: DateTime(2026, 8, 19),
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
    recovery: const MemoryRecoverySection(
      healthy: true,
      quarantinedFiles: 0,
      findings: [],
    ),
  );

  @override
  Future<MemoryItemDetail?> fetchItemDetail(String id) async => null;

  @override
  Future<MemoryActionResult> editItem(String id, String text) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已保存。',
      );

  @override
  Future<MemoryActionResult> freezeItem(String id) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已暂停使用。',
      );

  @override
  Future<MemoryActionResult> unfreezeItem(String id) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已恢复使用。',
      );

  @override
  Future<MemoryActionResult> banItem(String id) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已不再提起。',
      );

  @override
  Future<MemoryActionResult> unbanItem(String id) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已解除禁提。',
      );

  @override
  Future<MemoryDeleteImpact?> previewDelete(String id) async => null;

  @override
  Future<MemoryActionResult> deleteItem(String id) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已删除。',
      );

  @override
  Future<MemoryActionResult> revealItem(
    String id, {
    String field = 'content',
  }) async => const MemoryActionResult(
    status: MemoryActionStatus.failed,
    message: '无可展示内容。',
  );
}

final class _FakeSettingsGateway implements SettingsGateway {
  var developerMode = false;

  @override
  Future<ExperiencePreferences> readPreferences() async =>
      ExperiencePreferences(developerMode: developerMode);

  @override
  Future<ExperiencePreferences> savePreferences({
    required bool developerMode,
  }) async {
    this.developerMode = developerMode;
    return ExperiencePreferences(developerMode: developerMode);
  }

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
    finalization: null,
    dream: null,
    fileHealth: const {},
  );
}

final class _FakeOnboardingGateway implements OnboardingGateway {
  _FakeOnboardingGateway({required this.completed});

  bool completed;

  @override
  Future<OnboardingState> read() async => OnboardingState(completed: completed);

  @override
  Future<void> complete() async {
    completed = true;
  }
}

final class _FixedProviderGateway implements ProviderSettingsGateway {
  _FixedProviderGateway({required this.configured});
  final bool configured;

  @override
  Future<ProviderSettings> read() async => ProviderSettings(
    configured: configured,
    keySet: configured,
    provider: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.example.com/v1',
    model: 'chat-model',
    temperature: 0.7,
    timeoutSeconds: 60,
  );

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) async => read();

  @override
  Future<ProviderSettings> forgetApiKey() async => read();

  @override
  Future<ProviderTestResult> testConnection(
    ProviderSettingsDraft draft,
  ) async => const ProviderTestResult(
    succeeded: true,
    status: ProviderTestStatus.success,
    message: '连接成功。',
  );
}

final class _FixedProbe implements HostConnectionProbe {
  @override
  Future<bool> isHostAvailable() async => true;
}

final class _FixedWebSearchSettingsGateway implements WebSearchSettingsGateway {
  const _FixedWebSearchSettingsGateway();

  @override
  Future<WebSearchSettings> read() async =>
      const WebSearchSettings(configured: false, keySet: false);

  @override
  Future<WebSearchSettings> save(WebSearchSettingsDraft draft) =>
      throw UnimplementedError();

  @override
  Future<WebSearchSettings> forgetApiKey() => throw UnimplementedError();
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

final class _FixedTtsSettingsGateway implements TtsSettingsGateway {
  const _FixedTtsSettingsGateway();

  @override
  Future<TtsSettings> read() async =>
      const TtsSettings(configured: false, keySet: false);

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) async => TtsSettings(
    configured: true,
    keySet: draft.apiKey != null,
    baseUrl: draft.baseUrl,
    model: draft.model,
  );

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) async =>
      throw UnimplementedError();

  @override
  Future<TtsSettings> forgetApiKey() async =>
      const TtsSettings(configured: false, keySet: false);

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) async =>
      const TtsConnectionTest(succeeded: false, message: '还没有保存语音合成服务配置。');
}
