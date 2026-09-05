import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'dream.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_controls.dart';
import 'memory_recovery.dart';
import 'persona_tree.dart';

/// 开发者诊断最近请求环形缓冲容量：只保留最近若干条、仅存内存、
/// 不落盘；条目只有时间、来源、结果与脱敏后的诊断细节，绝不记录
/// 任何用户输入或回复正文。
const requestDiagnosticsCapacity = 50;

/// 最近请求条目来源（哪条管线发起了请求）。只列真实存在记录点的
/// 来源，不做投机预留。
abstract final class RecentRequestSources {
  static const chat = 'chat';
  static const providerTest = 'provider-test';
  static const finalization = 'finalization';
  static const dream = 'dream';
}

/// 最近请求结果分类。
abstract final class RecentRequestResults {
  static const ok = 'ok';
  static const fallback = 'fallback';
  static const failed = 'failed';
  static const skipped = 'skipped';
  static const cancelled = 'cancelled';
}

final class RecentRequestEntry {
  const RecentRequestEntry({
    required this.at,
    required this.source,
    required this.result,
    this.replySource,
    this.fallbackReason,
    this.detail,
  });

  final DateTime at;

  /// 发起管线：chat / provider-test / finalization / dream。
  final String source;

  /// 结果分类：ok / fallback / failed / skipped / cancelled。
  final String result;

  /// 回复来源（local / llm），只对聊天请求有意义。
  final String? replySource;

  /// 回退原因的 wire 名（发生降级时携带）。
  final String? fallbackReason;

  /// 诊断细节：错误码级，写入前已过 [redactDiagnosticText]。
  final String? detail;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'source': source,
    'result': result,
    if (replySource != null) 'replySource': replySource,
    if (fallbackReason != null) 'fallbackReason': fallbackReason,
    if (detail != null) 'detail': detail,
  };
}

/// 本机请求诊断环形缓冲：开发者诊断「最近请求」的唯一数据源。
///
/// 隐私约束：条目结构上不存在用户文本字段；[detail] 在记录时强制
/// 过 [redactDiagnosticText]，密钥、授权头与本机路径不会进入缓冲。
final class RequestDiagnosticsRecorder {
  RequestDiagnosticsRecorder({
    this.capacity = requestDiagnosticsCapacity,
    Clock? clock,
  }) : _clock = clock ?? DateTime.now;

  final int capacity;
  final Clock _clock;
  final List<RecentRequestEntry> _entries = [];

  void record({
    required String source,
    required String result,
    String? replySource,
    String? fallbackReason,
    String? detail,
  }) {
    _entries.add(
      RecentRequestEntry(
        at: _clock(),
        source: source,
        result: result,
        replySource: replySource,
        fallbackReason: fallbackReason,
        detail: detail == null ? null : redactDiagnosticText(detail),
      ),
    );
    while (_entries.length > capacity) {
      _entries.removeAt(0);
    }
  }

  /// 最近请求，最新在前。
  List<RecentRequestEntry> recent() => List.unmodifiable(_entries.reversed);
}

/// 体验与开发者选项（ticket 23）：目前只有开发者模式一项——开启后
/// 设置页才出现开发者诊断入口。默认关闭，不打扰普通用户。
final class ExperienceSettings {
  const ExperienceSettings({this.developerMode = false});

  final bool developerMode;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'developerMode': developerMode,
  };

  factory ExperienceSettings.fromJson(Map<String, Object?> json) =>
      ExperienceSettings(developerMode: json['developerMode'] == true);
}

abstract interface class ExperienceSettingsRepository {
  Future<ExperienceSettings> load();

  Future<ExperienceSettings> save(ExperienceSettings settings);
}

/// 体验选项持久化：runtime 目录下的 `experience.json`，原子写入。
/// 文件缺失或无法读取时回到默认值（开发者模式关闭），绝不阻塞。
final class JsonExperienceSettingsRepository
    implements ExperienceSettingsRepository {
  const JsonExperienceSettingsRepository({
    required this.filePath,
    this.writer = const IoAtomicTextWriter(),
  });

  final String filePath;
  final AtomicTextWriter writer;

  @override
  Future<ExperienceSettings> load() async {
    final file = File(filePath);
    if (!await file.exists()) {
      return const ExperienceSettings();
    }
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      return ExperienceSettings.fromJson(json);
    } on Object {
      return const ExperienceSettings();
    }
  }

  @override
  Future<ExperienceSettings> save(ExperienceSettings settings) async {
    await writer.replace(
      filePath,
      '${const JsonEncoder.withIndent('  ').convert(settings.toJson())}\n',
    );
    return settings;
  }
}

/// episodes 单次扫描结果：后台整理状态与文件健康度共用，避免同一
/// 份诊断快照把日文件读两遍。
final class _EpisodeScan {
  const _EpisodeScan({
    required this.today,
    required this.todayFinalized,
    required this.dayCount,
    required this.unfinalized,
    required this.unreadable,
    required this.pendingBeforeToday,
    required this.unreadableBeforeToday,
  });

  /// pipeline 缺失时的空扫描：今天归档状态未知，计数全为 0。
  _EpisodeScan.empty(this.today)
    : todayFinalized = null,
      dayCount = 0,
      unfinalized = 0,
      unreadable = 0,
      pendingBeforeToday = 0,
      unreadableBeforeToday = 0;

  final String today;

  /// 今天是否已归档；pipeline 缺失时为 null（未知）。
  final bool? todayFinalized;
  final int dayCount;

  /// 全部日期（含今天）里未归档与不可读的天数——文件健康度用。
  final int unfinalized;
  final int unreadable;

  /// 早于今天的日期里未归档与不可读的天数——后台整理状态用：
  /// 当天仍在进行中，不算待补归档。
  final int pendingBeforeToday;
  final int unreadableBeforeToday;
}

/// 开发者诊断快照服务（ticket 23）：把最近请求、后台整理状态、
/// Dream 资格与本地文件健康度汇总为一份只读快照。
///
/// 安全边界：
/// - 全部数据来自既有存储的只读接口，不写任何文件、不触发整理；
/// - 不携带用户输入、回复正文或受控内容，文件健康只有计数与可读性；
/// - 文本细节一律过 [redactDiagnosticText]。
final class DeveloperDiagnosticsService {
  DeveloperDiagnosticsService({
    required this.memoryDirectory,
    required this.recorder,
    this.repository,
    this.episodePipeline,
    this.dreamService,
    this.memoryControls,
    this.personaTree,
    this.memoryRecovery,
    this.providerConfiguredReader,
    Clock? clock,
  }) : _clock = clock ?? DateTime.now;

  final String memoryDirectory;
  final RequestDiagnosticsRecorder recorder;
  final MemoryRepository? repository;
  final EpisodeMemoryPipeline? episodePipeline;
  final DreamService? dreamService;
  final MemoryControlsStore? memoryControls;
  final PersonaTreeStore? personaTree;
  final MemoryRecoveryService? memoryRecovery;

  /// Provider 是否已配置：诊断本身不读凭据，只取布尔事实。
  final Future<bool> Function()? providerConfiguredReader;
  final Clock _clock;

  Future<Map<String, Object?>> snapshot() async {
    final providerConfigured = await providerConfiguredReader?.call() ?? false;
    final episodes = await _episodeScan();
    return {
      'generatedAt': _clock().toUtc().toIso8601String(),
      'memoryDirectory': memoryDirectory,
      'recentRequests': [
        for (final entry in recorder.recent()) entry.toJson(),
      ],
      'finalization': _finalizationHealth(episodes),
      'dream': await _dreamHealth(providerConfigured),
      'fileHealth': await _fileHealth(episodes),
    };
  }

  /// episodes 只遍历一次：finalization 与 fileHealth 两区共用结果。
  Future<_EpisodeScan> _episodeScan() async {
    final today = localSessionDate(_clock());
    final pipeline = episodePipeline;
    if (pipeline == null) {
      return _EpisodeScan.empty(today);
    }
    var todayFinalized = false;
    var unfinalized = 0;
    var unreadable = 0;
    var pendingBeforeToday = 0;
    var unreadableBeforeToday = 0;
    final dates = await pipeline.listEpisodeDates();
    for (final date in dates) {
      final day = await pipeline.readDay(date);
      final usable = day.exists && day.readable;
      if (date == today) {
        todayFinalized = usable && day.finalized;
      } else if (!usable) {
        unreadableBeforeToday += 1;
      } else if (!day.finalized) {
        pendingBeforeToday += 1;
      }
      if (!usable) {
        unreadable += 1;
      } else if (!day.finalized) {
        unfinalized += 1;
      }
    }
    return _EpisodeScan(
      today: today,
      todayFinalized: todayFinalized,
      dayCount: dates.length,
      unfinalized: unfinalized,
      unreadable: unreadable,
      pendingBeforeToday: pendingBeforeToday,
      unreadableBeforeToday: unreadableBeforeToday,
    );
  }

  /// 后台整理状态：以 episodes 落盘事实为准——今天是否已归档、
  /// 早于今天的日期里还有多少未归档/不可读。
  Map<String, Object?> _finalizationHealth(_EpisodeScan episodes) => {
    'today': episodes.today,
    'todayFinalized': episodes.todayFinalized,
    'pendingDays': episodes.pendingBeforeToday,
    'unreadableDays': episodes.unreadableBeforeToday,
  };

  /// Dream 资格事实：日差与 3 天间隔由 DreamService 按资格复查同
  /// 口径给出；Provider 配置是诊断侧补充的事实。
  Future<Map<String, Object?>> _dreamHealth(bool providerConfigured) async {
    final dream = dreamService;
    if (dream == null) {
      return {
        'minIntervalDays': dreamMinIntervalDays,
        'providerConfigured': providerConfigured,
      };
    }
    final facts = await dream.healthFacts(today: localSessionDate(_clock()));
    return {
      'lastSuccessAt': ?facts.lastSuccess?.toUtc().toIso8601String(),
      'daysSinceLastSuccess': ?facts.daysSinceLastSuccess,
      'pending': facts.pending,
      'minIntervalDays': dreamMinIntervalDays,
      'intervalSatisfied': facts.intervalSatisfied,
      'providerConfigured': providerConfigured,
      'eligible': facts.intervalSatisfied && providerConfigured,
    };
  }

  /// 本地文件健康度：只有计数与可读性，绝不携带内容。
  Future<Map<String, Object?>> _fileHealth(_EpisodeScan episodes) async {
    var sessionsReadable = 0;
    var sessionsUnavailable = 0;
    final sessions = repository;
    if (sessions != null) {
      try {
        final listing = await sessions.readHistory();
        sessionsReadable = listing.sessions.length;
        sessionsUnavailable = listing.unavailable.length;
      } on Object {
        sessionsUnavailable = -1;
      }
    }

    return {
      'sessionsReadable': sessionsReadable,
      'sessionsUnavailable': sessionsUnavailable,
      'episodeDays': episodes.dayCount,
      'episodeUnfinalized': episodes.unfinalized,
      'episodeUnreadable': episodes.unreadable,
      'longMemory': await _longMemoryReadability(),
      'dreamState': await _dreamStateReadability(),
      'memoryControls': await _controlsReadability(),
      'personaTreeReadable': await _personaTreeReadable(),
      'recovery': await _recoveryHealth(),
    };
  }

  /// 文件缺失的健康度口径：缺失视为可读（从未产生过材料），不计损坏。
  static Map<String, Object?> _missing() => {'exists': false, 'readable': true};

  static Map<String, Object?> _present(bool readable) => {
    'exists': true,
    'readable': readable,
  };

  /// long-memory 可读性 = 结构可解析（与 Dream/恢复同口径），不是
  /// 单纯的 IO 可读。
  Future<Map<String, Object?>> _longMemoryReadability() async {
    final file = File(path.join(memoryDirectory, 'long-memory.md'));
    if (!await file.exists()) {
      return _missing();
    }
    try {
      final parsed = parseLongMemory(await file.readAsString());
      return _present(parsed.readable);
    } on Object {
      return _present(false);
    }
  }

  /// Dream 状态可读性：缺失视为可读（从未运行），结构损坏不可读。
  Future<Map<String, Object?>> _dreamStateReadability() async {
    final file = File(path.join(memoryDirectory, 'dream', 'state.md'));
    if (!await file.exists()) {
      return _missing();
    }
    final dream = dreamService;
    if (dream == null) {
      return _present(true);
    }
    return _present(await dream.stateReadable());
  }

  Future<Map<String, Object?>> _controlsReadability() async {
    final store = memoryControls;
    if (store == null) {
      return _missing();
    }
    final exists = await store.controlsFile.exists();
    if (!exists) {
      return _missing();
    }
    final controls = await store.load();
    return _present(controls.readable);
  }

  Future<bool?> _personaTreeReadable() async {
    final tree = personaTree;
    if (tree == null) {
      return null;
    }
    try {
      final snapshot = await tree.readSnapshot();
      return snapshot.branches.values.every((branch) => branch.readable);
    } on Object {
      return false;
    }
  }

  Future<Map<String, Object?>> _recoveryHealth() async {
    final recovery = memoryRecovery;
    final report = recovery == null ? null : await recovery.readReport();
    if (report == null) {
      return {'reportExists': false, 'quarantinedFiles': 0};
    }
    return {
      'reportExists': true,
      'quarantinedFiles': report.quarantinedFiles,
      'healthy': report.healthy,
    };
  }
}
