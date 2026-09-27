import 'package:http/http.dart' as http;

export 'host_bootstrap_io.dart'
    if (dart.library.js_interop) 'host_bootstrap_web.dart';

/// 进程内本机 Host 的启动装配结果（安卓壳）：原生壳先在进程内起
/// [LocalAppHost]（127.0.0.1 随机端口），再经票 03 的地址接缝把会话
/// 接管 client 与显式基址注入全部领域网关——领域 client 与网关底座
/// 零感知，web 缺省路径零变化。
///
/// 双端行为（条件导入缝，与四个 `*_platform_*` 缝同构）：
///
/// - **io 侧**（`host_bootstrap_io.dart`）：准备数据目录与应用私有
///   web root 占位 → 起 [LocalAppHost] → 用一次性启动凭据建
///   [NativeHostSessionClient] → 返回绑定。Host 行为（幂等、危机兜
///   底、本地降级、晚安）全由既有包测试锁定，装配不绕过任何安全
///   校验（会话/CSRF/Origin 全链路走接管 client）。
/// - **web 侧**（`host_bootstrap_web.dart`）：不装配，返回 null——
///   `QiyuApp` 收到 null 时一切维持同源缺省（`Uri.base`），与改造前
///   完全一致。
final class HostBinding {
  HostBinding({
    required this.client,
    required this.baseUri,
    Future<void> Function()? shutdown,
  }) : // named 参数不能是私有标识；与 NativeHostSessionClient 同款先例。
       // ignore: prefer_initializing_formals
       _shutdown = shutdown;

  /// 会话接管 client：作为共享单例注入各域网关既有的 `client` 参数
  /// （引导兑换、会话 Cookie 回传、修改请求同源 Origin 均在其内部）。
  final http.Client client;

  /// 本机 Host 的显式基址（`http://127.0.0.1:<port>`）：注入各域网关
  /// 既有的 `baseUri` 参数，与 client 同源同例。
  final Uri baseUri;

  final Future<void> Function()? _shutdown;

  /// 关停进程内 Host（测试收尾用；生产 Android 进程退出即终结，
  /// 不显式调用）。
  Future<void> shutdown() async => _shutdown?.call();
}
