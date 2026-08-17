import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'daily_finalization.dart';
import 'episode_index.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'monthly_summary.dart';
import 'open_loop_store.dart';
import 'provider_settings_service.dart';

/// Dream 最小间隔（天）：距上次成功 Dream 的日历日差至少达到该值才
/// 具备执行资格（T04/T13 定稿取保守值 7 天；频率越高漂移风险越大）。
const dreamMinIntervalDays = 7;

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

/// long-memory 四分区（T03 定稿，顺序固定）。
const longMemorySections = ['人与关系', '重要事件', '模式与轨迹', '共同过往'];

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

  /// 距上次成功 Dream 不足七天。
  notDue,

  /// 没有已 finalized 的整理材料可供深度重组。
  skippedNoMaterial,

  /// 未配置 Provider：语义重组只调用用户配置的 LLM，绝不用规则补写。
  skippedNoProvider,

  /// Dream 状态或现有 long-memory 不可读：等待恢复流程，绝不覆盖。
  skippedUnreadable,

  /// 模型调用失败或输出无法解析：旧记忆原样保留，等待下次重试。
  modelFailed,

  /// 草稿未通过结构/证据/敏感/用户控制/相互矛盾五关之一：整份作废，
  /// 失败原因记入变更清单。
  validationFailed,

  /// 接纳过程写入失败：旧 long-memory 与上次成功时间保持原样。
  writeFailed,
}

final class DreamOutcome {
  const DreamOutcome({required this.status, this.detail});

  final DreamStatus status;

  /// 诊断细节（错误码级别），只进本机诊断，不含用户内容。
  final String? detail;
}

/// Dream 持久化状态：上次成功时间与是否有待补跑的晚安请求。
final class DreamState {
  const DreamState({this.lastSuccess, this.pending = false});

  final DateTime? lastSuccess;

  /// 晚安时具备资格但未成功（模型失败、验证失败、写入失败或配置
  /// 缺失）：下次启动补跑。只有成功才清除。
  final bool pending;
}

/// long-memory.md 解析结果。[readable] 为 false 表示结构无法识别
/// （损坏或手写越界）：Dream 绝不覆盖，等待恢复流程（ticket 21）。
final class LongMemoryFile {
  const LongMemoryFile({required this.readable, this.sections = const {}});

  final bool readable;
  final Map<String, List<String>> sections;

  List<String> get allItems => [
    for (final section in longMemorySections) ...?sections[section],
  ];
}

/// 解析 long-memory.md：只认 `# long-memory` 标题、四分区 `##` 小节
/// 与 `- ` 条目行；其余一律视为不可读。
LongMemoryFile parseLongMemory(String contents) {
  final sections = <String, List<String>>{};
  String? current;
  var sawTitle = false;
  for (final rawLine in contents.replaceAll('\r\n', '\n').split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      continue;
    }
    if (!sawTitle) {
      if (line != '# long-memory') {
        return const LongMemoryFile(readable: false);
      }
      sawTitle = true;
      continue;
    }
    if (line.startsWith('## ')) {
      final title = line.substring(3).trim();
      if (!longMemorySections.contains(title)) {
        return const LongMemoryFile(readable: false);
      }
      current = title;
      sections.putIfAbsent(title, () => <String>[]);
      continue;
    }
    if (line.startsWith('- ') && current != null) {
      final item = line.substring(2).trim();
      if (item.isEmpty) {
        return const LongMemoryFile(readable: false);
      }
      sections[current]!.add(item);
      continue;
    }
    return const LongMemoryFile(readable: false);
  }
  if (!sawTitle) {
    return const LongMemoryFile(readable: false);
  }
  return LongMemoryFile(readable: true, sections: sections);
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
    while (renderLongMemory(sections).runes.length > maxRunes &&
        items.isNotEmpty) {
      items.removeLast();
    }
    if (renderLongMemory(sections).runes.length <= maxRunes) {
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
/// 留给自检五关整份裁决。
List<DreamItem>? parseDreamCandidate(
  String raw, {
  void Function(String message)? diagnosticsSink,
}) {
  final sink = diagnosticsSink ?? stderrDiagnostics;
  final json = _extractJsonObject(raw);
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

/// Dream（五段节奏第五动作，ticket 16 / T04 / T08 / T13 定稿）。
///
/// 资格：触发必须来自晚安（[run] 的 bedtime 路径），或来自上次晚安
/// 未成功留下的补跑请求（pending，启动/空闲时兑现）；且距上次成功
/// Dream 的日历日差至少 [dreamMinIntervalDays] 天。日终归档与月压缩
/// 每天都可以执行，但从不写入 Dream 状态，绝不重置或绕过该间隔。
///
/// 输入（全部只读，遵守 [dreamInputMaxRunes] 预算）：上次成功之后的
/// finalized 日摘要（窗口 [dreamSummaryWindowDays] 天）、月摘要（至多
/// [dreamMaxMonthSummaries] 月）、关系状态、未闭环线索、现有长期印象
/// 与禁提清单。不读 sessions 原文，不写 episodes。
///
/// 流程：一次模型调用产出全量候选 → 写独立草稿与变更清单 → 自检五关
/// （结构、证据、敏感信息、用户控制、相互矛盾）→ 全部通过后原子接纳：
/// 备份旧文件 → 替换 long-memory.md → 记录成功时间 → 清单归档 history →
/// 清空 draft。任一关不过整份作废；中断、模型失败、验证失败或写入
/// 失败都不更新上次成功时间，也不破坏旧长期记忆。
///
/// 未配置 Provider 时不运行：语义重组只能调用用户配置的 LLM，绝不
/// 用规则或推断补写长期内容（对齐 T26 语义重建原则）。
final class DreamService {
  DreamService({
    required this.memoryDirectory,
    required this.episodePipeline,
    this.openLoopStore,
    this.monthlySummary,
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

  /// 深度重组调用的 Provider 客户端；null 时 Dream 整体跳过。
  final ProviderChatClient? modelClient;
  final Clock _clock;
  final AtomicTextWriter _atomicWriter;
  final void Function(String) _diagnosticsSink;

  File get _longMemoryFile => File(path.join(memoryDirectory, 'long-memory.md'));
  File get _stateFile => File(path.join(memoryDirectory, 'dream', 'state.md'));
  File get _changesFile => File(path.join(memoryDirectory, 'dream', 'changes.md'));
  File get _draftFile =>
      File(path.join(memoryDirectory, 'dream', 'draft', 'long-memory.md'));
  File get _backupFile =>
      File(path.join(memoryDirectory, 'dream', 'backup', 'long-memory.md'));
  Directory get _historyDirectory =>
      Directory(path.join(memoryDirectory, 'dream', 'history'));

  /// 晚安触发预登记：满足七天间隔时先把 pending 落盘。挂在晚安后台
  /// 任务链的最前面，保证即使进程在随后的归档/月压缩/Dream 链跑完前
  /// 退出（「当晚没跑成」），下次启动补跑仍能兑现这次晚安请求。
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
    if (state.lastSuccess != null &&
        _daysBetween(localSessionDate(state.lastSuccess!), today) <
            dreamMinIntervalDays) {
      return;
    }
    if (!await _writeState(
      DreamState(lastSuccess: state.lastSuccess, pending: true),
    )) {
      _diagnosticsSink('dream bedtime mark deferred [state not writable]');
    }
  }

  /// 执行一次 Dream。[bedtime] 为 true 表示本轮由晚安触发；为 false
  /// 时只在存在待补跑请求（pending）时执行（启动补跑路径）。
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
    if (state.lastSuccess != null) {
      final lastDate = localSessionDate(state.lastSuccess!);
      if (_daysBetween(lastDate, today) < dreamMinIntervalDays) {
        return const DreamOutcome(status: DreamStatus.notDue);
      }
    }

    // 中断补扫：上一轮被打断留下的草稿一律作废，同一时间只有一份
    // 进行中的草稿。
    await _deleteIfExists(_draftFile);

    final existingContent = await _readIfExists(_longMemoryFile);
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
      // 没有任何已整理材料：不跑也不记成功，清掉 pending，下次晚安
      // 有了材料再评估。
      await _writeState(DreamState(lastSuccess: state.lastSuccess, pending: false));
      return const DreamOutcome(status: DreamStatus.skippedNoMaterial);
    }

    final client = modelClient;
    if (client == null) {
      return const DreamOutcome(status: DreamStatus.skippedNoProvider);
    }
    ModelCompletion completion;
    try {
      final result = await client.complete(_dreamMessages(input));
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
          today,
          state,
          input,
          const [],
          existing,
          'rejected (unparseable)',
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

    // 独立草稿：先写候选版与变更清单，再跑五关。
    final draftSections = <String, List<String>>{
      for (final section in longMemorySections) section: <String>[],
    };
    for (final item in items) {
      draftSections[item.section]!.add(item.text);
    }
    final draftContent = renderLongMemory(draftSections);
    try {
      await _atomicWriter.replace(_draftFile.path, draftContent);
      // 五关之前的清单不含候选原文：草稿可能携带敏感或被禁内容，
      // 只有通过全部自检的条目才允许持久化正文。
      await _writeChanges(
        _buildChanges(
          today,
          state,
          input,
          items,
          existing,
          'pending',
          includeDetails: false,
        ),
      );
    } on Object catch (error) {
      return DreamOutcome(status: DreamStatus.writeFailed, detail: '$error');
    }

    final gateFailure = _validateDraft(
      items: items,
      draftContent: draftContent,
      validDates: input.validDates,
      validMonths: input.validMonths,
      banned: input.banned,
    );
    if (gateFailure != null) {
      await _writeChanges(
        _buildChanges(
          today,
          state,
          input,
          items,
          existing,
          'rejected ($gateFailure)',
          includeDetails: false,
        ),
      );
      await _deleteIfExists(_draftFile);
      return DreamOutcome(status: DreamStatus.validationFailed, detail: gateFailure);
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
      await _writeChanges(
        _buildChanges(
          today,
          state,
          input,
          items,
          existing,
          'accepted',
          includeDetails: true,
        ),
      );
      await _archiveChanges(today);
      await _deleteIfExists(_draftFile);
    } on Object catch (error) {
      return DreamOutcome(status: DreamStatus.writeFailed, detail: '$error');
    }
    return const DreamOutcome(status: DreamStatus.accepted);
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

  /// 组装 Dream 输入（全部只读）并执行上下文预算裁剪。
  Future<_DreamInput> _collectInput({required String? after}) async {
    final dates = await episodePipeline.listEpisodeDates();
    final summaries = <({String date, String summary})>[];
    for (final date in dates) {
      if (after != null && date.compareTo(after) <= 0) {
        continue;
      }
      final day = await episodePipeline.readDay(date);
      if (!day.readable || !day.finalized) {
        continue;
      }
      final summary = day.summary?.trim() ?? '';
      if (summary.isEmpty) {
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
        monthSummaries.insert(0, (month: month, contents: _renderMonthForModel(summary)));
      }
    }

    final relationship = await _readIfExists(
      File(path.join(memoryDirectory, 'relationship.md')),
    );
    final openLoops = await _readIfExists(
      File(path.join(memoryDirectory, 'open-loops.md')),
    );
    final longMemory = await _readIfExists(_longMemoryFile);
    final banned = openLoopStore == null
        ? const <String>{}
        : await openLoopStore!.bannedTitles();

    // 预算裁剪：关系与未闭环线索体量已有分块预算，先裁最旧月摘要，
    // 再裁最旧日摘要。
    var total = _inputRunes(windowed, monthSummaries, relationship, openLoops, longMemory);
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
      banned: banned,
      validDates: {for (final entry in windowed) entry.date},
      validMonths: {for (final entry in monthSummaries) entry.month},
    );
  }

  int _inputRunes(
    List<({String date, String summary})> summaries,
    List<({String month, String contents})> monthSummaries,
    String? relationship,
    String? openLoops,
    String? longMemory,
  ) {
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
    return total;
  }

  String _renderMonthForModel(MonthSummary summary) {
    final buffer = StringBuffer();
    if (summary.theme.isNotEmpty) {
      buffer.writeln('主题: ${summary.theme.join('、')}');
    }
    for (final item in summary.items) {
      buffer.writeln('- [${item.section}] ${item.date} ${item.text}');
    }
    return buffer.toString().trim();
  }

  /// 自检五关：任一不过返回失败原因码，整份草稿作废。
  String? _validateDraft({
    required List<DreamItem> items,
    required String draftContent,
    required Set<String> validDates,
    required Set<String> validMonths,
    required Set<String> banned,
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
    // 证据关：每条必须携带至少一个真实出处，且出处必须出自本轮递给
    // 模型的整理日期/月份，编造的一律整份作废。
    for (final item in items) {
      if (item.evidence.isEmpty) {
        return 'missing-evidence';
      }
      for (final ref in item.evidence) {
        final known = _dayPattern.hasMatch(ref)
            ? validDates.contains(ref)
            : _monthPattern.hasMatch(ref) && validMonths.contains(ref);
        if (!known) {
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
    // 用户控制关：不得改写或复活禁提内容。
    for (final item in items) {
      if (bannedTitleMatches(normalizeMemoryText(item.text), banned)) {
        return 'banned';
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
  /// [includeDetails] 只在接纳成功（全部五关通过）时为 true。被拒或
  /// 待定的草稿可能携带敏感、禁提内容，清单绝不能落盘其原文，只记
  /// 结果码与数量——否则等于把模型吐出的密钥写进记忆目录。
  String _buildChanges(
    String today,
    DreamState previousState,
    _DreamInput input,
    List<DreamItem> items,
    LongMemoryFile? existing,
    String result, {
    required bool includeDetails,
  }) {
    final rangeStart = previousState.lastSuccess == null
        ? '最初'
        : localSessionDate(previousState.lastSuccess!);
    final buffer = StringBuffer()
      ..writeln('# dream-changes')
      ..writeln()
      ..writeln('date: $today')
      ..writeln(
        'range: $rangeStart → $today'
        '（日摘要 ${input.summaries.length} 天，月摘要 ${input.monthSummaries.length} 月）',
      )
      ..writeln('result: $result')
      ..writeln('候选条目数: ${items.length}');
    if (!includeDetails) {
      return buffer.toString();
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

  Future<String?> _readIfExists(File file) async {
    if (!await file.exists()) {
      return null;
    }
    try {
      return await file.readAsString(encoding: utf8);
    } on Object {
      return null;
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
    const system = '''
你是栖语离线记忆的深度重组模块（Dream）。给你用户已整理的记忆与当前长期印象，请产出新长期印象的候选版。要求：
1. 只输出一个 JSON 对象，不要输出任何其它文字、解释或代码块标记。
2. 每条印象必须有给定材料中的依据，不得编造、不得引入材料外的事实。
3. 只保留高压缩的生活倾向、持续关注和关系变化：用户现实里的重要的人、值得长期记住的人生事件、经历过的变化与反复出现的主题、双方共同形成的经历；不写产品机制、逐日流水账、一次性任务细节、原话细节或证据链。
4. 每条是一行压缩印象，不超过60字，可以带时间词。
5. 以当前长期印象为基础保守重组：同义的合并，仍有依据的保留，被更新证据推翻的改写；拿不准就不写。
6. 绝不出现密码、密钥、证件号、银行卡号等敏感内容；绝不触碰禁提清单中的话题。
字段白名单：
- items: 数组，最多24项，每项 {"section": 人与关系、重要事件、模式与轨迹、共同过往 之一, "text": 一行压缩印象，不超过60字, "evidence": 日期数组，每项形如 YYYY-MM-DD，必须取自递来的已整理记录日期，绝不编造}。''';

    final user = StringBuffer()
      ..writeln('## 当前长期印象')
      ..writeln(_sectionOrEmpty(input.longMemory))
      ..writeln()
      ..writeln('## 已整理记录（finalized 摘要）');
    if (input.summaries.isEmpty) {
      user.writeln('（无）');
    } else {
      for (final entry in input.summaries) {
        user.writeln('- ${entry.date}: ${entry.summary}');
      }
    }
    user
      ..writeln()
      ..writeln('## 月摘要');
    if (input.monthSummaries.isEmpty) {
      user.writeln('（无）');
    } else {
      for (final entry in input.monthSummaries) {
        user
          ..writeln('### ${entry.month}')
          ..writeln(entry.contents);
      }
    }
    user
      ..writeln()
      ..writeln('## 关系状态')
      ..writeln(_sectionOrEmpty(input.relationship))
      ..writeln()
      ..writeln('## 未闭环线索')
      ..writeln(_sectionOrEmpty(input.openLoops))
      ..writeln()
      ..writeln('## 禁提清单（以下话题绝不出现）');
    if (input.banned.isEmpty) {
      user.writeln('（无）');
    } else {
      for (final title in input.banned) {
        user.writeln('- $title');
      }
    }
    return [
      const ModelMessage(ModelMessageRole.system, system),
      ModelMessage(ModelMessageRole.user, redactSessionText(user.toString())),
    ];
  }
}

/// Dream 一次运行的输入快照。
final class _DreamInput {
  const _DreamInput({
    required this.summaries,
    required this.monthSummaries,
    required this.relationship,
    required this.openLoops,
    required this.longMemory,
    required this.banned,
    required this.validDates,
    required this.validMonths,
  });

  final List<({String date, String summary})> summaries;
  final List<({String month, String contents})> monthSummaries;
  final String? relationship;
  final String? openLoops;
  final String? longMemory;
  final Set<String> banned;

  /// 本轮实际递给模型的整理日期与月份：证据关的白名单。
  final Set<String> validDates;
  final Set<String> validMonths;
}

String _sectionOrEmpty(String? contents) {
  final trimmed = contents?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return '（无）';
  }
  return trimmed;
}

String _encodeState(DreamState state) {
  final json = <String, Object?>{
    'schemaVersion': 1,
    if (state.lastSuccess != null)
      'lastSuccess': state.lastSuccess!.toUtc().toIso8601String(),
    'pending': state.pending,
  };
  return '# dream-state\n\n<!-- qiyu-dream-state:${_encodeJson(json)} -->\n';
}

DreamState? _decodeState(String contents) {
  final match = RegExp(
    r'^<!-- qiyu-dream-state:([A-Za-z0-9_-]+) -->\r?$',
    multiLine: true,
  ).firstMatch(contents);
  if (match == null) {
    return null;
  }
  try {
    final json = _decodeJson(match.group(1)!);
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

String _encodeJson(Map<String, Object?> value) =>
    base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

Map<String, Object?> _decodeJson(String value) {
  final padded = value.padRight(value.length + (4 - value.length % 4) % 4, '=');
  return jsonDecode(utf8.decode(base64Url.decode(padded)))
      as Map<String, Object?>;
}

/// 两个 YYYY-MM-DD 日期之间的日历日差（later - earlier）。
int _daysBetween(String earlier, String later) {
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

/// 从模型输出中提取 JSON 对象：容忍代码块围栏与前后多余文字，只取
/// 第一个 `{` 到最后一个 `}` 之间的内容。
Map<String, Object?>? _extractJsonObject(String raw) {
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) {
    return null;
  }
  try {
    final decoded = jsonDecode(raw.substring(start, end + 1));
    return decoded is Map<String, Object?> ? decoded : null;
  } on Object {
    return null;
  }
}
