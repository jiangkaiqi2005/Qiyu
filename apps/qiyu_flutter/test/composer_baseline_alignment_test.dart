import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

/// composer 输入框空态/输入态的基线对齐回归锁。
///
/// 背景：空态占位字曾被报告在浏览器里垂直偏下。当前构建的浏览器逐像素
/// 实测（引导页输入框、空态居中、底部停靠、打字态四态）只偏 0–1px，未
/// 复现明显偏下；「proportional 导致约 4.5px 偏下」的根因模型也已被实测
/// 证伪——M3 默认字体档本来就隐式给了 even。本测试钉两件事：
/// ①空态 hint 与输入文字同一条基线（差 ≤1px），敲下首字不跳；
/// ②主题显式声明与渲染生效样式都是 even，防样式装配路径变化后隐式
/// 继承悄悄退回 proportional，把上重下轻字体的基线压向 34px 行盒深处。
///
/// 做法：pump 真实 [LocalChatView] 的 composer，用 [FontLoader] 加载随包
/// 宋体子集（避免 FlutterTest 字体度量失真——hint 行高是 34/15 的放大行盒，
/// 基线位置直接由字体的 hhea 上下行比例决定），在同一全局坐标系里分别取
/// 空态 hint 的 RenderParagraph 基线与输入文字（由 RenderEditable 承载，
/// 外层被 `_RenderCompositionCallback` 包住，需沿 child 链下探）的基线比较。
/// 注意：基线锁是相对锁，两者若被布局整体同向下移它测不到，绝对居中由
/// 浏览器目测把关。
void main() {
  testWidgets('composer 空态占位字与输入文字同基线，且生效样式为 even 分布', (
    tester,
  ) async {
    // 测试环境的 FlutterTest 默认字体上下行比例失真，必须先加载真实字体。
    final fontBytes =
        File('assets/fonts/NotoSerifSC-QiyuSubset.ttf').readAsBytesSync();
    final loader = FontLoader(QiyuType.fontFamily)
      ..addFont(Future.value(fontBytes.buffer.asByteData()));
    await loader.load();

    tester.view.physicalSize = const Size(960, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final viewModel = LocalChatViewModel(
      _FakeChatGateway(),
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

    // 成因锁（两半）：主题 hintStyle 必须显式声明 even（防隐式依赖被拆），
    // 且它真的落到渲染出的 hint 样式上（防装配链把显式声明丢掉）。
    expect(
      qiyuDarkTheme().inputDecorationTheme.hintStyle?.leadingDistribution,
      TextLeadingDistribution.even,
      reason: '主题 hintStyle 必须显式声明 even，不能靠 M3 默认字体档隐式代偿',
    );
    final hintStyle = tester.widget<Text>(find.text('想说点什么…')).style;
    expect(
      hintStyle?.leadingDistribution,
      TextLeadingDistribution.even,
      reason: '渲染出的占位字必须用 even 行距分布：宋体上重下轻，'
          'proportional 会把 34px 行盒内的基线压向盒底',
    );

    // 空态：占位字的 alphabetic 基线（全局坐标）。
    final hintBaseline = _globalBaseline(
      tester.renderObject<RenderParagraph>(find.text('想说点什么…')),
    );

    await tester.enterText(find.byKey(const Key('chat-input')), '你好');
    await tester.pumpAndSettle();

    // 输入态：正文文字的基线（同一全局坐标系；composer 不随首字移动）。
    final textBaseline = _globalBaseline(_editableOf(tester));

    expect(
      (hintBaseline - textBaseline).abs(),
      lessThanOrEqualTo(1.0),
      reason: '空态占位字与输入文字基线相差 '
          '${(hintBaseline - textBaseline).abs().toStringAsFixed(2)}px：'
          '敲下首字会看到文字跳动',
    );
  });
}

/// 渲染盒顶部到自身 alphabetic 基线的距离，加盒顶全局 y 得基线全局坐标。
/// 基线查询是 RenderBox 家族的内部布局协议（`computeDistanceToActualBaseline`
/// 带 @protected），对外入口只有 dry 布局：用与当前尺寸一致的 tight 约束
/// 重放同一份文本布局，取到的基线与装饰区对齐用的是同一套度量。
double _globalBaseline(RenderBox box) =>
    box.localToGlobal(Offset.zero).dy +
    (box.getDryBaseline(
          BoxConstraints.tight(box.size),
          TextBaseline.alphabetic,
        ) ??
        box.size.height);

/// [EditableText] 的渲染对象在新版被 `_RenderCompositionCallback`
/// （RenderProxyBox）包住，沿 child 链下探到真正的 RenderEditable。
RenderEditable _editableOf(WidgetTester tester) {
  RenderObject current = tester.renderObject(find.byType(EditableText));
  while (current is RenderProxyBox && current is! RenderEditable) {
    current = current.child!;
  }
  return current as RenderEditable;
}

final class _FakeChatGateway implements StreamingLocalChatGateway {
  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async =>
      const LocalChatSnapshot(sessionId: 'session-1', messages: []);

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
