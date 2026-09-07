import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'episode_index.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_controls.dart';
import 'memory_text_primitives.dart';

/// relationship.md 写入关预算（设计定稿：150-300 tokens，按 rune 上限保守计）。
const relationshipMaxRunes = 300;

/// 「当前相处方式」与「近期变化」的保留上限；新换旧，是温度缓慢变化的
/// 结构性保证——可见窗口永远只有最近几条。
const relationshipConfirmedMax = 2;
const relationshipProbeMax = 2;
const relationshipRecentMax = 3;

/// 单条相处方式/近期变化投影到 relationship.md 的长度上限（runes）。
const relationshipLineMaxRunes = 30;

/// 阶段升级的确定性证据阈值（验收要求：互动数量、时间跨度、相互回应、
/// 稳定关系证据）。阈值参考旧 JS 实现并按「宁可慢不可跳」收紧：
/// - 互动数量 = 累计 episode 条目数（每条可追溯到用户轮次）；
/// - 时间跨度 = 首次互动到本次归档的天数；
/// - 相互回应 = 有互动内容的活跃天数（用户反复回来）；
/// - 稳定关系证据 = 深谈信号（deep_talk）数量。
const familiarMinActiveDays = 3;
const familiarMinEntries = 3;
const friendMinSpanDays = 12;
const friendMinActiveDays = 12;
const friendMinDeepTalkSignals = 2;
const deepMinSpanDays = 30;
const deepMinActiveDays = 30;
const deepMinDeepTalkSignals = 4;

/// 关系升级证据：全部来自可追溯的落盘记录。
final class RelationshipEvidence {
  const RelationshipEvidence({
    required this.totalEntries,
    required this.activeDays,
    required this.spanDays,
    required this.deepTalkSignals,
  });

  /// 累计 episode 条目数（互动数量）。
  final int totalEntries;

  /// 有条目的日期数（相互回应：用户反复回来互动）。
  final int activeDays;

  /// 首次互动到本次归档的天数（时间跨度）；无互动为 0。
  final int spanDays;

  /// 深谈信号数量（稳定关系证据）。
  final int deepTalkSignals;
}

/// 纯函数：证据 → 目标阶段。棘轮与「每次日终最多一级」在
/// [RelationshipLifecycle] 应用层保证，这里只回答「证据配得上哪一级」。
RelationshipStage evaluateTargetStage(RelationshipEvidence evidence) {
  if (evidence.spanDays >= deepMinSpanDays &&
      evidence.activeDays >= deepMinActiveDays &&
      evidence.deepTalkSignals >= deepMinDeepTalkSignals) {
    return RelationshipStage.deep;
  }
  if (evidence.spanDays >= friendMinSpanDays &&
      evidence.activeDays >= friendMinActiveDays &&
      evidence.deepTalkSignals >= friendMinDeepTalkSignals) {
    return RelationshipStage.friend;
  }
  if (evidence.activeDays >= familiarMinActiveDays &&
      evidence.totalEntries >= familiarMinEntries) {
    return RelationshipStage.familiar;
  }
  return RelationshipStage.stranger;
}

/// 各阶段行为权限文案的单一来源：relationship.md 的阶段描述与每日状态包的
/// 阶段边界注入共用同一措辞，避免两处维护漂移（产品灵魂阶段表的压缩投影）。
String relationshipStageBehaviorLine(RelationshipStage stage) =>
    switch (stage) {
      RelationshipStage.stranger =>
        '以回应当前话题、倾听为主；不调侃、不翻旧账、不引用共同过往、不主动追问私事。',
      RelationshipStage.familiar =>
        '可以自然提起用户说过的事，偶尔分享自己的想法；仍不调侃、不翻旧账、不主动追问私事。',
      RelationshipStage.friend =>
        '可以轻调侃、翻旧账、直说、引用共同过往，遵循调侃尺度，'
            '用户低落或认真时停止一切调侃；深水区边界仍按当前相处方式试探。',
      RelationshipStage.deep =>
        '可以挑战用户的想法、引用共同的深层过往；用户低落时不逗。',
    };

/// 关系阶段与温度的生命周期（日终归档固定顺序第 3 步）。
///
/// 定稿规则：
/// - 阶段 = 棘轮，初识→熟悉→朋友→深交只升不降；每次日终最多上升一级；
///   单个自然日最多升级一次（since 早于今天才允许升级），重复日终、
///   补扫旧日与跨重启都不会造成重复升级或倒退；
/// - 升级依据全部来自可追溯证据（见 [RelationshipEvidence]），
///   单次热聊或模型主观判断不能越级；
/// - 温度走「近期变化」，新换旧、窗口固定，永不改写阶段权限；
/// - 对话中只落 episode，不更新本文件；新阶段从下一次对话生效；
/// - 升级只更新 stage/since/阶段描述，不写「因某次交流升级」日志。
final class RelationshipLifecycle {
  RelationshipLifecycle({
    required this.memoryDirectory,
    AtomicTextWriter? atomicWriter,
    Clock? clock,
  }) : _atomicWriter = atomicWriter ?? const IoAtomicTextWriter(),
       _clock = clock ?? DateTime.now;

  final String memoryDirectory;
  final AtomicTextWriter _atomicWriter;
  final Clock _clock;

  File get _file => File(path.join(memoryDirectory, 'relationship.md'));

  /// 日终更新：文件缺失则按初识播种；受管结构则按证据整体重建；
  /// 手写不可识别文件绝不改写。播种当晚同样投影当天已有的关系证据。
  ///
  /// 日终模型理解调用产出的关系信号持久化在各日文件元数据里，
  /// [_collectSignals] 与 episode 证据一并读取投影；它们绝不进入
  /// [_collectEvidence] 的阶段计数——棘轮只认 episodes 里可追溯的
  /// 互动证据，模型主观判断不能越级。
  Future<void> updateAtEndOfDay(
    String date,
    EpisodeMemoryPipeline pipeline,
    List<String> episodeDates,
  ) async {
    final file = _file;
    ParsedRelationship parsed;
    if (await file.exists()) {
      final existing = parseRelationshipFile(
        await file.readAsString(encoding: utf8),
      );
      if (existing == null) {
        return;
      }
      parsed = existing;
    } else {
      // 播种：初识起步，since 取最早互动日期；当天没有可追溯互动时
      // 用归档日。
      final earliest = await _earliestEpisodeDate(pipeline, episodeDates);
      parsed = ParsedRelationship(
        stage: RelationshipStage.stranger,
        since: earliest ?? date,
        confirmed: const [],
        probes: const [],
        recentChanges: const [],
      );
    }

    final collected = await _collectEvidence(pipeline, episodeDates, date);
    final today = localSessionDate(_clock());
    final target = evaluateTargetStage(collected.evidence);
    var stage = parsed.stage;
    var since = parsed.since;
    // 棘轮 + 每次日终最多一级 + 单日上限：since 早于今天才允许升级。
    if (target.index > stage.index && since.compareTo(today) < 0) {
      stage = RelationshipStage.values[stage.index + 1];
      since = today;
    }

    final signals = await _collectSignals(pipeline, episodeDates);
    final contents = _compose(
      stage: stage,
      since: since,
      description: _stageDescription(stage, since, date),
      confirmed: _projectBoundaries(signals.opens, relationshipConfirmedMax),
      probes: _projectBoundaries(signals.closes, relationshipProbeMax),
      recentChanges: _projectRecentChanges(signals.changes),
    );
    await _atomicWriter.replace(file.path, contents);
  }

  /// 恢复重建（ticket 21 / T26）：原文件已被恢复流程隔离后，从全部
  /// 有效 episodes 一次性写入整体关系判断。与日终不同：不受「每次最多
  /// 一级」限制——阶段直接取证据配得上的级别；当前轮不变、下轮生效
  /// 由文件写入时机自然保证。文件仍存在（无论可读与否）时绝不动它。
  Future<bool> rebuildForRecovery(
    EpisodeMemoryPipeline pipeline,
    List<String> episodeDates,
    String today,
  ) async {
    final file = _file;
    if (await file.exists()) {
      return false;
    }
    // 证据与最早互动日期一次读取同时得出，不再为 since 全量重读。
    final (:evidence, :earliest) = await _collectEvidence(
      pipeline,
      episodeDates,
      today,
    );
    final stage = evaluateTargetStage(evidence);
    final since = earliest ?? today;
    final signals = await _collectSignals(pipeline, episodeDates);
    final contents = _compose(
      stage: stage,
      since: since,
      description: _stageDescription(stage, since, today),
      confirmed: _projectBoundaries(signals.opens, relationshipConfirmedMax),
      probes: _projectBoundaries(signals.closes, relationshipProbeMax),
      recentChanges: _projectRecentChanges(signals.changes),
    );
    await _atomicWriter.replace(file.path, contents);
    return true;
  }

  /// 全量读取 day 文件：阶段证据与最早互动日期（两处 earliest 判定
  /// 原本逐字相同）一次得出，重建路径借此省掉一次全量重读。
  Future<({RelationshipEvidence evidence, String? earliest})>
  _collectEvidence(
    EpisodeMemoryPipeline pipeline,
    List<String> episodeDates,
    String upTo,
  ) async {
    var totalEntries = 0;
    var deepTalk = 0;
    final activeDates = <String>{};
    String? earliest;
    for (final date in episodeDates) {
      final day = await pipeline.readDay(date);
      if (!day.readable || day.entries.isEmpty) {
        continue;
      }
      activeDates.add(date);
      totalEntries += day.entries.length;
      if (earliest == null || date.compareTo(earliest) < 0) {
        earliest = date;
      }
      deepTalk += day.entries
          .where(
            (entry) =>
                entry.kind == episodeKindRelationshipSignal &&
                entry.signal == 'deep_talk',
          )
          .length;
    }
    final spanDays = earliest == null
        ? 0
        : parseLocalSessionDate(upTo)
              .difference(parseLocalSessionDate(earliest))
              .inDays +
              1;
    return (
      evidence: RelationshipEvidence(
        totalEntries: totalEntries,
        activeDays: activeDates.length,
        spanDays: spanDays,
        deepTalkSignals: deepTalk,
      ),
      earliest: earliest,
    );
  }

  Future<String?> _earliestEpisodeDate(
    EpisodeMemoryPipeline pipeline,
    List<String> episodeDates,
  ) async {
    String? earliest;
    for (final date in episodeDates) {
      final day = await pipeline.readDay(date);
      if (!day.readable || day.entries.isEmpty) {
        continue;
      }
      if (earliest == null || date.compareTo(earliest) < 0) {
        earliest = date;
      }
    }
    return earliest;
  }

  Future<_RelationshipSignals> _collectSignals(
    EpisodeMemoryPipeline pipeline,
    List<String> episodeDates,
  ) async {
    final entries = <EpisodeEntry>[];
    for (final date in episodeDates) {
      final day = await pipeline.readDay(date);
      if (!day.readable) {
        continue;
      }
      entries.addAll(
        day.entries.where(
          (entry) => entry.kind == episodeKindRelationshipSignal,
        ),
      );
      // 日终模型理解的关系信号随日文件元数据持久化，之后每次日终
      // 重建都与 episode 证据一起投影，不会在次日消失；它不参与
      // _collectEvidence 的阶段计数，棘轮证据保持纯 episode 来源。
      final signals = day.understanding?['relationshipSignals'];
      if (signals is List<Object?>) {
        for (final (index, item) in signals
            .whereType<Map<String, Object?>>()
            .indexed) {
          final signal = item['signal'];
          final summary = item['summary'];
          if (signal is! String ||
              summary is! String ||
              summary.trim().isEmpty) {
            continue;
          }
          final parsedDate = parseLocalSessionDate(date);
          entries.add(
            EpisodeEntry(
              id: 'finalize:$date:signal:$index',
              sessionId: 'finalization',
              requestId: 'finalization',
              summary: summary,
              at: DateTime(
                parsedDate.year,
                parsedDate.month,
                parsedDate.day,
                23,
              ).toUtc(),
              kind: episodeKindRelationshipSignal,
              signal: signal,
            ),
          );
        }
      }
    }
    entries.sort((left, right) => left.at.compareTo(right.at));
    return _RelationshipSignals(
      opens: entries
          .where((entry) => entry.signal == 'boundary_open')
          .toList(),
      closes: entries
          .where((entry) => entry.signal == 'boundary_close')
          .toList(),
      changes: entries
          .where(
            (entry) =>
                entry.signal == 'deep_talk' || entry.signal == 'temperature',
          )
          .toList(),
    );
  }

  /// 已确认/待试探：按规范化摘要去重（同一边界只留最新证据），
  /// 按时间保留最近的几条。
  List<String> _projectBoundaries(List<EpisodeEntry> entries, int max) =>
      _keepLatest(entries, max).map(_boundaryLine).toList();

  String _boundaryLine(EpisodeEntry entry) {
    final summary = clipRunes(entry.summary.trim(), relationshipLineMaxRunes);
    final evidence = entry.evidence?.trim() ?? '';
    if (evidence.isEmpty) {
      return '- $summary';
    }
    final line =
        '- $summary（${clipRunes(evidence, relationshipLineMaxRunes)}）';
    return clipRunes(line, relationshipLineMaxRunes * 2 + 4);
  }

  /// 近期变化：深谈与冷暖信号投影为带日期的自然抽象状态，新换旧。
  List<String> _projectRecentChanges(List<EpisodeEntry> entries) =>
      _keepLatest(entries, relationshipRecentMax).map((entry) {
        final date = localSessionDate(entry.at.toLocal());
        return '- $date '
            '${clipRunes(entry.summary.trim(), relationshipLineMaxRunes)}';
      }).toList();

  /// 投影前置（已确认/待试探/近期变化共用）：按规范化摘要去重（同
  /// 一摘要只留最新一条）→ 按时间升序 → 截尾保留最近 [max] 条。
  List<EpisodeEntry> _keepLatest(List<EpisodeEntry> entries, int max) {
    final byKey = <String, EpisodeEntry>{};
    for (final entry in entries) {
      final key = normalizeRelationshipLine(entry.summary);
      if (key.isNotEmpty) {
        byKey[key] = entry;
      }
    }
    final sorted = byKey.values.toList()
      ..sort((left, right) => left.at.compareTo(right.at));
    final overflow = sorted.length - max;
    return sorted.skip(overflow > 0 ? overflow : 0).toList();
  }

  /// 阶段描述：阶段行为边界 + 该用户的可追溯事实（认识时长）。
  /// 相处方式与近期变化的用户细节由专属小节承载，不在此重复。
  String _stageDescription(
    RelationshipStage stage,
    String since,
    String date,
  ) {
    final base = '${stage.wireName}阶段：${relationshipStageBehaviorLine(stage)}';
    if (stage == RelationshipStage.stranger) {
      return base;
    }
    final days = parseLocalSessionDate(date)
        .difference(parseLocalSessionDate(since))
        .inDays;
    if (days <= 0) {
      return base;
    }
    return '$base 已认识 $days 天。';
  }

  /// 删除清除：relationship.md 里命中封禁范围的投影行（当前相处方式
  /// 与近期变化）立即移除；stage/since/阶段描述是结构性字段不受影响。
  /// 手写不可识别文件绝不改写。返回移除行数。
  Future<int> purgeBlockedTitles(Set<String> blocked) async {
    if (blocked.isEmpty) {
      return 0;
    }
    final file = _file;
    if (!await file.exists()) {
      return 0;
    }
    String contents;
    try {
      contents = await file.readAsString(encoding: utf8);
    } on Object {
      return 0;
    }
    final parsed = parseRelationshipFile(contents);
    if (parsed == null) {
      return 0;
    }
    bool hit(String line) =>
        bannedTitleMatches(normalizeRelationshipLine(line), blocked);
    final confirmed = parsed.confirmed.where((line) => !hit(line)).toList();
    final probes = parsed.probes.where((line) => !hit(line)).toList();
    final recent = parsed.recentChanges.where((line) => !hit(line)).toList();
    final removed =
        (parsed.confirmed.length - confirmed.length) +
        (parsed.probes.length - probes.length) +
        (parsed.recentChanges.length - recent.length);
    if (removed == 0) {
      return 0;
    }
    // 原阶段描述逐字保留（结构性描述，不含被删用户内容）。
    final descriptionMatch = RegExp(
      r'^阶段描述\s*[:：]\s*(.+)$',
      multiLine: true,
    ).firstMatch(contents.replaceAll('\r\n', '\n'));
    await _atomicWriter.replace(
      file.path,
      _compose(
        stage: parsed.stage,
        since: parsed.since,
        description: descriptionMatch?.group(1)?.trim() ?? '',
        confirmed: confirmed,
        probes: probes,
        recentChanges: recent,
      ),
    );
    return removed;
  }

  String _compose({
    required RelationshipStage stage,
    required String since,
    required String description,
    required List<String> confirmed,
    required List<String> probes,
    required List<String> recentChanges,
  }) {
    var confirmedKept = confirmed;
    var probesKept = probes;
    var recentKept = recentChanges;
    String build() {
      final buffer = StringBuffer()
        ..writeln('# relationship')
        ..writeln()
        ..writeln('stage: ${stage.wireName}')
        ..writeln('since: $since')
        ..writeln('阶段描述: $description');
      if (confirmedKept.isNotEmpty || probesKept.isNotEmpty) {
        buffer
          ..writeln()
          ..writeln('## 当前相处方式');
        if (confirmedKept.isNotEmpty) {
          buffer.writeln('已确认：');
          confirmedKept.forEach(buffer.writeln);
        }
        if (probesKept.isNotEmpty) {
          buffer.writeln('待试探：');
          probesKept.forEach(buffer.writeln);
        }
      }
      if (recentKept.isNotEmpty) {
        buffer
          ..writeln()
          ..writeln('## 近期变化');
        recentKept.forEach(buffer.writeln);
      }
      return buffer.toString();
    }

    // 写入关：超预算按「近期变化 → 待试探 → 已确认」从最旧开始砍，
    // stage/since/阶段描述永不砍。
    var contents = build();
    while (contents.runes.length > relationshipMaxRunes) {
      if (recentKept.isNotEmpty) {
        recentKept = recentKept.sublist(1);
      } else if (probesKept.isNotEmpty) {
        probesKept = probesKept.sublist(1);
      } else if (confirmedKept.isNotEmpty) {
        confirmedKept = confirmedKept.sublist(1);
      } else {
        break;
      }
      contents = build();
    }
    return contents;
  }
}

final class _RelationshipSignals {
  const _RelationshipSignals({
    required this.opens,
    required this.closes,
    required this.changes,
  });

  final List<EpisodeEntry> opens;
  final List<EpisodeEntry> closes;
  final List<EpisodeEntry> changes;
}

/// 规范化用于去重比较：与 [normalizeMemoryText] 同一规则（折叠空白
/// 并统一大小写）；不改变落盘原文。
String normalizeRelationshipLine(String value) => normalizeMemoryText(value);

/// 从 relationship.md 解析关系阶段；缺失或不可识别按初识处理。
RelationshipStage parseRelationshipStage(String? contents) {
  if (contents == null) {
    return RelationshipStage.stranger;
  }
  final match = RegExp(
    r'^\s*stage\s*[:：]\s*(.+)$',
    multiLine: true,
  ).firstMatch(contents);
  if (match == null) {
    return RelationshipStage.stranger;
  }
  final value = match.group(1)!.trim();
  return relationshipStageFromWire(value) ?? RelationshipStage.stranger;
}
