import 'dart:async';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'episode_index.dart';
import 'episode_memory.dart';
import 'memory_controls.dart';
import 'model_gateway.dart';
import 'open_loop_store.dart';
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
  /// 未命中或组织失败为 null。
  final String? bubbleText;

  /// 命中证据的压缩整理记录：bubble 2 没赶上交付时并入下一用户轮
  /// 注入（现状路径）；未命中为 null。
  final String? pendingContext;

  final List<String> diagnostics;
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
/// 两级索引只负责定位：索引关键词永远不是事实来源，命中必须回到
/// 索引指向的 daily episode 原始证据（硬规则定稿）。索引缺失或损坏
/// 时先从原始 episode 重建再继续。找到而 bubble 2 没赶上交付时，压缩
/// 结果存入按会话保存的短期 memory context，下一轮装配取用一次后
/// 即失效（临时透镜，不落盘、不进状态包）。
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
    required List<TypedHiddenAction> recallActions,
  }) async {
    final diagnostics = <String>[];
    try {
      return await _runClean(userText, recallActions, diagnostics);
    } on Object catch (error) {
      // 诊断只收进结果，由调用方统一落 sink，避免同一错误重复打印。
      diagnostics.add('recall deferred [$error]');
      return RecallTurnResult(diagnostics: diagnostics);
    }
  }

  Future<RecallTurnResult> _runClean(
    String userText,
    List<TypedHiddenAction> recallActions,
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
    // 记忆控制过滤贯穿全部递给模型的材料：索引关键词、回读证据与
    // 压缩注入。封禁（禁提 ∪ 删除）与冻结都不得被检索。
    final banned = await _blockedTitles();

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
        return RecallTurnResult(diagnostics: diagnostics);
      }
    }
    topIndex = _filterBannedMonthLines(topIndex, banned, diagnostics);
    if (topIndex.isEmpty) {
      diagnostics.add('recall miss reason=no-visible-months');
      return RecallTurnResult(diagnostics: diagnostics);
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

    // 调用2：模型在递过的目录里选择月份/日期。
    var selection = await _select(
      client,
      query: query,
      userText: userText,
      topIndex: topIndex,
      dayIndexByMonth: dayIndexByMonth,
      diagnostics: diagnostics,
    );
    var dates = _memberDates(selection?.dates, passedDates, diagnostics);
    if (dates.isEmpty) {
      final months = _memberMonths(selection?.months, topMonths, diagnostics);
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
            diagnostics: diagnostics,
          );
          dates = _memberDates(
            selection?.dates,
            _datesOf(dayIndexByMonth),
            diagnostics,
          );
        }
      }
    }
    if (dates.isEmpty) {
      diagnostics.add('recall miss reason=no-date-selection');
      return RecallTurnResult(diagnostics: diagnostics);
    }

    // 索引只负责定位：回读选中日文件的原始证据。跨月跨年检索不设
    // 日期数量上限（定稿）；只按压缩预算裁剪单条内容，不搬运全文。
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
      rawDays.add((date, entries));
    }
    if (rawDays.isEmpty) {
      diagnostics.add('recall miss reason=no-evidence');
      return RecallTurnResult(diagnostics: diagnostics);
    }

    final pendingContext = _buildPendingContext(rawDays);

    // 调用3：模型基于原始证据组织 bubble 2。
    final bubbleText = await _composeBubble(
      client,
      query: query,
      userText: userText,
      rawDays: rawDays,
      diagnostics: diagnostics,
    );
    return RecallTurnResult(
      bubbleText: bubbleText,
      pendingContext: pendingContext,
      diagnostics: diagnostics,
    );
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
  ) => keywords.where((keyword) => !bannedMemoryText(keyword, banned)).toList();

  Set<String> _datesOf(Map<String, List<DayIndexLine>> dayIndexByMonth) {
    final dates = <String>{};
    for (final lines in dayIndexByMonth.values) {
      for (final line in lines) {
        dates.add(line.date);
      }
    }
    return dates;
  }

  /// 成员校验：月份选取必须出自递过的顶层索引，编造的丢弃并记诊断。
  List<String> _memberMonths(
    List<String>? selections,
    Set<String> passed,
    List<String> diagnostics,
  ) {
    final kept = <String>[];
    for (final month in selections ?? const <String>[]) {
      if (passed.contains(month)) {
        kept.add(month);
      } else {
        diagnostics.add(
          'recall selection dropped month=$month reason=not-in-passed-index',
        );
      }
    }
    return kept;
  }

  /// 成员校验：日期选取必须出自递过的每日索引，编造的丢弃并记诊断。
  List<String> _memberDates(
    List<String>? selections,
    Set<String> passed,
    List<String> diagnostics,
  ) {
    final kept = <String>[];
    for (final date in selections ?? const <String>[]) {
      if (passed.contains(date)) {
        kept.add(date);
      } else {
        diagnostics.add(
          'recall selection dropped date=$date reason=not-in-passed-index',
        );
      }
    }
    return kept;
  }

  /// 检索封禁集合 = 封禁（禁提 ∪ 删除）∪ 冻结：冻结同样停止检索。
  Future<Set<String>> _blockedTitles() async {
    final store = openLoopStore;
    if (store == null) {
      return const {};
    }
    final controls = await store.memoryControls.load();
    return controls.controlledSummaries;
  }

  /// 选择调用：把查找意图与递回的目录交给模型，收回 memory_recall
  /// 选择。模型输出无法解析或没有给出动作时返回 null（没有头绪）。
  Future<MemoryRecallAction?> _select(
    ProviderChatClient client, {
    required String query,
    required String userText,
    required List<MonthIndexLine> topIndex,
    required Map<String, List<DayIndexLine>> dayIndexByMonth,
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
        ),
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
    final action = parsed.typedActions
        .whereType<MemoryRecallAction>()
        .firstOrNull;
    for (final diagnostic in parsed.diagnostics) {
      diagnostics.add('recall selection dropped [$diagnostic]');
    }
    if (action == null) {
      diagnostics.add('recall selection empty reason=no-action');
      return null;
    }
    return action;
  }

  /// 组织调用：把选中日的原始证据交给模型，请它自然地补一句。
  /// 失败、哨兵或空输出都返回 null（压缩结果仍可留给下一轮）。
  Future<String?> _composeBubble(
    ProviderChatClient client, {
    required String query,
    required String userText,
    required List<(String, List<EpisodeEntry>)> rawDays,
    required List<String> diagnostics,
  }) async {
    ModelCompletion? completion;
    try {
      completion = await client.complete(
        _composeMessages(query: query, userText: userText, rawDays: rawDays),
      );
    } on Object catch (error) {
      diagnostics.add('recall compose deferred [$error]');
      return null;
    }
    final text = completion?.text;
    if (text == null) {
      diagnostics.add(
        'recall compose deferred [${completion?.failure?.name ?? 'no-provider'}]',
      );
      return null;
    }
    final visibleText = parseHiddenActions(text).visibleText;
    // 哨兵容忍尾部标点/空白（模型可能输出「没有了。」），避免把
    // 「没有」的表态当成 bubble 2 内容交付。
    final sentinelNormalized = visibleText
        .replaceAll(RegExp(r'[。．.…!！?？,，、\s]+$'), '')
        .trim();
    if (sentinelNormalized.isEmpty ||
        sentinelNormalized == _recallNoBubbleSentinel) {
      diagnostics.add('recall compose empty reason=model-passed');
      return null;
    }
    return visibleText;
  }

  /// 短期 memory context 内容：压缩后的证据 + 使用纪律。
  /// 只带回与问题相关的压缩结果，不搬运选中文件全文。
  String _buildPendingContext(List<(String, List<EpisodeEntry>)> rawDays) {
    final buffer = StringBuffer()..writeln('此前对话的后台整理记录（临时参考，不是新发生的事）：');
    for (final (date, entries) in rawDays) {
      for (final entry in entries) {
        buffer.writeln(
          '- $date：${clipRunes(entry.summary.trim(), recallRawSummaryMaxRunes)}',
        );
        final evidence = entry.evidence?.trim();
        if (evidence != null && evidence.isNotEmpty) {
          buffer.writeln(
            '  原话摘录：${clipRunes(evidence, recallPendingEvidenceMaxRunes)}',
          );
        }
      }
    }
    buffer.write('语境合适时自然补上；与当前话题无关就不提；拿不准时保持不确定，不声称一直记得。');
    return buffer.toString();
  }

  List<ModelMessage> _selectionMessages({
    required String query,
    required String userText,
    required List<MonthIndexLine> topIndex,
    required Map<String, List<DayIndexLine>> dayIndexByMonth,
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
        '- ${line.month} | ${line.keywords.join(', ')} | '
        'episodes/${line.month.substring(0, 4)}/${line.month.substring(5, 7)}/index.md',
      );
    }
    for (final MapEntry(:key, :value) in dayIndexByMonth.entries) {
      user
        ..writeln()
        ..writeln('## 每日索引（$key）');
      for (final line in value) {
        user.writeln(
          '- ${line.date} | ${line.keywords.join(', ')} | ${line.date}.md',
        );
      }
    }
    return [
      const ModelMessage(ModelMessageRole.system, system),
      ModelMessage(ModelMessageRole.user, user.toString()),
    ];
  }

  List<ModelMessage> _composeMessages({
    required String query,
    required String userText,
    required List<(String, List<EpisodeEntry>)> rawDays,
  }) {
    const system =
        '''
你是栖语。刚才用户提起一件旧事，你先按一时没想起回应了；现在后台查找有了结果，你要自然地补一句。
要求：
1. 只输出要补给用户的一到两句话本身；不输出标签、解释、前缀或隐藏块。
2. 只能使用下面查到的记录里真实存在的内容；记录里没有的细节不提，不编造。
3. 像刚想起来那样轻轻补上；不复述用户的话，不开新话题，不追问。
4. 查到的记录与用户问的不是一回事时，只输出「$_recallNoBubbleSentinel」三个字。
5. 禁止客服式话术；少说，安静，温暖。''';

    final user = StringBuffer()
      ..writeln('用户刚才说：$userText')
      ..writeln('查找意图：$query')
      ..writeln()
      ..writeln('## 查到的记录');
    for (final (date, entries) in rawDays) {
      user.writeln('### $date');
      for (final entry in entries) {
        user.writeln(
          '- ${clipRunes(entry.summary.trim(), recallRawSummaryMaxRunes)}',
        );
        final evidence = entry.evidence?.trim();
        if (evidence != null && evidence.isNotEmpty) {
          user.writeln(
            '  原话摘录：${clipRunes(evidence, recallRawEvidenceMaxRunes)}',
          );
        }
      }
    }
    return [
      const ModelMessage(ModelMessageRole.system, system),
      ModelMessage(ModelMessageRole.user, user.toString()),
    ];
  }
}
