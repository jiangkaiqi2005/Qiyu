import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

// 平台无关 Host 逻辑整体在新包 qiyu_local_host（shelf 站点、聊天交付、
// 记忆节奏、模型网关、Markdown 持久化、凭据仓接口），本壳只保留启动
// 入口、Windows 凭据管理器实现与开浏览器实现。整体转发新包导出口，
// 原有 import 缝（package:qiyu_windows_host）符号面保持不变。
export 'package:qiyu_local_host/qiyu_local_host.dart';

export 'src/browser_launcher.dart';
export 'src/host_command.dart';
export 'src/host_runner.dart';
export 'src/secret_store.dart';

final class HostPreflightReport {
  HostPreflightReport({
    required this.operatingSystem,
    required Map<String, bool> checks,
  }) : checks = Map.unmodifiable(checks);

  final String operatingSystem;
  final Map<String, bool> checks;

  bool get ready => checks.values.every((passed) => passed);

  Map<String, Object?> toJson() => {
    'ready': ready,
    'operatingSystem': operatingSystem,
    'checks': checks,
  };
}

HostPreflightReport runHostPreflight({
  required String operatingSystem,
  String? webRoot,
}) {
  const core = QiyuBehaviorCore();
  final coreOutcome = core.reply(
    const ChatRequest(requestId: 'host-preflight', text: '我到家了'),
    StateSnapshot.initial('local-user'),
  );
  final coreReady =
      coreOutcome is ChatResult &&
      coreOutcome.messages.length == 1 &&
      coreOutcome.messages.single == '嗯';

  final checks = <String, bool>{
    'supportedPlatform': operatingSystem == 'windows',
    'behaviorCore': coreReady,
  };
  if (webRoot != null) {
    checks['webAssets'] = File(path.join(webRoot, 'index.html')).existsSync();
  }

  return HostPreflightReport(operatingSystem: operatingSystem, checks: checks);
}
