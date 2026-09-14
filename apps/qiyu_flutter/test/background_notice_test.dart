import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_flutter/features/baseline/background_status_client.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/shell/qiyu_background_notice.dart';
import 'package:qiyu_flutter/features/shell/qiyu_shell.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart'
    show ProviderTestResult;
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

/// 后台记忆整理提示位（ticket 21）：壳层状态区安静位的出现、恢复与
/// 隐去，以及与连接状态的同区共存。定位一律按 Key（Spec Testing
/// Decisions 第 8 条）。
void main() {
  group('后台记忆整理提示位 QiyuBackgroundNotice', () {
    testWidgets('无失败时整块不出现，同区连接状态照常在场', (tester) async {
      await _pumpShell(tester, await _viewModel(_StubBackgroundGateway(null)));

      expect(find.byKey(const Key('background-notice')), findsNothing);
      expect(find.text(QiyuBackgroundNotice.failureLabel), findsNothing);
      expect(find.byKey(const Key('conn-status')), findsOneWidget);
    });

    testWidgets('失败未恢复时出现安静位：文案逐字、着 danger，不做弹窗', (
      tester,
    ) async {
      await _pumpShell(
        tester,
        await _viewModel(_StubBackgroundGateway(_failure(recovered: false))),
      );

      expect(find.byKey(const Key('background-notice')), findsOneWidget);
      expect(find.text('今晚的记忆整理没完成，下次会自动补'), findsOneWidget);
      final text = tester.widget<Text>(
        find.byKey(const Key('background-notice-text')),
      );
      expect(text.style!.color, QiyuColors.danger);
      // 同区的既有状态指示不动。
      expect(find.byKey(const Key('conn-status')), findsOneWidget);
    });

    testWidgets('恢复后短暂展示「已恢复」再隐去', (tester) async {
      final gateway = _StubBackgroundGateway(_failure(recovered: false));
      final viewModel = await _viewModel(gateway);
      await _pumpShell(tester, viewModel);
      expect(find.text('今晚的记忆整理没完成，下次会自动补'), findsOneWidget);

      // 该任务重试成功：状态翻转为已恢复，短暂展示「已恢复」。
      gateway.result = _failure(recovered: true);
      await viewModel.checkHostNow();
      await tester.pump();
      expect(find.text('记忆整理已恢复'), findsOneWidget);
      expect(find.text('今晚的记忆整理没完成，下次会自动补'), findsNothing);
      final recoveredText = tester.widget<Text>(
        find.byKey(const Key('background-notice-text')),
      );
      expect(recoveredText.style!.color, QiyuColors.muted);

      // 停留窗口结束：隐去，整块不再占位。
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(find.byKey(const Key('background-notice')), findsNothing);
      expect(find.byKey(const Key('conn-status')), findsOneWidget);
    });
  });

  group('后台状态取用规则（现状锁定，先于结构收拢建立）', () {
    testWidgets('Host 不可达时不读取后台状态：安静位保持缺席', (tester) async {
      final gateway = _StubBackgroundGateway(_failure(recovered: false));
      final viewModel = _nonAutoViewModel(
        gateway,
        probe: _StubProbe(available: false),
      );

      await viewModel.checkHostNow();

      expect(gateway.calls, 0, reason: '只在 Host 可达时读取后台状态');
      expect(viewModel.backgroundFailure, isNull);
      expect(viewModel.hostStopped, isTrue);
    });

    testWidgets('状态读取失败保留上一份快照：安静位不闪烁', (tester) async {
      final gateway = _StubBackgroundGateway(_failure(recovered: false));
      final viewModel = _nonAutoViewModel(gateway);
      await viewModel.checkHostNow();
      final lastSnapshot = viewModel.backgroundFailure;
      expect(lastSnapshot, isNotNull);

      // 下一轮读取抛错：快照保持原样，绝不闪成无失败。
      gateway.throwError = Exception('cadence-status 读取失败');
      gateway.result = null;
      await viewModel.checkHostNow();

      expect(viewModel.backgroundFailure, lastSnapshot);

      await _pumpShell(tester, viewModel);
      expect(find.text('今晚的记忆整理没完成，下次会自动补'), findsOneWidget);
    });

    testWidgets('连接探测进行中不重复探测，后台读取每轮至多一次', (tester) async {
      final probe = _StubProbe(available: true)..gate = Completer<bool>();
      final gateway = _StubBackgroundGateway(_failure(recovered: false))
        ..gate = Completer<BackgroundFailureStatus?>();
      final viewModel = _nonAutoViewModel(gateway, probe: probe);
      addTearDown(viewModel.dispose);

      final first = viewModel.checkHostNow();
      final second = viewModel.checkHostNow();
      await tester.pump();
      expect(probe.calls, 1, reason: '探测进行中再次触发不重复探测');

      // 放行探测并撤掉挂闸：若重入保护失效，后续调用立即返回而不是挂死。
      probe.gate!.complete(true);
      probe.gate = null;
      await tester.pump();
      expect(gateway.calls, 1, reason: 'Host 可达后随同一轮取用后台状态');

      // 后台读取挂起期间再次触发：整轮重入被挡，不重复取用。
      final third = viewModel.checkHostNow();
      expect(gateway.calls, 1, reason: '后台读取进行中不重复取用');
      gateway.gate!.complete(_failure(recovered: false));
      await first;
      await second;
      await third;
    });

    testWidgets('状态未变化时不重复通知界面', (tester) async {
      final gateway = _StubBackgroundGateway(_failure(recovered: false));
      final viewModel = _nonAutoViewModel(gateway);
      await viewModel.checkHostNow();

      var notifications = 0;
      viewModel.addListener(() => notifications += 1);

      await viewModel.checkHostNow();
      expect(
        notifications,
        0,
        reason: '连接与后台状态都没变时不再通知（重复状态不重复播报）',
      );
    });

    testWidgets('恢复提示窗口满 4 秒：窗口未到不提前隐去', (tester) async {
      final gateway = _StubBackgroundGateway(_failure(recovered: false));
      final viewModel = _nonAutoViewModel(gateway);
      await viewModel.checkHostNow();
      await _pumpShell(tester, viewModel);
      expect(find.text('今晚的记忆整理没完成，下次会自动补'), findsOneWidget);

      gateway.result = _failure(recovered: true);
      await viewModel.checkHostNow();
      await tester.pump();
      expect(find.text('记忆整理已恢复'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      expect(
        find.text('记忆整理已恢复'),
        findsOneWidget,
        reason: '4 秒窗口未满，恢复提示不得提前隐去',
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const Key('background-notice')), findsNothing);
    });
  });

  group('连接监控释放后的在途结果（票 06）：静默丢弃与空操作', () {
    testWidgets('连接探测在途时释放：放闸后结果静默丢弃，不通知不触碰状态', (
      tester,
    ) async {
      final probe = _StubProbe(available: true)..gate = Completer<bool>();
      final gateway = _StubBackgroundGateway(_failure(recovered: false));
      final viewModel = _nonAutoViewModel(gateway, probe: probe);

      final pending = viewModel.checkHostNow();
      await tester.pump();
      expect(probe.calls, 1);
      expect(
        viewModel.hostStatusKnown,
        isFalse,
        reason: '探测未返回前连接保持未探明',
      );

      var notifications = 0;
      viewModel.addListener(() => notifications += 1);

      // 探测还在途就释放监控：请求不被取消（适配器无取消能力），但结果
      // 到达时必须整体丢弃——不改三态、不通知、不顺带读取后台状态。
      viewModel.dispose();
      probe.gate!.complete(true);
      await tester.pump();
      await pending;

      expect(notifications, 0, reason: '释放后在途探测结果不通知');
      expect(viewModel.hostStatusKnown, isFalse, reason: '连接三态不被在途结果触碰');
      expect(viewModel.hostStopped, isFalse);
      expect(gateway.calls, 0, reason: '释放后不再随探测顺带读取后台状态');
      expect(viewModel.backgroundFailure, isNull);
    });

    testWidgets('后台状态读取在途时释放：放闸后结果静默丢弃，旧快照与恢复窗口不被触碰', (
      tester,
    ) async {
      final gateway = _StubBackgroundGateway(_failure(recovered: false));
      final viewModel = _nonAutoViewModel(gateway);
      await viewModel.checkHostNow();
      final lastSnapshot = viewModel.backgroundFailure;
      expect(lastSnapshot, isNotNull);

      // 第二轮读取挂起在途，结果将翻转为已恢复：若不被丢弃，会改写失败
      // 快照并开启 4 秒恢复提示窗口。
      gateway.gate = Completer<BackgroundFailureStatus?>();
      gateway.result = _failure(recovered: true);
      final pending = viewModel.checkHostNow();
      await tester.pump();
      expect(gateway.calls, 2);

      var notifications = 0;
      viewModel.addListener(() => notifications += 1);

      viewModel.dispose();
      gateway.gate!.complete(_failure(recovered: true));
      await tester.pump();
      await pending;

      expect(notifications, 0, reason: '释放后在途的后台状态结果不通知');
      expect(
        viewModel.backgroundFailure,
        lastSnapshot,
        reason: '失败快照保持旧值，不被在途结果触碰',
      );
      expect(
        viewModel.backgroundRecoveredNotice,
        isFalse,
        reason: '释放后不开恢复提示窗口',
      );
    });

    testWidgets('释放后手动探测是安全空操作：不发请求、不读后台、不改状态、不通知', (
      tester,
    ) async {
      final probe = _StubProbe(available: true);
      final gateway = _StubBackgroundGateway(_failure(recovered: false));
      final viewModel = _nonAutoViewModel(gateway, probe: probe);
      await viewModel.checkHostNow();
      expect(probe.calls, 1);
      expect(viewModel.hostStopped, isFalse);
      final lastSnapshot = viewModel.backgroundFailure;
      expect(lastSnapshot, isNotNull);

      var notifications = 0;
      viewModel.addListener(() => notifications += 1);

      // 壳层重试入口在释放后再拨到也必须无害：整体空操作，不抛错。
      viewModel.dispose();
      await viewModel.checkHostNow();
      await tester.pump();

      expect(probe.calls, 1, reason: '释放后手动探测不启动新请求');
      expect(gateway.calls, 1, reason: '释放后不读取后台状态');
      expect(notifications, 0, reason: '释放后手动探测不通知');
      expect(viewModel.hostStopped, isFalse, reason: '连接三态不被修改');
      expect(
        viewModel.backgroundFailure,
        lastSnapshot,
        reason: '失败快照不被修改',
      );
    });
  });

  group('真实页面与壳层共存：服务异常提示与后台失败/恢复互不干扰', () {
    testWidgets('已有服务异常提示条时后台失败及恢复照常展示；4 秒窗口结束不清除聊天提示，不重置会话频控，不重复弹窗', (
      tester,
    ) async {
      final gateway = _NoticeChatGateway(
        fallbackReasons: const [
          FallbackReason.modelRateLimited,
          FallbackReason.modelRateLimited,
          FallbackReason.modelRateLimited,
        ],
      );
      final background = _StubBackgroundGateway(null);
      final viewModel = LocalChatViewModel(
        gateway,
        hostConnectionProbe: _StubProbe(),
        backgroundStatusGateway: background,
        autoStart: false,
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<LocalChatViewModel>.value(value: viewModel),
          ],
          child: MaterialApp.router(
            theme: qiyuDarkTheme(),
            routerConfig: GoRouter(
              initialLocation: '/chat',
              routes: [
                GoRoute(
                  path: '/chat',
                  builder: (context, state) => QiyuShell(
                    showHomeBackdrop: true,
                    child: LocalChatView(
                      sttSettingsGateway: _FixedSttGateway(),
                    ),
                  ),
                ),
                GoRoute(
                  path: '/settings',
                  builder: (context, state) =>
                      const Scaffold(body: Text('设置页')),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      addTearDown(viewModel.dispose);

      // 第 1 次同类服务错误：首次弹窗，点「知道了」关闭。
      await tester.enterText(find.byKey(const Key('chat-input')), '第一句');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('api-error-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('api-error-dialog-dismiss')));
      await tester.pumpAndSettle();

      // 第 2 次同类服务错误：会话频控生效，只出提示条。
      await tester.enterText(find.byKey(const Key('chat-input')), '第二句');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
      expect(find.byKey(const Key('api-error-notice-banner')), findsOneWidget);

      // 后台失败：安静位照常出现；聊天提示条原样，也不重复弹窗。
      background.result = _failure(recovered: false);
      await viewModel.checkHostNow();
      await tester.pump();
      expect(find.byKey(const Key('background-notice')), findsOneWidget);
      expect(find.byKey(const Key('api-error-notice-banner')), findsOneWidget);
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);

      // 后台恢复：「已恢复」出现，聊天提示条不被覆盖。
      background.result = _failure(recovered: true);
      await viewModel.checkHostNow();
      await tester.pump();
      expect(find.text('记忆整理已恢复'), findsOneWidget);
      expect(find.byKey(const Key('api-error-notice-banner')), findsOneWidget);

      // 4 秒恢复窗口结束：后台隐去，聊天提示条原样保留。
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(find.byKey(const Key('background-notice')), findsNothing);
      expect(find.byKey(const Key('api-error-notice-banner')), findsOneWidget);

      // 第 3 次同类服务错误：频控未被轮询重置——仍只提示条，不重复弹窗。
      await tester.enterText(find.byKey(const Key('chat-input')), '第三句');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('api-error-dialog')), findsNothing);
      expect(find.byKey(const Key('api-error-notice-banner')), findsOneWidget);
    });
  });
}

/// autoStart 关掉、不经会话恢复的视图模型：测试只拨
/// [LocalChatViewModel.checkHostNow] 驱动「探测 + 后台失败状态」取用，
/// 与生产同一入口。
LocalChatViewModel _nonAutoViewModel(
  _StubBackgroundGateway gateway, {
  _StubProbe? probe,
}) {
  final viewModel = LocalChatViewModel(
    _StubChatGateway(),
    hostConnectionProbe: probe ?? _StubProbe(),
    backgroundStatusGateway: gateway,
    autoStart: false,
  );
  return viewModel;
}

Future<void> _pumpShell(WidgetTester tester, LocalChatViewModel viewModel) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<LocalChatViewModel>.value(value: viewModel),
      ],
      child: MaterialApp(
        theme: qiyuDarkTheme(),
        home: QiyuShell(child: const SizedBox.shrink()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// autoStart 关掉、不经会话恢复：测试只拨 [LocalChatViewModel.checkHostNow]
/// 驱动一次「探测 + 后台失败状态」取用，与生产同一入口。
Future<LocalChatViewModel> _viewModel(_StubBackgroundGateway gateway) async {
  final viewModel = LocalChatViewModel(
    _StubChatGateway(),
    hostConnectionProbe: _StubProbe(),
    backgroundStatusGateway: gateway,
    autoStart: false,
  );
  await viewModel.checkHostNow();
  return viewModel;
}

BackgroundFailureStatus _failure({required bool recovered}) =>
    BackgroundFailureStatus(
      task: '日终归档',
      failedAt: DateTime(2026, 9, 7, 23, 10),
      count: 2,
      recovered: recovered,
    );

final class _StubProbe implements HostConnectionProbe {
  _StubProbe({this.available = true});

  bool available;
  int calls = 0;

  /// 非空时探测挂起：用于锁定重入保护。
  Completer<bool>? gate;

  @override
  Future<bool> isHostAvailable() async {
    calls += 1;
    final gate = this.gate;
    if (gate != null) {
      return gate.future;
    }
    return available;
  }
}

final class _StubBackgroundGateway implements BackgroundStatusGateway {
  _StubBackgroundGateway(this.result);

  BackgroundFailureStatus? result;

  /// 非空时 read 抛错：用于锁定「读取失败保旧值」。
  Object? throwError;

  /// 非空时读取挂起：用于锁定重入保护。
  Completer<BackgroundFailureStatus?>? gate;

  int calls = 0;

  @override
  Future<BackgroundFailureStatus?> read() async {
    calls += 1;
    final gate = this.gate;
    if (gate != null) {
      return gate.future;
    }
    final error = throwError;
    if (error != null) {
      throw error;
    }
    return result;
  }
}

final class _StubChatGateway implements StreamingLocalChatGateway {
  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      const LocalChatSnapshot(sessionId: 'session-1', messages: []);

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '';

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {}
}

/// 共存回归用聊天网关：按调用序给出 fallbackReason 的本地回复流。
final class _NoticeChatGateway implements StreamingLocalChatGateway {
  _NoticeChatGateway({required this.fallbackReasons});

  final List<FallbackReason> fallbackReasons;
  int deliverCallCount = 0;

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      const LocalChatSnapshot(sessionId: 'session-1', messages: []);

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '';

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {
    final index = deliverCallCount;
    deliverCallCount += 1;
    final reason = index < fallbackReasons.length
        ? fallbackReasons[index]
        : null;
    yield LocalChatDeliveryEvent.accepted(
      requestId: requestId,
      sessionId: 'session-1',
    );
    yield LocalChatDeliveryEvent.waiting(
      requestId: requestId,
    );
    yield LocalChatDeliveryEvent.delta(
      requestId: requestId,
      text: '本地基础回复',
    );
    yield LocalChatDeliveryEvent.message(
      requestId: requestId,
      messages: const ['本地基础回复'],
    );
    yield LocalChatDeliveryEvent.state(
      requestId: requestId,
      source: ReplySource.local,
      fallbackReason: reason,
    );
    yield LocalChatDeliveryEvent.done(
      requestId: requestId,
    );
  }
}

/// 共存回归用 STT 设置网关：固定未配置，避免测试环境真实发起 HTTP。
final class _FixedSttGateway implements SttSettingsGateway {
  @override
  Future<SttSettings> read() async =>
      const SttSettings(configured: false, keySet: false);

  @override
  Future<SttSettings> save(SttSettingsDraft draft) => throw UnimplementedError();

  @override
  Future<SttSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) =>
      throw UnimplementedError();
}
