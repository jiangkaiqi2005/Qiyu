import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/baseline/background_status_client.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/shell/qiyu_background_notice.dart';
import 'package:qiyu_flutter/features/shell/qiyu_shell.dart';
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
  @override
  Future<bool> isHostAvailable() async => true;
}

final class _StubBackgroundGateway implements BackgroundStatusGateway {
  _StubBackgroundGateway(this.result);

  BackgroundFailureStatus? result;
  int calls = 0;

  @override
  Future<BackgroundFailureStatus?> read() async {
    calls += 1;
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
