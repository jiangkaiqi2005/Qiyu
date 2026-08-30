import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

/// 焦点环的可观察事实读法（design-system §9、Spec Testing Decisions 1/3）：
/// 只看「控件外面有没有一圈 2px accentBright、离控件多远」，不读环组件的内部
/// 结构，也不要求页面为套环改动任何 Key 与交互。
typedef FocusRingReading = ({
  BorderSide border,
  Rect outerRect,
  Size controlSize,
});

/// 量出包住 [targetKey] 那一层自绘焦点环：描边、外沿矩形与控件自身尺寸。
///
/// 返回 null 表示这个控件**根本没套环**——页面漏挂时用例就是红的，
/// 不能靠「颜色不对」蒙过去。
FocusRingReading? readFocusRing(WidgetTester tester, Key targetKey) {
  final control = find.byKey(targetKey);
  final rings = find
      .ancestor(
        of: control,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).border?.top.width ==
                  QiyuLayout.focusRingWidth,
        ),
      )
      .last;
  if (rings.evaluate().isEmpty) {
    return null;
  }
  final offsets = find
      .ancestor(
        of: control,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Padding &&
              widget.padding ==
                  const EdgeInsets.all(QiyuLayout.focusRingOffset),
        ),
      )
      .last;
  final ring = tester.widget<DecoratedBox>(rings);
  return (
    border: (ring.decoration as BoxDecoration).border!.top,
    outerRect: tester.getRect(offsets),
    controlSize: tester.getSize(control),
  );
}

/// 键盘 Tab 一直走到 [targetKey] 画出实紫环为止，返回那一份读数。
///
/// 走到上限仍没出现紫环就返回 null：用例直接红，不放宽断言。
Future<FocusRingReading?> tabUntilRingAppears(
  WidgetTester tester,
  Key targetKey, {
  int maxTabs = 24,
}) async {
  for (var i = 0; i < maxTabs; i++) {
    final reading = readFocusRing(tester, targetKey);
    if (reading != null &&
        reading.border.color == QiyuColors.accentBright) {
      return reading;
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  return null;
}
