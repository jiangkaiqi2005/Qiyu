import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';

import '../chat/voice_player_platform_io.dart';
import 'android_secret_store.dart';
import 'host_bootstrap.dart';
import 'native_host_session_client.dart';

/// 随 APK 分发的人格宪法（与仓库根 `栖语人格宪法.md` 同步的打版副本）：
/// Windows 壳在运行时读文件，安卓壳没有文件系统外的原料来源，改为
/// 资产分发后经 rootBundle 读入。
const _personaConstitutionAssetPath = 'assets/persona/persona-constitution.md';

/// 静态托管的占位 web root：安卓上 UI 是 Flutter 自绘，Host 的静态
/// 面没有消费方，但 `LocalAppHost.start` 必需一个含 `index.html` 的
/// web root（启动校验 + shelf_static 初始化）。占位写在应用缓存目录
/// 并随每次启动重建——被系统清理也不影响 API 面（API 路径不落静态
/// 处理器），API Key 与会话数据永不在此。
const _placeholderIndexHtml = '<!doctype html><title>栖语</title>';

/// 安卓壳启动装配（进程内先起服务、再跑 UI）：由 `main()` 在
/// `runApp` 之前 await。失败即启动失败——原生壳没有比本机 Host 更
/// 底层的可用形态，静默降级只会把 401 撒向全部网关。
///
/// 本函数是平台通道粘合（目录解析 + 宪法资产读取），不进 dart 测试
/// （平台行为归真机冒烟）；可测的装配核心是 [startEmbeddedHost]。
Future<HostBinding?> bootstrapHost() async {
  final support = await getApplicationSupportDirectory();
  final cache = await getTemporaryDirectory();
  // 朗读音量偏好的存储目录（票 06）：应用私有 support 目录，与
  // provider.json 同级的 runtime 目录。取目录要 await 而 getInitialVolume()
  // 是同步接口，注入只能落在装配阶段——本函数是唯一「已解析出目录、又早于
  // main() 的 runApp（任何控制器构造之前）」的 io 壳装配点；main.dart 为
  // web/安卓共用，不能引 chat 的 io 实现，故注入在这里而非应用入口。
  IoVoicePlayerPlatform.configureDefaultVolumeStore(support);
  final webRoot = Directory(
    '${cache.path}${Platform.pathSeparator}host-web',
  )..createSync(recursive: true);
  File(
    '${webRoot.path}${Platform.pathSeparator}index.html',
  ).writeAsStringSync(_placeholderIndexHtml, flush: true);
  return startEmbeddedHost(
    webRoot: webRoot.path,
    // 数据目录（会话/记忆 Markdown + provider.json 等运行时文件）落
    // 应用私有目录：杀进程重启仍在，卸载随沙盒清除。memories 子目录
    // 与 Windows 布局同构（Host 以其父目录为 runtime 目录）。
    memoryDirectory:
        '${support.path}${Platform.pathSeparator}memories',
    personaConstitution: await rootBundle.loadString(
      _personaConstitutionAssetPath,
    ),
  );
}

/// 装配核心：在进程内起 [LocalAppHost]（loopback 随机端口）并接出
/// 会话接管绑定。目录与宪法由调用方给足，因此可被 dart 测试直接
/// 驱动（真 127.0.0.1 服务器、本地规则引擎降级路径）。
///
/// 凭据仓注入（票 05）：缺省生产实现 [AndroidSecretStore]——密钥入
/// AndroidKeyStore 不可导出，密文落应用私有存储，Host 的读取回退与
/// 旧值清理路径在安卓上真实生效；显式传 [secretStore] 可覆盖（测试
/// 在通道层模拟原生回包驱动真装配，Host 侧接口零改动）。
Future<HostBinding> startEmbeddedHost({
  required String webRoot,
  required String memoryDirectory,
  required String personaConstitution,
  SecretStore? secretStore,
}) async {
  final host = await LocalAppHost.start(
    webRoot: webRoot,
    memoryDirectory: memoryDirectory,
    personaConstitution: personaConstitution,
    secretStore: secretStore ?? const AndroidSecretStore(),
  );
  // 在任何引导发生前取出启动凭据（launchUri 是 getter，兑换成功即
  // 轮换）：共享 client 用它引导一次，此后每个请求回传会话 Cookie。
  // 启动凭据是装配的硬前提（缺失即会话接管无从谈起），显式判空并
  // 关停刚起的服务器——绝不让装配带着空凭据走进白屏且无诊断的 UI。
  final startupToken = host.launchUri.queryParameters['token'];
  if (startupToken == null || startupToken.isEmpty) {
    await host.close();
    throw StateError('本机服务已启动但启动凭据缺失，无法建立会话接管。');
  }
  final session = NativeHostSessionClient(
    baseUri: host.origin,
    startupToken: startupToken,
  );
  return HostBinding(
    client: session,
    baseUri: session.baseUri,
    shutdown: host.close,
  );
}
