import 'package:flutter/widgets.dart';

import 'app.dart';
import 'features/baseline/host_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 启动装配缝（票 04）：原生壳（Android）先在进程内起本机 Host
  // （127.0.0.1 随机端口）再跑 UI，UI 经票 03 的地址接缝显式指向它；
  // web 构建不装配（返回 null），一切维持同源缺省。
  final hostBinding = await bootstrapHost();
  runApp(QiyuApp(hostBinding: hostBinding));
}
