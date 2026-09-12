import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'daily_finalization.dart';
import 'episode_index.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_controls.dart';
import 'memory_marker_codec.dart';
import 'memory_text_primitives.dart';
import 'model_gateway.dart';
import 'model_text_protocol.dart';
import 'monthly_summary.dart';
import 'open_loop_store.dart';
import 'persona_tree.dart';
import 'provider_settings_service.dart';

/// Dream 最小间隔（天）：距上次成功 Dream 的日历日差至少达到该值才
/// 具备执行资格（T04/T13 定稿后于 2026-08-24 调整为 3 天，兼顾敏锐度与防漂移）。
const dreamMinIntervalDays = 3;

/// long-memory 预算上限（runes）。热层分块预算 800-1500 tokens
/// （T03 定稿），保守按 1 rune ≈ 1 token，写入关取上限 1500。
const longMemoryMaxRunes = 1500;

/// long-memory 单条上限（runes）：一行压缩印象，不存原话细节。
const longMemoryItemMaxRunes = 60;

/// Dream 草稿条目总数上限：与单条上限一起保证草稿可落进预算。
const dreamMaxItems = 24;

/// 递给 Dream 的 finalized 摘要窗口（天）：从上次成功 Dream 之后算起，
/// 至多取最近这些天；更早的内容由月摘要覆盖。
const dreamSummaryWindowDays = 14;

/// 递给 Dream 的月摘要最多月数（取最近）。
const dreamMaxMonthSummaries = 6;

/// Dream 单次输入上下文预算（runes）：超出先裁最旧月摘要，再裁最旧
/// 日摘要。关系状态与未闭环线索自身体量已有分块预算，不参与裁剪。
const dreamInputMaxRunes = 9000;

/// dream/history/ 保留的变更清单份数。
const dreamHistoryKeep = 4;

/// 单次 Dream 接受的根节点提案上限：防止模型一次性大改树结构。
const dreamMaxRootProposals = 8;

/// Dream 重组调用的输出预算：一次要吐出全部分区草稿加根节点提案的
/// 单个 JSON 对象，与日终理解同一量级，远超聊天的少说护栏。缺省吃
/// 聊天上限 512 时输出被截断，JSON 解析必失败（材料积压期的真实事故）。
const dreamMaxOutputTokens = 16384;

final _rootIdPattern = RegExp(r'^[A-Z]{2}-R\d+$');
final _middleIdPattern = RegExp(r'^[A-Z]{2}-M\d+$');

final _dayPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _monthPattern = RegExp(r'^\d{4}-\d{2}$');

/// 句中否定词：相互矛盾检查先移除它们还原核心断言，同一核心一正
/// 一反两条并存即矛盾。只收多字词，避免拆开「未来」这类词。
const _negationTokens = ['不喜欢', '不是', '没有', '不再', '不会', '还没', '并未', '尚未'];

/// 句首否定前缀（长者优先）：覆盖「不/没/无 + 断言」的简短句式。
const _leadingNegations = ['不喜欢', '不是', '没有', '不再', '不', '没', '无'];

/// 比较时忽略的动态助词：让「换了工作」与「换工作」落在同一核心上。
const _aspectParticles = ['了', '过', '着'];

/// Dream 单次运行结果。
enum DreamStatus {
  /// 草稿通过全部自检并原子接纳，long-memory 已更新、成功时间已记录。
  accepted,

  /// 既非晚安触发，也没有待补跑的晚安请求。
  notEligible,

  /// 距上次成功 Dream 不足 [dreamMinIntervalDays] 天。
  notDue,

  /// 没有已 finalized 的整理材料可供深度重组。
  skippedNoMaterial,

  /// 未配置 Provider：语义重组只调用用户配置的 LLM，绝不用规则补写。
  skippedNoProvider,

  /// Dream 状态或现有 long-memory 不可读：等待恢复流程，绝不覆盖。
  skippedUnreadable,

  /// 模型调用失败或输出无法解析：旧记忆原样保留，等待下次重试。
  modelFailed,

  /// 草稿未通过结构/证据/敏感/用户控制/冻结保留/冻结禁增/相互矛盾
  /// 各自检关之一：整份作废，失败原因记入变更清单。
  validationFailed,

  /// 接纳过程写入失败：旧 long-memory 与上次成功时间保持原样。
  writeFailed,
}

final class DreamOutcome {
  const DreamOutcome({
    required this.status,
    this.detail,
    this.rootOpsApplied = 0,
    this.rootOpsRejected = 0,
  });

  final DreamStatus status;

  /// 诊断细节（错误码级别），只进本机诊断，不含用户内容。
  final String? detail;

  /// 本轮落盘的根节点提案数量（仅接纳成功的 Dream 计数）。
  final int rootOpsApplied;

  /// 本轮被拒绝的根节点提案数量（无证据、过度推断、敏感、禁提等）。
  final int rootOpsRejected;
}

/// Dream 持久化状态：上次成功时间与是否有待补跑的晚安请求。
final class DreamState {
  const DreamState({this.lastSuccess, this.pending = false});

  final DateTime? lastSuccess;

  /// 晚安时具备资格但未成功（模型失败、验证失败、写入失败或配置
  /// 缺失）：下次启动或跨天首条消息时补跑。只有成功才清除。
  final bool pending;
}

/// Dream 诊断事实（ticket 23）：供开发者诊断页只读展示。日差与
/// 最小间隔（[dreamMinIntervalDays] 天）判定与 [DreamService.run]
/// 内部资格复查同一口径。
final class DreamHealthFacts {
  const DreamHealthFacts({
    required this.lastSuccess,
    required this.pending,
    required this.daysSinceLastSuccess,
    required this.intervalSatisfied,
  });

  final DateTime? lastSuccess;
  final bool pending;

  /// 距上次成功的本地日历日差；从未成功时为 null。
  final int? daysSinceLastSuccess;

  /// 最小间隔（[dreamMinIntervalDays] 天）是否已满足（从未成功视为满足）。
  final bool intervalSatisfied;
}

/// 按四分区固定顺序渲染 long-memory.md；空分区不输出。
String renderLongMemory(Map<String, List<String>> sections) {
  final buffer = StringBuffer()..writeln('# long-memory');
  for (final section in longMemorySections) {
    final items = sections[section];
    if (items == null || items.isEmpty) {
      continue;
    }
    buffer
      ..writeln()
      ..writeln('## $section');
    for (final item in items) {
      buffer.writeln('- $item');
    }
  }
  return buffer.toString();
}

/// 长期印象四分区受控过滤：封禁命中条目从各分区剔除，返回过滤后的
/// 分区与是否发生变化。Dream 输入过滤与删除清除管线共用同一份核心；
/// 过滤谓词 [bannedMemoryText] 本体不动，解析与写入时机归调用方。
({Map<String, List<String>> sections, bool changed}) filterLongMemorySections(
  LongMemoryFile parsed,
  Set<String> banned,
) {
  var changed = false;
  final sections = <String, List<String>>{};
  for (final section in longMemorySections) {
    final items = parsed.sections[section] ?? const <String>[];
    final kept = items
        .where((item) => !bannedMemoryText(item, banned))
        .toList();
    if (kept.length != items.length) {
      changed = true;
    }
    sections[section] = kept;
  }
  return (sections: sections, changed: changed);
}

/// 注入关裁剪 long-memory 到预算内：可解析内容按分区逆序（共同过往
/// 最先）从尾部丢弃条目；不可解析内容预算内原样保留、超预算整体放弃
/// （绝不注入裁半的内容）。条目丢空时返回空串（空块不输出）。
String clipLongMemoryBlock(String contents, int maxRunes) {
  if (maxRunes <= 0) {
    return '';
  }
  if (contents.runes.length <= maxRunes) {
    return contents;
  }
  final parsed = parseLongMemory(contents);
  if (!parsed.readable) {
    return '';
  }
  final sections = {
    for (final section in longMemorySections)
      section: List<String>.of(parsed.sections[section] ?? const []),
  };
  for (final section in longMemorySections.reversed) {
    final items = sections[section]!;
    var rendered = renderLongMemory(sections);
    while (rendered.runes.length > maxRunes && items.isNotEmpty) {
      items.removeLast();
      rendered = renderLongMemory(sections);
    }
    if (rendered.runes.length <= maxRunes) {
      break;
    }
  }
  final remaining = sections.values.fold<int>(0, (sum, items) => sum + items.length);
  if (remaining == 0) {
    return '';
  }
  final clipped = renderLongMemory(sections);
  return clipped.runes.length <= maxRunes ? clipped : '';
}

/// Dream 草稿的一条候选印象。
typedef DreamItem = ({String section, String text, List<String> evidence});

/// 解析 Dream 模型输出：只认带 items 数组的 JSON 对象；条目字段逐条
/// 白名单校验（分区白名单、条目限长、证据只认日期/月份形态），无效
/// 条目整条丢弃；整体无法解析返回 null。敏感与禁提不在此处静默清洗，
/// 留给自检各关整份裁决。
List<DreamItem>? parseDreamCandidate(
  String raw, {
  void Function(String message)? diagnosticsSink,
}) {
  final sink = diagnosticsSink ?? stderrDiagnostics;
  final json = extractJsonObject(raw);
  if (json == null) {
    return null;
  }
  final itemsValue = json['items'];
  if (itemsValue is! List<Object?>) {
    return null;
  }
  final items = <DreamItem>[];
  for (final entry in itemsValue) {
    if (entry is! Map<String, Object?>) {
      sink('dream candidate dropped [not an object]');
      continue;
    }
    final section = entry['section'];
    if (section is! String || !longMemorySections.contains(section.trim())) {
      sink('dream candidate dropped [section not in whitelist]');
      continue;
    }
    final textValue = entry['text'];
    if (textValue is! String) {
      sink('dream candidate dropped [missing text]');
      continue;
    }
    final text = clipRunes(textValue.trim(), longMemoryItemMaxRunes);
    if (text.isEmpty) {
      sink('dream candidate dropped [empty text]');
      continue;
    }
    final evidence = <String>[];
    final evidenceValue = entry['evidence'];
    if (evidenceValue is List<Object?>) {
      for (final ref in evidenceValue.whereType<String>()) {
        final trimmed = ref.trim();
        if (evidence.length >= 4) {
          break;
        }
        if (_dayPattern.hasMatch(trimmed) || _monthPattern.hasMatch(trimmed)) {
          evidence.add(trimmed);
        }
      }
    }
    items.add((section: section.trim(), text: text, evidence: evidence));
  }
  return items;
}

/// 解析 Dream 模型输出中的根节点提案：只认 rootProposals 数组，逐条
/// 白名单校验（op 白名单、branch 白名单、ID 形态、数量上限），无效
/// 提案单条丢弃。提案校验（证据门槛、敏感、禁提、防复活）在
/// DreamService 内逐条进行；结构解析失败一律返回空列表，绝不影响
/// items 的接纳路径。
List<PersonaDreamOp> parseDreamRootProposals(
  String raw, {
  void Function(String message)? diagnosticsSink,
}) {
  final sink = diagnosticsSink ?? stderrDiagnostics;
  final json = extractJsonObject(raw);
  if (json == null) {
    return const [];
  }
  final value = json['rootProposals'];
  if (value is! List<Object?>) {
    return const [];
  }
  final ops = <PersonaDreamOp>[];
  for (final entry in value) {
    if (ops.length >= dreamMaxRootProposals) {
      sink('dream root proposal dropped [too many proposals]');
      break;
    }
    if (entry is! Map<String, Object?>) {
      sink('dream root proposal dropped [not an object]');
      continue;
    }
    final op = entry['op'];
    final branchWire = entry['branch'];
    if (op is! String ||
        branchWire is! String ||
        personaBranchForWire(branchWire) == null) {
      sink('dream root proposal dropped [op/branch not in whitelist]');
      continue;
    }
    switch (op) {
      case 'promote':
        final claim = entry['claim'];
        final middleIds = _idList(entry['middles'], _middleIdPattern);
        if (claim is! String || middleIds == null) {
          sink('dream root proposal dropped [promote fields invalid]');
          continue;
        }
        ops.add(
          PersonaPromoteOp(
            branchWire,
            claim: claim.trim(),
            middleIds: middleIds,
          ),
        );
      case 'absorb':
        final rootId = entry['root'];
        final middleIds = _idList(entry['middles'], _middleIdPattern);
        if (rootId is! String ||
            !_rootIdPattern.hasMatch(rootId.trim()) ||
            middleIds == null) {
          sink('dream root proposal dropped [absorb fields invalid]');
          continue;
        }
        ops.add(
          PersonaAbsorbOp(
            branchWire,
            rootId: rootId.trim(),
            middleIds: middleIds,
          ),
        );
      case 'demote':
        final rootId = entry['root'];
        final counterId = entry['counter'];
        if (rootId is! String ||
            !_rootIdPattern.hasMatch(rootId.trim()) ||
            counterId is! String ||
            !_middleIdPattern.hasMatch(counterId.trim())) {
          sink('dream root proposal dropped [demote fields invalid]');
          continue;
        }
        ops.add(
          PersonaDemoteOp(
            branchWire,
            rootId: rootId.trim(),
            counterId: counterId.trim(),
          ),
        );
      case 'merge':
        final claim = entry['claim'];
        final rootIds = _idList(entry['roots'], _rootIdPattern);
        if (claim is! String || rootIds == null) {
          sink('dream root proposal dropped [merge fields invalid]');
          continue;
        }
        ops.add(
          PersonaMergeOp(
            branchWire,
            claim: claim.trim(),
            rootIds: rootIds,
          ),
        );
      default:
        sink('dream root proposal dropped [unknown op]');
    }
  }
  return ops;
}

/// ID 列表白名单：只保留形态合法的 ID；空列表返回 null（提案缺证据
/// 对象，整条丢弃）。
List<String>? _idList(Object? value, RegExp pattern) {
  if (value is! List<Object?>) {
    return null;
  }
  final ids = <String>[];
  for (final id in value.whereType<String>()) {
    if (ids.length >= 8) {
      break;
    }
    final trimmed = id.trim();
    if (pattern.hasMatch(trimmed)) {
      ids.add(trimmed);
    }
  }
  return ids.isEmpty ? null : ids;
}

/// Dream（五段节奏第五动作，ticket 16 / T04 / T08 / T13 定稿）。
///
/// 资格：触发必须来自晚安（[run] 的 bedtime 路径），或来自上次晚安
/// 未成功留下的补跑请求（pending，启动、跨天首条消息时兑现）；且距上次成功
/// Dream 的日历日差至少 [dreamMinIntervalDays] 天。日终归档与月压缩
/// 每天都可以执行，但从不写入 Dream 状态，绝不重置或绕过该间隔。
///
/// 输入（全部只读，遵守 [dreamInputMaxRunes] 预算）：上次成功当天及
/// 之后的 finalized 日摘要（窗口 [dreamSummaryWindowDays] 天）、月摘要（至多
/// [dreamMaxMonthSummaries] 月）、关系状态、未闭环线索、现有长期印象、
/// 封禁（禁提 ∪ 删除）清单与冻结清单。受控内容在递给模型前按层过滤，
/// 冻结的既有条目由模型原样带回。不读 sessions 原文，不写 episodes。
///
/// 流程：一次模型调用产出全量候选 → 写独立草稿与变更清单 → 自检各关
/// （结构、证据、敏感信息、用户控制、冻结保留、冻结禁增、相互矛盾）
/// → 全部通过后原子接纳：备份旧文件 → 替换 long-memory.md → 记录成功
/// 时间 → 清单归档 history → 清空 draft。任一关不过整份作废；中断、
/// 模型失败、验证失败或写入失败都不更新上次成功时间，也不破坏旧长期记忆。
///
/// 未配置 Provider 时不运行：语义重组只能调用用户配置的 LLM，绝不
/// 用规则或推断补写长期内容（对齐 T26 语义重建原则）。
final class DreamService {
  DreamService({
    required this.memoryDirectory,
    required this.episodePipeline,
    this.openLoopStore,
    this.monthlySummary,
    this.personaTree,
    this.modelClient,
    Clock? clock,
    AtomicTextWriter? atomicWriter,
    void Function(String message)? diagnosticsSink,
  }) : _clock = clock ?? DateTime.now,
       _atomicWriter = atomicWriter ?? const IoAtomicTextWriter(),
       _diagnosticsSink = diagnosticsSink ?? stderrDiagnostics;

  final String memoryDirectory;
  final EpisodeMemoryPipeline episodePipeline;
  final OpenLoopStore? openLoopStore;
  final MonthlySummaryStore? monthlySummary;

  /// PersonaTree 真树（ticket 17）：Dream 读快照组模型输入，接纳后
  /// 把通过校验的根节点提案落盘；null 时只重组长期印象不动树。
  final PersonaTreeStore? personaTree;

  /// 深度重组调用的 Provider 客户端；null 时 Dream 整体跳过。
  final ProviderChatClient? modelClient;
  final Clock _clock;
  final AtomicTextWriter _atomicWriter;
  final void Function(String) _diagnosticsSink;

  File get _longMemoryFile => memoryFile(memoryDirectory, longMemoryFileName);
  File get _stateFile => File(path.join(memoryDirectory, 'dream', 'state.md'));
  File get _changesFile => File(path.join(memoryDirectory, 'dream', 'changes.md'));
  File get _draftFile => File(
    path.join(memoryDirectory, 'dream', 'draft', longMemoryFileName),
  );
  File get _backupFile => File(
    path.join(memoryDirectory, 'dream', 'backup', longMemoryFileName),
  );
  Directory get _historyDirectory =>
      Directory(path.join(memoryDirectory, 'dream', 'history'));

  /// 晚安触发预登记：满足最小间隔（[dreamMinIntervalDays] 天）时先
  /// 把 pending 落盘。挂在晚安后台
  /// 任务链的最前面，保证即使进程在随后的归档/月压缩/Dream 链跑完前
  /// 退出（「当晚没跑成」），下次启动或跨天首条消息补跑仍能兑现这次晚安请求。
  Future<void> markBedtime() async {
    final stateRead = await _readState();
    if (stateRead.corrupted) {
      return;
    }
    final state = stateRead.state;
    if (state.pending) {
      return;
    }
    final today = localSessionDate(_clock());
    final gap = _daysSinceLastSuccess(state, today);
    if (gap != null && gap < dreamMinIntervalDays) {
      return;
    }
    if (!await _writeState(
      DreamState(lastSuccess: state.lastSuccess, pending: true),
    )) {
      _diagnosticsSink('dream bedtime mark deferred [state not writable]');
    }
  }

  /// 执行一次 Dream。[bedtime] 为 true 表示本轮由晚安触发；为 false
  /// 时只在存在待补跑请求（pending）时执行（启动/跨天首条消息补跑路径）。
  Future<DreamOutcome> run({required bool bedtime}) async {
    final now = _clock();
    final stateRead = await _readState();
    if (stateRead.corrupted) {
      // 状态不可读：无法确认间隔，保守拒绝，等待恢复流程。
      return const DreamOutcome(
        status: DreamStatus.skippedUnreadable,
        detail: 'dream-state',
      );
    }
    final state = stateRead.state;
    if (!bedtime && !state.pending) {
      return const DreamOutcome(status: DreamStatus.notEligible);
    }
    final today = localSessionDate(now);
    final gap = _daysSinceLastSuccess(state, today);
    if (gap != null && gap < dreamMinIntervalDays) {
      return const DreamOutcome(status: DreamStatus.notDue);
    }

    // 中断补扫：上一轮被打断留下的草稿一律作废，同一时间只有一份
    // 进行中的草稿。
    await _deleteIfExists(_draftFile);

    final existingContent = await readFileIfExists(_longMemoryFile);
    LongMemoryFile? existing;
    if (existingContent != null) {
      existing = parseLongMemory(existingContent);
      if (!existing.readable) {
        return const DreamOutcome(
          status: DreamStatus.skippedUnreadable,
          detail: 'long-memory',
        );
      }
    }

    // 先落「本轮已开始」：此后任何中断或失败都保留 pending 供启动
    // 补跑；只有接纳成功才推进成功时间。
    if (!await _writeState(DreamState(lastSuccess: state.lastSuccess, pending: true))) {
      return const DreamOutcome(status: DreamStatus.writeFailed, detail: 'state');
    }

    final input = await _collectInput(
      after: state.lastSuccess == null ? null : localSessionDate(state.lastSuccess!),
    );
    if (input.summaries.isEmpty && input.monthSummaries.isEmpty) {
      // 没有任何已整理材料：不跑也不记成功，也不写状态——pending 已在
      // 本轮开头落盘，原样保留即是保留补跑请求（笔记定稿：当晚没跑成，
      // 下次启动/空闲时补；材料齐前的空跑不调模型，无配额代价）。
      return const DreamOutcome(status: DreamStatus.skippedNoMaterial);
    }

    final client = modelClient;
    if (client == null) {
      return const DreamOutcome(status: DreamStatus.skippedNoProvider);
    }
    ModelCompletion completion;
    try {
      final result = await client.complete(
        _dreamMessages(input),
        maxTokens: dreamMaxOutputTokens,
      );
      if (result == null) {
        // Provider 未配置（complete 返回 null）：语义重组不做。
        return const DreamOutcome(status: DreamStatus.skippedNoProvider);
      }
      completion = result;
    } on Object catch (error) {
      return DreamOutcome(status: DreamStatus.modelFailed, detail: '$error');
    }
    final raw = completion.text;
    if (raw == null) {
      return DreamOutcome(
        status: DreamStatus.modelFailed,
        detail: completion.failure?.name ?? 'failure',
      );
    }
    final parsed = parseDreamCandidate(raw, diagnosticsSink: _diagnosticsSink);
    if (parsed == null) {
      await _writeChanges(
        _buildChanges(
          (today: today, previousState: state, result: 'rejected (unparseable)'),
          input,
          const [],
          existing,
          includeDetails: false,
        ),
      );
      return const DreamOutcome(
        status: DreamStatus.modelFailed,
        detail: 'unparseable',
      );
    }
    // 去重规则（T08）的代码兜底：完全同文的条目合并为一条。
    final items = <DreamItem>[];
    final seen = <String>{};
    for (final item in parsed) {
      if (seen.add(normalizeMemoryText(item.text))) {
        items.add(item);
      }
    }

    // 根节点提案：未接 PersonaTree 时不解析。提案与 items 同出一份
    // 模型输出，但逐条独立校验；结构解析失败只丢提案，不影响 items。
    final proposals = personaTree == null
        ? const <PersonaDreamOp>[]
        : parseDreamRootProposals(raw, diagnosticsSink: _diagnosticsSink);

    // 独立草稿：先写候选版与变更清单，再跑自检各关。
    final draftSections = <String, List<String>>{
      for (final section in longMemorySections) section: <String>[],
    };
    for (final item in items) {
      draftSections[item.section]!.add(item.text);
    }
    final draftContent = renderLongMemory(draftSections);
    try {
      await _atomicWriter.replace(_draftFile.path, draftContent);
      // 过关前的清单不含候选原文：草稿可能携带敏感或被禁内容，
      // 只有通过全部自检的条目才允许持久化正文。
      await _writeChanges(
        _buildChanges(
          (today: today, previousState: state, result: 'pending'),
          input,
          items,
          existing,
          includeDetails: false,
        ),
      );
    } on Object catch (error) {
      return DreamOutcome(status: DreamStatus.writeFailed, detail: '$error');
    }

    // 冻结保留清单：现有长期印象里命中冻结的条目必须在候选版中
    // 原样保留（冻结停止自动修改）。模型删掉或改写任何一条都整份
    // 拒绝——旧文件保持原样，冻结内容绝不丢失。同时命中封禁的条目
    // 不保留：封禁严格强于冻结，冲突取最保守裁决（该内容离开长期
    // 印象，Dream 对其余内容照常），绝不陷入「 banned 关要它消失、
    // 冻结关要它留下」的死锁。
    final frozenRequired = <String>[];
    if (input.frozen.isNotEmpty && existing != null) {
      for (final item in existing.allItems) {
        if (bannedMemoryText(item, input.frozen) &&
            !bannedMemoryText(item, input.banned)) {
          frozenRequired.add(item);
        }
      }
    }

    final gateFailure = _validateDraft(
      items: items,
      draftContent: draftContent,
      validDates: input.validDates,
      validMonths: input.validMonths,
      banned: input.banned,
      frozen: input.frozen,
      frozenRequired: frozenRequired,
    );
    if (gateFailure != null) {
      await _writeChanges(
        _buildChanges(
          (
            today: today,
            previousState: state,
            result: 'rejected ($gateFailure)',
          ),
          input,
          items,
          existing,
          includeDetails: false,
          rootOps: [
            for (final op in proposals) _RootOpRecord(op, 'draft-rejected'),
          ],
        ),
      );
      await _deleteIfExists(_draftFile);
      return DreamOutcome(status: DreamStatus.validationFailed, detail: gateFailure);
    }

    // 根节点提案逐条校验：无证据、过度推断、敏感、禁提或复活的提案
    // 单独拒绝，其余提案与 items 接纳互不影响。被拒提案不持久化主张
    // 原文，只落原因码（草稿可能携带敏感内容，与过关前的清单同律）。
    final opRecords = <_RootOpRecord>[];
    final acceptedOps = <PersonaDreamOp>[];
    if (proposals.isNotEmpty) {
      final snapshot = input.personaSnapshot;
      final createdClaims = <String>[];
      for (final op in proposals) {
        final reason = snapshot == null
            ? 'persona-unavailable'
            : _validateProposal(
                op,
                snapshot,
                input.banned,
                createdClaims,
                frozen: input.frozen,
              );
        final record = _RootOpRecord(op, reason);
        opRecords.add(record);
        if (reason == null) {
          acceptedOps.add(op);
        } else {
          _diagnosticsSink(
            'dream root proposal rejected reason=$reason '
            'branch=${op.branchWire}',
          );
        }
      }
    }

    // 原子接纳（T10：先备份旧文件再替换；每一步都是 temp+rename）。
    try {
      if (existingContent != null) {
        await _atomicWriter.replace(_backupFile.path, existingContent);
      }
      await _atomicWriter.replace(_longMemoryFile.path, draftContent);
      await _atomicWriter.replace(
        _stateFile.path,
        _encodeState(DreamState(lastSuccess: now, pending: false)),
      );
      // 树变更落盘前先备份全部可读分支与归档（T26：PersonaTree 的
      // 最近有效 Dream 备份是它的恢复来源）。备份失败只记诊断，
      // 不阻断树变更（与既有「树失败不回滚长期印象」同律）。
      await _backupPersonaTree();
      // 长期印象替换成功后才动树：树变更失败不回滚长期印象（不同文件，
      // 下次 Dream 可再评估），只把对应提案记为未落盘。
      if (acceptedOps.isNotEmpty) {
        try {
          final result = await personaTree!.applyDreamChanges(
            date: today,
            ops: acceptedOps,
          );
          var cursor = 0;
          for (final record in opRecords) {
            if (record.reason != null) {
              continue;
            }
            final outcome = result.outcomes[cursor];
            cursor += 1;
            if (outcome != null) {
              record.reason = 'skipped-in-apply($outcome)';
            }
          }
        } on Object catch (error) {
          _diagnosticsSink('dream persona apply deferred [$error]');
          for (final record in opRecords) {
            record.reason ??= 'apply-deferred';
          }
        }
      }
      await _writeChanges(
        _buildChanges(
          (today: today, previousState: state, result: 'accepted'),
          input,
          items,
          existing,
          includeDetails: true,
          rootOps: opRecords,
        ),
      );
      await _archiveChanges(today);
      await _deleteIfExists(_draftFile);
    } on Object catch (error) {
      return DreamOutcome(status: DreamStatus.writeFailed, detail: '$error');
    }
    final appliedCount = opRecords
        .where((record) => record.reason == null)
        .length;
    return DreamOutcome(
      status: DreamStatus.accepted,
      rootOpsApplied: appliedCount,
      rootOpsRejected: opRecords.length - appliedCount,
    );
  }

  /// 只读暴露最近一次成功 Dream 的状态（ticket 19 记忆中心展示
  /// 「最近整理时间」用）；文件缺失或不可读时返回空状态。
  Future<DreamState> readState() async => (await _readState()).state;

  /// Dream 状态文件结构可读性（ticket 23 开发者诊断用）：文件缺失
  /// 视为可读（从未运行），结构无法识别为不可读，等待恢复流程。
  Future<bool> stateReadable() async => !(await _readState()).corrupted;

  /// 开发者诊断事实（ticket 23）：上次成功时间、日历日差、待补跑与
  /// 最小间隔（[dreamMinIntervalDays] 天）是否满足。只读，不写状态；
  /// [today] 供测试注入当前日期。
  Future<DreamHealthFacts> healthFacts({String? today}) async {
    final state = await readState();
    final currentDate = today ?? localSessionDate(_clock());
    final daysSinceLastSuccess = _daysSinceLastSuccess(state, currentDate);
    final intervalSatisfied =
        daysSinceLastSuccess == null ||
        daysSinceLastSuccess >= dreamMinIntervalDays;
    return DreamHealthFacts(
      lastSuccess: state.lastSuccess,
      pending: state.pending,
      daysSinceLastSuccess: daysSinceLastSuccess,
      intervalSatisfied: intervalSatisfied,
    );
  }

  Directory get _personaBackupDirectory =>
      Directory(path.join(memoryDirectory, 'dream', 'backup', 'persona-tree'));

  /// 树变更前的整树备份：全部可读分支与归档文件逐文件原子写入
  /// `dream/backup/persona-tree/`。单文件失败只记诊断，其余照写。
  Future<void> _backupPersonaTree() async {
    final tree = personaTree;
    if (tree == null) {
      return;
    }
    try {
      final files = await tree.backupFiles();
      for (final MapEntry(:key, :value) in files.entries) {
        await _atomicWriter.replace(
          path.join(_personaBackupDirectory.path, key),
          value,
        );
      }
    } on Object catch (error) {
      _diagnosticsSink('dream persona backup deferred [$error]');
    }
  }

  /// 最近有效的 long-memory Dream 备份（ticket 21 恢复来源）；
  /// 不存在或结构不可读时返回 null。
  Future<String?> readLongMemoryBackup() async {
    final contents = await readFileIfExists(_backupFile);
    if (contents == null) {
      return null;
    }
    return parseLongMemory(contents).readable ? contents : null;
  }

  /// 最近有效的 PersonaTree Dream 备份（ticket 21 恢复来源）：键为
  /// 相对布局（`identity.md`、`archive/identity.md`）；目录不存在时
  /// 返回空映射。逐文件的可解析校验在恢复写入侧执行。
  Future<Map<String, String>> readPersonaTreeBackup() async {
    final directory = _personaBackupDirectory;
    if (!await directory.exists()) {
      return const {};
    }
    final files = <String, String>{};
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File || !entity.path.endsWith('.md')) {
        continue;
      }
      final relative = path
          .relative(entity.path, from: directory.path)
          .replaceAll(Platform.pathSeparator, '/');
      try {
        final contents = await entity.readAsString(encoding: utf8);
        if (contents.trim().isNotEmpty) {
          files[relative] = contents;
        }
      } on Object {
        // 读不到的备份文件不入备份集。
      }
    }
    return files;
  }

  /// 读取 Dream 状态；文件不存在返回空状态，存在但不可读时
  /// [corrupted] 为 true。
  Future<({DreamState state, bool corrupted})> _readState() async {
    final file = _stateFile;
    if (!await file.exists()) {
      return (state: const DreamState(), corrupted: false);
    }
    try {
      final decoded = _decodeState(await file.readAsString(encoding: utf8));
      if (decoded == null) {
        return (state: const DreamState(), corrupted: true);
      }
      return (state: decoded, corrupted: false);
    } on Object {
      return (state: const DreamState(), corrupted: true);
    }
  }

  Future<bool> _writeState(DreamState state) async {
    try {
      await _atomicWriter.replace(_stateFile.path, _encodeState(state));
      return true;
    } on Object {
      return false;
    }
  }

  /// 组装 Dream 输入（全部只读）并执行上下文预算裁剪。受控内容
  /// （封禁 ∪ 冻结）不参与整理：日摘要、月摘要条目、关系投影、
  /// 未闭环线索与长期印象里的封禁条目都在递给模型前过滤；冻结的
  /// 长期印象条目保留给模型，由冻结保留关强制原样带回。
  Future<_DreamInput> _collectInput({required String? after}) async {
    // Dream 只读最小控制信息（定稿）：封禁集合（禁提 ∪ 删除）进自检
    // 闸门与模型清单；冻结集合用于保持被冻结条目原样、拒绝触碰
    // 冻结节点的根提案。
    final controls = openLoopStore == null
        ? null
        : await openLoopStore!.memoryControls.load();
    final banned = controls?.blockedSummaries ?? const <String>{};
    final frozen = controls?.frozenSummaries ?? const <String>{};
    bool controlled(String text) =>
        bannedMemoryText(text, banned) || bannedMemoryText(text, frozen);

    final dates = await episodePipeline.listEpisodeDates();
    final summaries = <({String date, String summary})>[];
    for (final date in dates) {
      // 含 after 当天：上次成功时刻（如当天凌晨补跑）早于当天日终归档，
      // 当天的日摘要必然未被上一轮看过；重复纳入无害，漏看一天才是真缺口。
      if (after != null && date.compareTo(after) < 0) {
        continue;
      }
      final day = await episodePipeline.readDay(date);
      if (!day.readable || !day.finalized) {
        continue;
      }
      final summary = day.summary?.trim() ?? '';
      if (summary.isEmpty || controlled(summary)) {
        continue;
      }
      summaries.add(
        (date: date, summary: clipRunes(summary, dailySummaryMaxRunes)),
      );
    }
    final windowed = summaries.length > dreamSummaryWindowDays
        ? summaries.sublist(summaries.length - dreamSummaryWindowDays)
        : summaries;

    final monthSummaries = <({String month, String contents})>[];
    final compressor = monthlySummary;
    if (compressor != null) {
      final months = <String>{
        for (final date in dates) date.substring(0, 7),
      }.toList()
        ..sort();
      for (final month in months.reversed.take(dreamMaxMonthSummaries)) {
        final summary = await compressor.readMonthSummary(month);
        if (summary == null || !summary.readable) {
          continue;
        }
        final contents = _renderMonthForModel(summary, controlled: controlled);
        if (contents.isEmpty) {
          continue;
        }
        monthSummaries.insert(0, (month: month, contents: contents));
      }
    }

    final relationship = filterControlledLines(
      await readFileIfExists(
        File(path.join(memoryDirectory, 'relationship.md')),
      ),
      controlled,
    );
    final openLoops = await _filteredOpenLoops(controlled);
    final longMemory = _filterLongMemoryInput(
      await readFileIfExists(_longMemoryFile),
      banned,
    );

    // PersonaTree 快照：模型输入只给活跃根与未归根理解（含叶证据的
    // 日期/来源/关系）；归档只作代码校验的负面依据，不递给模型。
    // 命中冻结的主张按原样留在树里但不递给模型——冻结内容绝不参与
    // 自动整理（否则模型可能据冻结主张写出新的长期印象条目）。
    PersonaTreeSnapshot? personaSnapshot;
    String? personaSection;
    String? appellation;
    final tree = personaTree;
    if (tree != null) {
      personaSnapshot = await tree.readSnapshot();
      final rendered = _renderTreeForModel(personaSnapshot, frozen);
      personaSection = rendered.isEmpty ? null : rendered;
      // 记忆表述惯例（称呼定稿）：新长期印象指称用户按称呼走。
      appellation = await tree.readAppellation();
    }

    // 预算裁剪：关系与未闭环线索体量已有分块预算，PersonaTree 结构
    // 是提案依据不裁；先裁最旧月摘要，再裁最旧日摘要。
    var total = _inputRunes(
      windowed,
      monthSummaries,
      relationship: relationship,
      openLoops: openLoops,
      longMemory: longMemory,
      personaSection: personaSection,
    );
    while (total > dreamInputMaxRunes && monthSummaries.isNotEmpty) {
      total -= monthSummaries.removeAt(0).contents.runes.length;
    }
    while (total > dreamInputMaxRunes && windowed.isNotEmpty) {
      final removed = windowed.removeAt(0);
      total -= '${removed.date}: ${removed.summary}'.runes.length;
    }

    return _DreamInput(
      summaries: windowed,
      monthSummaries: monthSummaries,
      relationship: relationship,
      openLoops: openLoops,
      longMemory: longMemory,
      personaSnapshot: personaSnapshot,
      personaSection: personaSection,
      appellation: appellation,
      banned: banned,
      frozen: frozen,
      validDates: {for (final entry in windowed) entry.date},
      validMonths: {for (final entry in monthSummaries) entry.month},
    );
  }

  int _inputRunes(
    List<({String date, String summary})> summaries,
    List<({String month, String contents})> monthSummaries, {
    required String? relationship,
    required String? openLoops,
    required String? longMemory,
    required String? personaSection,
  }) {
    var total = 0;
    for (final entry in summaries) {
      total += '${entry.date}: ${entry.summary}'.runes.length;
    }
    for (final entry in monthSummaries) {
      total += entry.contents.runes.length;
    }
    total += (relationship ?? '').runes.length;
    total += (openLoops ?? '').runes.length;
    total += (longMemory ?? '').runes.length;
    total += (personaSection ?? '').runes.length;
    return total;
  }

  String _renderMonthForModel(
    MonthSummary summary, {
    bool Function(String text)? controlled,
  }) {
    bool hit(String text) => controlled != null && controlled(text);
    final buffer = StringBuffer();
    final theme = summary.theme.where((keyword) => !hit(keyword)).toList();
    if (theme.isNotEmpty) {
      buffer.writeln('主题: ${theme.join('、')}');
    }
    for (final item in summary.items) {
      if (hit(item.text)) {
        continue;
      }
      buffer.writeln('- [${item.section}] ${item.date} ${item.text}');
    }
    return buffer.toString().trim();
  }

  /// 未闭环线索的受控过滤：封禁/冻结标题的条目不递给 Dream。
  /// 结构不可识别时原样递交（写侧另有控制闸门兜底）。
  Future<String?> _filteredOpenLoops(
    bool Function(String text) controlled,
  ) async => filterOpenLoopContents(
    await readFileIfExists(File(path.join(memoryDirectory, 'open-loops.md'))),
    controlled,
  );

  /// 长期印象输入过滤：封禁条目不递给模型（递给模型只会让草稿被
  /// 用户控制关整份拒绝）；冻结条目保留，冻结保留关要求其原样带回。
  /// 结构不可识别时原样递交。
  String? _filterLongMemoryInput(String? contents, Set<String> banned) {
    if (contents == null || banned.isEmpty) {
      return contents;
    }
    final parsed = parseLongMemory(contents);
    if (!parsed.readable) {
      return contents;
    }
    final (:sections, :changed) = filterLongMemorySections(parsed, banned);
    return changed ? renderLongMemory(sections) : contents;
  }

  /// PersonaTree 结构的模型输入：活跃根与未归根中间理解，附叶证据
  /// 的日期、来源性质与 support/conflict 关系。归档是代码校验的负面
  /// 依据，不递给模型（避免已纠正内容重新进入生成）。命中冻结集合的
  /// 根/中间理解/叶同样不递给模型：冻结按设计留在树里，但绝不参与
  /// 自动整理。
  String _renderTreeForModel(PersonaTreeSnapshot snapshot, Set<String> frozen) {
    final buffer = StringBuffer();
    for (final branch in personaBranches) {
      final view = snapshot.branches[branch.wireName];
      if (view == null || !view.readable) {
        continue;
      }
      if (view.roots.isEmpty && view.unrooted.isEmpty) {
        continue;
      }
      buffer.writeln('### ${branch.title}（${branch.wireName}）');
      for (final root in view.roots) {
        if (frozenTitleHit(root.claim, frozen)) {
          continue;
        }
        buffer.writeln('- 根 [${root.id}] ${root.claim}');
        for (final middle in root.middles) {
          if (frozenTitleHit(middle.claim, frozen)) {
            continue;
          }
          buffer.writeln(
            '  - [${middle.id}] ${middle.type}｜${middle.claim}'
            '（${_describeLeaves(middle.leaves)}）',
          );
        }
      }
      for (final middle in view.unrooted) {
        if (frozenTitleHit(middle.claim, frozen)) {
          continue;
        }
        buffer.writeln(
          '- 未归根 [${middle.id}] ${middle.type}｜${middle.claim}'
          '（${_describeLeaves(middle.leaves)}）',
        );
      }
    }
    return buffer.toString().trim();
  }

  String _describeLeaves(List<PersonaLeaf> leaves) {
    if (leaves.isEmpty) {
      return '无叶证据';
    }
    return [
      for (final leaf in leaves) '${leaf.date} ${leaf.nature} ${leaf.relation}',
    ].join('；');
  }

  /// 根节点提案逐条校验：返回拒绝原因码，null 为通过。所有门槛都
  /// 来自 PersonaTree.md 定稿——证据不足、过度推断、敏感、封禁、
  /// 复活已归档主张、带时间限定的近况，一律拒绝该提案。冻结停止
  /// 自动整理：触碰冻结节点（根或中间理解）的提案同样拒绝。
  String? _validateProposal(
    PersonaDreamOp op,
    PersonaTreeSnapshot snapshot,
    Set<String> banned,
    List<String> claimsCreatedThisRound, {
    Set<String> frozen = const {},
  }) {
    final view = snapshot.branches[op.branchWire];
    if (view == null || !view.readable) {
      return 'branch-unreadable';
    }
    // 归档无法恢复时暂停受影响分支的全部根节点操作（T26 定稿）：没有
    // 「已纠正主张」的负面依据，升根与合并都可能复活旧画像。
    if (!view.archiveReadable) {
      return 'archive-unavailable';
    }

    // 按 ID 查活跃根 / 未归根中间理解并统一冻结命中判定：节点不存在
    // 返回 'unknown-root'/'unknown-middle'，命中冻结集合返回 'frozen'
    // （冻结停止自动整理：触碰冻结节点的提案一律拒绝）。拒绝码为
    // null 时节点必非空。
    (PersonaRoot?, String?) rootById(String id) {
      final root = view.roots
          .where((candidate) => candidate.id == id)
          .firstOrNull;
      if (root == null) {
        return (null, 'unknown-root');
      }
      return (root, frozenTitleHit(root.claim, frozen) ? 'frozen' : null);
    }

    (PersonaMiddle?, String?) middleById(String id, String missingCode) {
      final middle = view.unrooted
          .where((candidate) => candidate.id == id)
          .firstOrNull;
      if (middle == null) {
        return (null, missingCode);
      }
      return (middle, frozenTitleHit(middle.claim, frozen) ? 'frozen' : null);
    }

    switch (op) {
      case PersonaPromoteOp(:final claim, :final middleIds):
        final claimFailure = rootClaimGateFailure(claim, banned: banned);
        if (claimFailure != null) {
          return claimFailure;
        }
        if (frozenTitleHit(claim, frozen)) {
          return 'frozen';
        }
        final ids = middleIds.toSet();
        final middles = <PersonaMiddle>[];
        for (final id in ids) {
          final (middle, failure) = middleById(id, 'unknown-middle');
          if (failure != null) {
            return failure;
          }
          middles.add(middle!);
        }
        final leaves = [for (final middle in middles) ...middle.leaves];
        if (leaves.any((leaf) => leaf.relation == 'conflict')) {
          return 'unresolved-conflict';
        }
        final branch = personaBranchForWire(op.branchWire)!;
        final gateFailure = promotionGateFailure(branch, leaves);
        if (gateFailure != null) {
          return gateFailure;
        }
        final collision = _claimCollision(claim, view, claimsCreatedThisRound);
        if (collision != null) {
          return collision;
        }
        claimsCreatedThisRound.add(normalizeMemoryText(claim));
        return null;
      case PersonaAbsorbOp(:final rootId, :final middleIds):
        final (root, rootFailure) = rootById(rootId);
        if (rootFailure != null) {
          return rootFailure;
        }
        final ids = middleIds.toSet();
        for (final id in ids) {
          final (middle, failure) = middleById(id, 'unknown-middle');
          if (failure != null) {
            return failure;
          }
          if (middle!.leaves.any((leaf) => leaf.relation == 'conflict')) {
            return 'unresolved-conflict';
          }
          if (!sameClaim(middle.claim, root!.claim)) {
            return 'claim-mismatch';
          }
        }
        return null;
      case PersonaDemoteOp(:final rootId, :final counterId):
        final (root, rootFailure) = rootById(rootId);
        if (rootFailure != null) {
          return rootFailure;
        }
        final (counter, counterFailure) = middleById(
          counterId,
          'unknown-counter',
        );
        if (counterFailure != null) {
          return counterFailure;
        }
        // 降根只认「两个不同日期的反向行为已形成反向中间理解」的
        // 证据形态（日终冲突升级的产物）；单日期或无叶的引用不成立。
        final counterDates = counter!.leaves
            .map((leaf) => leaf.date)
            .toSet()
            .length;
        if (counter.leaves.length < 2 || counterDates < 2) {
          return 'counter-insufficient';
        }
        if (sameClaim(counter.claim, root!.claim)) {
          return 'counter-same-claim';
        }
        return null;
      case PersonaMergeOp(:final claim, :final rootIds):
        final claimFailure = rootClaimGateFailure(claim, banned: banned);
        if (claimFailure != null) {
          return claimFailure;
        }
        if (frozenTitleHit(claim, frozen)) {
          return 'frozen';
        }
        final ids = rootIds.toSet();
        if (ids.length < 2) {
          return 'needs-two-roots';
        }
        final roots = <PersonaRoot>[];
        for (final id in ids) {
          final (root, failure) = rootById(id);
          if (failure != null) {
            return failure;
          }
          roots.add(root!);
        }
        for (final root in roots) {
          if (root.allLeaves.any((leaf) => leaf.relation == 'conflict')) {
            return 'unresolved-conflict';
          }
          if (conflictTopic(claim, root.claim)) {
            return 'claim-conflict';
          }
        }
        if (!roots.any((root) => sameClaim(claim, root.claim))) {
          return 'claim-drift';
        }
        final collision = _claimCollision(
          claim,
          view,
          claimsCreatedThisRound,
          excludeRootIds: ids,
        );
        if (collision != null) {
          return collision;
        }
        claimsCreatedThisRound.add(normalizeMemoryText(claim));
        return null;
    }
  }

  /// 新根主张的重复/复活检查：与现有根、归档主张或本轮已接纳主张
  /// 同义即拒绝。[excludeRootIds] 供合并操作排除参与合并的根。
  String? _claimCollision(
    String claim,
    PersonaBranchSnapshot view,
    List<String> claimsCreatedThisRound, {
    Set<String> excludeRootIds = const {},
  }) {
    for (final root in view.roots) {
      if (excludeRootIds.contains(root.id)) {
        continue;
      }
      if (sameClaim(claim, root.claim)) {
        return 'duplicate-root';
      }
    }
    for (final archived in view.archivedClaims) {
      if (sameClaim(claim, archived)) {
        return 'archived-claim';
      }
    }
    for (final created in claimsCreatedThisRound) {
      if (sameClaim(claim, created)) {
        return 'duplicate-root';
      }
    }
    return null;
  }

  /// 自检七关：任一不过返回失败原因码，整份草稿作废。
  String? _validateDraft({
    required List<DreamItem> items,
    required String draftContent,
    required Set<String> validDates,
    required Set<String> validMonths,
    required Set<String> banned,
    required Set<String> frozen,
    required List<String> frozenRequired,
  }) {
    // 结构关：条目数与总量都在预算内；空候选一律拒绝——没有产出就
    // 不接纳，绝不允许一次清空已有的全部长期印象。
    if (items.isEmpty) {
      return 'empty';
    }
    if (items.length > dreamMaxItems) {
      return 'too-many';
    }
    if (draftContent.runes.length > longMemoryMaxRunes) {
      return 'over-budget';
    }
    // 证据关：每条必须携带至少一个真实出处，编造的一律整份作废。
    // 日摘要只是窗口采样，月摘要却覆盖整月：日期引用命中日摘要窗口、
    // 或其所属月份的月摘要在场，即可核；PersonaTree、关系与未闭环是
    // 状态快照不是记录，其日期仍不认。拒绝时诊断第一个被拒引用
    // （只含日期，绝不含候选文本）。
    for (final item in items) {
      if (item.evidence.isEmpty) {
        return 'missing-evidence';
      }
      for (final ref in item.evidence) {
        final known = _dayPattern.hasMatch(ref)
            ? validDates.contains(ref) ||
                  validMonths.contains(ref.substring(0, 7))
            : _monthPattern.hasMatch(ref) && validMonths.contains(ref);
        if (!known) {
          _diagnosticsSink('dream evidence rejected [ref=$ref]');
          return 'unknown-evidence';
        }
      }
    }
    // 脱敏关：secrets 不得进入热层。
    for (final item in items) {
      if (redactSessionText(item.text) != item.text) {
        return 'sensitive';
      }
    }
    // 用户控制关：不得改写或复活封禁（禁提 ∪ 删除）内容。
    for (final item in items) {
      if (bannedMemoryText(item.text, banned)) {
        return 'banned';
      }
    }
    // 冻结保留关：被冻结的既有条目必须在候选版中原样出现；缺少任何
    // 一条都整份作废（旧长期印象不动，冻结绝不因 Dream 失效）。
    final draftNormalized = {
      for (final item in items) normalizeMemoryText(item.text),
    };
    for (final required in frozenRequired) {
      if (!draftNormalized.contains(normalizeMemoryText(required))) {
        return 'frozen';
      }
    }
    // 冻结禁止新增关：冻结停止自动整理——候选版除了原样保留的既有
    // 冻结条目，绝不允许出现命中冻结范围的新内容。
    final requiredNormalized = {
      for (final item in frozenRequired) normalizeMemoryText(item),
    };
    for (final item in items) {
      final normalized = normalizeMemoryText(item.text);
      if (bannedTitleMatches(normalized, frozen) &&
          !requiredNormalized.contains(normalized)) {
        return 'frozen';
      }
    }
    // 相互矛盾关：候选版内部同一核心断言一正一反并存。
    final cores = <String, bool>{};
    for (final item in items) {
      final (core, negated) = _coreAndNegation(item.text);
      if (core.isEmpty) {
        continue;
      }
      final seen = cores[core];
      if (seen != null && seen != negated) {
        return 'contradiction';
      }
      cores[core] = negated;
    }
    return null;
  }

  (String, bool) _coreAndNegation(String text) {
    final stripped = text.replaceAll(RegExp(r'[。．.！!？?，,；;、]'), '');
    var core = normalizeMemoryText(stripped);
    var negated = false;
    for (final token in _negationTokens) {
      if (core.contains(token)) {
        core = core.replaceAll(token, '');
        negated = true;
      }
    }
    if (!negated) {
      for (final prefix in _leadingNegations) {
        if (core.startsWith(prefix) && core.length > prefix.length) {
          core = core.substring(prefix.length);
          negated = true;
          break;
        }
      }
    }
    for (final particle in _aspectParticles) {
      core = core.replaceAll(particle, '');
    }
    return (core, negated);
  }

  /// 变更清单（诊断档案，不是审批单）：接纳后逐条写改了什么、证据在
  /// 哪，以及与上一版的增删保留。栖语聊天时永远不提。
  ///
  /// [includeDetails] 只在接纳成功（自检各关全部通过）时为 true。被拒或
  /// 待定的草稿可能携带敏感、禁提内容，清单绝不能落盘其原文，只记
  /// 结果码与数量——否则等于把模型吐出的密钥写进记忆目录。
  String _buildChanges(
    ({String today, DreamState previousState, String result}) run,
    _DreamInput input,
    List<DreamItem> items,
    LongMemoryFile? existing, {
    required bool includeDetails,
    List<_RootOpRecord> rootOps = const [],
  }) {
    final rangeStart = run.previousState.lastSuccess == null
        ? '最初'
        : localSessionDate(run.previousState.lastSuccess!);
    final buffer = StringBuffer()
      ..writeln('# dream-changes')
      ..writeln()
      ..writeln('date: ${run.today}')
      ..writeln(
        'range: $rangeStart → ${run.today}'
        '（日摘要 ${input.summaries.length} 天，月摘要 ${input.monthSummaries.length} 月）',
      )
      ..writeln('result: ${run.result}')
      ..writeln('候选条目数: ${items.length}');
    if (rootOps.isNotEmpty) {
      buffer.writeln('根节点提案数: ${rootOps.length}');
    }
    if (!includeDetails) {
      return buffer.toString();
    }
    if (rootOps.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## 根节点提案');
      for (final record in rootOps) {
        final verdict = record.reason == null
            ? 'accepted'
            : 'rejected(${record.reason})';
        buffer.writeln('- ${_describeOp(record.op)}: $verdict');
      }
    }
    final oldItems = existing?.allItems ?? const <String>[];
    final newNormalized = {
      for (final item in items) normalizeMemoryText(item.text),
    };
    final oldNormalized = {for (final item in oldItems) normalizeMemoryText(item)};
    buffer
      ..writeln()
      ..writeln('## 候选条目');
    if (items.isEmpty) {
      buffer.writeln('（无）');
    }
    for (final item in items) {
      buffer.writeln(
        '- [${item.section}] ${item.text} | 证据: ${item.evidence.join('、')}',
      );
    }
    buffer
      ..writeln()
      ..writeln('## 相对上一版');
    final added = items
        .where((item) => !oldNormalized.contains(normalizeMemoryText(item.text)))
        .toList();
    final kept = items
        .where((item) => oldNormalized.contains(normalizeMemoryText(item.text)))
        .toList();
    final removed = oldItems
        .where((item) => !newNormalized.contains(normalizeMemoryText(item)))
        .toList();
    buffer.writeln('### 新增');
    for (final item in added) {
      buffer.writeln('- [${item.section}] ${item.text}');
    }
    buffer.writeln('### 保留');
    for (final item in kept) {
      buffer.writeln('- [${item.section}] ${item.text}');
    }
    buffer.writeln('### 移除');
    for (final item in removed) {
      buffer.writeln('- $item');
    }
    return buffer.toString();
  }

  Future<void> _writeChanges(String contents) async {
    try {
      await _atomicWriter.replace(_changesFile.path, contents);
    } on Object catch (error) {
      _diagnosticsSink('dream changes deferred [$error]');
    }
  }

  /// 清单归档属于接纳后的收尾：失败只记诊断，不影响已完成的接纳。
  Future<void> _archiveChanges(String today) async {
    try {
      final source = _changesFile;
      if (!await source.exists()) {
        return;
      }
      final contents = await source.readAsString(encoding: utf8);
      await _atomicWriter.replace(
        path.join(_historyDirectory.path, 'changes-$today.md'),
        contents,
      );
      await source.delete();
      // 只保留最近几份清单。
      if (!await _historyDirectory.exists()) {
        return;
      }
      final archives = <String>[];
      await for (final entity in _historyDirectory.list(followLinks: false)) {
        if (entity is File &&
            path.basename(entity.path).startsWith('changes-')) {
          archives.add(entity.path);
        }
      }
      archives.sort();
      if (archives.length > dreamHistoryKeep) {
        for (final old in archives.take(archives.length - dreamHistoryKeep)) {
          await File(old).delete();
        }
      }
    } on Object catch (error) {
      _diagnosticsSink('dream archive deferred [$error]');
    }
  }

  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on Object catch (error) {
      _diagnosticsSink('dream cleanup deferred [$error]');
    }
  }

  List<ModelMessage> _dreamMessages(_DreamInput input) {
    // 记忆表述惯例（称呼定稿 2026-09-03）：有称呼用称呼、无称呼用
    // 「用户」。称呼格式受控（无换行与控制字符、限长），可安全内嵌；
    // 值与主链画像块同源，进提示前套用同一份脱敏规则。
    final safeAppellation = input.appellation == null
        ? null
        : redactSessionText(input.appellation!);
    final appellationRule = safeAppellation == null
        ? '8. 印象文本指称用户时一律写「用户」，不要替用户起昵称。'
        : '8. 印象文本指称用户时一律用称呼「$safeAppellation」，不要写'
            '「用户」，也不要替用户起昵称。';
    final system = '''
你是栖语离线记忆的深度重组模块（Dream）。给你用户已整理的记忆与当前长期印象，请产出新长期印象的候选版。要求：
1. 只输出一个 JSON 对象，不要输出任何其它文字、解释或代码块标记。
2. 每条印象必须有给定材料中的依据，不得编造、不得引入材料外的事实。
3. 只保留高压缩的生活倾向、持续关注和关系变化：用户现实里的重要的人、值得长期记住的人生事件、经历过的变化与反复出现的主题、双方共同形成的经历；不写产品机制、逐日流水账、一次性任务细节、原话细节或证据链。模式与轨迹按成长线写：一行「时间段＋前后变化」，保持中性；共同过往只收双方真实互动、有整理日期依据的内容，不写单方面印象。
4. 每条是一行压缩印象，不超过60字，可以带时间词。
5. 以当前长期印象为基础保守重组：同义的合并，仍有依据的保留，被更新证据推翻的改写；拿不准就不写。
6. 绝不出现密码、密钥、证件号、银行卡号等敏感内容；绝不触碰禁提清单中的话题；冻结清单命中的现有长期印象必须逐字原样保留。
7. rootProposals：可选数组，最多8条；递来 PersonaTree 结构时才可提保守的根节点调整，没有把握就不提，节点 ID 必须取自递来的结构，绝不编造：
   - {"op":"promote","branch":"identity|expression|values|preferences|boundaries","claim":"一句不带时间词的稳定主张，不超过60字","middles":["XX-Mnnn"]}：把证据充分的未归根中间理解升为新根；identity 分支只接受明确自述；证据不足的中间理解保持未归根，不强行升根。
   - {"op":"absorb","branch":"…","root":"XX-Rnnn","middles":["XX-Mnnn"]}：把与已有根同主张的未归根中间理解归入该根。
   - {"op":"demote","branch":"…","root":"XX-Rnnn","counter":"XX-Mnnn"}：只有反向中间理解真实存在时才降根，counter 必填且取自未归根中间理解。
   - {"op":"merge","branch":"…","roots":["XX-Rnnn","XX-Rnnn"],"claim":"合并后的稳定主张"}：只合并同义或过度细分的根。
   boundaries 分支的行为推断只能写成「少探问」「谨慎接近」这类软边界，不得伪装成用户明确禁止。
   提案的 claim 同样不得带「最近/这周/这几天」等时间限定，不得出现敏感或禁提内容。
$appellationRule
字段白名单：
- items: 数组，最多24项，每项 {"section": 人与关系、重要事件、模式与轨迹、共同过往 之一, "text": 一行压缩印象，不超过60字, "evidence": 日期数组，每项形如 YYYY-MM-DD 或 YYYY-MM，只能取自「可用证据清单」列出的日期/月份，绝不编造}。
- rootProposals: 可选数组，格式见第7条；不调整树时省略该字段。''';

    final user = StringBuffer()
      ..writeln('## 当前长期印象')
      ..writeln(sectionOrEmpty(input.longMemory));

    // 「节标题 +（无）或逐行」的统一写法：材料为空写占位，否则逐行。
    void writeList(String title, Iterable<String> lines) {
      user
        ..writeln()
        ..writeln(title);
      final items = lines.toList();
      if (items.isEmpty) {
        user.writeln('（无）');
      } else {
        for (final line in items) {
          user.writeln(line);
        }
      }
    }

    writeList(
      '## 已整理记录（finalized 摘要）',
      [
        for (final entry in input.summaries) '- ${entry.date}: ${entry.summary}',
      ],
    );
    writeList(
      '## 月摘要',
      [
        for (final entry in input.monthSummaries)
          ...['### ${entry.month}', entry.contents],
      ],
    );
    // 证据清单显式列出可引用的日期/月份：长期印象、PersonaTree 叶证据
    // 都带旧日期，模型无从自行判断哪些可作证据，显式清单是唯一可靠依据。
    user
      ..writeln()
      ..writeln('## 可用证据清单');
    final evidenceDates = input.validDates.toList()..sort();
    final evidenceMonths = input.validMonths.toList()..sort();
    if (evidenceDates.isEmpty && evidenceMonths.isEmpty) {
      user.writeln('（无）');
    } else {
      if (evidenceDates.isNotEmpty) {
        user.writeln('日期：${evidenceDates.join('、')}');
      }
      if (evidenceMonths.isNotEmpty) {
        user.writeln('月份：${evidenceMonths.join('、')}');
      }
    }
    user
      ..writeln()
      ..writeln('## PersonaTree 当前结构')
      ..writeln(sectionOrEmpty(input.personaSection))
      ..writeln()
      ..writeln('## 关系状态')
      ..writeln(sectionOrEmpty(input.relationship))
      ..writeln()
      ..writeln('## 未闭环线索')
      ..writeln(sectionOrEmpty(input.openLoops));
    writeList('## 禁提清单（以下话题绝不出现）', [
      for (final title in input.banned) '- $title',
    ]);
    writeList(
      '## 冻结清单（命中的现有长期印象必须原样保留，不得改写、合并或删除）',
      [for (final title in input.frozen) '- $title'],
    );
    return [
      ModelMessage(ModelMessageRole.system, system),
      ModelMessage(ModelMessageRole.user, redactSessionText(user.toString())),
    ];
  }
}

/// 一条根节点提案的校验/落盘记录。[reason] 为 null 表示通过校验并
/// 落盘；否则是拒绝原因码。只存原因码与操作对象（含节点 ID），绝不
/// 存主张原文——被拒提案可能携带敏感内容。[reason] 可变：校验通过后
/// 仍可能在落盘阶段被 store 的存在性防御跳过。
final class _RootOpRecord {
  _RootOpRecord(this.op, this.reason);

  final PersonaDreamOp op;
  String? reason;
}

/// 提案的诊断描述：只含操作类型、分支与节点 ID，绝不含主张原文。
String _describeOp(PersonaDreamOp op) => switch (op) {
  PersonaPromoteOp(:final middleIds) =>
    'promote ${op.branchWire}(${middleIds.join(',')})',
  PersonaAbsorbOp(:final rootId, :final middleIds) =>
    'absorb ${op.branchWire}($rootId←${middleIds.join(',')})',
  PersonaDemoteOp(:final rootId, :final counterId) =>
    'demote ${op.branchWire}($rootId,counter=$counterId)',
  PersonaMergeOp(:final rootIds) =>
    'merge ${op.branchWire}(${rootIds.join(',')})',
};

/// Dream 一次运行的输入快照。
final class _DreamInput {
  const _DreamInput({
    required this.summaries,
    required this.monthSummaries,
    required this.relationship,
    required this.openLoops,
    required this.longMemory,
    required this.personaSnapshot,
    required this.personaSection,
    required this.appellation,
    required this.banned,
    required this.frozen,
    required this.validDates,
    required this.validMonths,
  });

  final List<({String date, String summary})> summaries;
  final List<({String month, String contents})> monthSummaries;
  final String? relationship;
  final String? openLoops;
  final String? longMemory;

  /// PersonaTree 只读快照：根节点提案校验的事实来源；未接树时为 null。
  final PersonaTreeSnapshot? personaSnapshot;

  /// 递给模型的树结构渲染；无树或树为空时为 null。
  final String? personaSection;

  /// 当前称呼（persona.md 受保护设定行）：印象文本指称用户的惯例依据。
  final String? appellation;

  /// 封禁集合（禁提 ∪ 删除，规范化后）：草稿与根提案都不得触碰。
  final Set<String> banned;

  /// 冻结集合（规范化后）：现有长期印象里命中的条目必须原样保留，
  /// 命中冻结节点的根提案一律拒绝。
  final Set<String> frozen;

  /// 本轮实际递给模型的整理日期与月份：证据关的白名单。
  final Set<String> validDates;
  final Set<String> validMonths;
}

String _encodeState(DreamState state) {
  final json = <String, Object?>{
    'schemaVersion': 1,
    if (state.lastSuccess != null)
      'lastSuccess': state.lastSuccess!.toUtc().toIso8601String(),
    'pending': state.pending,
  };
  return '# dream-state\n\n<!-- qiyu-dream-state:${encodeMarkerPayload(json)} -->\n';
}

DreamState? _decodeState(String contents) {
  final match = dreamStateMarkerPattern.firstMatch(contents);
  if (match == null) {
    return null;
  }
  try {
    final json = decodeMarkerPayload(match.group(1)!);
    if (json['schemaVersion'] != 1) {
      return null;
    }
    final lastSuccess = json['lastSuccess'];
    return DreamState(
      lastSuccess: lastSuccess is String ? DateTime.parse(lastSuccess) : null,
      pending: json['pending'] == true,
    );
  } on Object {
    return null;
  }
}

/// 距上次成功 Dream 的本地日历日差（[today] 为 YYYY-MM-DD）；从未
/// 成功时为 null。晚安预登记、执行资格复查与诊断事实共用同一口径。
int? _daysSinceLastSuccess(DreamState state, String today) =>
    state.lastSuccess == null
    ? null
    : dateSpanDays(localSessionDate(state.lastSuccess!), today);
