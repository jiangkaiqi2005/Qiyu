import 'dart:async';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'episode_index.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_text_primitives.dart';
import 'model_gateway.dart';
import 'open_loop_store.dart';
import 'persona_tree.dart';
import 'provider_settings_service.dart';

/// bubble 2 轮内窗口预算（节奏定稿：秒级常量）。窗口内命中且用户
/// 没有停止/新消息时主动补第二条气泡；没赶上就把压缩结果并入下一
/// 用户轮注入，绝不阻塞首响。
const recallBubbleWindow = Duration(seconds: 8);

/// 选择调用随顶层索引一并递回的近期每日索引月数。
const recallRecentMonthCount = 3;

/// 递回日原文里单条摘要/原话摘录的裁剪预算（runes）：回读的是原始
/// 证据，但仍按压缩预算递送，不搬运整段长文。
const recallRawSummaryMaxRunes = 120;
const recallRawEvidenceMaxRunes = 160;

/// 并入下一用户轮的压缩整理记录用更紧的摘录预算（临时透镜只留线索）。
const recallPendingEvidenceMaxRunes = 100;

/// 画像树路径检索的单次预算（runes）：Memory 注入定稿「单次最多 2 条
/// 相关路径、总计不超过 600 tokens」，按仓库 rune 口径保守计
/// （1 rune ≈ 1 token，与 persona.md 投影同一口径）。超出预算的路径
/// 整条放弃并记诊断——宁少勿超。
const recallPersonaPathMaxRunes = 600;

/// 画像路径里单条主张（根主张 / 中间理解 / 叶摘要）的裁剪预算
/// （runes）：与递回日原文的摘要预算同口径，防手改树文件写出超长
/// 主张顶爆路径预算。
const recallPersonaClaimMaxRunes = 120;

/// 下一轮临时 memory_context 的条目记录总量预算（runes）：条目级相关性
/// 筛选后仍可能命中多日多条目，压缩记录必须整体有界。取画像路径预算
/// 的两倍：单条目摘要 120 + 摘录 100 runes，覆盖常见多日命中，连同
/// 路径素材仍稳在一块热层预算（3000 tokens）以内。
const recallPendingContextMaxRunes = 1200;

/// 选择/组织调用的输出预算：同属理解类调用，必须显式给足预算——
/// 缺省会吃聊天护栏 512，材料变大后输出截断即整轮召回失败。
const recallModelMaxOutputTokens = 16384;

/// 轮内查找选择调用里「没有相关记录」的哨兵输出：模型宁可说没有，
/// 也不得牵强组织 bubble 2。
const _recallNoBubbleSentinel = '没有了';

/// 一次轮内召回查找的结果。诊断只进本机 stderr，绝不展示给用户。
final class RecallTurnResult {
  const RecallTurnResult({
    this.bubbleText,
    this.pendingContext,
    this.diagnostics = const [],
  });

  /// 模型组织好的 bubble 2 候选文本（尚未经行为核心安全校验）；
  /// 明确拒绝、未完成判断或未命中为 null。
  final String? bubbleText;

  /// 命中证据的压缩整理记录：bubble 2 没赶上交付或判断未完成时并入
  /// 下一用户轮注入；明确拒绝（不建立下一轮候选）或没有可注入内容时
  /// 为 null。
  final String? pendingContext;

  final List<String> diagnostics;
}

/// 组织调用的三态判断（票 01）：明确使用、明确拒绝与未完成判断必须
/// 分开——明确拒绝不补气泡也不建立下一轮候选，未完成判断不冒充拒绝，
/// 明确使用按有效回执收窄下一轮材料。
sealed class _ComposeOutcome {
  const _ComposeOutcome();
}

/// 模型组出了候选气泡（明确使用）。[entryIds] 是回执里的所用条目 ID；
/// null 表示没给回执，有效性由调用方按本轮递送材料成员校验。
final class _ComposeUsed extends _ComposeOutcome {
  const _ComposeUsed(this.text, this.entryIds);

  final String text;
  final List<String>? entryIds;
}

/// 模型明确表态查到的记录与用户问的不是一回事（哨兵输出）：不组气泡。
final class _ComposeRejected extends _ComposeOutcome {
  const _ComposeRejected();
}

/// 调用异常、Provider 失败或输出不可解析（既没有可见句也没有哨兵）：
/// 判断没有完成，材料保持候选身份。
final class _ComposeUnjudged extends _ComposeOutcome {
  const _ComposeUnjudged();
}

/// 一次定位结果的形状（轮内召回与实时查找共用）：选中日原始证据与
/// 画像路径素材。
typedef _LocatedEvidence =
    ({List<(String, List<EpisodeEntry>)> rawDays, String personaPathText});

/// 画像树路径检索目录：按分支线名分组的活跃根（已受控过滤）。索引
/// 文本（递给选择调用）与路径展开（查 ID）共用同一份数据；归档不出
/// 现在快照里——archive/ 永不进入普通聊天检索。
final class _PersonaCatalog {
  _PersonaCatalog(this.byBranch);

  final Map<String, List<PersonaRoot>> byBranch;
}

/// 召回模型查找轮内循环（Memory.md 查找流程定稿 2026-08-16）。
///
/// 查找者是模型，不打分、无规则兜底、不常驻挂载索引：
/// 1. 聊天轮模型在隐藏块里发出 memory_recall{query}（常驻字段没命中
///    且用户问旧事才发）；
/// 2. Host 读取顶层索引 + 近期每月每日索引递回（罕见路径：模型先指到
///    老月时，Host 补读该月每日索引再递一次）；
/// 3. 模型选月份/日期，代码做成员校验——选取必须出自递过的目录，
///    编造的丢弃并记诊断；
/// 4. Host 回读选中日文件的原始证据递回，模型组织 bubble 2。
///
/// 画像树路径检索（Memory 注入定稿，与选日同一调用）：需要解释习惯、
/// 核对画像依据或追溯具体事件时，选择调用随月份/日期顺带选最多 2 条
/// 「根 → 中间理解 → 叶指针」路径（默认只取根与最相关中间理解，问题
/// 需要依据或事件细节时每条路径再带至多 2 条叶指针），Host 展开后与
/// 原始日证据一并供组织调用组句，并并入下一轮临时 memory_context；
/// 不涉及具体日期的纯画像依据问题可以只选路径（跳过 episode 回读），
/// 日期命中但证据不可用时路径素材仍可组句。persona-tree/archive/ 永不
/// 进入普通聊天检索，冻结/禁提/删除范围同样不进索引与展开。
///
/// 两级索引只负责定位：索引关键词永远不是事实来源，命中必须回到
/// 索引指向的 daily episode 原始证据（硬规则定稿）。索引缺失或损坏
/// 时先从原始 episode 重建再继续。找到而 bubble 2 没赶上交付时，压缩
/// 结果存入按会话保存的短期 memory context，下一轮装配取用一次后
/// 即失效（临时透镜，不落盘、不进状态包）；总量受预算封顶，不搬运
/// 选中文件全文。组织调用的结果三态分开（票 01）：明确使用只收有效
/// 回执条目（回执缺失、为空或全不可信不扩成全量候选）；明确拒绝
/// （哨兵）本轮不补气泡、下一轮也不留候选；调用异常或输出不可解析
/// 属于未完成判断，材料按既有规则留给下一轮，不冒充拒绝。
///
/// 未配置 Provider 不召回（保持现状）；任何失败都降级为无结果，
/// 检索失败不纠缠，话题再来再查。
final class RecallOrchestrator {
  RecallOrchestrator({
    required this.memoryDirectory,
    required EpisodeMemoryPipeline episodePipeline,
    this.modelClient,
    EpisodeIndexStore? indexStore,
    this.openLoopStore,
    this.personaTree,
  }) : _episodePipeline = episodePipeline,
       _indexStore =
           indexStore ??
           EpisodeIndexStore(
             memoryDirectory: memoryDirectory,
             episodePipeline: episodePipeline,
           );

  final String memoryDirectory;
  final EpisodeMemoryPipeline _episodePipeline;

  /// 选择/组织两次小调用使用的模型客户端；未配置（null）时整个
  /// 轮内循环静默跳过。
  final ProviderChatClient? modelClient;
  final EpisodeIndexStore _indexStore;
  final OpenLoopStore? openLoopStore;

  /// 画像树只读来源（Memory 注入定稿的路径检索）：null 时不做路径
  /// 检索，episode 检索链路照常工作——路径是增强不是门槛。
  final PersonaTreeStore? personaTree;

  final Map<String, String> _pendingContexts = {};

  EpisodeIndexStore get indexStore => _indexStore;

  /// 取用并清空该会话的短期 memory context（一次性临时透镜）。
  /// 没有待注入内容时返回 null。
  String? consumePendingContext(String sessionId) =>
      _pendingContexts.remove(sessionId);

  /// 本轮模型调用没有成功消费时放回短期 memory context，留给下一轮；
  /// 已有更新的结果（新的检索命中）时不覆盖。
  void restorePendingContext(String sessionId, String context) {
    if (context.trim().isEmpty) {
      return;
    }
    _pendingContexts.putIfAbsent(sessionId, () => context);
  }

  /// 存入一次命中的压缩结果（新结果覆盖旧结果：旧的还没被注入说明
  /// 话题已经过去，最新的才值得下一轮带出）。
  void storePendingContext(String sessionId, String context) {
    if (context.trim().isEmpty) {
      return;
    }
    _pendingContexts[sessionId] = context;
  }

  /// 执行一次轮内查找。绝不抛出：任何异常都降级为无结果并记诊断。
  Future<RecallTurnResult> runTurnRecall({
    required String userText,
    required List<HiddenAction> recallActions,
  }) async {
    final diagnostics = <String>[];
    try {
      return await _runTurnRecallInner(userText, recallActions, diagnostics);
    } on Object catch (error) {
      // 诊断只收进结果，由调用方统一落 sink，避免同一错误重复打印。
      diagnostics.add('recall deferred [$error]');
      return RecallTurnResult(diagnostics: diagnostics);
    }
  }

  /// 实时会话的后台查找（T03）：与轮内召回同一套两级索引、受控过滤与
  /// 压缩预算定位证据，但不组气泡——命中证据压缩成临时上下文后由调用
  /// 方回填给实时会话的 memory_recall 工具，是否补充、怎么说由会话内
  /// 模型结合最新话题决定（spec:54，选择小调用仍走选中 Provider，不换
  /// 模型）。绝不抛出：任何异常都降级为无结果并记诊断。
  Future<({String? context, List<String> diagnostics})> lookupForRealtime({
    required String query,
    required String userText,
  }) async {
    final diagnostics = <String>[];
    try {
      if (modelClient == null) {
        diagnostics.add('recall skipped reason=no-provider');
        return (context: null, diagnostics: diagnostics);
      }
      final cleanQuery = sanitizeUserInput(query).trim();
      if (cleanQuery.isEmpty) {
        diagnostics.add('recall skipped reason=empty-query');
        return (context: null, diagnostics: diagnostics);
      }
      final located = await _locateEvidence(
        query: cleanQuery,
        userText: userText,
        diagnostics: diagnostics,
      );
      if (located == null) {
        return (context: null, diagnostics: diagnostics);
      }
      return (
        context: _buildPendingContext(
          located.rawDays,
          null,
          located.personaPathText,
          diagnostics,
        ),
        diagnostics: diagnostics,
      );
    } on Object catch (error) {
      diagnostics.add('recall deferred [$error]');
      return (context: null, diagnostics: diagnostics);
    }
  }

  Future<RecallTurnResult> _runTurnRecallInner(
    String userText,
    List<HiddenAction> recallActions,
    List<String> diagnostics,
  ) async {
    final client = modelClient;
    if (client == null) {
      diagnostics.add('recall skipped reason=no-provider');
      return RecallTurnResult(diagnostics: diagnostics);
    }
    final query = sanitizeUserInput(
      recallActions
              .whereType<MemoryRecallAction>()
              .map((action) => action.query)
              .where((value) => value.trim().isNotEmpty)
              .firstOrNull ??
          '',
    ).trim();
    if (query.isEmpty) {
      diagnostics.add('recall skipped reason=empty-query');
      return RecallTurnResult(diagnostics: diagnostics);
    }
    final located = await _locateEvidence(
      query: query,
      userText: userText,
      diagnostics: diagnostics,
    );
    if (located == null) {
      return RecallTurnResult(diagnostics: diagnostics);
    }

    // 调用3：模型基于原始证据与画像路径组织 bubble 2，并回执所用条目。
    // 结果三态分开（票 01）：明确拒绝不补气泡也不建下一轮 pending；
    // 未完成判断（调用异常、Provider 失败或输出不可解析）保持候选
    // 身份，按既有规则留给下一轮；明确使用按有效回执收窄。
    final compose = await _composeBubble(
      client,
      query: query,
      userText: userText,
      rawDays: located.rawDays,
      personaPathText: located.personaPathText,
      diagnostics: diagnostics,
    );
    return switch (compose) {
      // 明确拒绝：候选本轮与下一轮都不再出现，不写任何记忆。
      _ComposeRejected() => RecallTurnResult(diagnostics: diagnostics),
      // 未完成判断：材料按既有规则整体并入下一轮（受总量预算封顶）。
      _ComposeUnjudged() => RecallTurnResult(
        pendingContext: _buildPendingContext(
          located.rawDays,
          null,
          located.personaPathText,
          diagnostics,
        ),
        diagnostics: diagnostics,
      ),
      _ComposeUsed(:final text, :final entryIds) => _usedTurnResult(
        text,
        entryIds,
        located,
        diagnostics,
      ),
    };
  }

  /// 明确使用的结果：只收回执采信的条目（票 01）。回执缺失、为空或
  /// 全部不可信时不把候选扩成全量——没有可注入条目也没有路径素材时
  /// 下一轮不留任何临时上下文。
  RecallTurnResult _usedTurnResult(
    String text,
    List<String>? entryIds,
    _LocatedEvidence located,
    List<String> diagnostics,
  ) {
    final usedEntries = _validatedEntries(
      entryIds,
      located.rawDays,
      diagnostics,
    );
    if (usedEntries == null && located.personaPathText.isEmpty) {
      return RecallTurnResult(bubbleText: text, diagnostics: diagnostics);
    }
    return RecallTurnResult(
      bubbleText: text,
      pendingContext: _buildPendingContext(
        located.rawDays,
        // 回执不可采信时收窄为空集：只带路径素材，不搬运全部候选。
        usedEntries ?? const [],
        located.personaPathText,
        diagnostics,
      ),
      diagnostics: diagnostics,
    );
  }

  /// 定位阶段（轮内召回与实时查找共用）：受控集合 → 两级索引（缺失
  /// 重建）→ 模型选择月份/日期与画像路径（成员校验）→ 回读选中日原始
  /// 证据。没有可回读证据与路径素材时返回 null（miss 诊断已记）。
  Future<_LocatedEvidence?> _locateEvidence({
    required String query,
    required String userText,
    required List<String> diagnostics,
  }) async {
    final client = modelClient;
    if (client == null) {
      diagnostics.add('recall skipped reason=no-provider');
      return null;
    }
    // 记忆控制过滤贯穿全部递给模型的材料：索引关键词、回读证据与
    // 压缩注入。封禁（禁提 ∪ 删除）与冻结都不得被检索。
    final banned = await _blockedTitles();

    // 画像树路径检索素材（Memory 注入定稿）：快照只取活跃根与根下
    // 中间理解，归档永不进入普通聊天检索；受控过滤与 episode 链路
    // 同一集合。未注入树（或分支不可读）时路径检索静默跳过。
    final personaCatalog = await _readPersonaCatalog(banned, diagnostics);
    final personaIndex = personaCatalog == null
        ? ''
        : _renderPersonaIndex(personaCatalog);

    var topIndex = await _indexStore.readTopIndex();
    if (topIndex == null) {
      // 索引缺失或损坏：先从原始 episode 重建，再继续查找。
      // 重建写索引文件，必须在 episode 日文件写锁内执行。
      await _episodePipeline.synchronizedOnDayFiles(
        () => _indexStore.rebuild(includeUnfinalized: true),
      );
      diagnostics.add('recall index rebuilt reason=missing-or-corrupt');
      topIndex = await _indexStore.readTopIndex();
      if (topIndex == null) {
        diagnostics.add('recall miss reason=no-episodes');
        return null;
      }
    }
    topIndex = _filterBannedMonthLines(topIndex, banned, diagnostics);
    if (topIndex.isEmpty) {
      diagnostics.add('recall miss reason=no-visible-months');
      return null;
    }

    // 递回目录：顶层索引全部月份 + 近期月份的每日索引。
    final topMonths = topIndex.map((line) => line.month).toSet();
    final dayIndexByMonth = <String, List<DayIndexLine>>{};
    final recentMonths = (topIndex.map((line) => line.month).toList()..sort())
        .reversed
        .take(recallRecentMonthCount)
        .toList()
        .reversed;
    for (final month in recentMonths) {
      final dayLines = await _readMonthIndexWithRepair(
        month,
        banned,
        diagnostics,
      );
      if (dayLines != null) {
        dayIndexByMonth[month] = dayLines;
      }
    }
    final passedDates = _datesOf(dayIndexByMonth);

    // 调用2：模型在递过的目录里选择月份/日期，顺带选画像树路径。
    var selection = await _select(
      client,
      query: query,
      userText: userText,
      topIndex: topIndex,
      dayIndexByMonth: dayIndexByMonth,
      personaIndex: personaIndex,
      diagnostics: diagnostics,
    );
    var dates = _memberSelections(
      'date',
      selection?.dates,
      passedDates,
      diagnostics,
    );
    if (dates.isEmpty) {
      final months = _memberSelections(
        'month',
        selection?.months,
        topMonths,
        diagnostics,
      );
      if (months.isNotEmpty) {
        // 罕见路径：模型先指到月份（通常是没有递过每日索引的老月）。
        // Host 补读这些月的每日索引再递一次，重新选择；没有补到
        // 任何新目录时不再重复同样的选择调用。
        var supplemented = false;
        for (final month in months) {
          if (dayIndexByMonth.containsKey(month)) {
            continue;
          }
          final dayLines = await _readMonthIndexWithRepair(
            month,
            banned,
            diagnostics,
          );
          if (dayLines != null) {
            dayIndexByMonth[month] = dayLines;
            supplemented = true;
            diagnostics.add('recall month index supplemented month=$month');
          }
        }
        if (supplemented) {
          selection = await _select(
            client,
            query: query,
            userText: userText,
            topIndex: topIndex,
            dayIndexByMonth: dayIndexByMonth,
            personaIndex: personaIndex,
            diagnostics: diagnostics,
          );
          dates = _memberSelections(
            'date',
            selection?.dates,
            _datesOf(dayIndexByMonth),
            diagnostics,
          );
        }
      }
    }
    // 画像树路径展开（Memory 注入定稿）：选中路径展开为「根主张 +
    // 中间理解 + 至多 2 条叶指针」，受控过滤后的目录里做成员校验，
    // 总量受 recallPersonaPathMaxRunes 约束。先于日期证据判定——定稿
    // 的检索场景前两种（解释习惯、核对画像依据）不一定涉及具体日期，
    // 纯画像依据的问题可以只选路径不选日期。
    final personaPathText = _expandPersonaPaths(
      selection?.paths,
      personaCatalog,
      diagnostics,
    );
    if (dates.isEmpty && personaPathText.isEmpty) {
      diagnostics.add('recall miss reason=no-date-selection');
      return null;
    }

    // 索引只负责定位：回读选中日文件的原始证据。跨月跨年检索不设
    // 日期数量上限（定稿）；只按压缩预算裁剪单条内容，不搬运全文。
    // 没有选日期（纯画像依据）时跳过回读，路径素材自含依据。
    final rawDays = <(String, List<EpisodeEntry>)>[];
    for (final date in dates) {
      final day = await _episodePipeline.readDay(date);
      if (!day.readable) {
        diagnostics.add('recall day skipped reason=$date-unreadable');
        continue;
      }
      final entries = <EpisodeEntry>[];
      for (final entry in validEpisodeEntries(day.entries)) {
        if (bannedMemoryText(entry.summary, banned)) {
          diagnostics.add('recall entry skipped reason=blocked date=$date');
          continue;
        }
        final evidence = entry.evidence;
        if (evidence != null && bannedMemoryText(evidence, banned)) {
          // 摘要未命中但原话摘录命中受控范围：丢掉摘录，保留摘要。
          diagnostics.add('recall evidence dropped reason=blocked date=$date');
          entries.add(
            EpisodeEntry(
              id: entry.id,
              sessionId: entry.sessionId,
              requestId: entry.requestId,
              summary: entry.summary,
              at: entry.at,
              kind: entry.kind,
              signal: entry.signal,
            ),
          );
          continue;
        }
        entries.add(entry);
      }
      if (entries.isEmpty) {
        diagnostics.add('recall day skipped reason=$date-no-evidence');
        continue;
      }
      // 旧规则时代落盘的条目可能残留秘密：回读证据递给模型（组织
      // 调用与压缩注入）前按会话脱敏规则过滤自由文本，只动文本
      // 内容，不碰条目结构与索引语义。
      rawDays.add((date, entries.map((entry) => entry.redactedForModel()).toList()));
    }
    if (rawDays.isEmpty && personaPathText.isEmpty) {
      diagnostics.add('recall miss reason=no-evidence');
      return null;
    }
    if (dates.isNotEmpty && rawDays.isEmpty) {
      // 日期命中但证据不可读或全被封禁：画像路径素材自含依据，仍可组句。
      diagnostics.add('recall episode evidence skipped reason=no-evidence');
    }
    return (rawDays: rawDays, personaPathText: personaPathText);
  }

  /// 读取某月每日索引；缺失或损坏时整体重建（幂等）再读，仍不可读
  /// 返回 null 并记诊断。读出后按受控范围过滤关键词（见
  /// [_filterBannedDayLines]）。
  Future<List<DayIndexLine>?> _readMonthIndexWithRepair(
    String month,
    Set<String> banned,
    List<String> diagnostics,
  ) async {
    var dayLines = await _indexStore.readMonthIndex(month);
    if (dayLines == null) {
      await _episodePipeline.synchronizedOnDayFiles(
        () => _indexStore.rebuild(includeUnfinalized: true),
      );
      diagnostics.add('recall index rebuilt reason=month-index-unreadable');
      dayLines = await _indexStore.readMonthIndex(month);
    }
    if (dayLines == null) {
      diagnostics.add('recall month skipped reason=$month-unreadable');
      return null;
    }
    return _filterBannedDayLines(dayLines, banned, diagnostics);
  }

  /// 顶层索引行禁提过滤：逐行剥掉命中禁提的关键词；剥空后整行隐藏，
  /// 不让模型看到该月份的存在。索引只负责定位，禁提内容绝不递出。
  List<MonthIndexLine> _filterBannedMonthLines(
    List<MonthIndexLine> lines,
    Set<String> banned,
    List<String> diagnostics,
  ) {
    if (banned.isEmpty) {
      return lines;
    }
    final kept = <MonthIndexLine>[];
    for (final line in lines) {
      final keywords = _filterBannedKeywords(line.keywords, banned);
      if (keywords.isEmpty) {
        diagnostics.add('recall index line hidden reason=blocked');
        continue;
      }
      kept.add(MonthIndexLine(month: line.month, keywords: keywords));
    }
    return kept;
  }

  /// 每日索引行禁提过滤：同 [_filterBannedMonthLines]。
  List<DayIndexLine> _filterBannedDayLines(
    List<DayIndexLine> lines,
    Set<String> banned,
    List<String> diagnostics,
  ) {
    if (banned.isEmpty) {
      return lines;
    }
    final kept = <DayIndexLine>[];
    for (final line in lines) {
      final keywords = _filterBannedKeywords(line.keywords, banned);
      if (keywords.isEmpty) {
        diagnostics.add('recall index line hidden reason=blocked');
        continue;
      }
      kept.add(DayIndexLine(date: line.date, keywords: keywords));
    }
    return kept;
  }

  List<String> _filterBannedKeywords(
    List<String> keywords,
    Set<String> banned,
  ) {
    // 全受控行仍按原词项隐藏，不能因脱敏抹掉禁提词而重新可见。
    if (keywords.every((keyword) => bannedMemoryText(keyword, banned))) {
      return const [];
    }
    // 在剔除词项前保留完整凭据上下文，避免只剩失去键名的秘密尾部。
    return _redactedIndexKeywords(keywords)
        .split(', ')
        .where((keyword) => !bannedMemoryText(keyword, banned))
        .toList();
  }

  Set<String> _datesOf(Map<String, List<DayIndexLine>> dayIndexByMonth) {
    final dates = <String>{};
    for (final lines in dayIndexByMonth.values) {
      for (final line in lines) {
        dates.add(line.date);
      }
    }
    return dates;
  }

  /// 成员校验：模型选取的月份/日期必须出自递过的索引目录，编造的
  /// 丢弃并记诊断；[kind] 是诊断串里的字段名（month/date）。
  List<String> _memberSelections(
    String kind,
    List<String>? selections,
    Set<String> passed,
    List<String> diagnostics,
  ) {
    final kept = <String>[];
    for (final value in selections ?? const <String>[]) {
      if (passed.contains(value)) {
        kept.add(value);
      } else {
        diagnostics.add(
          'recall selection dropped $kind=$value reason=not-in-passed-index',
        );
      }
    }
    return kept;
  }

  /// 检索的受控集合：冻结同样停止检索（并集定义见
  /// [OpenLoopStore.controlledTitles]）。
  Future<Set<String>> _blockedTitles() async =>
      (await openLoopStore?.controlledTitles()) ?? const {};

  /// 读取画像树只读目录：活跃根 + 根下中间理解（含叶），受控过滤
  /// （禁提/删除/冻结，与 episode 链路同一集合）在读取时一次完成，
  /// 索引与展开都不会再看到受控节点。未归根中间理解不构成「根 →
  /// 中间理解」路径，不进目录。未注入树返回 null；分支不可读只记
  /// 诊断并跳过该分支，episode 检索链路不受影响。
  Future<_PersonaCatalog?> _readPersonaCatalog(
    Set<String> banned,
    List<String> diagnostics,
  ) async {
    final tree = personaTree;
    if (tree == null) {
      return null;
    }
    final snapshot = await tree.readSnapshot();
    final byBranch = <String, List<PersonaRoot>>{};
    for (final branch in personaBranches) {
      final view = snapshot.branches[branch.wireName];
      if (view == null || !view.readable) {
        diagnostics.add(
          'recall persona skipped reason=${branch.wireName}-unreadable',
        );
        continue;
      }
      final roots = <PersonaRoot>[];
      for (final root in view.roots) {
        if (bannedMemoryText(root.claim, banned)) {
          diagnostics.add(
            'recall persona node dropped reason=blocked root=${root.id}',
          );
          continue;
        }
        final middles = <PersonaMiddle>[];
        for (final middle in root.middles) {
          if (bannedMemoryText(middle.claim, banned)) {
            diagnostics.add(
              'recall persona node dropped reason=blocked middle=${middle.id}',
            );
            continue;
          }
          middles.add(
            PersonaMiddle(
              id: middle.id,
              type: middle.type,
              claim: middle.claim,
              formedOn: middle.formedOn,
              reviewedOn: middle.reviewedOn,
              leaves: middle.leaves
                  .where((leaf) => !bannedMemoryText(leaf.summary, banned))
                  .toList(),
            ),
          );
        }
        if (middles.isEmpty) {
          // 没有可走中间理解的根给不出路径，不进索引。
          continue;
        }
        roots.add(
          PersonaRoot(id: root.id, claim: root.claim, middles: middles),
        );
      }
      if (roots.isNotEmpty) {
        byBranch[branch.wireName] = roots;
      }
    }
    return _PersonaCatalog(byBranch);
  }

  /// 递回选择调用的紧凑画像索引：活跃根 + 根下中间理解主张 + 叶 ID
  /// （带日期与来源性质，供模型在需要依据或事件细节时选叶）。不含
  /// 归档、不含叶摘要，控制过滤已在目录构建时完成。
  String _renderPersonaIndex(_PersonaCatalog catalog) {
    final buffer = StringBuffer();
    for (final branch in personaBranches) {
      final roots = catalog.byBranch[branch.wireName];
      if (roots == null) {
        continue;
      }
      buffer.writeln('### ${branch.title}（${branch.wireName}）');
      for (final root in roots) {
        buffer.writeln(
          '- 根 [${root.id}] '
          '${clipRunes(root.claim.trim(), recallPersonaClaimMaxRunes)}',
        );
        for (final middle in root.middles) {
          buffer.write(
            '  - 中间理解 [${middle.id}] ${middle.type}｜'
            '${clipRunes(middle.claim.trim(), recallPersonaClaimMaxRunes)}',
          );
          if (middle.leaves.isNotEmpty) {
            final leaves = middle.leaves
                .map((leaf) => '${leaf.id} ${leaf.date} ${leaf.nature}')
                .join(', ');
            buffer.write('（叶: $leaves）');
          }
          buffer.writeln();
        }
      }
    }
    return buffer.toString().trim();
  }

  /// 展开选中的画像树路径：每条 = 根主张 + 中间理解 + 至多 2 条叶指针
  /// （叶由模型在需要依据或事件细节时选）。ID 必须出自受控过滤后的
  /// 目录，编造的丢弃并记诊断（与月份/日期同一成员校验口径）。总量
  /// 受 [recallPersonaPathMaxRunes] 约束，超预算的路径整条放弃。无
  /// 命中时返回空串。
  String _expandPersonaPaths(
    List<String>? selections,
    _PersonaCatalog? catalog,
    List<String> diagnostics,
  ) {
    if (selections == null || catalog == null || selections.isEmpty) {
      return '';
    }
    final blocks = <String>[];
    var usedRunes = 0;
    for (final selection in selections) {
      final segments = selection.split('/');
      final rootId = segments[0];
      final middleId = segments[1];
      final root = catalog.byBranch.values
          .expand((roots) => roots)
          .where((candidate) => candidate.id == rootId)
          .firstOrNull;
      final middle = root?.middles
          .where((candidate) => candidate.id == middleId)
          .firstOrNull;
      if (root == null || middle == null) {
        diagnostics.add(
          'recall selection dropped path=$selection reason=not-in-passed-index',
        );
        continue;
      }
      final leaves = <PersonaLeaf>[];
      for (final leafId in segments.length > 2
          ? segments[2].split(',')
          : const <String>[]) {
        final leaf = middle.leaves
            .where((candidate) => candidate.id == leafId)
            .firstOrNull;
        if (leaf == null) {
          diagnostics.add(
            'recall selection dropped path=$selection leaf=$leafId '
            'reason=not-in-passed-index',
          );
          continue;
        }
        leaves.add(leaf);
      }
      final block = _renderPersonaPath(root, middle, leaves);
      if (usedRunes + block.runes.length > recallPersonaPathMaxRunes) {
        diagnostics.add(
          'recall persona path dropped root=$rootId reason=over-budget',
        );
        continue;
      }
      usedRunes += block.runes.length;
      blocks.add(block);
    }
    return blocks.join('\n');
  }

  /// 单条画像路径的渲染（组织调用输入与下一轮临时上下文共用）。
  String _renderPersonaPath(
    PersonaRoot root,
    PersonaMiddle middle,
    List<PersonaLeaf> leaves,
  ) {
    final buffer = StringBuffer()
      ..writeln(
        '- 根 [${root.id}] '
        '${clipRunes(root.claim.trim(), recallPersonaClaimMaxRunes)}',
      )
      ..writeln(
        '  - 中间理解 [${middle.id}] ${middle.type}｜'
        '${clipRunes(middle.claim.trim(), recallPersonaClaimMaxRunes)}',
      );
    for (final leaf in leaves) {
      buffer.writeln(
        '    - 叶 [${leaf.id}] ${leaf.date} ${leaf.nature}：'
        '${clipRunes(leaf.summary.trim(), recallPersonaClaimMaxRunes)}',
      );
    }
    return buffer.toString().trimRight();
  }

  /// 组织回执的所用条目 ID 成员校验：只能取自本轮递过的原始条目，
  /// 编造的丢弃并记诊断。没有可采信回执（没给回执、回执为空或全部
  /// 编造）时返回 null——幻觉回执不构成相关性信号，明确使用路径
  /// 不把候选扩成全量（票 01）；只有未完成判断（调用失败、输出不可
  /// 解析）才按既有规则保留全量材料。
  List<String>? _validatedEntries(
    List<String>? declared,
    List<(String, List<EpisodeEntry>)> rawDays,
    List<String> diagnostics,
  ) {
    if (declared == null) {
      return null;
    }
    final known = <String>{
      for (final (_, entries) in rawDays)
        for (final entry in entries) entry.id,
    };
    final kept = <String>[];
    for (final id in declared) {
      if (known.contains(id)) {
        kept.add(id);
      } else {
        diagnostics.add(
          'recall entry dropped id=$id reason=not-in-passed-evidence',
        );
      }
    }
    return kept.isEmpty ? null : kept;
  }

  /// 选择调用：把查找意图与递回的目录交给模型，收回 memory_recall
  /// 选择（月份/日期 + 画像树路径）。模型输出无法解析或没有给出动作
  /// 时返回 null（没有头绪）。
  Future<MemoryRecallAction?> _select(
    ProviderChatClient client, {
    required String query,
    required String userText,
    required List<MonthIndexLine> topIndex,
    required Map<String, List<DayIndexLine>> dayIndexByMonth,
    required String personaIndex,
    required List<String> diagnostics,
  }) async {
    ModelCompletion? completion;
    try {
      completion = await client.complete(
        _selectionMessages(
          query: query,
          userText: userText,
          topIndex: topIndex,
          dayIndexByMonth: dayIndexByMonth,
          personaIndex: personaIndex,
        ),
        maxTokens: recallModelMaxOutputTokens,
      );
    } on Object catch (error) {
      diagnostics.add('recall selection deferred [$error]');
      return null;
    }
    final text = completion?.text;
    if (text == null) {
      diagnostics.add(
        'recall selection deferred '
        '[${completion?.failure?.name ?? 'no-provider'}]',
      );
      return null;
    }
    final parsed = parseHiddenActions(text);
    final action = parsed.actions.whereType<MemoryRecallAction>().firstOrNull;
    for (final diagnostic in parsed.diagnostics) {
      diagnostics.add('recall selection dropped [$diagnostic]');
    }
    if (action == null) {
      diagnostics.add('recall selection empty reason=no-action');
      return null;
    }
    return action;
  }

  /// 组织调用：把选中日的原始证据与画像树路径交给模型，请它自然地
  /// 补一句。返回三态结果（票 01）：
  /// - 明确使用：模型组出了候选气泡；回执条目 ID（entries）供下一轮
  ///   临时上下文做条目级相关性筛选，没给回执时 entryIds 为 null，
  ///   调用方不扩成全量。
  /// - 明确拒绝：哨兵输出（容忍尾部标点/空白），查到的记录与用户问
  ///   的不是一回事——本轮不补气泡，下一轮也不留候选。
  /// - 未完成判断：调用异常、Provider 失败或输出不可解析（既没有
  ///   可见句也没有哨兵），不能冒充明确拒绝或没有候选。
  Future<_ComposeOutcome> _composeBubble(
    ProviderChatClient client, {
    required String query,
    required String userText,
    required List<(String, List<EpisodeEntry>)> rawDays,
    required String personaPathText,
    required List<String> diagnostics,
  }) async {
    ModelCompletion? completion;
    try {
      completion = await client.complete(
        _composeMessages(
          query: query,
          userText: userText,
          rawDays: rawDays,
          personaPathText: personaPathText,
          // 表述惯例（称呼定稿）：称呼用户时按 persona.md 设定行走。
          appellation: await readAppellationFromMemory(memoryDirectory),
        ),
        maxTokens: recallModelMaxOutputTokens,
      );
    } on Object catch (error) {
      diagnostics.add('recall compose deferred [$error]');
      return const _ComposeUnjudged();
    }
    final text = completion?.text;
    if (text == null) {
      diagnostics.add(
        'recall compose deferred [${completion?.failure?.name ?? 'no-provider'}]',
      );
      return const _ComposeUnjudged();
    }
    final parsed = parseHiddenActions(text);
    for (final diagnostic in parsed.diagnostics) {
      diagnostics.add('recall compose dropped [$diagnostic]');
    }
    final visibleText = parsed.visibleText;
    // 哨兵容忍尾部标点/空白（模型可能输出「没有了。」），避免把
    // 「没有」的表态当成 bubble 2 内容交付。
    final sentinelNormalized = visibleText
        .replaceAll(RegExp(r'[。．.…!！?？,，、\s]+$'), '')
        .trim();
    if (sentinelNormalized == _recallNoBubbleSentinel) {
      // 明确拒绝（票 01）：模型表态查到的记录与用户问的不是一回事。
      diagnostics.add('recall compose rejected reason=model-sentinel');
      return const _ComposeRejected();
    }
    if (sentinelNormalized.isEmpty) {
      // 输出不可解析（既没有可见句也没有哨兵）：判断没有完成，不能
      // 冒充明确拒绝（票 01），材料按未判断留给下一轮。
      diagnostics.add('recall compose empty reason=unparseable');
      return const _ComposeUnjudged();
    }
    // 所用条目回执：只认选择/组织协议里的 memory_recall entries 字段。
    final receipt = parsed.actions.whereType<MemoryRecallAction>().firstOrNull;
    return _ComposeUsed(visibleText, receipt?.entries);
  }

  /// 短期 memory context 内容：压缩后的证据 + 使用纪律。只带回与问题
  /// 相关的压缩结果，不搬运选中文件全文。
  ///
  /// 条目级相关性筛选（Memory 注入定稿）：组织调用声明了所用条目时
  /// 只收这些；未完成判断（组织调用失败、输出不可解析）才退回全量。
  /// 明确使用而回执不可采信时收窄为空集（只带路径素材），不把候选
  /// 统一扩成全量（票 01）。总量受 [recallPendingContextMaxRunes]
  /// 封顶——超预算的后续条目不再收入并记诊断，先命中的优先。
  String _buildPendingContext(
    List<(String, List<EpisodeEntry>)> rawDays,
    List<String>? usedEntryIds,
    String personaPathText,
    List<String> diagnostics,
  ) {
    final used = usedEntryIds?.toSet();
    final lines = <String>[];
    var totalRunes = 0;
    outer:
    for (final (date, entries) in rawDays) {
      for (final entry in entries) {
        if (used != null && !used.contains(entry.id)) {
          continue;
        }
        final line = StringBuffer()
          ..writeln(
            '- $date：${clipRunes(entry.summary.trim(), recallRawSummaryMaxRunes)}',
          );
        final evidence = entry.evidence?.trim();
        if (evidence != null && evidence.isNotEmpty) {
          line.writeln(
            '  原话摘录：${clipRunes(evidence, recallPendingEvidenceMaxRunes)}',
          );
        }
        final text = line.toString();
        if (totalRunes + text.runes.length > recallPendingContextMaxRunes) {
          diagnostics.add('recall pending context truncated reason=over-budget');
          break outer;
        }
        totalRunes += text.runes.length;
        lines.add(text);
      }
    }
    final buffer = StringBuffer()
      ..writeln('此前对话的后台整理记录（临时参考，不是新发生的事）：');
    buffer.writeAll(lines);
    if (personaPathText.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('画像树路径（根 → 中间理解 → 叶指针，只是检索到的相关依据）：')
        ..writeln(personaPathText);
    }
    buffer.write('语境合适时自然补上；与当前话题无关就不提；拿不准时保持不确定，不声称一直记得。');
    return buffer.toString();
  }

  List<ModelMessage> _selectionMessages({
    required String query,
    required String userText,
    required List<MonthIndexLine> topIndex,
    required Map<String, List<DayIndexLine>> dayIndexByMonth,
    required String personaIndex,
  }) {
    const system = '''
你是栖语的本机记忆检索模块。用户在对话里提起一件旧事，聊天模型已经请求后台查找。给你两层索引目录，请选出最可能相关的月份和日期。
两层索引的路径与格式：
- 月份索引 episodes/index.md：每行 `- YYYY-MM | 关键词 | episodes/YYYY/MM/index.md`
- 每日索引 episodes/YYYY/MM/index.md：每行 `- YYYY-MM-DD | 关键词 | YYYY-MM-DD.md`
要求：
1. 只输出一个隐藏块 <qiyu-actions>[{"action":"memory_recall","query":"查找意图原样带回","months":["YYYY-MM",…],"dates":["YYYY-MM-DD",…]}]</qiyu-actions>，除此之外不输出任何文字。
2. months 只能取自下面月份索引中出现过的月份；dates 只能取自下面每日索引中出现过的日期。可以少选；没有头绪时两个数组都留空。
3. 严禁编造目录里没有的月份或日期。
4. 目录里没有足够线索定位具体日期时，只选 months，不要猜 dates。
5. 不输出密码、密钥、证件号等敏感内容。''';

    final user = StringBuffer()
      ..writeln('查找意图：$query')
      ..writeln('用户当时的原话：$userText')
      ..writeln()
      ..writeln('## 月份索引（episodes/index.md）');
    for (final line in topIndex) {
      user.writeln(
        '- ${line.month} | ${_redactedIndexKeywords(line.keywords)} | '
        '${episodeMonthRelativeDirectory(line.month)}/index.md',
      );
    }
    for (final MapEntry(:key, :value) in dayIndexByMonth.entries) {
      user
        ..writeln()
        ..writeln('## 每日索引（$key）');
      for (final line in value) {
        user.writeln(
          '- ${line.date} | ${_redactedIndexKeywords(line.keywords)} | '
          '${line.date}.md',
        );
      }
    }
    // 画像树路径检索（Memory 注入定稿）：需要解释习惯、核对画像依据
    // 或追溯具体事件时才选路径；默认只选根与最相关中间理解，问题需要
    // 依据或事件细节时才在第三段附最多 2 条叶 ID。
    if (personaIndex.isNotEmpty) {
      user
        ..writeln()
        ..writeln('## 画像树路径索引（persona-tree，活跃根 → 中间理解）')
        ..writeln(personaIndex)
        ..writeln()
        ..writeln('路径选择（需要解释习惯、核对画像依据或追溯具体事件时才选）：')
        ..writeln('- 形式「根ID/中间理解ID」，最多 2 条；ID 只能取自上面画像树路径索引。')
        ..writeln('- 默认只选根与最相关中间理解；只有问题需要依据或事件细节时，才在第三条段附该中间理解下最多 2 条叶 ID：「根ID/中间理解ID/叶ID,叶ID」。')
        ..writeln('- 解释习惯、核对画像依据这类不涉及具体日期的问题，可以只选 paths、不选月份和日期。');
    }
    return [
      const ModelMessage(ModelMessageRole.system, system),
      ModelMessage(ModelMessageRole.user, user.toString()),
    ];
  }

  String _redactedIndexKeywords(List<String> keywords) {
    final text = keywords.join(', ');
    final separated = StringBuffer();
    var cursor = 0;
    // 索引行本身没有换行。用已有 JSON 区间保护字符串内的逗号，
    // 其余逗号两侧临时换行，让 Cookie 规则及空值后的空白匹配都
    // 止于关键词边界。JSON 允许这些空白，数组归属与密码值不变。
    for (final field in jsonScalarFields(text)) {
      separated
        ..write(text.substring(cursor, field.valueStart).replaceAll(',', '\n,\n'))
        ..write(text.substring(field.valueStart, field.valueEnd));
      cursor = field.valueEnd;
    }
    separated.write(text.substring(cursor).replaceAll(',', '\n,\n'));
    return redactSessionText(separated.toString()).replaceAll('\n,\n', ',');
  }

  List<ModelMessage> _composeMessages({
    required String query,
    required String userText,
    required List<(String, List<EpisodeEntry>)> rawDays,
    required String personaPathText,
    String? appellation,
  }) {
    // 称呼用户的惯例（称呼定稿 2026-09-03）：有称呼自然可用，没有就
    // 用「你」；称呼格式受控（无换行与控制字符、限长），可安全内嵌；
    // 值可能与主链画像块同源，进提示前套用同一份脱敏规则。
    final safeAppellation = appellation == null
        ? null
        : redactSessionText(appellation);
    final appellationRule = safeAppellation == null
        ? '6. 称呼用户时用「你」，不要替用户起昵称。'
        : '6. 语境自然时可以用「$safeAppellation」称呼用户，不要替用户起'
              '其他昵称。';
    final system =
        '''
你是栖语。刚才用户提起一件旧事，你先按一时没想起回应了；现在后台查找有了结果，你要自然地补一句。
要求：
1. 先只输出要补给用户的一到两句话本身；不输出标签、解释或前缀。用到了哪些记录，就在气泡后另起一行追加隐藏块 <qiyu-actions>[{"action":"memory_recall","query":"查找意图原样带回","entries":["用到的条目ID",…]}]</qiyu-actions>；entries 只能取下面记录里方括号内的条目 ID，一条都没用到就省略整个隐藏块。
2. 只能使用下面查到的记录里真实存在的内容；记录里没有的细节不提，不编造。
3. 像刚想起来那样轻轻补上；不复述用户的话，不开新话题，不追问。
4. 查到的记录与用户问的不是一回事时，只输出「$_recallNoBubbleSentinel」三个字。
5. 禁止客服式话术；少说，安静，温暖。
$appellationRule''';

    final user = StringBuffer()
      ..writeln('用户刚才说：$userText')
      ..writeln('查找意图：$query');
    // 纯画像依据的查找没有 episode 证据：整节省略，不递空节。
    if (rawDays.isNotEmpty) {
      user
        ..writeln()
        ..writeln('## 查到的记录');
      for (final (date, entries) in rawDays) {
        user.writeln('### $date');
        for (final entry in entries) {
          // 方括号内是条目 ID：组织回执按 ID 声明所用条目，Host 据此
          // 做下一轮临时上下文的条目级相关性筛选。
          user.writeln(
            '- [${entry.id}] '
            '${clipRunes(entry.summary.trim(), recallRawSummaryMaxRunes)}',
          );
          final evidence = entry.evidence?.trim();
          if (evidence != null && evidence.isNotEmpty) {
            user.writeln(
              '  原话摘录：${clipRunes(evidence, recallRawEvidenceMaxRunes)}',
            );
          }
        }
      }
    }
    if (personaPathText.isNotEmpty) {
      user
        ..writeln()
        ..writeln('## 画像树路径（根 → 中间理解 → 叶指针）')
        ..writeln(personaPathText);
    }
    return [
      ModelMessage(ModelMessageRole.system, system),
      ModelMessage(ModelMessageRole.user, user.toString()),
    ];
  }
}
