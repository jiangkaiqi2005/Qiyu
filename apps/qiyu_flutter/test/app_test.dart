import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/main.dart';

void main() {
  testWidgets('Flutter Web migration shell exposes a ready baseline', (
    tester,
  ) async {
    await tester.pumpWidget(const QiyuApp());
    await tester.pumpAndSettle();

    expect(find.text('栖语'), findsOneWidget);
    expect(find.text('迁移基线已就绪'), findsOneWidget);
    expect(find.text('纯 Dart 行为核心已连接'), findsOneWidget);
  });
}
