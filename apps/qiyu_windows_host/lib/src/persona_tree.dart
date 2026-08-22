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
    required this.personaTitle,
  });

  /// 隐藏动作协议里的 branch 取值。
  final String wireName;
  final String fileName;
  final String idPrefix;
  final String title;

  /// persona.md 投影五节的节标题（定稿措辞与分支标题不同）。
  final String personaTitle;
}

const personaBranches = [
  PersonaBranch(
    wireName: 'identity',
    fileName: 'identity.md',
    idPrefix: 'ID',
    title: '身份事实',
    personaTitle: '身份与客观事实',
  ),
  PersonaBranch(
    wireName: 'expression',
    fileName: 'expression.md',
    idPrefix: 'EX',
    title: '性格表达',
    personaTitle: '性格与表达',
  ),
  PersonaBranch(
    wireName: 'values',
    fileName: 'values.md',
    idPrefix: 'VA',
    title: '价值原则',
    personaTitle: '价值观与原则',
  ),
  PersonaBranch(
    wireName: 'preferences',
    fileName: 'preferences.md',
    idPrefix: 'PR',
    title: '偏好习惯',
    personaTitle: '偏好与习惯',
  ),
  PersonaBranch(
    wireName: 'boundaries',
    fileName: 'boundaries.md',
    idPrefix: 'BO',
    title: '边界禁区',
    personaTitle: '边界与禁区',
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

/// 组内最长的摘要作为主张原文；同长取先出现者。
String _longestSummary(Iterable<PersonaLeaf> leaves) => leaves
    .map((leaf) => leaf.summary)
    .reduce((left, right) => left.runes.length >= right.runes.length ? left : right);

/// 归档原因（定稿三种）。用户禁提不归档而是直接删除：归档仍可能被
/// Dream 作为负面依据读到，禁提内容必须彻底遗忘。
const archiveReasonCorrection = '明确纠正';
const archiveReasonConflict = '行为冲突';
const archiveReasonDedup = '去重';

/// 根主张上限（runes）：一句稳定主张，与中间理解同源限长。
const rootClaimMaxRunes = 60;

/// 每个中间理解最多保留的代表性叶指针数（定稿）：多余同义指针由
/// Dream 清理，优先保留最早、最近与跨日期覆盖。
const personaMiddleMaxLeaves = 6;

/// 孤儿叶保留天数（定稿）：未挂到任何中间理解的叶超过该天数仍未
/// 形成模式时，由 Dream 删除叶指针，episode 本体永久保留。
const personaOrphanLeafKeepDays = 30;

/// persona.md 热层投影预算（runes）：300–600 tokens 定稿取上限，
/// 保守按 1 rune ≈ 1 token。
const personaMaxRunes = 600;

/// 热层预算超限时的投影裁剪顺序（定稿）：偏好习惯、性格表达先省略，
/// 身份事实最后省略；边界禁区不在裁剪顺序里，永不裁掉。
const personaTrimOrder = ['偏好与习惯', '性格与表达', '价值观与原则', '身份与客观事实'];

/// 超预算时按 [personaTrimOrder] 从第一个可裁小节尾部丢弃一条；
/// 只剩边界禁区等不可裁内容时返回 false。persona.md 写盘与注入关
/// [clipPersonaBlock] 共用同一砍序。
bool _dropOneByTrimOrder(List<(String, List<String>)> sections) {
  for (final title in personaTrimOrder) {
    final section = sections.where((entry) => entry.$1 == title).firstOrNull;
    if (section == null || section.$2.isEmpty) {
      continue;
    }
    section.$2.removeLast();
    return true;
  }
  return false;
}

/// 根主张禁止携带的时间限定词（定稿）：带时间限定的近况不得升根。
final rootTimeWordPattern = RegExp(
  r'最近|这周|这几天|本周|上周|下周|今天|昨天|明天|前天|近期|这段时间|暂时|目前',
);

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

  /// 复制叶并按需改写 relation（挂载为 conflict、升级回 support）或
  /// summary（条目修正同步）；其余证据指针字段原样保留。
  PersonaLeaf copyWith({String? relation, String? summary}) => PersonaLeaf(
    id: id,
    date: date,
    nature: nature,
    relation: relation ?? this.relation,
    summary: summary ?? this.summary,
    episodePath: episodePath,
    entryRef: entryRef,
  );
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

/// 根节点（第一层）：只存稳定 ID 与一句无时间词的稳定人物主张
/// （定稿不保存 confidence、priority、version、证据计数或投影开关）。
/// 支持它的中间理解嵌套在下方；证据数量和跨度从子树计算。
final class PersonaRoot {
  PersonaRoot({required this.id, required this.claim, required this.middles});

  final String id;

  /// 稳定主张。合并（去重）时幸存根吸收合并后的主张，因此可变。
  String claim;
  final List<PersonaMiddle> middles;

  Iterable<PersonaLeaf> get allLeaves sync* {
    for (final middle in middles) {
      yield* middle.leaves;
    }
  }
}

/// 归档的根节点：原根（降根时子树已退回未归根区，纠正时整条路径
/// 随迁）+ 失效元数据（日期、原因、原关联中间理解 ID）。
final class _ArchivedRoot {
  _ArchivedRoot({
    required this.root,
    required this.archivedOn,
    required this.reason,
    required this.relatedIds,
  });

  final PersonaRoot root;
  final String archivedOn;
  final String reason;
  final List<String> relatedIds;
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

  /// 根节点区（`## [XX-Rnnn]`）：ticket 17 起结构化解析。日终链路
  /// 只维护根下中间理解（挂载、冲突升级、身份纠正），根的升降与
  /// persona.md 刷新仍只归 Dream。
  final List<PersonaRoot> roots = [];

  /// 全部叶（含根下中间理解的叶）：建叶幂等与 ID 分配共用。
  Iterable<PersonaLeaf> get allLeaves sync* {
    for (final middle in unrooted) {
      yield* middle.leaves;
    }
    for (final root in roots) {
      yield* root.allLeaves;
    }
    yield* unclassified;
  }

  /// 全部中间理解（未归根区 + 根下），按先未归根后根下的顺序。
  Iterable<PersonaMiddle> get allMiddles sync* {
    yield* unrooted;
    for (final root in roots) {
      yield* root.middles;
    }
  }
}

final class _ArchiveState {
  _ArchiveState({required this.readable});

  final bool readable;
  final List<_ArchivedMiddle> entries = [];
  final List<_ArchivedRoot> rootEntries = [];

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
    for (final entry in rootEntries) {
      ids.add(entry.root.id);
      for (final middle in entry.root.middles) {
        ids.add(middle.id);
        for (final leaf in middle.leaves) {
          ids.add(leaf.id);
        }
      }
      ids.addAll(entry.relatedIds);
    }
    return ids;
  }

  /// 归档主张（根与中间理解）：Dream 只把归档当作「已被纠正、不得
  /// 用旧证据复活」的负面依据，升根前逐一比对。
  List<String> archivedClaims() => [
    for (final entry in rootEntries) entry.root.claim,
    for (final entry in entries) entry.middle.claim,
  ];
}

/// Dream 对 PersonaTree 的结构提案（ticket 17）。校验在 Dream 侧
/// 完成（门槛、冲突、敏感、禁提、防复活），本服务落盘时只做存在性
/// 防御。全部操作都以分支为单位。
sealed class PersonaDreamOp {
  const PersonaDreamOp(this.branchWire);

  final String branchWire;
}

/// 把未归根中间理解升为新根。
final class PersonaPromoteOp extends PersonaDreamOp {
  const PersonaPromoteOp(
    super.branchWire, {
    required this.claim,
    required this.middleIds,
  });

  final String claim;
  final List<String> middleIds;
}

/// 把与已有根同主张的未归根中间理解归入该根。
final class PersonaAbsorbOp extends PersonaDreamOp {
  const PersonaAbsorbOp(
    super.branchWire, {
    required this.rootId,
    required this.middleIds,
  });

  final String rootId;
  final List<String> middleIds;
}

/// 降根：旧根移入归档，子树退回未归根区。只有存在真实反向中间
/// 理解时才允许，[counterId] 即该反向理解的 ID。
final class PersonaDemoteOp extends PersonaDreamOp {
  const PersonaDemoteOp(
    super.branchWire, {
    required this.rootId,
    required this.counterId,
  });

  final String rootId;
  final String counterId;
}

/// 同义去重 / 过度细分合并：幸存根吸收其余根的子树并改用合并主张。
final class PersonaMergeOp extends PersonaDreamOp {
  const PersonaMergeOp(
    super.branchWire, {
    required this.claim,
    required this.rootIds,
  });

  final String claim;
  final List<String> rootIds;
}

/// 单分支只读快照：Dream 组装模型输入与校验提案的事实来源。
final class PersonaBranchSnapshot {
  const PersonaBranchSnapshot({
    required this.readable,
    this.roots = const [],
    this.unrooted = const [],
    this.archivedClaims = const [],
    this.unclassified = const [],
    this.archiveReadable = true,
  });

  final bool readable;
  final List<PersonaRoot> roots;
  final List<PersonaMiddle> unrooted;

  /// 归档主张（根与中间理解）：只作「不得用旧证据复活」的负面依据。
  final List<String> archivedClaims;

  /// 归档文件是否可读（ticket 21）：归档无法恢复时，受影响分支必须
  /// 暂停根节点升降——没有负面依据的升根可能复活已被纠正的旧画像。
  final bool archiveReadable;

  /// 未归类叶（等待日终整理的证据指针）：Dream 不消费，供记忆中心
  /// 删除预览与 applyBan 的实际清除范围对齐。
  final List<PersonaLeaf> unclassified;
}

/// 全树只读快照。
final class PersonaTreeSnapshot {
  const PersonaTreeSnapshot({required this.branches});

  /// 按 branch wireName 索引。
  final Map<String, PersonaBranchSnapshot> branches;
}

/// Dream 变更应用结果：[outcomes] 与输入 ops 一一对应，null 表示已
/// 落盘，否则是跳过原因码（存在性防御）。只含原因码，不含主张原文。
final class PersonaDreamApplyResult {
  const PersonaDreamApplyResult({required this.outcomes});

  final List<String?> outcomes;

  int get appliedCount => outcomes.where((outcome) => outcome == null).length;

  int get skippedCount => outcomes.length - appliedCount;
}

/// 根主张公共闸门：返回失败原因码，null 为通过。定稿要求根主张是
/// 一句无时间词的稳定人物主张，且不携带敏感或禁提内容。
String? rootClaimGateFailure(String claim, {required Set<String> banned}) {
  final trimmed = claim.trim();
  if (trimmed.isEmpty) {
    return 'empty-claim';
  }
  if (trimmed.runes.length > rootClaimMaxRunes) {
    return 'long-claim';
  }
  if (redactSessionText(trimmed) != trimmed) {
    return 'sensitive-claim';
  }
  if (bannedMemoryText(trimmed, banned)) {
    return 'banned-claim';
  }
  if (rootTimeWordPattern.hasMatch(trimmed)) {
    return 'time-word-claim';
  }
  return null;
}

/// 升根门槛（定稿表）：按分支与支持叶证据判断。返回失败原因码，
/// null 为通过。调用方必须先确认无未解决冲突（无 conflict 叶）。
String? promotionGateFailure(
  PersonaBranch branch,
  List<PersonaLeaf> supportLeaves,
) {
  if (supportLeaves.isEmpty) {
    return 'insufficient-evidence';
  }
  int spanDays(List<String> dates) {
    if (dates.length < 2) {
      return 0;
    }
    final sorted = [...dates]..sort();
    return dateSpanDays(sorted.first, sorted.last);
  }

  final selfDates = supportLeaves
      .where((leaf) => leaf.nature == natureSelfReport)
      .map((leaf) => leaf.date)
      .toSet()
      .toList();
  final behaviorDates = supportLeaves
      .where((leaf) => leaf.nature == natureBehavior)
      .map((leaf) => leaf.date)
      .toSet()
      .toList();
  switch (branch.wireName) {
    case 'identity':
      // 身份事实只认明确自述，一次清晰自述即可；绝不接受行为推断。
      return selfDates.isNotEmpty ? null : 'identity-needs-self-report';
    case 'boundaries':
      // 明确边界一次自述即可；推断边界需三个不同日期且跨度至少14天。
      if (selfDates.isNotEmpty) {
        return null;
      }
      return behaviorDates.length >= 3 && spanDays(behaviorDates) >= 14
          ? null
          : 'insufficient-evidence';
    default:
      // 明确表达：至少两个不同日期均由用户明确表达，跨度至少7天；
      // 行为推断：至少三个不同日期的一致证据，跨度至少14天。
      if (selfDates.length >= 2 && spanDays(selfDates) >= 7) {
        return null;
      }
      if (behaviorDates.length >= 3 && spanDays(behaviorDates) >= 14) {
        return null;
      }
      return 'insufficient-evidence';
  }
}

/// 两个 YYYY-MM-DD 日期之间的日历日差（later - earlier）。dream.dart
/// 的间隔判定与孤儿叶过期判定共用同一实现。
int dateSpanDays(String earlier, String later) {
  final from = DateTime(
    int.parse(earlier.substring(0, 4)),
    int.parse(earlier.substring(5, 7)),
    int.parse(earlier.substring(8, 10)),
  );
  final to = DateTime(
    int.parse(later.substring(0, 4)),
    int.parse(later.substring(5, 7)),
    int.parse(later.substring(8, 10)),
  );
  return to.difference(from).inDays;
}

/// 定稿冻结标题命中判定，Persona 注入关与 Dream 校验共用。
bool frozenTitleHit(String text, Set<String> frozen) =>
    frozen.isNotEmpty && bannedMemoryText(text, frozen);

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
final _rootHeaderPattern = RegExp(r'^## \[([A-Z]{2}-R\d+)\] (.+)$');

/// PersonaTree 真树的叶、中间理解与根节点维护（ticket 14 / 17）。
///
/// 分工遵循五段节奏定稿：随手记只建叶指针（[createLeaves]，不得建
/// 中间理解）；日终归档建立、挂载与整理中间理解（[processDay]），
/// 日终绝不创建、升级或普通降级根；根节点升降、同义去重、孤儿叶
/// 清理、叶指针裁剪与 `persona.md` 刷新只由 Dream 经
/// [applyDreamChanges] 执行（ticket 17），校验门槛在 Dream 侧，本
/// 服务落盘时仍做存在性防御。用户明确纠正是唯一在线撤根例外：
/// 当轮身份自述与根下理解冲突时立即撤根并重投影
/// （[revokeCorrectedIdentityRoots]），日终身份分支的最新自述同样
/// 可以整条路径归档旧根。
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
  Future<void> createLeaves(List<EpisodeEntry> entries) =>
      _locked(() => _createLeavesLocked(entries));

  /// 用户明确纠正是唯一在线撤根例外（定稿）：当轮身份自述与根下
  /// 身份理解冲突时，立即把旧根从 persona.md 撤下并停止生效——旧根
  /// 连同整条路径移入归档（原因「明确纠正」），persona.md 当场重投影。
  /// 新说法的新叶由 [createLeaves] 先行建立；新中间理解仍等日终建立，
  /// 新路径使用新 ID，不拿旧证据背书。失败只记诊断，不阻塞对话。
  Future<void> revokeCorrectedIdentityRoots(List<EpisodeEntry> entries) =>
      _locked(() async {
        final corrections = entries
            .where(
              (entry) =>
                  entry.personaBranch == 'identity' &&
                  entry.personaNature == 'self_report' &&
                  entry.summary.trim().isNotEmpty,
            )
            .toList();
        if (corrections.isEmpty) {
          return;
        }
        final branch = personaBranchForWire('identity')!;
        final state = await _readBranch(branch);
        if (!state.readable) {
          _diagnosticsSink(
            'persona correction deferred reason=identity-unreadable',
          );
          return;
        }
        if (state.roots.isEmpty) {
          return;
        }
        final archive = await _readArchive(branch);
        if (!archive.readable) {
          _diagnosticsSink(
            'persona correction deferred reason=identity-archive-unreadable',
          );
          return;
        }
        var changed = false;
        for (final entry in corrections) {
          final summary = redactSessionText(entry.summary).trim();
          if (summary.isEmpty) {
            continue;
          }
          final date = localSessionDate(entry.at.toLocal());
          final outdated = state.roots
              .where(
                (root) => root.middles.any(
                  (middle) =>
                      middle.type == middleTypePendingFact &&
                      conflictTopic(summary, middle.claim),
                ),
              )
              .toList();
          for (final root in outdated) {
            state.roots.remove(root);
            _archiveRoot(
              archive,
              root,
              archiveReasonCorrection,
              date,
              root.middles.map((middle) => middle.id).toList(),
            );
            changed = true;
          }
        }
        if (changed) {
          await _writeArchive(branch, archive);
          await _writeBranch(branch, state);
          await _regeneratePersona();
        }
      });

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
    final blocked = await _blockedTitles();
    final frozen = await _frozenTitles();
    var rootsChanged = false;
    for (final branch in personaBranches) {
      try {
        if (await _organizeBranch(branch, date, blocked, frozen)) {
          rootsChanged = true;
        }
      } on Object catch (error) {
        _diagnosticsSink(
          'persona branch deferred [$error] branch=${branch.wireName}',
        );
      }
    }
    // 身份纠正撤根是唯一在线撤根例外：撤过根就重投影 persona.md。
    if (rootsChanged) {
      await _regeneratePersona();
    }
  });

  /// 封禁清扫：命中封禁集合（禁提 ∪ 删除）的未归根中间理解与未归类
  /// 叶直接删除，不进归档。返回是否删除过内容。[applyBan] 与日终
  /// 整理共用同一清扫口径。
  bool _sweepBanned(_BranchState state, Set<String> banned) {
    var changed = false;
    final bannedMiddles = state.unrooted
        .where((middle) => bannedMemoryText(middle.claim, banned))
        .toList();
    if (bannedMiddles.isNotEmpty) {
      state.unrooted.removeWhere(bannedMiddles.contains);
      changed = true;
    }
    final bannedLeaves = state.unclassified
        .where((leaf) => bannedMemoryText(leaf.summary, banned))
        .toList();
    if (bannedLeaves.isNotEmpty) {
      state.unclassified.removeWhere(bannedLeaves.contains);
      changed = true;
    }
    return changed;
  }

  /// 禁提/删除即时生效（用户记忆控制高于 PersonaTree 提炼）：命中
  /// 封禁集合（禁提 ∪ 删除）的中间理解连同其叶直接删除，未归类叶
  /// 同样删除；命中的根连同整条子树直接删除，根下中间理解命中时
  /// 删除该理解——不进归档，彻底遗忘。根被删除后立即重投影
  /// persona.md。返回是否实际清理了内容。
  Future<bool> applyBan(String title) => _locked(() async {
    final normalized = normalizeMemoryText(title);
    if (normalized.isEmpty) {
      return false;
    }
    final banned = await _blockedTitles();
    var applied = false;
    var rootsChanged = false;
    for (final branch in personaBranches) {
      final state = await _readBranch(branch);
      if (!state.readable) {
        _diagnosticsSink(
          'persona ban skipped reason=${branch.wireName}-unreadable',
        );
        continue;
      }
      var changed = _sweepBanned(state, banned);
      if (changed) {
        applied = true;
      }
      final bannedRoots = state.roots
          .where((root) => bannedMemoryText(root.claim, banned))
          .toList();
      if (bannedRoots.isNotEmpty) {
        state.roots.removeWhere(bannedRoots.contains);
        changed = true;
        applied = true;
        rootsChanged = true;
      }
      for (final root in state.roots) {
        final hitMiddles = root.middles
            .where((middle) => bannedMemoryText(middle.claim, banned))
            .toList();
        if (hitMiddles.isNotEmpty) {
          root.middles.removeWhere(hitMiddles.contains);
          changed = true;
          applied = true;
        }
      }
      if (changed) {
        await _writeBranch(branch, state);
      }
    }
    if (rootsChanged) {
      await _regeneratePersona();
    }
    return applied;
  });

  /// 用户修正 episode 条目后同步叶的摘要副本（ticket 20）：指向该
  /// 条目（entryRef 相同）的叶改用修正文本，关系（support/conflict）
  /// 维持原值等待下一次日终复核重判；叶只是证据指针，不影响
  /// persona.md 投影。分支文件不可读时跳过该分支。返回更新叶数。
  Future<int> resyncLeafSummaries(
    String entryRef,
    String newSummary,
  ) => _locked(() async {
    final summary = redactSessionText(newSummary).trim();
    if (entryRef.isEmpty || summary.isEmpty) {
      return 0;
    }
    var updated = 0;
    for (final branch in personaBranches) {
      final state = await _readBranch(branch);
      if (!state.readable) {
        _diagnosticsSink(
          'persona leaf resync skipped reason=${branch.wireName}-unreadable',
        );
        continue;
      }
      PersonaLeaf? resync(PersonaLeaf leaf) {
        if (leaf.entryRef != entryRef || leaf.summary == summary) {
          return null;
        }
        return leaf.copyWith(summary: summary);
      }

      var changed = false;
      for (var i = 0; i < state.unclassified.length; i += 1) {
        final next = resync(state.unclassified[i]);
        if (next != null) {
          state.unclassified[i] = next;
          changed = true;
          updated += 1;
        }
      }
      for (final middle in state.allMiddles) {
        for (var i = 0; i < middle.leaves.length; i += 1) {
          final next = resync(middle.leaves[i]);
          if (next != null) {
            middle.leaves[i] = next;
            changed = true;
            updated += 1;
          }
        }
      }
      if (changed) {
        await _writeBranch(branch, state);
      }
    }
    return updated;
  });

  /// Dream 只读快照：活跃根、未归根中间理解与归档主张（负面依据）。
  /// 读失败不回 null，用 readable=false 表达，Dream 对该分支不提案。
  Future<PersonaTreeSnapshot> readSnapshot() => _locked(() async {
    final branches = <String, PersonaBranchSnapshot>{};
    for (final branch in personaBranches) {
      final state = await _readBranch(branch);
      if (!state.readable) {
        _diagnosticsSink(
          'persona snapshot partial reason=${branch.wireName}-unreadable',
        );
        branches[branch.wireName] = const PersonaBranchSnapshot(
          readable: false,
        );
        continue;
      }
      final archive = await _readArchive(branch);
      if (!archive.readable) {
        _diagnosticsSink(
          'persona snapshot partial reason=${branch.wireName}-archive-unreadable',
        );
      }
      branches[branch.wireName] = PersonaBranchSnapshot(
        readable: true,
        roots: state.roots,
        unrooted: state.unrooted,
        archivedClaims: archive.readable
            ? archive.archivedClaims()
            : const <String>[],
        unclassified: state.unclassified,
        archiveReadable: archive.readable,
      );
    }
    return PersonaTreeSnapshot(branches: branches);
  });

  /// 备份全部可读的分支与归档文件（ticket 21 / T26：PersonaTree 的
  /// Dream 备份与恢复）。键为相对布局（`identity.md`、
  /// `archive/identity.md`），值为原文；不可读的文件不入备份。
  Future<Map<String, String>> backupFiles() => _locked(() async {
    final files = <String, String>{};
    for (final branch in personaBranches) {
      final active = _branchFile(branch);
      if (await active.exists()) {
        final state = await _readBranch(branch);
        if (state.readable) {
          files[branch.fileName] = await active.readAsString(encoding: utf8);
        }
      }
      final archive = _archiveFile(branch);
      if (await archive.exists()) {
        final state = await _readArchive(branch);
        if (state.readable) {
          files['archive/${branch.fileName}'] =
              await archive.readAsString(encoding: utf8);
        }
      }
    }
    return files;
  });

  /// 用 Dream 备份恢复分支与归档文件（ticket 21）：只接受布局白名单
  /// 内的键，逐文件校验可解析后才原子写入，解析不回来的备份内容一律
  /// 丢弃（绝不把坏备份写成现状）。恢复结束后从活跃根重投影
  /// persona.md；仍有分支不可读时保留旧投影。返回实际落盘的键集合，
  /// 供恢复流程判断哪些原件可以安全清理。
  Future<Set<String>> restoreBackupFiles(Map<String, String> files) =>
      _locked(() async {
        final validNames = {
          for (final branch in personaBranches) branch.fileName,
        };
        final applied = <String>{};
        for (final MapEntry(:key, :value) in files.entries) {
          final archived = key.startsWith('archive/');
          final name = archived ? key.substring('archive/'.length) : key;
          if (!validNames.contains(name) || value.trim().isEmpty) {
            continue;
          }
          final branch = personaBranches.firstWhere(
            (candidate) => candidate.fileName == name,
          );
          if (archived) {
            if (!_parseArchive(value).readable) {
              _diagnosticsSink(
                'persona restore skipped reason=${branch.wireName}-archive-backup-unreadable',
              );
              continue;
            }
            await _atomicWriter.replace(_archiveFile(branch).path, value);
          } else {
            if (!_parseActive(value).readable) {
              _diagnosticsSink(
                'persona restore skipped reason=${branch.wireName}-backup-unreadable',
              );
              continue;
            }
            await _atomicWriter.replace(_branchFile(branch).path, value);
          }
          applied.add(key);
        }
        await _regeneratePersona();
        return applied;
      });

  /// 应用 Dream 已通过校验的根节点提案，并顺带执行 Dream 的维护
  /// 职责（孤儿叶清理、冗余叶裁剪、零中间理解根归档），最后从活跃
  /// 根重投影 persona.md（任一分支不可读时保留旧投影）。落盘时仍做
  /// 存在性防御：ID 不存在或与快照不符的操作跳过并记诊断。
  Future<PersonaDreamApplyResult> applyDreamChanges({
    required String date,
    required List<PersonaDreamOp> ops,
  }) => _locked(() async {
    final outcomes = <String?>[];
    final states = <String, _BranchState>{};
    final archives = <String, _ArchiveState>{};
    for (final branch in personaBranches) {
      states[branch.wireName] = await _readBranch(branch);
      archives[branch.wireName] = await _readArchive(branch);
    }
    final dirty = <String>{};

    void skip(PersonaDreamOp op, String reason) {
      outcomes.add(reason);
      _diagnosticsSink(
        'persona dream op skipped reason=$reason branch=${op.branchWire}',
      );
    }

    for (final op in ops) {
      final branch = personaBranchForWire(op.branchWire);
      final state = states[op.branchWire];
      final archive = archives[op.branchWire];
      if (branch == null ||
          state == null ||
          archive == null ||
          !state.readable ||
          !archive.readable) {
        skip(op, 'branch-unreadable');
        continue;
      }
      switch (op) {
        case PersonaPromoteOp(:final claim, :final middleIds):
          final middles = _collectUnrooted(state, middleIds.toSet());
          if (middles == null) {
            skip(op, middleIds.isEmpty ? 'no-middles' : 'unknown-middle');
            continue;
          }
          state.unrooted.removeWhere(middles.contains);
          final root = PersonaRoot(
            id: _nextId(branch, 'R', state, archive),
            claim: claim.trim(),
            middles: middles,
          );
          state.roots.add(root);
          dirty.add(op.branchWire);
          outcomes.add(null);
        case PersonaAbsorbOp(:final rootId, :final middleIds):
          final root = _findRoot(state, rootId);
          if (root == null) {
            skip(op, 'unknown-root');
            continue;
          }
          final middles = _collectUnrooted(state, middleIds.toSet());
          if (middles == null) {
            skip(op, middleIds.isEmpty ? 'no-middles' : 'unknown-middle');
            continue;
          }
          state.unrooted.removeWhere(middles.contains);
          root.middles.addAll(middles);
          dirty.add(op.branchWire);
          outcomes.add(null);
        case PersonaDemoteOp(:final rootId, :final counterId):
          final root = _findRoot(state, rootId);
          if (root == null) {
            skip(op, 'unknown-root');
            continue;
          }
          // 快照与落盘之间有锁间隔：反向理解也必须仍在未归根区。
          if (_findUnrooted(state, counterId) == null) {
            skip(op, 'unknown-counter');
            continue;
          }
          state.roots.remove(root);
          final related = root.middles.map((middle) => middle.id).toList();
          // 仍有自身证据支持的原中间理解退回未归根区；根壳入归档。
          state.unrooted.addAll(root.middles);
          root.middles.clear();
          _archiveRoot(archive, root, archiveReasonConflict, date, related);
          dirty.add(op.branchWire);
          outcomes.add(null);
        case PersonaMergeOp(:final claim, :final rootIds):
          final ids = rootIds.toSet();
          if (ids.length < 2) {
            skip(op, 'needs-two-roots');
            continue;
          }
          final roots = <PersonaRoot>[];
          var unknown = false;
          for (final id in ids) {
            final root = _findRoot(state, id);
            if (root == null) {
              unknown = true;
              break;
            }
            roots.add(root);
          }
          if (unknown) {
            skip(op, 'unknown-root');
            continue;
          }
          roots.sort((left, right) => left.id.compareTo(right.id));
          final survivor = roots.first;
          survivor.claim = claim.trim();
          for (final other in roots.skip(1)) {
            final related = other.middles.map((middle) => middle.id).toList();
            survivor.middles.addAll(other.middles);
            other.middles.clear();
            state.roots.remove(other);
            _archiveRoot(archive, other, archiveReasonDedup, date, related);
          }
          dirty.add(op.branchWire);
          outcomes.add(null);
      }
    }

    // Dream 维护职责：清理过期孤儿叶、裁剪冗余叶指针、归档零中间
    // 理解的根（子树被冲突升级清空后的残留根壳）。
    for (final branch in personaBranches) {
      final state = states[branch.wireName]!;
      final archive = archives[branch.wireName]!;
      if (!state.readable || !archive.readable) {
        continue;
      }
      var changed = false;
      final orphans = state.unclassified.where((leaf) {
        try {
          return dateSpanDays(leaf.date, date) > personaOrphanLeafKeepDays;
        } on Object {
          return false;
        }
      }).toList();
      if (orphans.isNotEmpty) {
        state.unclassified.removeWhere(orphans.contains);
        changed = true;
      }
      for (final middle in state.allMiddles) {
        if (middle.leaves.length > personaMiddleMaxLeaves) {
          final kept = _representativeLeaves(middle.leaves);
          middle.leaves
            ..clear()
            ..addAll(kept);
          changed = true;
        }
      }
      for (final root in [...state.roots]) {
        if (root.middles.isEmpty) {
          state.roots.remove(root);
          _archiveRoot(archive, root, archiveReasonConflict, date, const []);
          changed = true;
        }
      }
      if (changed) {
        dirty.add(branch.wireName);
      }
    }

    for (final branch in personaBranches) {
      if (!dirty.contains(branch.wireName)) {
        continue;
      }
      // 先归档后活跃：与日终整理同一写序。
      await _writeArchive(branch, archives[branch.wireName]!);
      await _writeBranch(branch, states[branch.wireName]!);
    }
    final allReadable = personaBranches.every(
      (branch) =>
          states[branch.wireName]!.readable &&
          archives[branch.wireName]!.readable,
    );
    if (allReadable) {
      await _writePersona(states);
    } else {
      _diagnosticsSink('persona projection deferred reason=branch-unreadable');
    }
    return PersonaDreamApplyResult(outcomes: outcomes);
  });

  /// 按 ID 从未归根区收集中间理解；任一缺失（或集合为空）返回 null。
  List<PersonaMiddle>? _collectUnrooted(_BranchState state, Set<String> ids) {
    if (ids.isEmpty) {
      return null;
    }
    final middles = <PersonaMiddle>[];
    for (final id in ids) {
      final middle = _findUnrooted(state, id);
      if (middle == null) {
        return null;
      }
      middles.add(middle);
    }
    return middles;
  }

  PersonaMiddle? _findUnrooted(_BranchState state, String id) {
    for (final middle in state.unrooted) {
      if (middle.id == id) {
        return middle;
      }
    }
    return null;
  }

  PersonaRoot? _findRoot(_BranchState state, String id) {
    for (final root in state.roots) {
      if (root.id == id) {
        return root;
      }
    }
    return null;
  }

  /// 封禁集合（禁提 ∪ 删除）：命中即清除或拒绝建叶，绝不复活。
  Future<Set<String>> _blockedTitles() async =>
      await openLoopStore?.blockedTitles() ?? const <String>{};

  /// 冻结集合：冻结停止自动整理，命中的叶与中间理解保持原样，
  /// 不参与挂载、冲突升级或新建理解，直到用户解除。
  Future<Set<String>> _frozenTitles() async =>
      await openLoopStore?.frozenTitles() ?? const <String>{};

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
    final banned = await _blockedTitles();
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
        if (bannedMemoryText(summary, banned)) {
          _diagnosticsSink(
            'persona leaf skipped reason=blocked branch=${branch.wireName}',
          );
          continue;
        }
        final date = localSessionDate(entry.at.toLocal());
        // 幂等与合并：同一 episode 条目不重复建叶（allLeaves 含根下
        // 中间理解的叶）；同日同摘要的近似信号合并为一条叶（重复
        // 计数体现在跨日期叶数量上）。
        final exists = state.allLeaves.any(
          (leaf) =>
              leaf.entryRef == entry.id ||
              (leaf.date == date &&
                  normalizeMemoryText(leaf.summary) ==
                      normalizeMemoryText(summary)),
        );
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

  /// 日终单分支整理（锁内）：封禁清扫 → 身份最新陈述胜出 → 挂载 →
  /// 冲突升级 → 从未归类叶建立中间理解。冻结内容停止自动整理：
  /// 命中冻结的叶与中间理解原地保留，不参与挂载、冲突升级或新建
  /// 理解（用户当前纠正仍高于冻结，身份纠正不受冻结限制）。
  /// 返回本轮是否撤销过根（身份纠正），供调用方决定是否重投影 persona.md。
  Future<bool> _organizeBranch(
    PersonaBranch branch,
    String date,
    Set<String> banned,
    Set<String> frozen,
  ) async {
    final state = await _readBranch(branch);
    if (!state.readable) {
      _diagnosticsSink(
        'persona branch skipped reason=${branch.wireName}-unreadable',
      );
      return false;
    }
    final archive = await _readArchive(branch);
    if (!archive.readable) {
      _diagnosticsSink(
        'persona branch skipped reason=${branch.wireName}-archive-unreadable',
      );
      return false;
    }
    var changed = false;
    var rootsChanged = false;

    // 1. 禁提清扫：用户禁止提及高于提炼，命中即删除、不进归档。
    if (_sweepBanned(state, banned)) {
      changed = true;
    }

    // 2. 身份事实的最新明确陈述胜出：新的自述与旧「待稳定事实」
    //    冲突时归档旧理解，新说法走全新 ID，不拿旧证据背书。
    //    用户明确纠正是唯一在线撤根例外：命中旧根时整条路径（根与
    //    其全部中间理解）移入归档，persona.md 由调用方重投影。
    if (branch.wireName == 'identity') {
      for (final leaf in [...state.unclassified]) {
        if (leaf.nature != natureSelfReport) {
          continue;
        }
        final outdated = state.unrooted
            .where(
              (middle) =>
                  middle.type == middleTypePendingFact &&
                  conflictTopic(leaf.summary, middle.claim),
            )
            .toList();
        for (final middle in outdated) {
          state.unrooted.remove(middle);
          _archiveMiddle(archive, middle, archiveReasonCorrection, date);
          changed = true;
        }
        final outdatedRoots = state.roots
            .where(
              (root) => root.middles.any(
                (middle) =>
                    middle.type == middleTypePendingFact &&
                    conflictTopic(leaf.summary, middle.claim),
              ),
            )
            .toList();
        for (final root in outdatedRoots) {
          state.roots.remove(root);
          _archiveRoot(
            archive,
            root,
            archiveReasonCorrection,
            date,
            root.middles.map((middle) => middle.id).toList(),
          );
          changed = true;
          rootsChanged = true;
        }
      }
    }

    // 3. 挂载：未归类叶优先归入现有中间理解。同一主张挂 support；
    //    同话题不同主张挂 conflict（并存不覆盖）。身份分支只认自述，
    //    行为叶不得挂载或反驳身份事实。根下中间理解同样参与挂载：
    //    新证据必须够得到高层理解，反向证据才能浮出并支撑降根裁决。
    for (final leaf
        in state.unclassified.toList()
          ..sort((left, right) => left.date.compareTo(right.date))) {
      // 身份事实只认自述：行为叶不得挂载或反驳身份理解。
      if (branch.wireName == 'identity' && leaf.nature != natureSelfReport) {
        continue;
      }
      // 冻结停止自动整理：冻结的叶与中间理解原地保留，不挂载。
      if (frozenTitleHit(leaf.summary, frozen)) {
        continue;
      }
      for (final middle in state.allMiddles) {
        if (frozenTitleHit(middle.claim, frozen)) {
          continue;
        }
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
          middle.leaves.add(leaf.copyWith(relation: 'conflict'));
          middle.reviewedOn = date;
          changed = true;
          break;
        }
      }
    }

    // 4. 冲突升级：两个不同日期的反向证据组成新的反向中间理解，
    //    反向理解一律落在未归根区；旧理解保留仍成立的支持证据。
    //    旧根不在日终撤销：根下中间理解被反驳时同样升级，根级裁决
    //    （比较旧根与反向理解后降根与否）归下一次 Dream。
    if (branch.wireName != 'identity') {
      for (final middle in [...state.allMiddles]) {
        if (frozenTitleHit(middle.claim, frozen)) {
          continue;
        }
        final conflicts = middle.leaves
            .where((leaf) => leaf.relation == 'conflict')
            .toList();
        final distinctDates = conflicts.map((leaf) => leaf.date).toSet().length;
        if (conflicts.length < 2 || distinctDates < 2) {
          continue;
        }
        middle.leaves.removeWhere(conflicts.contains);
        middle.reviewedOn = date;
        final counterClaim = _longestSummary(conflicts);
        final counter = PersonaMiddle(
          id: _nextId(branch, 'M', state, archive),
          type: branch.wireName == 'boundaries'
              ? middleTypeBoundarySignal
              : middleTypeRepeatPattern,
          claim: counterClaim,
          formedOn: date,
          reviewedOn: date,
          leaves: [for (final leaf in conflicts) leaf.copyWith(relation: 'support')],
        );
        state.unrooted.add(counter);
        if (middle.leaves.isEmpty) {
          state.unrooted.remove(middle);
          // 若该理解挂在根下，从根子树移除；根本身保留，等 Dream
          // 比较反向理解后裁决（根为零中间理解时由 Dream 维护清理）。
          for (final root in state.roots) {
            if (root.middles.remove(middle)) {
              break;
            }
          }
          _archiveMiddle(archive, middle, archiveReasonConflict, date);
        }
        changed = true;
      }
    }

    // 5. 建立：剩余未归类叶按同一主张分组，跨时间证据足够才成理解。
    //    冻结的叶不参与新建理解，留在未归类区等待解除。
    final groups = <List<PersonaLeaf>>[];
    for (final leaf in [...state.unclassified]) {
      if (frozenTitleHit(leaf.summary, frozen)) {
        continue;
      }
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
      final claim = _longestSummary(attach);
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
    return rootsChanged;
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

  /// 归档根：[relatedIds] 记原关联中间理解 ID。纠正归档时整条子树
  /// 随根入档；降根归档时子树已先退回未归根区，归档只留根壳。
  void _archiveRoot(
    _ArchiveState archive,
    PersonaRoot root,
    String reason,
    String date,
    List<String> relatedIds,
  ) {
    archive.rootEntries.add(
      _ArchivedRoot(
        root: root,
        archivedOn: date,
        reason: reason,
        relatedIds: relatedIds,
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
    for (final middle in state.allMiddles) {
      observe(middle.id);
    }
    for (final root in state.roots) {
      observe(root.id);
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
    PersonaRoot? currentRoot;
    var section = 'header';
    for (final rawLine in contents.replaceAll('\r\n', '\n').split('\n')) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      if (trimmed.startsWith('## ')) {
        currentMiddle = null;
        currentRoot = null;
        if (trimmed == '## 未归根中间节点') {
          section = 'unrooted';
        } else if (trimmed == '## 未归类叶') {
          section = 'unclassified';
        } else {
          final rootMatch = _rootHeaderPattern.firstMatch(trimmed);
          if (rootMatch == null) {
            return _BranchState(readable: false);
          }
          section = 'root';
          currentRoot = PersonaRoot(
            id: rootMatch.group(1)!,
            claim: rootMatch.group(2)!,
            middles: [],
          );
          state.roots.add(currentRoot);
        }
        continue;
      }
      switch (section) {
        case 'header':
          if (!trimmed.startsWith('# ')) {
            return _BranchState(readable: false);
          }
        case 'unrooted':
        case 'root':
          // 两个区都只认中间理解头、元数据行与叶行；其余视为损坏。
          // 差别只在头的去向：未归根区平铺，根区挂到当前根下。
          if (section == 'root' && currentRoot == null) {
            return _BranchState(readable: false);
          }
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
            if (section == 'unrooted') {
              state.unrooted.add(currentMiddle);
            } else {
              currentRoot?.middles.add(currentMiddle);
            }
            continue;
          }
          final middle = currentMiddle;
          if (middle == null) {
            return _BranchState(readable: false);
          }
          final metaMatch = _middleMetaPattern.firstMatch(trimmed);
          if (metaMatch != null) {
            middle.formedOn = metaMatch.group(1)!;
            middle.reviewedOn = metaMatch.group(2)!;
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
        default:
          return _BranchState(readable: false);
      }
    }
    return state;
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

  /// 归档文件解析：支持两种条目——中间理解条目（`###` 头 + 失效
  /// 元数据）与根条目（`##` 头 + 失效元数据 + 嵌套中间理解）。
  /// 根条目的失效元数据必须紧跟根头；嵌套中间理解不再携带自己的
  /// 失效元数据。
  _ArchiveState _parseArchive(String contents) {
    final archive = _ArchiveState(readable: true);
    PersonaMiddle? currentMiddle;
    PersonaRoot? currentRoot;
    var rootMetaPending = false;
    String? rootArchivedOn;
    String? rootReason;
    List<String>? rootRelatedIds;
    String? archivedOn;
    String? reason;
    List<String>? relatedIds;
    var sawHeader = false;
    void flushMiddle() {
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

    void flushRoot() {
      final root = currentRoot;
      if (root != null && rootArchivedOn != null && rootReason != null) {
        archive.rootEntries.add(
          _ArchivedRoot(
            root: root,
            archivedOn: rootArchivedOn!,
            reason: rootReason!,
            relatedIds: rootRelatedIds ?? const [],
          ),
        );
      }
      currentRoot = null;
      rootMetaPending = false;
      rootArchivedOn = null;
      rootReason = null;
      rootRelatedIds = null;
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
      if (trimmed.startsWith('## ')) {
        if (rootMetaPending) {
          return _ArchiveState(readable: false);
        }
        flushMiddle();
        flushRoot();
        final match = _rootHeaderPattern.firstMatch(trimmed);
        if (match == null) {
          return _ArchiveState(readable: false);
        }
        currentRoot = PersonaRoot(
          id: match.group(1)!,
          claim: match.group(2)!,
          middles: [],
        );
        rootMetaPending = true;
        continue;
      }
      if (trimmed.startsWith('### ')) {
        if (rootMetaPending) {
          return _ArchiveState(readable: false);
        }
        flushMiddle();
        final match = _middleHeaderPattern.firstMatch(trimmed);
        if (match == null) {
          return _ArchiveState(readable: false);
        }
        final middle = PersonaMiddle(
          id: match.group(1)!,
          type: match.group(2)!,
          claim: match.group(3)!,
          formedOn: '',
          reviewedOn: '',
          leaves: [],
        );
        currentMiddle = middle;
        currentRoot?.middles.add(middle);
        continue;
      }
      final archiveMeta = _archiveMetaPattern.firstMatch(trimmed);
      if (archiveMeta != null) {
        if (rootMetaPending) {
          rootArchivedOn = archiveMeta.group(1);
          rootReason = archiveMeta.group(2);
          rootRelatedIds = archiveMeta
              .group(3)!
              .split(',')
              .map((id) => id.trim())
              .where((id) => id.isNotEmpty)
              .toList();
          rootMetaPending = false;
          continue;
        }
        final middle = currentMiddle;
        if (middle == null || currentRoot != null || archivedOn != null) {
          return _ArchiveState(readable: false);
        }
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
      final middle = currentMiddle;
      if (middle == null || rootMetaPending) {
        return _ArchiveState(readable: false);
      }
      final metaMatch = _middleMetaPattern.firstMatch(trimmed);
      if (metaMatch != null) {
        middle.formedOn = metaMatch.group(1)!;
        middle.reviewedOn = metaMatch.group(2)!;
        continue;
      }
      final leaf = _parseLeafLine(trimmed);
      if (leaf == null) {
        return _ArchiveState(readable: false);
      }
      middle.leaves.add(leaf);
    }
    if (rootMetaPending) {
      return _ArchiveState(readable: false);
    }
    flushMiddle();
    flushRoot();
    return archive;
  }

  Future<void> _writeBranch(PersonaBranch branch, _BranchState state) async {
    final file = _branchFile(branch);
    final empty =
        state.unrooted.isEmpty &&
        state.unclassified.isEmpty &&
        state.roots.isEmpty;
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
    for (final root in state.roots) {
      buffer
        ..writeln()
        ..writeln('## [${root.id}] ${root.claim}');
      for (final middle in root.middles) {
        _writeMiddleBlock(buffer, middle);
      }
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

  /// 中间理解块：活跃区与归档区共用同一渲染，归档条目经 [archivedMeta]
  /// 在头行后插入「失效」元数据行，两侧序列化格式永不漂移。
  void _writeMiddleBlock(
    StringBuffer buffer,
    PersonaMiddle middle, {
    String? archivedMeta,
  }) {
    buffer
      ..writeln()
      ..writeln('### [${middle.id}] ${middle.type}｜${middle.claim}');
    if (archivedMeta != null) {
      buffer.writeln(archivedMeta);
    }
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
    if (archive.entries.isEmpty && archive.rootEntries.isEmpty) {
      // 归档只增不减；没有归档内容时不建文件。
      return;
    }
    final buffer = StringBuffer()..writeln('# ${branch.title}（归档）');
    for (final entry in archive.entries) {
      _writeMiddleBlock(
        buffer,
        entry.middle,
        archivedMeta:
            '- 失效: ${entry.archivedOn} · 原因: ${entry.reason} · '
            '关联: ${entry.relatedIds.join(', ')}',
      );
    }
    for (final entry in archive.rootEntries) {
      final root = entry.root;
      buffer
        ..writeln()
        ..writeln('## [${root.id}] ${root.claim}')
        ..writeln(
          '- 失效: ${entry.archivedOn} · 原因: ${entry.reason} · '
          '关联: ${entry.relatedIds.join(', ')}',
        );
      for (final middle in root.middles) {
        _writeMiddleBlock(buffer, middle);
      }
    }
    await _atomicWriter.replace(file.path, buffer.toString());
  }

  /// 代表性叶裁剪（定稿每理解最多 6 条）：冲突叶优先保留（反向证据
  /// 必须完整留给降根裁决；冲突升级到两条即移走，稳态下不超过一条），
  /// 其余名额保留最早与最近，优先给能体现跨日期覆盖的指针。
  List<PersonaLeaf> _representativeLeaves(List<PersonaLeaf> leaves) {
    final sorted = [...leaves]
      ..sort((left, right) => left.date.compareTo(right.date));
    final kept = <PersonaLeaf>[
      for (final leaf in sorted)
        if (leaf.relation == 'conflict') leaf,
    ];
    final support = [
      for (final leaf in sorted)
        if (leaf.relation != 'conflict') leaf,
    ];
    if (support.isNotEmpty) {
      kept.add(support.first);
      if (!identical(support.last, support.first)) {
        kept.add(support.last);
      }
      final coveredDates = {for (final leaf in kept) leaf.date};
      for (final leaf in support) {
        if (kept.length >= personaMiddleMaxLeaves) {
          break;
        }
        if (coveredDates.add(leaf.date)) {
          kept.add(leaf);
        }
      }
      for (final leaf in support) {
        if (kept.length >= personaMiddleMaxLeaves) {
          break;
        }
        if (!kept.contains(leaf)) {
          kept.add(leaf);
        }
      }
    }
    kept.sort((left, right) => left.date.compareTo(right.date));
    return kept;
  }

  /// 恢复流程的投影重建入口（ticket 21）：分支修复后从活跃根重投影
  /// persona.md；仍有分支不可读时保留旧投影。
  Future<void> regeneratePersonaProjection() =>
      _locked(() => _regeneratePersona());

  /// 从活跃根重投影 persona.md：重新读取全部分支，任一分支不可读时
  /// 保留旧投影等待恢复流程，绝不写出残缺画像。
  Future<void> _regeneratePersona() async {
    final states = <String, _BranchState>{};
    for (final branch in personaBranches) {
      final state = await _readBranch(branch);
      if (!state.readable) {
        _diagnosticsSink(
          'persona projection deferred reason=${branch.wireName}-unreadable',
        );
        return;
      }
      states[branch.wireName] = state;
    }
    await _writePersona(states);
  }

  /// persona.md：只逐条复制活跃根主张原文，不含节点 ID、证据提示、
  /// 日期或二次概括；超预算按 [personaTrimOrder] 裁剪，边界禁区永不裁。
  Future<void> _writePersona(Map<String, _BranchState> states) async {
    final file = File(path.join(memoryDirectory, 'persona.md'));
    final sections = <(String, List<String>)>[];
    for (final branch in personaBranches) {
      final claims = states[branch.wireName]!.roots
          .map((root) => root.claim.trim())
          .where((claim) => claim.isNotEmpty)
          .toList();
      if (claims.isNotEmpty) {
        sections.add((branch.personaTitle, claims));
      }
    }
    if (sections.isEmpty) {
      if (await file.exists()) {
        await file.delete();
      }
      return;
    }
    while (_renderPersona(sections).runes.length > personaMaxRunes) {
      if (!_dropOneByTrimOrder(sections)) {
        // 只剩边界禁区也超预算：边界不得裁掉，原样落盘。
        break;
      }
    }
    sections.removeWhere((entry) => entry.$2.isEmpty);
    await _atomicWriter.replace(file.path, _renderPersona(sections));
  }

  String _renderPersona(List<(String, List<String>)> sections) {
    final buffer = StringBuffer()..writeln('# persona');
    for (final (title, claims) in sections) {
      buffer
        ..writeln()
        ..writeln('## $title');
      for (final claim in claims) {
        buffer.writeln('- $claim');
      }
    }
    return buffer.toString();
  }
}

/// 注入关裁剪 persona.md 投影：超预算按定稿砍序（偏好习惯 → 性格
/// 表达 → 价值观与原则 → 身份事实）逐条丢弃条目；边界禁区永不裁掉。
/// 不可解析内容超预算时整体放弃（绝不注入裁半的内容）。极端情形下
/// 预算被压到零甚至负数时，仍只保留边界禁区节——边界内容优先于
/// 预算数字，宁可短暂超预算也不丢安全边界。
String clipPersonaBlock(String contents, int maxRunes) {
  if (contents.runes.length <= maxRunes) {
    return contents;
  }
  final sections = <(String, List<String>)>[];
  (String, List<String>)? current;
  for (final rawLine in contents.replaceAll('\r\n', '\n').split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line == '# persona') {
      continue;
    }
    if (line.startsWith('## ')) {
      final section = (line.substring(3).trim(), <String>[]);
      sections.add(section);
      current = section;
      continue;
    }
    if (line.startsWith('- ') && current != null) {
      current.$2.add(line.substring(2).trim());
      continue;
    }
    return '';
  }

  String render() {
    final buffer = StringBuffer();
    for (final (title, items) in sections) {
      if (items.isEmpty) {
        continue;
      }
      if (buffer.isNotEmpty) {
        buffer.writeln();
      }
      buffer.writeln('## $title');
      for (final item in items) {
        buffer.writeln('- $item');
      }
    }
    return buffer.toString().trimRight();
  }

  while (render().runes.length > maxRunes) {
    if (!_dropOneByTrimOrder(sections)) {
      // 只剩边界禁区：边界不得裁掉，剩余内容原样返回。
      break;
    }
  }
  return render();
}
