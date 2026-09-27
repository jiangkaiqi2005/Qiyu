import 'dart:io';
import 'dart:typed_data';

/// 聊天模型出网的明文 HTTP 允许判定与代理规则（纯 Dart，无 IO）。
///
/// 应用层的明文姿态（ticket 08）：`https://` 一律放行；`http://` 默认
/// 拒绝，仅当主机属于私有网段字面量（10/8、172.16/12、192.168/16、
/// 127/8）或环回（localhost、*.localhost、::1 及 IPv4 映射形态）才
/// 放行——这些只能是用户显式配置的本机／局域网目标（Ollama 本机部署
/// 是 AGENTS 明确支持的产品功能）。公网 IP 与无法静态判定的主机名
/// （DNS 解析后的归属无法在出网前核实）一律拒绝并给出人话。
///
/// 平台层（Android network security config）不管辖 dart:io 出站：
/// 平台明文策略由 Java 网络栈（OkHttp／Conscrypt 经
/// NetworkSecurityPolicy）执行，Flutter 的 dart:io 在自有 socket 上
/// 自建 HTTP 栈（Flutter 2.0 短暂引入过 Dart 层禁令，2.2.0 已回退，
/// 见 docs.flutter.dev「network-policy-ios-android」）。因此本允许
/// 列表是 dart:io 出站唯一生效的放行口；安卓 manifest 保持平台默认
/// 禁明文姿态，不另开豁免。

/// 主机是否为本机／私有网段（明文 HTTP 允许列表与「局域网目标不走
/// 代理」共用）。只认字面量 IP 与 localhost 形态；主机名返回 false。
bool isPrivateOrLoopbackHost(String host) {
  final normalized = host.trim().toLowerCase();
  if (normalized.isEmpty) {
    return false;
  }
  if (normalized == 'localhost' || normalized.endsWith('.localhost')) {
    return true;
  }
  final address = InternetAddress.tryParse(normalized);
  if (address == null) {
    return false;
  }
  final raw = address.rawAddress;
  if (raw.length == 4) {
    return _isPrivateOrLoopbackIpv4(raw);
  }
  if (raw.length == 16) {
    return _isPrivateOrLoopbackIpv6(raw);
  }
  return false;
}

bool _isPrivateOrLoopbackIpv4(Uint8List b) {
  final a0 = b[0];
  final a1 = b[1];
  if (a0 == 10) return true; // 10/8
  if (a0 == 127) return true; // 环回
  if (a0 == 172 && a1 >= 16 && a1 <= 31) return true; // 172.16/12
  if (a0 == 192 && a1 == 168) return true; // 192.168/16
  return false;
}

bool _isPrivateOrLoopbackIpv6(Uint8List b) {
  var zeroPrefix = 0;
  while (zeroPrefix < 16 && b[zeroPrefix] == 0) {
    zeroPrefix += 1;
  }
  if (zeroPrefix == 15 && b[15] == 1) return true; // ::1 环回
  // IPv4 映射地址 ::ffff:a.b.c.d：按内嵌 IPv4 再判。
  if (zeroPrefix == 10 && b[10] == 0xFF && b[11] == 0xFF) {
    return _isPrivateOrLoopbackIpv4(Uint8List.sublistView(b, 12, 16));
  }
  return false;
}

/// 聊天模型出网目标的明文拒绝原因：允许返回 null，拒绝返回人话文案。
/// 聊天网关出网前与设置保存／连接测试共用同一份判定。拒绝文案分两型：
/// 公网 IP 字面量与保留段 IP 点「改用 HTTPS」；主机名形态（域名、
/// mDNS／.local 名）点「请直接填 IP」——它不是公网地址，别误导用户。
String? chatCleartextRefusalReason(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'https') {
    return null;
  }
  if (scheme != 'http') {
    return '模型服务地址必须是有效的 HTTP 地址。';
  }
  if (isPrivateOrLoopbackHost(uri.host)) {
    return null;
  }
  if (InternetAddress.tryParse(uri.host.trim().toLowerCase()) == null) {
    return '局域网服务请直接填 IP 地址（明文 HTTP 不接受主机名）。';
  }
  return '明文 HTTP 地址只允许本机或局域网（私有网段）的服务，'
      '公网地址请改用 HTTPS。';
}

/// 已启用的代理出站规则：交给 dart:io HttpClient.findProxy 使用。
/// 代理只承载「地址 + 端口」，没有凭据字段（本期代理认证不做，
/// 因此没有需要保密、禁止回显的代理凭据）。
final class ProxyRules {
  const ProxyRules({required this.host, required this.port});

  final String host;
  final int port;

  /// findProxy 回调的标准返回：全部目标走该代理（DIRECT 分流由
  /// 「是否装配规则」这一层决定——环回／私有网段目标在装配前已
  /// 摘除，永远直连；用户显式开启代理就是要把流量交给代理，不做
  /// 静默直连兜底）。IPv6 字面量主机按约定加方括号，配置里写成
  /// `[::1]` 括号形态或裸 `::1` 都归一到同一个输出。
  String findProxyFor(Uri uri) {
    final bareHost = host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host;
    return 'PROXY ${bareHost.contains(':') ? '[$bareHost]' : bareHost}:$port';
  }
}
