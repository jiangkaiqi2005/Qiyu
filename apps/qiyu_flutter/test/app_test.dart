import 'package:qiyu_flutter/app.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/baseline/migration_baseline_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Flutter Web migration shell exposes a ready baseline', (
    tester,
  ) async {
    final viewModel = MigrationBaselineViewModel(
      hostConnectionProbe: _FakeHostConnectionProbe([true]),
      autoStartMonitoring: false,
    );
    await viewModel.checkHostNow();

    await tester.pumpWidget(QiyuApp(viewModel: viewModel));
    await tester.pumpAndSettle();

    expect(find.text('栖语'), findsOneWidget);
    expect(find.text('迁移基线已就绪'), findsOneWidget);
    expect(find.text('纯 Dart 行为核心已连接'), findsOneWidget);
  });

  testWidgets('shows a clear stopped state when the local host disappears', (
    tester,
  ) async {
    final viewModel = MigrationBaselineViewModel(
      hostConnectionProbe: _FakeHostConnectionProbe([true, false]),
      autoStartMonitoring: false,
    );
    await viewModel.checkHostNow();
    await tester.pumpWidget(QiyuApp(viewModel: viewModel));

    expect(find.text('本机程序已停止'), findsNothing);

    await viewModel.checkHostNow();
    await tester.pump();

    expect(find.text('本机程序已停止'), findsOneWidget);
    expect(find.text('请重新启动栖语本机程序。'), findsOneWidget);
  });
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
