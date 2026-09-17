import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/shell/qiyu_fading_notice.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

/// 渐隐提示（全应用唯一的轻提示出口）：总时长 5 秒 = 清晰显示 4.4 秒 +
/// 最后 0.6 秒整条连背景一起淡出后从树上移除；重复触发只替换当前提示、
/// 不排队、同一句可见期内不续时；动作点击先收起再跳转。定位一律按 Key。
void main() {
  group('渐隐提示 QiyuFadingNotice', () {
    testWidgets('清晰停留 4.4 秒，最后 0.6 秒整条淡出，5 秒从树上移除', (tester) async {
      await _pumpPage(tester);
      showQiyuFadingNotice(_pageContext, '提示正文', key: _noticeKey);
      await tester.pump();

      expect(find.text('提示正文'), findsOneWidget);
      expect(_noticeOpacity(tester), 1.0, reason: '刚出现时必须完全不透明');

      // 4.4 秒整条清晰：这段窗口内一个字都不该变淡。
      await tester.pump(const Duration(milliseconds: 4400));
      expect(find.text('提示正文'), findsOneWidget);
      expect(_noticeOpacity(tester), 1.0, reason: '4.4 秒前不得开始淡出');

      // 4.4–5.0 秒：整条连背景一起淡，半程透明度落在 0 与 1 之间。
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('提示正文'), findsOneWidget);
      final mid = _noticeOpacity(tester);
      expect(mid, greaterThan(0.0));
      expect(mid, lessThan(1.0));

      // 5 秒前不得提前退场：窗口不足 5 秒同样算错。
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('提示正文'), findsOneWidget);
      expect(_noticeOpacity(tester), greaterThan(0.0));

      // 5.0 秒整：归零并整条离开树，不留半透明的残影。
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(_noticeKey), findsNothing);
      expect(find.text('提示正文'), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('5.5 秒后完全移除，不留下挂起的计时器', (tester) async {
      await _pumpPage(tester);
      showQiyuFadingNotice(_pageContext, '提示正文', key: _noticeKey);
      await tester.pump();

      await tester.pump(const Duration(milliseconds: 5500));
      await tester.pumpAndSettle();

      expect(find.byKey(_noticeKey), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('重复触发同一句：只留一条，不排队', (tester) async {
      await _pumpPage(tester);
      showQiyuFadingNotice(_pageContext, '同一句', key: _noticeKey);
      await tester.pump();
      showQiyuFadingNotice(_pageContext, '同一句', key: _noticeKey);
      await tester.pump();

      expect(find.text('同一句'), findsOneWidget);
      expect(find.byKey(_noticeKey), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 5500));
      await tester.pumpAndSettle();
    });

    testWidgets('同一句可见期内再触发不续时：寿命仍从首次触发算起', (tester) async {
      await _pumpPage(tester);
      showQiyuFadingNotice(_pageContext, '同一句', key: _noticeKey);
      await tester.pump();

      // 可见期内（3 秒处）再触发一次同一句：不得把 5 秒窗口往后推。
      await tester.pump(const Duration(seconds: 3));
      showQiyuFadingNotice(_pageContext, '同一句', key: _noticeKey);
      await tester.pump();
      expect(find.text('同一句'), findsOneWidget);

      // 从首次触发算满 5 秒即退场；若被续时，这里仍会在场。
      await tester.pump(const Duration(milliseconds: 2100));
      expect(find.byKey(_noticeKey), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('换一句触发：立刻换成新文案，旧句不留场', (tester) async {
      await _pumpPage(tester);
      showQiyuFadingNotice(_pageContext, '第一句', key: _noticeKey);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      showQiyuFadingNotice(_pageContext, '第二句', key: _noticeKey);
      await tester.pump();

      expect(find.text('第二句'), findsOneWidget);
      expect(find.text('第一句'), findsNothing);
      expect(find.byKey(_noticeKey), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 5500));
      await tester.pumpAndSettle();
    });

    testWidgets('点动作：整条立即收起，再执行回调', (tester) async {
      await _pumpPage(tester);
      var acted = 0;
      showQiyuFadingNotice(
        _pageContext,
        '还没配置，去设置页看看',
        key: _noticeKey,
        actionLabel: '去设置',
        onAction: () => acted++,
      );
      await tester.pump();
      expect(find.text('去设置'), findsOneWidget);

      await tester.tap(find.text('去设置'));
      await tester.pump();

      expect(acted, 1);
      expect(find.byKey(_noticeKey), findsNothing, reason: '跳转前提示必须先收起');
      expect(find.text('去设置'), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('动作文案与回调必须成对：只给一半当场判错', (tester) async {
      // 校验归 widget 自己：`showQiyuFadingNotice()` 只是转发，直接构造 widget
      // 的调用点（以及 release 下被剥掉的 assert 之外那条渲染路径）也要有据可依。
      QiyuFadingNotice notice({String? actionLabel, VoidCallback? onAction}) =>
          QiyuFadingNotice(
            message: '提示正文',
            onClose: () {},
            actionLabel: actionLabel,
            onAction: onAction,
          );
      expect(
        () => notice(actionLabel: '去设置'),
        throwsAssertionError,
        reason: '只有文案没有回调＝一颗点了没反应的按钮',
      );
      expect(
        () => notice(onAction: () {}),
        throwsAssertionError,
        reason: '只有回调没有文案＝一颗没有字的按钮',
      );
    });

    testWidgets('没有动作时不给动作按钮', (tester) async {
      await _pumpPage(tester);
      showQiyuFadingNotice(_pageContext, '只是说一声', key: _noticeKey);
      await tester.pump();

      expect(find.byType(TextButton), findsNothing);
      await tester.pump(const Duration(milliseconds: 5500));
      await tester.pumpAndSettle();
    });

    testWidgets('挂在覆盖层：不进页面骨架，也不挤动页面内容', (tester) async {
      await _pumpPage(tester);
      final before = tester.getRect(find.byKey(_pageMarkerKey));

      showQiyuFadingNotice(_pageContext, '提示正文', key: _noticeKey);
      await tester.pump();

      // 提示不在页面骨架内（覆盖层是它的宿主），页面自身因此不动。
      expect(
        find.ancestor(
          of: find.byKey(_noticeKey),
          matching: find.byType(Scaffold),
        ),
        findsNothing,
      );
      expect(tester.getRect(find.byKey(_pageMarkerKey)), before);
      await tester.pump(const Duration(milliseconds: 5500));
      await tester.pumpAndSettle();
    });

    testWidgets('页面整体销毁时正在显示的提示一并卸载，不留异常', (tester) async {
      await _pumpPage(tester);
      showQiyuFadingNotice(_pageContext, '提示正文', key: _noticeKey);
      await tester.pump();
      expect(find.text('提示正文'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('提示正文'), findsNothing);
    });

    testWidgets('reduced-motion 开启：不做淡出，清晰满 5 秒后整条移除', (tester) async {
      // §9「开启后关闭全部过渡与渐显……自绘的淡出……一律归零」。所以这一档
      // 既不淡出、也不提前退场：提示保持全不透明直到 5 秒截止再整条移除。
      await _pumpPage(tester, reducedMotion: true);
      showQiyuFadingNotice(_pageContext, '提示正文', key: _noticeKey);
      await tester.pump();
      expect(_noticeOpacity(tester), 1.0);

      // 4.4 秒是关闭动效时开始淡出的那一刻：4.7 秒处本该已经淡掉一半。
      // 两步泵（先跨过 4.4 秒让定时器起淡出，再走 0.3 秒）——一次跨到底只会
      // 在那一刻起 ticker，读到的是起始值。
      await tester.pump(const Duration(milliseconds: 4400));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('提示正文'), findsOneWidget);
      expect(
        _noticeOpacity(tester),
        1.0,
        reason: '开了 reduced-motion 还在淡出，§9 的自绘淡出没有归零',
      );

      // 总时长上限 5 秒在两种模式下都成立：到点整条离开树，不留透明占位。
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(_noticeKey), findsNothing);
      expect(find.text('提示正文'), findsNothing);
      await tester.pumpAndSettle();

      // 负对照：同一容器、同一时点，关掉这个开关必须正在淡出——否则上面那条
      // 可能只是「这条提示压根没在淡」，而不是「reduced-motion 把它关掉了」。
      await _pumpPage(tester);
      showQiyuFadingNotice(_pageContext, '提示正文', key: _noticeKey);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 4400));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        _noticeOpacity(tester),
        lessThan(1.0),
        reason: '没开 reduced-motion 时 4.4 秒起照旧淡出',
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(_noticeKey), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('动作按钮的字色不与底色同值', (tester) async {
      await _pumpPage(tester);
      showQiyuFadingNotice(
        _pageContext,
        '还没配置，去设置页看看',
        key: _noticeKey,
        actionLabel: '去设置',
        onAction: () {},
      );
      await tester.pump();

      // 底色是主题的中性面板；动作字色若回落到 `colorScheme.inversePrimary`
      // （本主题把它登记成同一档 panel）就等于隐形，用户截图里那颗按钮因此看
      // 不见。§8 组件 2：无底色的文字按钮取 accent-bright。
      expect(_noticeFill(tester), QiyuColors.panel);
      expect(
        _actionLabelColor(tester),
        QiyuColors.accentBright,
        reason: '动作按钮的字色不是 §8 组件 2 的 accent-bright',
      );
      expect(
        _actionLabelColor(tester),
        isNot(_noticeFill(tester)),
        reason: '动作按钮字色与底色同值＝这颗按钮用户根本看不见',
      );
      await tester.pump(const Duration(milliseconds: 5500));
      await tester.pumpAndSettle();
    });

    testWidgets('观感沿用主题的轻提示样式，失败前景字由调用点指定', (tester) async {
      await _pumpPage(tester);
      showQiyuFadingNotice(_pageContext, '中性正文', key: _noticeKey);
      await tester.pump();
      expect(_noticeFill(tester), QiyuColors.panel);
      expect(_noticeForeground(tester), QiyuColors.ink);

      // 换一句触发，顺带带上失败态前景色：底色仍走主题中性面板。
      showQiyuFadingNotice(
        _pageContext,
        '失败正文',
        key: _noticeKey,
        foregroundColor: QiyuColors.danger,
      );
      await tester.pump();
      expect(_noticeFill(tester), QiyuColors.panel);
      expect(_noticeForeground(tester), QiyuColors.danger);
      await tester.pump(const Duration(milliseconds: 5500));
      await tester.pumpAndSettle();
    });
  });
}

const _noticeKey = Key('fading-notice-under-test');
const _pageMarkerKey = Key('fading-notice-page-marker');

late BuildContext _pageContext;

/// 一页最小宿主：只为拿到一个真实页面上下文来触发提示，页面本身带一枚
/// 位置固定的标记，用来验证提示不占页面布局。
///
/// [reducedMotion] 只能经 `MaterialApp.builder` 覆写：提示挂在根覆盖层上，而
/// 覆盖层在 Navigator 之内、`home` 之外——`home` 里那层 MediaQuery 在
/// Navigator 之下，覆盖层读不到它。
Future<void> _pumpPage(
  WidgetTester tester, {
  bool reducedMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: qiyuDarkTheme(),
      builder: reducedMotion
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
          : null,
      home: Scaffold(
        body: Builder(
          builder: (context) {
            _pageContext = context;
            return const Center(
              child: SizedBox(key: _pageMarkerKey, width: 40, height: 40),
            );
          },
        ),
      ),
    ),
  );
}

double _noticeOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find.descendant(
        of: find.byKey(_noticeKey),
        matching: find.byType(FadeTransition),
      ),
    )
    .opacity
    .value;

/// 提示整条的底色。带动作按钮时树里有第二枚 `Material`（TextButton 自带一层），
/// 取先序第一枚＝提示自己那一层。
Color _noticeFill(WidgetTester tester) => tester
    .widget<Material>(
      find
          .descendant(
            of: find.byKey(_noticeKey),
            matching: find.byType(Material),
          )
          .first,
    )
    .color!;

Color _noticeForeground(WidgetTester tester) {
  final richText = tester.widget<RichText>(
    find.descendant(
      of: find.byKey(_noticeKey),
      matching: find.byType(RichText),
    ),
  );
  return (richText.text as TextSpan).style!.color!;
}

/// 动作按钮**实际渲染出**的字色：读按钮自己那棵 RichText，而不是读它传进去的
/// style——「与底色同值」这种缺陷只在渲染结果上现形。
Color? _actionLabelColor(WidgetTester tester) {
  final richText = tester.widget<RichText>(
    find.descendant(
      of: find.descendant(
        of: find.byKey(_noticeKey),
        matching: find.byType(TextButton),
      ),
      matching: find.byType(RichText),
    ),
  );
  return (richText.text as TextSpan).style?.color;
}
