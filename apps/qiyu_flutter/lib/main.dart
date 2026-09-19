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
    runApp(HostAssemblyErrorApp(
      assemble: bootstrapHost,
      launch: (binding) => runApp(QiyuApp(hostBinding: binding)),
    ));
    return;
  }
  runApp(QiyuApp(hostBinding: hostBinding));
}
