import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/shell/qiyu_widgets.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

/// 聊天态 composer 长高覆盖层回归锁。
///
/// 背景：`_chatBody` 原是 `Column [ Expanded(消息流), 通知条, composer, 底部留白 ]`，
/// 输入框随多行内容长高时 `Expanded` 的列表视口被精确压缩对应行高，正在阅读的
/// 消息被顶上去；且 composer 长高不改列表签名、贴底跳转不触发，底部消息沉到
/// composer 之下。期望：消息列表纹丝不动，composer 作为覆盖层向上生长盖住
/// 更早的消息（`_chatBody` 的 Stack 覆盖层方案）。
///
/// 做法：pump 真实 [LocalChatView]（与 composer_baseline_alignment_test 同款
/// seam 与字体加载），960×600 下先量 ListView 静息矩形与贴底位置，再向输入框
/// 注入 3 行文本，断言列表前后零位移。两案都带前置断言（composer 确实长高了 /
/// 恢复后确实贴底了），防止改动布局后用例空转。
void main() {
  setUpAll(() async {
    // 测试环境的 FlutterTest 默认字体度量失真，加载随包真实字体
    // （与 composer_baseline_alignment_test 同一做法）。
    final fontBytes =
        File('assets/fonts/NotoSerifSC-QiyuSubset.ttf').readAsBytesSync();
    final loader = FontLoader(QiyuType.fontFamily)
      ..addFont(Future.value(fontBytes.buffer.asByteData()));
    await loader.load();
  });

  Future<void> pumpChat(
    WidgetTester tester, {
    required int messageCount,
    int linesPerMessage = 1,
  }) async {
    tester.view.physicalSize = const Size(960, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final viewModel = LocalChatViewModel(
      _FakeChatGateway(
        messageCount: messageCount,
        linesPerMessage: linesPerMessage,
      ),
      hostConnectionProbe: _FixedProbe(),
      autoStart: false,
    );
    await viewModel.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: qiyuDarkTheme(),
        home: Scaffold(
          body: ChangeNotifierProvider.value(
            value: viewModel,
            child: const LocalChatView(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('聊天态输入框长高不挤压消息列表', (tester) async {
    await pumpChat(tester, messageCount: 1);

    final listView = find.byType(ListView).first;
    final listBefore = tester.getRect(listView);
    final composerBefore = tester.getRect(
      find.byKey(const Key('home-go-chat')),
    );

    // 静息面板高基线：输入行 46 + 上下内边距 12 + 发丝边框 2 = 60。多行展开
    // 留白只许加在展开态，单行静息分毫不能动（面板顶 516 基线依赖这一点）。
    expect(
      composerBefore.height,
      60.0,
      reason: '静息面板高基线漂移：展开态留白必须只作用于多行展开态',
    );
    // 静息内边距基线：左右 16/6、上下 6——展开态只许改下沿，其余三边钉死。
    expect(
      tester
          .widget<QiyuGlassPanel>(find.byKey(const Key('home-go-chat')))
          .padding,
      const EdgeInsets.fromLTRB(
        QiyuSpacing.md,
        QiyuLayout.composerPadding,
        QiyuLayout.composerPadding,
        QiyuLayout.composerPadding,
      ),
      reason: '静息面板内边距基线漂移',
    );

    await tester.enterText(
      find.byKey(const Key('chat-input')),
      '第一行\n第二行\n第三行',
    );
    await tester.pumpAndSettle();

    // 前置：注入的 3 行文本必须真的让 composer 长高，否则本用例测了个寂寞。
    final composerAfter = tester.getRect(
      find.byKey(const Key('home-go-chat')),
    );
    expect(
      composerAfter.height,
      greaterThan(composerBefore.height),
      reason: '前置失败：3 行文本没有让 composer 长高，用例空转',
    );

    // 展开态留白分配锁（2026-09-05 用户反馈「上面太宽了，下面太窄了，离圆角
    // 太近了」）：宋体行盒的空隙大头分在文字上方（行高按字体上伸比例分配、
    // CJK 字面偏上），上下对称加白视觉上仍上宽下窄。故展开态上沿回到静息 6、
    // 下沿 6+2×8=22，总留白 28 不变——高度断言区分不了分配，这里直接读面板
    // 内边距钉住。
    expect(
      tester
          .widget<QiyuGlassPanel>(find.byKey(const Key('home-go-chat')))
          .padding,
      const EdgeInsets.fromLTRB(
        QiyuSpacing.md,
        QiyuLayout.composerPadding,
        QiyuLayout.composerPadding,
        QiyuLayout.composerPadding + 2 * QiyuSpacing.xs,
      ),
      reason: '展开态留白应全在下沿（上 6 下 22），而不是上下对称',
    );

    // 展开态总高锁：3 行行盒（本环境 22/行）+ 上 6 + 下 22 + 发丝 2 = 96
    // （未加展开留白的旧实现实测 80）。
    expect(
      composerAfter.height,
      96.0,
      reason: '多行展开态面板高度：3 行行盒 + 上 6 + 下 22 + 发丝 2',
    );

    final listAfter = tester.getRect(listView);
    expect(listAfter.top, listBefore.top, reason: '消息列表视口顶部必须纹丝不动');
    expect(
      listAfter.height,
      listBefore.height,
      reason: '消息列表视口高度必须不变：composer 长高应走覆盖层，而不是挤压列表',
    );
  });

  testWidgets('两行即展开：行盒再矮，两行内容也必须有完整下沿留白', (tester) async {
    await pumpChat(tester, messageCount: 1);

    final listView = find.byType(ListView).first;
    final listBefore = tester.getRect(listView);

    await tester.enterText(
      find.byKey(const Key('chat-input')),
      '第一行\n第二行',
    );
    await tester.pumpAndSettle();

    // 展开判据是「内容多于一行」，不是「输入行高超过按钮行」：测试字体行盒
    // 22px 下两行内容 44px，仍矮于 46px 的按钮行——按高度判定时这里永远不
    // 展开、下沿只剩 6（2026-09-05 用户 200% 缩放真机踩中：两行贴边、三行
    // 才突然松开，观感即「两行和三行差太多」）。
    expect(
      tester
          .widget<QiyuGlassPanel>(find.byKey(const Key('home-go-chat')))
          .padding,
      const EdgeInsets.fromLTRB(
        QiyuSpacing.md,
        QiyuLayout.composerPadding,
        QiyuLayout.composerPadding,
        QiyuLayout.composerPadding + 2 * QiyuSpacing.xs,
      ),
      reason: '两行内容就必须展开：下沿留白不得等行数涨到按钮行高度才出现',
    );
    // 两行面板总高：发丝 2 + 上 6 + 按钮行 46（两行 44 矮于按钮行，行不撑高）
    // + 下 22 = 76。
    expect(
      tester.getRect(find.byKey(const Key('home-go-chat'))).height,
      76.0,
      reason: '两行展开态面板高度：按钮行 46 + 上 6 + 下 22 + 发丝 2',
    );

    final listAfter = tester.getRect(listView);
    expect(listAfter.top, listBefore.top, reason: '消息列表视口顶部必须纹丝不动');
    expect(
      listAfter.height,
      listBefore.height,
      reason: '消息列表视口高度必须不变：composer 长高应走覆盖层，而不是挤压列表',
    );
  });

  testWidgets('composer 长高不丢贴底', (tester) async {
    await pumpChat(tester, messageCount: 40, linesPerMessage: 6);

    final controller = tester
        .widget<ListView>(find.byType(ListView).first)
        .controller!;
    // 前置：恢复后应贴底（会话恢复默认跟到底部）。
    expect(
      controller.position.pixels,
      controller.position.maxScrollExtent,
      reason: '前置失败：40 条多行消息恢复后没有贴底',
    );

    // ── 静息基线锁（单行 composer，未输入多行）──────────────────────
    // 基线数值为当前实现实测写死：视口底 600 − 列表 bottom padding 常量
    // _chatListBottomInset(108) = 492；composer 静息面板顶 = 视口底 − 面板
    // 60 − 底部留白 24 = 516。任何一处被改动（例如有人把 padding 改回跟随
    // composer 实际高度联动）都会在这里红。
    final lastMsgBottom = tester.getRect(
      find.byKey(const Key('chat-message-39')),
    ).bottom;
    final panelTop = tester.getRect(find.byKey(const Key('home-go-chat'))).top;
    expect(
      lastMsgBottom,
      492.0,
      reason: '静息基线：贴底时最后一条消息底缘 = 视口底 600 − 覆盖层静息占位 '
          '108；漂移说明列表底部让位 padding 或滚动几何被改动',
    );
    expect(
      lastMsgBottom,
      lessThanOrEqualTo(panelTop),
      reason: '静息时最后一条消息必须完整落在 composer 之上，'
          '而不是沉到毛玻璃面板之下',
    );
    expect(
      controller.position.maxScrollExtent,
      moreOrLessEquals(7350.0, epsilon: 1),
      reason: '静息基线：maxScrollExtent 实测 7350（本环境字体度量下 40×6 行'
          '内容总高 − 视口高）；±1 只容忍亚像素抖动，布局回归会超出',
    );
    final pixelsBefore = controller.position.pixels;

    await tester.enterText(
      find.byKey(const Key('chat-input')),
      '第一行\n第二行\n第三行',
    );
    await tester.pumpAndSettle();

    // 前置：注入的 3 行文本必须真的让覆盖层长高，否则下方恢复锁空转。
    expect(
      tester.getRect(find.byKey(const Key('home-go-chat'))).top,
      lessThan(panelTop),
      reason: '前置失败：3 行文本没有让 composer 长高，恢复锁空转',
    );

    // 既定取舍：composer 长高时覆盖层向上生长，会暂时盖住最新一条消息的
    // 底部——这是用户明确授权的覆盖行为（「会话不动、对话框覆盖就行了」），
    // 不是 bug，因此这里刻意不断言注入态下消息可见；清空输入后的恢复由
    // 下方断言锁定。（测试字体行盒矮、长高幅度小，可能盖不住；真实浏览器
    // 约 34px/行、3 行即盖住。）

    // 贴底断言锁的是「列表几何不变」这一机制：composer 长高不改列表内容与
    // 视口，pixels 与 maxScrollExtent 都不动、故仍相等。修复前（Column 结构）
    // 视口被精确压缩两行高，max 增大而 pixels 停在原值，此断言红——但它不是
    // 唯一行为断言，静息基线与清空恢复的可见性断言在上方/下方。
    expect(
      controller.position.pixels,
      controller.position.maxScrollExtent,
      reason: 'composer 长高后仍应贴底：底部消息不能沉到 composer 之下',
    );
    expect(
      controller.position.pixels,
      pixelsBefore,
      reason: 'composer 长高时列表内容与滚动位置都不应变化',
    );

    // ── 恢复锁：清空输入，composer 回静息，消息重新完整可见 ─────────
    await tester.enterText(find.byKey(const Key('chat-input')), '');
    await tester.pumpAndSettle();

    final lastMsgAfterClear = tester.getRect(
      find.byKey(const Key('chat-message-39')),
    ).bottom;
    final panelTopAfterClear = tester.getRect(
      find.byKey(const Key('home-go-chat')),
    ).top;
    expect(
      lastMsgAfterClear,
      lastMsgBottom,
      reason: '清空后回到静息基线：最后一条消息底缘应回到 492',
    );
    expect(
      panelTopAfterClear,
      panelTop,
      reason: '清空后 composer 回到静息位置（面板顶 516）',
    );
    expect(
      lastMsgAfterClear,
      lessThanOrEqualTo(panelTopAfterClear),
      reason: '清空后最后一条消息重新完整可见于 composer 之上',
    );
    expect(
      controller.position.pixels,
      controller.position.maxScrollExtent,
      reason: '清空后仍贴底',
    );
  });
}

final class _FakeChatGateway implements StreamingLocalChatGateway {
  _FakeChatGateway({this.messageCount = 1, this.linesPerMessage = 1});

  final int messageCount;
  final int linesPerMessage;

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async {
    return LocalChatSnapshot(
      sessionId: 'session-1',
      messages: [
        for (var i = 0; i < messageCount; i++)
          LocalChatMessage(
            requestId: 'req-$i',
            speaker: i.isEven ? LocalChatSpeaker.user : LocalChatSpeaker.qiyu,
            text: [
              for (var j = 1; j <= linesPerMessage; j++)
                '第 $i 条消息的第 $j 行',
            ].join('\n'),
          ),
      ],
    );
  }

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) => const Stream.empty();

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => '';
}

final class _FixedProbe implements HostConnectionProbe {
  @override
  Future<bool> isHostAvailable() async => true;
}
