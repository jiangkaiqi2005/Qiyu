import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

export 'src/browser_launcher.dart';
export 'src/daily_finalization.dart';
export 'src/episode_index.dart';
export 'src/episode_memory.dart';
export 'src/host_command.dart';
export 'src/host_runner.dart';
export 'src/local_app_host.dart';
export 'src/local_chat_service.dart';
export 'src/markdown_memory_repository.dart';
export 'src/memory_recall.dart';
export 'src/model_gateway.dart';
export 'src/model_prompt_builder.dart';
export 'src/monthly_summary.dart';
export 'src/onboarding_state.dart';
export 'src/open_loop_store.dart';
export 'src/persona_tree.dart';
export 'src/provider_config.dart';
export 'src/provider_settings_service.dart';
export 'src/relationship_lifecycle.dart';
export 'src/secret_store.dart';
export 'src/state_pack_reader.dart';

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
    const ChatRequest(requestId: 'host-preflight', text: '晚安'),
    StateSnapshot.initial('local-user'),
  );
  final coreReady =
      coreOutcome is ChatResult &&
      coreOutcome.messages.length == 1 &&
      coreOutcome.messages.single == '晚安';

  final checks = <String, bool>{
    'supportedPlatform': operatingSystem == 'windows',
    'behaviorCore': coreReady,
  };
  if (webRoot != null) {
    checks['webAssets'] = File(path.join(webRoot, 'index.html')).existsSync();
  }

  return HostPreflightReport(operatingSystem: operatingSystem, checks: checks);
}
