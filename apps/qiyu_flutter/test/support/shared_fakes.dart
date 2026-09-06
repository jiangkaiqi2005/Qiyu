import 'dart:typed_data';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_flutter/features/baseline/host_connection_probe.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/memory/memory_client.dart';
import 'package:qiyu_flutter/features/onboarding/onboarding_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';

/// 各测试文件同名替身的共享收拢：连接探针、首见、固定模型设置、设置、
/// 聊天、记忆六类。差异用构造参数或命名构造表达；有独有能力的替身
/// （失败注入、挂起、逐会话分支等）仍留在各自测试文件里。

/// 连接探针替身：按 [results] 顺序应答探测，只给一枚则恒定，
/// 超出列表后沿用最后一枚。
final class FakeHostConnectionProbe implements HostConnectionProbe {
  FakeHostConnectionProbe(this.results);

  final List<bool> results;
  var _index = 0;

  @override
  Future<bool> isHostAvailable() async {
    final result = results[_index];
    if (_index < results.length - 1) {
      _index += 1;
    }
    return result;
  }
}

/// 首见网关替身：[completed] 可读可写，complete 记录为已完成。
final class FakeOnboardingGateway implements OnboardingGateway {
  FakeOnboardingGateway({this.completed = false});

  bool completed;

  @override
  Future<OnboardingState> read() async => OnboardingState(completed: completed);

  @override
  Future<void> complete({String? appellation}) async {
    completed = true;
  }
}

/// 固定读数的模型设置网关：read 只回 configured/keySet 同值的设置，
/// 写方法一律抛 UnimplementedError（被测页面不应走到写路径）。
final class FixedProviderSettingsGateway implements ProviderSettingsGateway {
  const FixedProviderSettingsGateway({this.configured = false});

  final bool configured;

  @override
  Future<ProviderSettings> read() async =>
      ProviderSettings(configured: configured, keySet: configured);

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) =>
      throw UnimplementedError();

  @override
  Future<ProviderSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<ProviderTestResult> testConnection(ProviderSettingsDraft draft) =>
      throw UnimplementedError();
}

/// 可用的模型设置网关：read 回一份完整的 OpenAI-compatible 配置，
/// save/forget 原样回读，连接测试恒成功。
final class EchoingProviderSettingsGateway implements ProviderSettingsGateway {
  EchoingProviderSettingsGateway({required this.configured});

  final bool configured;

  @override
  Future<ProviderSettings> read() async => ProviderSettings(
    configured: configured,
    keySet: configured,
    provider: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.example.com/v1',
    model: 'chat-model',
    temperature: 0.7,
    timeoutSeconds: 60,
  );

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) async => read();

  @override
  Future<ProviderSettings> forgetApiKey() async => read();

  @override
  Future<ProviderTestResult> testConnection(
    ProviderSettingsDraft draft,
  ) async => const ProviderTestResult(
    succeeded: true,
    status: ProviderTestStatus.success,
    message: '连接成功。',
  );
}

/// 设置网关替身：体验偏好可读写并计数写盘，记忆控制/清数据预览默认
/// 给空档位，诊断快照的各字段按需注入（不传即空健康、固定时间戳）。
class FakeSettingsGateway implements SettingsGateway {
  FakeSettingsGateway({
    this.onCleared,
    this.recentRequests,
    this.memoryControls = const MemoryControlsOverview(
      readable: true,
      frozen: [],
      banned: [],
      deletedCount: 0,
    ),
    this.clearPreview = const ClearPreview(
      memoryDirectory: 'C:/qiyu-test/memories',
      sessionCount: 0,
      episodeDayCount: 0,
      frozenCount: 0,
      bannedCount: 0,
      deletedCount: 0,
      snapshotCount: 0,
      providerConfigured: false,
      keySet: false,
    ),
    DateTime? generatedAt,
    String? memoryDirectory,
    FinalizationHealth? finalization,
    DreamHealth? dream,
    Map<String, Object?>? fileHealth,
  }) : diagnosticsGeneratedAt = generatedAt ?? DateTime(2026, 8, 19),
       diagnosticsMemoryDirectory = memoryDirectory ?? 'C:/qiyu-test/memories',
       diagnosticsFinalization = finalization,
       diagnosticsDream = dream,
       diagnosticsFileHealth = fileHealth ?? const {};

  /// 清除成功时的回调：测试用它同步翻转其他网关状态。
  final void Function()? onCleared;

  /// 诊断页「最近请求」的数据源；不给就是空列表。
  final List<RecentRequest>? recentRequests;
  final MemoryControlsOverview memoryControls;
  final ClearPreview clearPreview;
  final DateTime diagnosticsGeneratedAt;
  final String diagnosticsMemoryDirectory;
  final FinalizationHealth? diagnosticsFinalization;
  final DreamHealth? diagnosticsDream;
  final Map<String, Object?> diagnosticsFileHealth;

  bool developerMode = false;
  int clearCalls = 0;

  /// 主持久化链路（Host `/api` 那侧）被写了几次：分节折叠只准走本地
  /// UI 存储，这个计数一次都不该动。
  int prefWrites = 0;

  @override
  Future<ExperiencePreferences> readPreferences() async =>
      ExperiencePreferences(developerMode: developerMode);

  @override
  Future<ExperiencePreferences> savePreferences({
    required bool developerMode,
  }) async {
    prefWrites += 1;
    this.developerMode = developerMode;
    return ExperiencePreferences(developerMode: developerMode);
  }

  @override
  Future<MemoryControlsOverview> readMemoryControls() async => memoryControls;

  @override
  Future<ClearPreview> readClearPreview() async => clearPreview;

  @override
  Future<void> clearData() async {
    clearCalls += 1;
    onCleared?.call();
  }

  @override
  Future<DiagnosticsSnapshot> readDiagnostics() async => DiagnosticsSnapshot(
    generatedAt: diagnosticsGeneratedAt,
    memoryDirectory: diagnosticsMemoryDirectory,
    recentRequests: recentRequests ?? const [],
    finalization: diagnosticsFinalization,
    dream: diagnosticsDream,
    fileHealth: diagnosticsFileHealth,
  );
}

/// 聊天网关替身：restore 回放 [restored] 快照，deliver 默认发一轮
/// 完整交付事件（accepted → waiting → delta → message → state → done），
/// `.silent` 命名构造改为不发任何事件的空流。
final class FakeLocalChatGateway implements StreamingLocalChatGateway {
  FakeLocalChatGateway({
    this.restored = const LocalChatSnapshot(sessionId: 'session-1', messages: []),
    this.transcribeText = '语音测试转写',
    this.replySources = const [ReplySource.local],
    this.sendError,
    this.failuresRemaining = 0,
  }) : silent = false;

  /// deliver 不发任何事件：只借聊天页外壳验布局与导航的用例用。
  FakeLocalChatGateway.silent({
    this.restored = const LocalChatSnapshot(sessionId: 'session-1', messages: []),
    this.transcribeText = '语音测试转写',
  }) : replySources = const [ReplySource.local],
       sendError = null,
       failuresRemaining = 0,
       silent = true;

  final LocalChatSnapshot restored;
  final String transcribeText;

  /// 每次发送对应的完成来源（超出后沿用最后一个），供降级→恢复的
  /// 连续轮次测试。
  final List<ReplySource> replySources;

  final Object? sendError;
  int failuresRemaining;
  final bool silent;
  final List<String> sentTexts = [];
  final List<String> sentRequestIds = [];

  @override
  Future<LocalChatSnapshot> restore({String? sessionId}) async => restored;

  @override
  Future<bool> cancel(String requestId) async => true;

  @override
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
  }) async => transcribeText;

  @override
  Stream<LocalChatDeliveryEvent> deliver({
    required String requestId,
    required String text,
    String? sessionId,
  }) async* {
    sentTexts.add(text);
    sentRequestIds.add(requestId);
    if (sendError case final error? when failuresRemaining > 0) {
      failuresRemaining -= 1;
      throw error;
    }
    if (silent) {
      return;
    }
    final index = sentTexts.length - 1;
    final source = index < replySources.length
        ? replySources[index]
        : replySources.last;
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.accepted,
      requestId: requestId,
      sessionId: restored.sessionId,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.waiting,
      requestId: requestId,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.delta,
      requestId: requestId,
      text: '咋了',
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.message,
      requestId: requestId,
      messages: const ['咋了'],
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.state,
      requestId: requestId,
      source: source,
      fallbackReason: source == ReplySource.local ? FallbackReason.noLlmConfig : null,
    );
    yield LocalChatDeliveryEvent(
      kind: LocalChatEventKind.done,
      requestId: requestId,
    );
  }
}

/// 记忆网关替身：空记忆总览加一组标准动作回执，揭示恒失败
/// （空档案没有可揭示内容）。
final class FakeMemoryGateway implements MemoryGateway {
  @override
  Future<MemoryOverview> fetchOverview() async => MemoryOverview(
    generatedAt: DateTime(2026, 8, 19),
    recent: const MemoryRecentSection(days: []),
    longTerm: const MemoryLongTermSection(
      present: false,
      readable: true,
      organizedAt: null,
      groups: [],
    ),
    persona: const MemoryPersonaSection(branches: []),
    relationship: const MemoryRelationshipSection(
      present: false,
      stage: null,
      since: null,
      confirmed: [],
      probes: [],
      recentChanges: [],
      sharedPast: [],
    ),
    recovery: const MemoryRecoverySection(
      healthy: true,
      quarantinedFiles: 0,
      findings: [],
    ),
  );

  @override
  Future<MemoryItemDetail?> fetchItemDetail(String id) async => null;

  @override
  Future<void> setAppellation(String appellation) async {}

  @override
  Future<MemoryActionResult> editItem(String id, String text) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已保存。',
      );

  @override
  Future<MemoryActionResult> freezeItem(String id) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已暂停使用。',
      );

  @override
  Future<MemoryActionResult> unfreezeItem(String id) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已恢复使用。',
      );

  @override
  Future<MemoryActionResult> banItem(String id) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已不再提起。',
      );

  @override
  Future<MemoryActionResult> unbanItem(String id) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已解除禁提。',
      );

  @override
  Future<MemoryDeleteImpact?> previewDelete(String id) async => null;

  @override
  Future<MemoryActionResult> deleteItem(String id) async =>
      const MemoryActionResult(
        status: MemoryActionStatus.success,
        message: '已删除。',
      );

  @override
  Future<MemoryActionResult> revealItem(
    String id, {
    String field = 'content',
  }) async => const MemoryActionResult(
    status: MemoryActionStatus.failed,
    message: '无可展示内容。',
  );
}
