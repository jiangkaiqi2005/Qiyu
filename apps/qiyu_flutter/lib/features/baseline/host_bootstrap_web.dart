import 'host_bootstrap.dart';

/// web 侧装配：不起服务（Host 由本机程序另行提供），返回 null——
/// `QiyuApp` 收到 null 时各域网关维持同源缺省（`Uri.base` + 浏览器
/// 自带的 Cookie/Origin/CSRF 行为），与装配缝引入前完全一致。
Future<HostBinding?> bootstrapHost() async => null;
