import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'episode_index.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'open_loop_store.dart';

/// PersonaTree 五个主分支（真树机制定稿）：分支只是分类容器。
final class PersonaBranch {
  const PersonaBranch({
    required this.wireName,
    required this.fileName,
    required this.idPrefix,
    required this.title,
  });

  /// 隐藏动作协议里的 branch 取值。
  final String wireName;
  final String fileName;
  final String idPrefix;
  final String title;
}

const personaBranches = [
  PersonaBranch(
    wireName: 'identity',
    fileName: 'identity.md',
    idPrefix: 'ID',
    title: '身份事实',
  ),
  PersonaBranch(
    wireName: 'expression',
    fileName: 'expression.md',
    idPrefix: 'EX',
    title: '性格表达',
  ),
  PersonaBranch(
    wireName: 'values',
    fileName: 'values.md',
    idPrefix: 'VA',
    title: '价值原则',
  ),
  PersonaBranch(
    wireName: 'preferences',
    fileName: 'preferences.md',
    idPrefix: 'PR',
    title: '偏好习惯',
  ),
  PersonaBranch(
    wireName: 'boundaries',
    fileName: 'boundaries.md',
    idPrefix: 'BO',
    title: '边界禁区',
  ),
];

PersonaBranch? personaBranchForWire(String wireName) {
  for (final branch in personaBranches) {
    if (branch.wireName == wireName) {
      return branch;
    }
  }
  return null;
}

/// 中间理解的三种类型（定稿）。
const middleTypePendingFact = '待稳定事实';
const middleTypeRepeatPattern = '重复模式';
const middleTypeBoundarySignal = '边界信号';

/// 来源性质即叶节点唯一的置信维度（定稿不引入数值 confidence）：
/// 明确自述强于行为观察。
const natureSelfReport = '明确自述';
const natureBehavior = '行为观察';

String natureLabelForWire(String wire) =>
    wire == 'self_report' ? natureSelfReport : natureBehavior;

/// 归档原因（定稿三种）。用户禁提不归档而是直接删除：归档仍可能被
/// Dream 作为负面依据读到，禁提内容必须彻底遗忘。
const archiveReasonCorrection = '明确纠正';
const archiveReasonConflict = '行为冲突';
const archiveReasonDedup = '去重';

/// 叶节点：episode 证据指针（第三层）。episodes 是唯一证据本体，
/// 叶不复制完整上下文，只存定稿的六项可读信息：稳定 ID、日期、
/// 分支视角摘要、来源性质、support/conflict、episode 路径与条目号。
final class PersonaLeaf {
  PersonaLeaf({
    required this.id,
    required this.date,
    required this.nature,
    required this.relation,
    required this.summary,
    required this.episodePath,
    required this.entryRef,
  });

  final String id;
  final String date;

  /// 来源性质（明确自述 / 行为观察），唯一的置信维度。
  final String nature;

  /// 与当前中间理解的关系（support / conflict）。未归类叶暂记 support，
  /// 挂入时按实际关系改写。
  final String relation;
  final String summary;
  final String episodePath;
  final String entryRef;

  String get pointer => '$episodePath [$entryRef]';
}

/// 中间理解（第二层）：只存稳定 ID、类型、候选理解；形成与最近
/// 复核时间作为追溯元数据随节点记录（仓库 ticket 14 验收要求）。
/// 尚未归根的理解放在分支文件「未归根中间节点」区，位置本身表示
/// 未归根，不加状态字段。
final class PersonaMiddle {
  PersonaMiddle({
    required this.id,
    required this.type,
    required this.claim,
    required this.formedOn,
    required this.reviewedOn,
    required this.leaves,
  });

  final String id;
  final String type;
  final String claim;

  /// 形成与最近复核日期作为追溯元数据；解析期先落空串，读到
  /// 元数据行再回填，因此声明为可变字段。
  String formedOn;
  String reviewedOn;
  final List<PersonaLeaf> leaves;
}

/// 归档的中间理解：原节点 + 失效元数据（日期、原因、原关联叶 ID）。
final class _ArchivedMiddle {
  _ArchivedMiddle({
    required this.middle,
    required this.archivedOn,
    required this.reason,
    required this.relatedIds,
  });

  final PersonaMiddle middle;
  final String archivedOn;
  final String reason;
  final List<String> relatedIds;
}

final class _BranchState {
  _BranchState({required this.readable});

  final bool readable;
  final List<PersonaMiddle> unrooted = [];
  final List<PersonaLeaf> unclassified = [];

  /// 根节点区（`## [XX-Rnnn]`）原文块。ticket 14 不创建、不修改根，
  /// 只原样透传，留给 Dream（ticket 16/17）。
  final List<String> rootBlocks = [];

  Iterable<PersonaLeaf> get allLeaves sync* {
    for (final middle in unrooted) {
      yield* middle.leaves;
    }
    yield* unclassified;
  }
}

final class _ArchiveState {
  _ArchiveState({required this.readable});

  final bool readable;
  final List<_ArchivedMiddle> entries = [];

  /// 归档与活跃区共用 ID 空间，归档后不得复用：分配新 ID 前必须
  /// 同时扫归档（这是 ID 分配，不是内容检索）。
  Set<String> usedIds() {
    final ids = <String>{};
    for (final entry in entries) {
      ids.add(entry.middle.id);
      for (final leaf in entry.middle.leaves) {
        ids.add(leaf.id);
      }
    }
    return ids;
  }
}

final _leafLinePattern = RegExp(
  r'^- \[([A-Z]{2}-L\d+)\] (\d{4}-\d{2}-\d{2}) \| '
  r'(明确自述|行为观察) \| (support|conflict) \| (.+)$',
);

/// 叶指针条目号的安全字符集：session ID 为 base64url、index 为数字，
/// requestId 由客户端生成。条目号原样内嵌在叶行里，超出白名单的
/// 字符可能破坏行解析，这类条目不建叶（与 episode 注释标记只认
/// `[A-Za-z0-9_-]` 的不信任立场一致）。
final _safeEntryRefPattern = RegExp(r'^[A-Za-z0-9_:.-]+$');
final _middleHeaderPattern = RegExp(
  r'^### \[([A-Z]{2}-M\d+)\] (待稳定事实|重复模式|边界信号)｜(.+)$',
);
final _middleMetaPattern = RegExp(
  r'^- 形成: (\d{4}-\d{2}-\d{2}) · 复核: (\d{4}-\d{2}-\d{2})$',
);
final _archiveMetaPattern = RegExp(
  r'^- 失效: (\d{4}-\d{2}-\d{2}) · 原因: (.+?) · 关联: (.*)$',
);
final _rootHeaderPattern = RegExp(r'^## \[[A-Z]{2}-R\d+\] ');

/// PersonaTree 真树的叶与中间理解维护（ticket 14）。
///
/// 分工遵循五段节奏定稿：随手记只建叶指针（[createLeaves]，不得建
/// 中间理解）；日终归档建立、挂载与整理中间理解（[processDay]）；
/// 根节点升降与 `persona.md` 刷新归 Dream（ticket 16/17），本服务
/// 绝不创建根、绝不写 persona.md。
///
/// 保守写入门槛（避免把单次情绪写成人格结论）：
/// - 身份事实只能来自明确自述，一个叶即可在日终形成「待稳定事实」；
/// - 行为推断需要至少两个不同日期的一致叶且无冲突，同一天的多次
///   出现只算一个日期；
/// - 单轮自述最多形成候选理解（待稳定事实/重复模式），稳定主张
///   （根）的门槛归 Dream；玩笑与临时情绪按协议不携带画像提示。
///
/// 冲突与撤销：第一条反向证据以 conflict 叶挂在被反驳的理解下
/// （并存不覆盖）；第二个不同日期的反向证据把两条 conflict 叶移入
/// 新的反向中间理解；用户明确纠正时「最新明确陈述胜出」，旧理解
/// 归档；用户禁提高于提炼，命中的理解与叶立即归档或删除，不得
/// 通过抽象改写绕过。归档内容不参与注入与检索。
///
/// 全部文件写入走 temp+rename 原子替换；树文件有内部串行锁，
/// 随手记、日终与禁提即时生效互不覆盖。分支文件存在但无法解析时
/// 绝不覆盖，跳过该分支并记诊断，等待恢复流程（ticket 21）。
final class PersonaTreeStore {
  PersonaTreeStore({
    required this.memoryDirectory,
    required this.episodePipeline,
    this.openLoopStore,
    AtomicTextWriter? atomicWriter,
    void Function(String message)? diagnosticsSink,
  }) : _atomicWriter = atomicWriter ?? const IoAtomicTextWriter(),
       _diagnosticsSink = diagnosticsSink ?? stderrDiagnostics;

  final String memoryDirectory;
  final EpisodeMemoryPipeline episodePipeline;
  final OpenLoopStore? openLoopStore;
  final AtomicTextWriter _atomicWriter;
  final void Function(String message) _diagnosticsSink;

  Future<void> _tail = Future.value();

  File _branchFile(PersonaBranch branch) =>
      File(path.join(memoryDirectory, 'persona-tree', branch.fileName));

  File _archiveFile(PersonaBranch branch) => File(
    path.join(memoryDirectory, 'persona-tree', 'archive', branch.fileName),
  );

  /// 串行化全部树文件写操作：随手记建叶、日终整理与禁提即时生效
  /// 分属不同任务链，必须在此汇合。
  Future<T> _locked<T>(Future<T> Function() body) {
    final result = _tail.then((_) => body());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// 随手记：为带画像提示的 episode 条目建立叶指针。幂等——同一条目
  /// 或同日同摘要的信号不重复建叶（相同信号合并计数）。隐私与禁提
  /// 先于叶写入；失败只记诊断，不影响对话与 episode。
  Future<void> createLeaves(List<EpisodeEntry> entries) => _locked(
    () => _createLeavesLocked(entries),
  );

  /// 日终：先补齐当天可能遗漏的叶（跨重启重建也走这里），再对每个
  /// 分支做中间理解的建立、挂载与整理。幂等。
  ///
  /// [extraEntries] 承载日终模型理解调用产出的画像候选提示（白名单
  /// 校验后）：与当天 episode 条目走同一套建叶闸门（禁提、身份只认
  /// 自述、去重合并），指针落在日文件上。
  Future<void> processDay(
    String date, {
    List<EpisodeEntry> extraEntries = const [],
  }) => _locked(() async {
    final day = await episodePipeline.readDay(date);
    if (!day.readable) {
      _diagnosticsSink('persona day skipped reason=$date-unreadable');
      return;
    }
    final personaEntries = [
      ...day.entries.where((entry) => entry.summary.trim().isNotEmpty),
      ...extraEntries,
    ];
    await _createLeavesLocked(personaEntries);
    final banned = await _bannedTitles();
    for (final branch in personaBranches) {
      try {
        await _organizeBranch(branch, date, banned);
      } on Object catch (error) {
        _diagnosticsSink(
          'persona branch deferred [$error] branch=${branch.wireName}',
        );
      }
    }
  });

  /// 禁提即时生效（用户记忆控制高于 PersonaTree 提炼）：命中禁提的
  /// 中间理解连同其叶直接删除，未归类叶同样删除——不进归档，彻底遗忘。
  /// 返回是否实际清理了内容。
  Future<bool> applyBan(String title) => _locked(() async {
    final normalized = normalizeMemoryText(title);
    if (normalized.isEmpty) {
      return false;
    }
    final banned = await _bannedTitles();
    var applied = false;
    for (final branch in personaBranches) {
      final state = await _readBranch(branch);
      if (!state.readable) {
        _diagnosticsSink(
          'persona ban skipped reason=${branch.wireName}-unreadable',
        );
        continue;
      }
      var changed = false;
      final bannedMiddles = state.unrooted
          .where(
            (middle) =>
                bannedTitleMatches(normalizeMemoryText(middle.claim), banned),
          )
          .toList();
      if (bannedMiddles.isNotEmpty) {
        state.unrooted.removeWhere(bannedMiddles.contains);
        changed = true;
        applied = true;
      }
      final bannedLeaves = state.unclassified
          .where(
            (leaf) =>
                bannedTitleMatches(normalizeMemoryText(leaf.summary), banned),
          )
          .toList();
      if (bannedLeaves.isNotEmpty) {
        state.unclassified.removeWhere(bannedLeaves.contains);
        changed = true;
        applied = true;
      }
      if (changed) {
        await _writeBranch(branch, state);
      }
    }
    return applied;
  });

  Future<Set<String>> _bannedTitles() async {
    final store = openLoopStore;
    if (store == null) {
      return const {};
    }
    return store.bannedTitles();
  }

  /// 建叶（锁内）：只处理同时带 branch 与 nature 的记忆条目。
  Future<void> _createLeavesLocked(List<EpisodeEntry> entries) async {
    final tagged = <PersonaBranch, List<EpisodeEntry>>{};
    for (final entry in entries) {
      final branchWire = entry.personaBranch;
      final natureWire = entry.personaNature;
      if (branchWire == null || natureWire == null) {
        continue;
      }
      final branch = personaBranchForWire(branchWire);
      if (branch == null) {
        continue;
      }
      // 身份事实禁止行为推断：隐藏动作层已校验，这里再兜底。
      if (branch.wireName == 'identity' && natureWire != 'self_report') {
        continue;
      }
      (tagged[branch] ??= []).add(entry);
    }
    if (tagged.isEmpty) {
      return;
    }
    final banned = await _bannedTitles();
    for (final MapEntry(key: branch, value: branchEntries) in tagged.entries) {
      final state = await _readBranch(branch);
      if (!state.readable) {
        _diagnosticsSink(
          'persona leaves skipped reason=${branch.wireName}-unreadable',
        );
        continue;
      }
      final archive = await _readArchive(branch);
      if (!archive.readable) {
        _diagnosticsSink(
          'persona leaves skipped reason=${branch.wireName}-archive-unreadable',
        );
        continue;
      }
      var changed = false;
      for (final entry in branchEntries) {
        // 条目已脱敏，这里再过一层只是防御纵深。
        final summary = redactSessionText(entry.summary).trim();
        if (summary.isEmpty) {
          continue;
        }
        if (!_safeEntryRefPattern.hasMatch(entry.id)) {
          _diagnosticsSink(
            'persona leaf skipped reason=unsafe-entry-ref '
            'branch=${branch.wireName}',
          );
          continue;
        }
        if (bannedTitleMatches(normalizeMemoryText(summary), banned)) {
          _diagnosticsSink(
            'persona leaf skipped reason=banned branch=${branch.wireName}',
          );
          continue;
        }
        final date = localSessionDate(entry.at.toLocal());
        // 幂等与合并：同一 episode 条目不重复建叶（含已挂在根下的叶）；
        // 同日同摘要的近似信号合并为一条叶（重复计数体现在跨日期叶
        // 数量上）。
        final exists =
            state.allLeaves.any(
              (leaf) =>
                  leaf.entryRef == entry.id ||
                  (leaf.date == date &&
                      normalizeMemoryText(leaf.summary) ==
                          normalizeMemoryText(summary)),
            ) ||
            state.rootBlocks.any((block) => block.contains('[${entry.id}]'));
        if (exists) {
          continue;
        }
        final leafId = _nextId(branch, 'L', state, archive);
        state.unclassified.add(
          PersonaLeaf(
            id: leafId,
            date: date,
            nature: natureLabelForWire(entry.personaNature!),
            relation: 'support',
            summary: summary,
            episodePath: _episodePathFor(date),
            entryRef: entry.id,
          ),
        );
        changed = true;
      }
      if (changed) {
        await _writeBranch(branch, state);
      }
    }
  }

  /// 日终单分支整理（锁内）：禁提清扫 → 身份最新陈述胜出 → 挂载 →
  /// 冲突升级 → 从未归类叶建立中间理解。
  Future<void> _organizeBranch(
    PersonaBranch branch,
    String date,
    Set<String> banned,
  ) async {
    final state = await _readBranch(branch);
    if (!state.readable) {
      _diagnosticsSink(
        'persona branch skipped reason=${branch.wireName}-unreadable',
      );
      return;
    }
    final archive = await _readArchive(branch);
    if (!archive.readable) {
      _diagnosticsSink(
        'persona branch skipped reason=${branch.wireName}-archive-unreadable',
      );
      return;
    }
    var changed = false;

    // 1. 禁提清扫：用户禁止提及高于提炼，命中即删除、不进归档。
    final bannedMiddles = state.unrooted
        .where(
          (middle) =>
              bannedTitleMatches(normalizeMemoryText(middle.claim), banned),
        )
        .toList();
    if (bannedMiddles.isNotEmpty) {
      state.unrooted.removeWhere(bannedMiddles.contains);
      changed = true;
    }
    final bannedLeaves = state.unclassified
        .where(
          (leaf) =>
              bannedTitleMatches(normalizeMemoryText(leaf.summary), banned),
        )
        .toList();
    if (bannedLeaves.isNotEmpty) {
      state.unclassified.removeWhere(bannedLeaves.contains);
      changed = true;
    }

    // 2. 身份事实的最新明确陈述胜出：新的自述与旧「待稳定事实」
    //    冲突时归档旧理解，新说法走全新 ID，不拿旧证据背书。
    if (branch.wireName == 'identity') {
      for (final leaf in [...state.unclassified]) {
        if (leaf.nature != natureSelfReport) {
          continue;
        }
        final outdated = state.unrooted.where(
          (middle) =>
              middle.type == middleTypePendingFact &&
              conflictTopic(leaf.summary, middle.claim),
        ).toList();
        for (final middle in outdated) {
          state.unrooted.remove(middle);
          _archiveMiddle(archive, middle, archiveReasonCorrection, date);
          changed = true;
        }
      }
    }

    // 3. 挂载：未归类叶优先归入现有中间理解。同一主张挂 support；
    //    同话题不同主张挂 conflict（并存不覆盖）。身份分支只认自述，
    //    行为叶不得挂载或反驳身份事实。
    for (final leaf in state.unclassified.toList()
      ..sort((left, right) => left.date.compareTo(right.date))) {
      // 身份事实只认自述：行为叶不得挂载或反驳身份理解。
      if (branch.wireName == 'identity' && leaf.nature != natureSelfReport) {
        continue;
      }
      for (final middle in state.unrooted) {
        if (sameClaim(leaf.summary, middle.claim)) {
          state.unclassified.remove(leaf);
          middle.leaves.add(leaf);
          middle.reviewedOn = date;
          changed = true;
          break;
        }
        if (branch.wireName != 'identity' &&
            conflictTopic(leaf.summary, middle.claim)) {
          state.unclassified.remove(leaf);
          middle.leaves.add(
            PersonaLeaf(
              id: leaf.id,
              date: leaf.date,
              nature: leaf.nature,
              relation: 'conflict',
              summary: leaf.summary,
              episodePath: leaf.episodePath,
              entryRef: leaf.entryRef,
            ),
          );
          middle.reviewedOn = date;
          changed = true;
          break;
        }
      }
    }

    // 4. 冲突升级：两个不同日期的反向证据组成新的反向中间理解；
    //    旧理解保留仍成立的支持证据，根级裁决归 Dream。
    if (branch.wireName != 'identity') {
      for (final middle in [...state.unrooted]) {
        final conflicts = middle.leaves
            .where((leaf) => leaf.relation == 'conflict')
            .toList();
        final distinctDates = conflicts
            .map((leaf) => leaf.date)
            .toSet()
            .length;
        if (conflicts.length < 2 || distinctDates < 2) {
          continue;
        }
        middle.leaves.removeWhere(conflicts.contains);
        middle.reviewedOn = date;
        final counterClaim = conflicts
            .map((leaf) => leaf.summary)
            .reduce(
              (left, right) => left.runes.length >= right.runes.length
                  ? left
                  : right,
            );
        final counter = PersonaMiddle(
          id: _nextId(branch, 'M', state, archive),
          type: branch.wireName == 'boundaries'
              ? middleTypeBoundarySignal
              : middleTypeRepeatPattern,
          claim: counterClaim,
          formedOn: date,
          reviewedOn: date,
          leaves: [
            for (final leaf in conflicts)
              PersonaLeaf(
                id: leaf.id,
                date: leaf.date,
                nature: leaf.nature,
                relation: 'support',
                summary: leaf.summary,
                episodePath: leaf.episodePath,
                entryRef: leaf.entryRef,
              ),
          ],
        );
        state.unrooted.add(counter);
        if (middle.leaves.isEmpty) {
          state.unrooted.remove(middle);
          _archiveMiddle(archive, middle, archiveReasonConflict, date);
        }
        changed = true;
      }
    }

    // 5. 建立：剩余未归类叶按同一主张分组，跨时间证据足够才成理解。
    final groups = <List<PersonaLeaf>>[];
    for (final leaf in [...state.unclassified]) {
      List<PersonaLeaf>? target;
      for (final group in groups) {
        if (group.any((member) => sameClaim(member.summary, leaf.summary))) {
          target = group;
          break;
        }
      }
      if (target == null) {
        target = [];
        groups.add(target);
      }
      target.add(leaf);
    }
    for (final group in groups) {
      final distinctDates = group.map((leaf) => leaf.date).toSet().length;
      final hasSelfReport = group.any(
        (leaf) => leaf.nature == natureSelfReport,
      );
      String? type;
      late List<PersonaLeaf> attach;
      switch (branch.wireName) {
        case 'identity':
          // 身份事实只能来自明确自述；行为叶留在未归类等待清理。
          if (hasSelfReport) {
            type = middleTypePendingFact;
            attach = group
                .where((leaf) => leaf.nature == natureSelfReport)
                .toList();
          } else {
            attach = const [];
          }
        case 'boundaries':
          if (hasSelfReport || distinctDates >= 2) {
            type = middleTypeBoundarySignal;
            attach = group;
          } else {
            attach = const [];
          }
        default:
          if (hasSelfReport || distinctDates >= 2) {
            type = middleTypeRepeatPattern;
            attach = group;
          } else {
            attach = const [];
          }
      }
      if (type == null || attach.isEmpty) {
        // 证据不足：单轮行为信号不形成理解，叶留在未归类区。
        continue;
      }
      final claim = attach
          .map((leaf) => leaf.summary)
          .reduce(
            (left, right) => left.runes.length >= right.runes.length
                ? left
                : right,
          );
      final middle = PersonaMiddle(
        id: _nextId(branch, 'M', state, archive),
        type: type,
        claim: claim,
        formedOn: date,
        reviewedOn: date,
        leaves: [...attach],
      );
      state.unclassified.removeWhere(attach.contains);
      state.unrooted.add(middle);
      changed = true;
    }

    if (changed) {
      // 先归档后活跃：两次原子写之间崩溃时，宁可活跃区多出
      // 一条已被归档的理解（下次整理幂等补救），也不能丢归档
      // 记录导致已归档 ID 被复用（定稿禁止）。
      await _writeArchive(branch, archive);
      await _writeBranch(branch, state);
    }
  }

  void _archiveMiddle(
    _ArchiveState archive,
    PersonaMiddle middle,
    String reason,
    String date,
  ) {
    archive.entries.add(
      _ArchivedMiddle(
        middle: middle,
        archivedOn: date,
        reason: reason,
        relatedIds: middle.leaves.map((leaf) => leaf.id).toList(),
      ),
    );
  }

  /// ID = 分支前缀 + 层级 + 递增序号；活跃区与归档区共用序号空间，
  /// 归档后不复用。
  String _nextId(
    PersonaBranch branch,
    String level,
    _BranchState state,
    _ArchiveState archive,
  ) {
    final pattern = RegExp('^${branch.idPrefix}-$level(\\d+)\$');
    var maxNumber = 0;
    void observe(String id) {
      final match = pattern.firstMatch(id);
      if (match == null) {
        return;
      }
      final number = int.tryParse(match.group(1)!) ?? 0;
      if (number > maxNumber) {
        maxNumber = number;
      }
    }

    for (final leaf in state.allLeaves) {
      observe(leaf.id);
    }
    for (final middle in state.unrooted) {
      observe(middle.id);
    }
    for (final block in state.rootBlocks) {
      for (final match in RegExp('${branch.idPrefix}-[RML]\\d+')
          .allMatches(block)) {
        observe(match.group(0)!);
      }
    }
    for (final id in archive.usedIds()) {
      observe(id);
    }
    return '${branch.idPrefix}-$level${(maxNumber + 1).toString().padLeft(3, '0')}';
  }

  String _episodePathFor(String date) =>
      'episodes/${date.substring(0, 4)}/${date.substring(5, 7)}/$date.md';

  Future<_BranchState> _readBranch(PersonaBranch branch) async {
    final file = _branchFile(branch);
    if (!await file.exists()) {
      return _BranchState(readable: true);
    }
    String contents;
    try {
      contents = await file.readAsString(encoding: utf8);
    } on Object {
      return _BranchState(readable: false);
    }
    return _parseActive(contents);
  }

  Future<_ArchiveState> _readArchive(PersonaBranch branch) async {
    final file = _archiveFile(branch);
    if (!await file.exists()) {
      return _ArchiveState(readable: true);
    }
    String contents;
    try {
      contents = await file.readAsString(encoding: utf8);
    } on Object {
      return _ArchiveState(readable: false);
    }
    return _parseArchive(contents);
  }

  _BranchState _parseActive(String contents) {
    final state = _BranchState(readable: true);
    PersonaMiddle? currentMiddle;
    var section = 'header';
    final rootBlock = StringBuffer();
    for (final rawLine in contents.replaceAll('\r\n', '\n').split('\n')) {
      final line = rawLine.trimRight();
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        if (section == 'root') {
          rootBlock.writeln(line);
        }
        continue;
      }
      if (trimmed.startsWith('## ')) {
        if (section == 'root') {
          state.rootBlocks.add(rootBlock.toString().trimRight());
          rootBlock.clear();
        }
        currentMiddle = null;
        if (trimmed == '## 未归根中间节点') {
          section = 'unrooted';
        } else if (trimmed == '## 未归类叶') {
          section = 'unclassified';
        } else if (_rootHeaderPattern.hasMatch(trimmed)) {
          section = 'root';
          rootBlock.writeln(line);
        } else {
          return _BranchState(readable: false);
        }
        continue;
      }
      switch (section) {
        case 'header':
          if (!trimmed.startsWith('# ')) {
            return _BranchState(readable: false);
          }
        case 'unrooted':
          final middleMatch = _middleHeaderPattern.firstMatch(trimmed);
          if (middleMatch != null) {
            currentMiddle = PersonaMiddle(
              id: middleMatch.group(1)!,
              type: middleMatch.group(2)!,
              claim: middleMatch.group(3)!,
              formedOn: '',
              reviewedOn: '',
              leaves: [],
            );
            state.unrooted.add(currentMiddle);
            continue;
          }
          final middle = currentMiddle;
          if (middle == null) {
            return _BranchState(readable: false);
          }
          final metaMatch = _middleMetaPattern.firstMatch(trimmed);
          if (metaMatch != null) {
            _setMiddleMeta(middle, metaMatch.group(1)!, metaMatch.group(2)!);
            continue;
          }
          final leaf = _parseLeafLine(trimmed);
          if (leaf == null) {
            return _BranchState(readable: false);
          }
          middle.leaves.add(leaf);
        case 'unclassified':
          final leaf = _parseLeafLine(trimmed);
          if (leaf == null) {
            return _BranchState(readable: false);
          }
          state.unclassified.add(leaf);
        case 'root':
          rootBlock.writeln(line);
        default:
          return _BranchState(readable: false);
      }
    }
    if (section == 'root') {
      state.rootBlocks.add(rootBlock.toString().trimRight());
    }
    return state;
  }

  /// PersonaMiddle 的 formedOn/reviewedOn 声明为 final 之外的普通字段：
  /// 解析期先落空串，读到元数据行再回填。
  void _setMiddleMeta(PersonaMiddle middle, String formed, String reviewed) {
    middle.formedOn = formed;
    middle.reviewedOn = reviewed;
  }

  PersonaLeaf? _parseLeafLine(String line) {
    final match = _leafLinePattern.firstMatch(line);
    if (match == null) {
      return null;
    }
    final rest = match.group(5)!;
    final separator = rest.lastIndexOf(' | ');
    if (separator < 0) {
      return null;
    }
    final pointer = rest.substring(separator + 3);
    final bracket = pointer.lastIndexOf(' [');
    if (bracket < 0 || !pointer.endsWith(']')) {
      return null;
    }
    return PersonaLeaf(
      id: match.group(1)!,
      date: match.group(2)!,
      nature: match.group(3)!,
      relation: match.group(4)!,
      summary: rest.substring(0, separator),
      episodePath: pointer.substring(0, bracket),
      entryRef: pointer.substring(bracket + 2, pointer.length - 1),
    );
  }

  _ArchiveState _parseArchive(String contents) {
    final archive = _ArchiveState(readable: true);
    PersonaMiddle? currentMiddle;
    String? archivedOn;
    String? reason;
    List<String>? relatedIds;
    var sawHeader = false;
    void flush() {
      final middle = currentMiddle;
      if (middle != null && archivedOn != null && reason != null) {
        archive.entries.add(
          _ArchivedMiddle(
            middle: middle,
            archivedOn: archivedOn!,
            reason: reason!,
            relatedIds: relatedIds ?? const [],
          ),
        );
      }
      currentMiddle = null;
      archivedOn = null;
      reason = null;
      relatedIds = null;
    }

    for (final rawLine in contents.replaceAll('\r\n', '\n').split('\n')) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      if (trimmed.startsWith('# ')) {
        if (sawHeader) {
          return _ArchiveState(readable: false);
        }
        sawHeader = true;
        continue;
      }
      if (trimmed.startsWith('### ')) {
        flush();
        final match = _middleHeaderPattern.firstMatch(trimmed);
        if (match == null) {
          return _ArchiveState(readable: false);
        }
        currentMiddle = PersonaMiddle(
          id: match.group(1)!,
          type: match.group(2)!,
          claim: match.group(3)!,
          formedOn: '',
          reviewedOn: '',
          leaves: [],
        );
        continue;
      }
      final middle = currentMiddle;
      if (middle == null) {
        return _ArchiveState(readable: false);
      }
      final archiveMeta = _archiveMetaPattern.firstMatch(trimmed);
      if (archiveMeta != null) {
        archivedOn = archiveMeta.group(1);
        reason = archiveMeta.group(2);
        relatedIds = archiveMeta
            .group(3)!
            .split(',')
            .map((id) => id.trim())
            .where((id) => id.isNotEmpty)
            .toList();
        continue;
      }
      final metaMatch = _middleMetaPattern.firstMatch(trimmed);
      if (metaMatch != null) {
        _setMiddleMeta(middle, metaMatch.group(1)!, metaMatch.group(2)!);
        continue;
      }
      final leaf = _parseLeafLine(trimmed);
      if (leaf == null) {
        return _ArchiveState(readable: false);
      }
      middle.leaves.add(leaf);
    }
    flush();
    return archive;
  }

  Future<void> _writeBranch(PersonaBranch branch, _BranchState state) async {
    final file = _branchFile(branch);
    final empty =
        state.unrooted.isEmpty &&
        state.unclassified.isEmpty &&
        state.rootBlocks.isEmpty;
    if (empty) {
      if (await file.exists()) {
        await file.delete();
      }
      return;
    }
    final buffer = StringBuffer()..writeln('# ${branch.title}');
    if (state.unrooted.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## 未归根中间节点');
      for (final middle in state.unrooted) {
        _writeMiddleBlock(buffer, middle);
      }
    }
    for (final block in state.rootBlocks) {
      buffer
        ..writeln()
        ..write(block)
        ..writeln();
    }
    if (state.unclassified.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## 未归类叶');
      for (final leaf in state.unclassified) {
        buffer.writeln(_leafLine(leaf));
      }
    }
    await _atomicWriter.replace(file.path, buffer.toString());
  }

  void _writeMiddleBlock(StringBuffer buffer, PersonaMiddle middle) {
    buffer
      ..writeln()
      ..writeln('### [${middle.id}] ${middle.type}｜${middle.claim}');
    // 元数据缺失（手改文件）时省略该行而不是写空日期：
    // 空日期行解析不回来，会把可恢复文件变成永久不可读。
    if (middle.formedOn.isNotEmpty && middle.reviewedOn.isNotEmpty) {
      buffer.writeln('- 形成: ${middle.formedOn} · 复核: ${middle.reviewedOn}');
    }
    for (final leaf in middle.leaves) {
      buffer.writeln(_leafLine(leaf));
    }
  }

  String _leafLine(PersonaLeaf leaf) =>
      '- [${leaf.id}] ${leaf.date} | ${leaf.nature} | ${leaf.relation} | '
      '${leaf.summary} | ${leaf.pointer}';

  Future<void> _writeArchive(
    PersonaBranch branch,
    _ArchiveState archive,
  ) async {
    final file = _archiveFile(branch);
    if (archive.entries.isEmpty) {
      // 归档只增不减；没有归档内容时不建文件。
      return;
    }
    final buffer = StringBuffer()..writeln('# ${branch.title}（归档）');
    for (final entry in archive.entries) {
      final middle = entry.middle;
      buffer
        ..writeln()
        ..writeln('### [${middle.id}] ${middle.type}｜${middle.claim}')
        ..writeln(
          '- 失效: ${entry.archivedOn} · 原因: ${entry.reason} · '
          '关联: ${entry.relatedIds.join(', ')}',
        );
      if (middle.formedOn.isNotEmpty && middle.reviewedOn.isNotEmpty) {
        buffer.writeln('- 形成: ${middle.formedOn} · 复核: ${middle.reviewedOn}');
      }
      for (final leaf in middle.leaves) {
        buffer.writeln(_leafLine(leaf));
      }
    }
    await _atomicWriter.replace(file.path, buffer.toString());
  }
}
