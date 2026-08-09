import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

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

HostPreflightReport runHostPreflight({required String operatingSystem}) {
  const core = QiyuBehaviorCore();
  final coreOutcome = core.reply(
    const ChatRequest(requestId: 'host-preflight', text: '晚安'),
    StateSnapshot.initial('local-user'),
  );
  final coreReady =
      coreOutcome is ChatResult &&
      coreOutcome.messages.length == 1 &&
      coreOutcome.messages.single == '晚安';

  return HostPreflightReport(
    operatingSystem: operatingSystem,
    checks: {
      'supportedPlatform': operatingSystem == 'windows',
      'behaviorCore': coreReady,
    },
  );
}
