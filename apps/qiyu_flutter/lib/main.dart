import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app.dart';
import 'features/baseline/host_assembly_error.dart';
import 'features/baseline/host_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 启动装配缝（票 04）：原生壳（Android）先在进程内起本机 Host
  // （127.0.0.1 随机端口）再跑 UI，UI 经票 03 的地址接缝显式指向它；
  // web 构建不装配（返回 null），一切维持同源缺省。
  //
  // 装配失败（票 07）：原生壳没有比本机 Host 更底层的可用形态，静默
  // 降级只会把 401 撒向全部网关，失败时换根到不依赖宿主与存储的错误
  // 页（人话原因 + 重试）；重试重新执行装配，成功仍走同一条放行链路
  // 进入原首帧。web 侧装配恒返回 null、无失败路径，此捕获对其零影响。
  final HostBinding? hostBinding;
  try {
    hostBinding = await bootstrapHost();
  } catch (error) {
    runAssemblyFailureApp(error);
    return;
  }
  runApp(QiyuApp(hostBinding: hostBinding));
}

/// 装配失败的可观察出口（票 07 评审 R1）：换根到错误页，并把异常作为
/// 排障线索送控制台。拆成函数只为可测——直接驱动 [main] 会先穿过
/// 平台通道粘合（目录解析），那在测试环境挂起且按仓库既定口径归真机
/// 冒烟，错误页与控制台线索的用例改由本缝承载。
///
/// 诊断纪律：线索只在**非 release 编译态**经 [debugPrint] 进控制台，
/// 供开发与真机排障；release 静默。绝不进 UI（错误页仍只有人话文案，
/// 见 host_assembly_error.dart 的文案纪律）、不上报、不落任何文件——
/// Windows 壳的启动失败日志（票 03）是那边的既定面，安卓壳不新增面。
void runAssemblyFailureApp(Object error) {
  if (!kReleaseMode) {
    debugPrint('栖语启动装配失败：$error');
  }
  runApp(HostAssemblyErrorApp(
    assemble: bootstrapHost,
    launch: (binding) => runApp(QiyuApp(hostBinding: binding)),
  ));
}
