import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/accessibility.dart';

/// 宽屏首页/初见页回归：[QiyuCenteredScrollable] 必须把窄于 `maxWidth` 的
/// 内容块在**整个视口**内水平居中，而不是被滚动视口顶到左缘；同时
/// `minHeight` 带来的「短内容垂直居中、长内容可滚动不溢出」语义不丢。
void main() {
  Future<void> pumpScrollable(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QiyuCenteredScrollable(
            maxWidth: 560,
            child: child,
          ),
        ),
      ),
    );
  }

  testWidgets('宽屏下窄于 maxWidth 的内容块水平居中于视口', (tester) async {
    await pumpScrollable(
      tester,
      const SizedBox(key: Key('centering-probe'), width: 300, height: 120),
    );

    final rect = tester.getRect(find.byKey(const Key('centering-probe')));
    // padding 左右对称，视口内容区中心即视口中心。
    expect(
      rect.center.dx,
      moreOrLessEquals(1200 / 2, epsilon: 1),
      reason: '内容块应落在视口水平中心，不能贴左缘',
    );
  });

  testWidgets('短内容仍整体垂直居中（minHeight 语义不变）', (tester) async {
    await pumpScrollable(
      tester,
      const SizedBox(key: Key('centering-probe'), width: 300, height: 120),
    );

    final rect = tester.getRect(find.byKey(const Key('centering-probe')));
    expect(
      rect.center.dy,
      moreOrLessEquals(800 / 2, epsilon: 1),
      reason: '内容短于一屏时仍应垂直居中，而不是顶到上缘',
    );
  });

  testWidgets('高于视口的内容可整体滚动且不溢出', (tester) async {
    await pumpScrollable(
      tester,
      const SizedBox(key: Key('centering-probe'), width: 300, height: 2000),
    );

    expect(tester.takeException(), isNull);
    final rect = tester.getRect(find.byKey(const Key('centering-probe')));
    expect(rect.height, 2000);
    expect(rect.center.dx, moreOrLessEquals(1200 / 2, epsilon: 1));
  });
}
