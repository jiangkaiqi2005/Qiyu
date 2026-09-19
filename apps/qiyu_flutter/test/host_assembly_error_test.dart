import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:qiyu_flutter/features/baseline/host_assembly_error.dart';
import 'package:qiyu_flutter/features/baseline/host_bootstrap.dart';
import 'package:qiyu_flutter/main.dart' as boot;

/// 装配失败错误页的验收（票 07）：安卓壳在 `main()` 里先起进程内本机
/// Host 再跑 UI，装配一旦失败就「白屏且无诊断」。错误页此刻是唯一还
/// 活着的界面，它**不依赖宿主与存储**——下面每个用例都在零平台通道
/// mock、零网络、零存储的状态下渲染，这本身就是验收的一部分。
///
/// 装配失败→错误页→重试→成功的完整弧线：
///
/// - 首次装配失败（生产由 `main()` 捕获后换根到错误页，测试直接从
///   错误页的既成状态开始）渲染人话原因与重试按钮，不透出异常类型、
///   堆栈与本机路径；
/// - 点重试期间按钮转为等待态；装配成功经 `launch` 放行（生产接线是
///   `runApp(QiyuApp(...))`，回到原首帧链路）；
/// - 连续重试失败达到阈值后，诚实展示卸载重装提示（恢复应用，但清除
///   本机数据），重试入口保留。
void main() {
  /// 放行回调用装配结果的替身：错误页只负责把它交给 [launch]，绑定
  /// 本身无需真启动过 Host。
  HostBinding fakeBinding() => HostBinding(
        client: http.Client(),
        baseUri: Uri.http('127.0.0.1', '/'),
      );

  testWidgets('装配失败渲染极简错误页：人话原因加重试，不透技术细节', (tester) async {
    var launches = 0;
    await tester.pumpWidget(HostAssemblyErrorApp(
      assemble: () async =>
          throw StateError('web root 校验失败: C:/Users/谁/host-web/index.html'),
      launch: (_) => launches++,
    ));
    await tester.pumpAndSettle();

    // 人话原因与重试按钮
    expect(find.text('栖语这次没能启动'), findsOneWidget);
    expect(
      find.text('可能是应用内部有一部分还没准备好。再试一次通常就能进去。'),
      findsOneWidget,
    );
    expect(find.text('再试一次'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
      reason: '重试按钮必须可点',
    );

    // 首次失败还没有卸载重装提示
    expect(find.textContaining('卸载'), findsNothing);

    // 不透出异常类型、堆栈与本机路径
    expect(find.textContaining('StateError'), findsNothing);
    expect(find.textContaining('web root'), findsNothing);
    expect(find.textContaining('127.0.0.1'), findsNothing);
    expect(find.textContaining('C:/'), findsNothing);
    expect(launches, 0, reason: '装配还没成功，不该放行');
  });

  testWidgets('重试期间按钮转等待态，装配成功后放行进入应用', (tester) async {
    final binding = fakeBinding();
    final assembly = Completer<HostBinding?>();
    final launched = <HostBinding?>[];
    await tester.pumpWidget(HostAssemblyErrorApp(
      assemble: () => assembly.future,
      launch: launched.add,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('再试一次'));
    await tester.pump();

    // 等待态：按钮文案换成「正在重新启动…」且不可再点（此时进度圈在
    // 转动，只能逐帧 pump，不能 pumpAndSettle）。
    expect(find.text('正在重新启动…'), findsOneWidget);
    expect(find.text('再试一次'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
      reason: '重试进行中不得重复触发',
    );

    assembly.complete(binding);
    await tester.pumpAndSettle();

    // 放行恰好一次，带回装配结果（生产接线由此 runApp 换根进原首帧）
    expect(launched, [binding]);
  });

  testWidgets('连续重试失败达到阈值后诚实提示卸载重装，重试入口保留', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(HostAssemblyErrorApp(
      assemble: () async {
        attempts++;
        throw StateError('装配持续失败');
      },
      launch: (_) {},
    ));
    await tester.pumpAndSettle();

    // 第一次重试失败（连续第 2 次）：还没到诚实提示的时刻
    await tester.tap(find.text('再试一次'));
    await tester.pumpAndSettle();
    expect(find.textContaining('卸载'), findsNothing);
    expect(attempts, 1);

    // 第二次重试失败（连续第 3 次）：如实告知代价，不替用户做决定
    await tester.tap(find.text('再试一次'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('卸载栖语后重新安装可以恢复应用，但会清除本机保存的全部数据'),
      findsOneWidget,
    );
    expect(attempts, 2);

    // 提示之外重试入口仍然可点：装配失败可能是暂时的
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('入口捕获装配失败：非 release 态控制台收异常线索，UI 只见人话错误页', (tester) async {
    // 捕获 debugPrint（评审 R1）：装配失败的异常线索只进控制台（非
    // release 编译态），不得进 UI、不上报、不落文件。flutter test 本身
    // 就是 debug 编译态，守卫分支在这里是活的。debugPrint 是 foundation
    // 受不变量校验的调试变量，同步收集完立即还原（tearDown 晚于校验）。
    final console = <String?>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => console.add(message);
    boot.runAssemblyFailureApp(StateError('装配失败的测试异常'));
    debugPrint = originalDebugPrint;
    await tester.pump(const Duration(milliseconds: 1));

    expect(
      console.where((line) => line!.startsWith('栖语启动装配失败')),
      isNotEmpty,
      reason: '开发期排障需要异常类别线索，装配失败不得静默丢弃异常',
    );
    expect(
      console.where((line) => line!.contains('装配失败的测试异常')),
      isNotEmpty,
      reason: '控制台线索应包含异常本身，足以归类排障',
    );
    // 换根到错误页，且异常细节不进 UI。出口缝由 main() 的捕获分支调
    // 用（一行接线，代码走查）；测试直接驱动缝——真 main() 会先穿过
    // 平台通道粘合（目录解析），在测试环境挂起且按仓库既定口径归真机
    // 冒烟，故不作为用例入口。
    expect(find.text('栖语这次没能启动'), findsOneWidget);
    expect(find.textContaining('StateError'), findsNothing);
  });
}
