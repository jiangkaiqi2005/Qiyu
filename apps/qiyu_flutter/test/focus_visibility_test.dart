import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/shell/qiyu_widgets.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

import 'support/focus_ring_probe.dart';

/// Story 21 的来源判定（design-system §9「焦点表意按来源分开」+ 2026-08-30
/// 第二轮裁定：判据自实现，不单独依赖 `FocusManager.highlightMode`）。
///
/// 三条用例锁同一件外部可观察事实：**同一只控件**，指针把焦点交给它时不出现
/// 亮紫外环，键盘把焦点走到它上面时出现 2px + offset 3px 的紫环；触摸永不画环。
///
/// 载体取输入框：它是这一版 Flutter 里**指针点击就会取得焦点**的 M3 控件
/// （`InkResponse` 已不在点击时 requestFocus，按钮点了不获焦，复现不出「鼠标也
/// 画环」这个缺陷），环本身仍是 §9 要自绘的那一份 [QiyuFocusRing]。
void main() {
  const fieldKey = Key('probe-field');
  late FocusNode node;

  setUp(() => QiyuFocusSource.instance.resetForTests());
  tearDown(() => QiyuFocusSource.instance.resetForTests());

  Future<void> pumpRingHarness(WidgetTester tester) async {
    node = FocusNode(debugLabel: 'probe-field');
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: qiyuDarkTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 260,
              child: QiyuFocusRing(
                focusNode: node,
                child: TextField(
                  key: fieldKey,
                  focusNode: node,
                  decoration: const InputDecoration(hintText: '说点什么'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 用真·鼠标指针点进控件：flutter_test 的 tap() 默认是触摸指针，会把框架的
  /// highlightMode 改成 touch，那样连缺陷都复现不出来。
  Future<void> mouseClick(WidgetTester tester, Finder target) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    final center = tester.getCenter(target);
    await mouse.down(center);
    await tester.pump();
    await mouse.up();
    await tester.pumpAndSettle();
  }

  testWidgets('鼠标点击把焦点交给控件时不画出 accentBright 紫环', (tester) async {
    await pumpRingHarness(tester);
    expect(node.hasFocus, isFalse, reason: '前提：初始无人持焦');

    await mouseClick(tester, find.byKey(fieldKey));

    expect(
      node.hasFocus,
      isTrue,
      reason: '前提：鼠标点进输入框确实把焦点交给了它',
    );
    // 框架的 highlightMode 到这一步仍是 traditional：旧判据正是在这里判错
    // （持焦 + traditional 就画环），所以这一条在改判之前是红的。
    expect(
      FocusManager.instance.highlightMode,
      FocusHighlightMode.traditional,
      reason: '前提：鼠标不改写框架的高亮模式，这正是它不能当判据的原因',
    );
    expect(
      readFocusRing(tester, fieldKey)!.border.color,
      isNot(QiyuColors.accentBright),
      reason: '指针聚焦不得画出 §9 的键盘紫环',
    );
  });

  testWidgets('键盘 Tab 把焦点走到同一只控件时出现 2px + offset 3px 紫环', (
    tester,
  ) async {
    await pumpRingHarness(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue, reason: '前提：Tab 把焦点走到这一只控件上');

    final reading = readFocusRing(tester, fieldKey);
    expect(reading, isNotNull, reason: '控件没套环就是缺陷');
    expect(reading!.border.color, QiyuColors.accentBright);
    expect(reading.border.width, QiyuLayout.focusRingWidth);
    // offset：环的外沿比控件本身每边多出 focusRingOffset 的常驻留白（未聚焦时
    // 也在，所以出现与消失都不跳版）。贴在控件表面上的是 Material 的
    // focusColor 淡底，给不出这一圈留白外环，§9 因此要求自绘。
    expect(
      reading.outerRect,
      Rect.fromCenter(
        center: reading.outerRect.center,
        width: reading.controlSize.width + 2 * QiyuLayout.focusRingOffset,
        height: reading.controlSize.height + 2 * QiyuLayout.focusRingOffset,
      ),
      reason: '焦点环必须是离控件 3px 的外环，不是贴在控件表面上的淡底',
    );
  });

  testWidgets('触摸点击把焦点交给控件时永不画出紫环', (tester) async {
    await pumpRingHarness(tester);

    await tester.tap(find.byKey(fieldKey));
    await tester.pumpAndSettle();
    expect(
      node.hasFocus,
      isTrue,
      reason: '前提：flutter_test 的 tap 是触摸指针',
    );

    expect(
      readFocusRing(tester, fieldKey)!.border.color,
      isNot(QiyuColors.accentBright),
      reason: '触摸设备上永不画环（§9 三条之一）',
    );
  });
}
