import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'episode_index.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'open_loop_store.dart';

/// 召回结果状态。
enum RecallStatus {
  /// 找到唯一可信证据，已写入短期 memory context，下一轮注入。
  hit,

  /// 索引与原始证据中都没有找到相关记录。没找到不代表没发生，
  /// 不注入、不编造，话题再来再查。
  miss,

  /// 多个相似候选平分最高分，无法确定用户指的是哪一件：
  /// 不强行认定，诊断说明未采用原因。
  ambiguous,

  /// 同一话题的多条证据内容不一致：不强行认定，诊断说明。
  conflict,
}

/// 一次后台召回检索的结果。诊断只进本机 stderr，绝不展示给用户。
final class RecallSearch {
  const RecallSearch({
    required this.status,
    required this.query,
    this.matchedDate,
    this.memoryContext,
    this.diagnostics = const [],
  });

  final RecallStatus status;
  final String query;

  /// 命中证据所在的 episode 日期（仅 hit）。
  final String? matchedDate;

  /// 命中时写入的短期 memory context 内容（仅 hit）。
  final String? memoryContext;

  /// 诊断码与原因（不含正文），说明未采用或降级的原因。
  final List<String> diagnostics;
}

/// 召回式输入的服务端规则兜底（首响运行层定稿的「双保险」之二）：
/// 模型隐藏检索请求缺失时，这类输入自动触发后台检索。
final recallIntentPattern = RegExp(
  r'还记得|记得吗|不记得|还记得吗|还记得不|还记得么|'
  r'我之前说|之前说过|以前说过|上次说|上回说|说过.{0,10}吗|'
  r'提过|聊过|有没有说|忘没忘|忘了吗',
);

/// 判断用户输入是否是召回式提问（服务端规则兜底触发检索）。
bool looksLikeRecallInput(String text) => recallIntentPattern.hasMatch(text);

/// 召回检索意图中的功能性措辞：匹配前先剥掉，留下真正的话题词。
/// 只剥召回话术与最常见虚词，绝不剥可能承载话题的字。
final _recallStopPhrases = RegExp(
  r'还记得吗|还记得不|还记得么|还记得|记得吗|不记得|'
  r'我之前说过|我之前说|之前说过|以前说过|上次说的|上次说|上回说的|上回说|'
  r'说过|提过|聊过|有没有|忘没忘|忘了吗|吗|呢|么|'
  r'我|你|他|她|它|的|了|吧|啊|是|在|有|和|就|都|也|很|这|那|哪',
);

/// 月份线索：显式年月（2026年7月 / 2026-07）、只有月份（7月）
/// 与相对时间（去年这时候 / 上个月），由 [MemoryRecallService] 解析。
final _explicitYearMonth = RegExp(r'(\d{4})\s*年\s*(\d{1,2})\s*月');
final _explicitMonth = RegExp(r'(?<!\d)(\d{1,2})\s*月');
final _monthHyphen = RegExp(r'(\d{4})-(\d{2})');

/// 「晚一拍想起」的后台召回服务（ticket 13）。
///
/// 两级索引只负责定位：月份索引选月份，每日索引选日期，命中后
/// 必须打开索引指向的 daily episode 原始证据，索引摘要本身永远
/// 不作为最终事实来源（硬规则定稿）。
///
/// 检索在可见回复交付之后后台执行，绝不阻塞首响；找到唯一可信
/// 证据时写入按会话保存的短期 memory context，下一轮装配时取用
/// 一次后即失效（临时透镜，不落盘、不进状态包）。索引缺失或
/// 损坏时先从原始 episode 重建再继续，普通聊天不读索引、不受影响。
///
/// 冻结/禁提/删除的全链路过滤归 ticket 18；当前只有禁提可写入
/// memory-controls.md，因此这里先过滤禁提范围。
final class MemoryRecallService {
  MemoryRecallService({
    required this.memoryDirectory,
    required EpisodeMemoryPipeline episodePipeline,
    EpisodeIndexStore? indexStore,
    this.openLoopStore,
    Clock? clock,
    void Function(String message)? diagnosticsSink,
  }) : _episodePipeline = episodePipeline,
       _indexStore = indexStore ??
           EpisodeIndexStore(
             memoryDirectory: memoryDirectory,
             episodePipeline: episodePipeline,
           ),
       _clock = clock ?? DateTime.now,
       _diagnosticsSink = diagnosticsSink ?? stderrDiagnostics;

  final String memoryDirectory;
  final EpisodeMemoryPipeline _episodePipeline;
  final EpisodeIndexStore _indexStore;
  final OpenLoopStore? openLoopStore;
  final Clock _clock;
  final void Function(String message) _diagnosticsSink;

  final Map<String, String> _pendingContexts = {};

  EpisodeIndexStore get indexStore => _indexStore;

  /// 执行一次后台召回检索。命中时把短期 memory context 存到
  /// [sessionId] 名下，供下一轮装配取用；其余状态只记诊断。
  /// 任何异常都降级为 miss：检索失败不纠缠，话题再来再查。
  Future<RecallSearch> search({
    required String sessionId,
    required String query,
  }) async {
    final cleanQuery = sanitizeUserInput(query).trim();
    if (cleanQuery.isEmpty) {
      return RecallSearch(
        status: RecallStatus.miss,
        query: query,
        diagnostics: const ['recall skipped reason=empty-query'],
      );
    }
    try {
      final result = await _searchClean(sessionId, cleanQuery);
      for (final diagnostic in result.diagnostics) {
        _diagnosticsSink(diagnostic);
      }
      return result;
    } on Object catch (error) {
      final diagnostic = 'recall deferred [$error]';
      _diagnosticsSink(diagnostic);
      return RecallSearch(
        status: RecallStatus.miss,
        query: query,
        diagnostics: [diagnostic],
      );
    }
  }

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

  Future<RecallSearch> _searchClean(
    String sessionId,
    String cleanQuery,
  ) async {
    final diagnostics = <String>[];
    final banned = await _bannedTitles();

    var topIndex = await _indexStore.readTopIndex();
    if (topIndex == null) {
      // 索引缺失或损坏：先从原始 episode 重建，再继续检索。
      // 重建写索引文件，必须在 episode 日文件写锁内执行。
      await _episodePipeline.synchronizedOnDayFiles(
        () => _indexStore.rebuild(includeUnfinalized: true),
      );
      diagnostics.add('recall index rebuilt reason=missing-or-corrupt');
      topIndex = await _indexStore.readTopIndex();
      if (topIndex == null) {
        diagnostics.add('recall miss reason=no-episodes');
        return RecallSearch(
          status: RecallStatus.miss,
          query: cleanQuery,
          diagnostics: diagnostics,
        );
      }
    }

    final months = _selectMonths(cleanQuery, topIndex, diagnostics);
    if (months.isEmpty) {
      return RecallSearch(
        status: RecallStatus.miss,
        query: cleanQuery,
        diagnostics: diagnostics,
      );
    }

    final candidates = <_RecallCandidate>[];
    for (final month in months) {
      var dayLines = await _indexStore.readMonthIndex(month);
      if (dayLines == null) {
        // 月索引缺失或损坏：整体重建一次（幂等），再读。
        await _episodePipeline.synchronizedOnDayFiles(
          () => _indexStore.rebuild(includeUnfinalized: true),
        );
        diagnostics.add('recall index rebuilt reason=month-index-unreadable');
        dayLines = await _indexStore.readMonthIndex(month);
        if (dayLines == null) {
          diagnostics.add('recall month skipped reason=$month-unreadable');
          continue;
        }
      }
      for (final line in dayLines) {
        if (_score(cleanQuery, line.keywords.join(' ')) < 1) {
          continue;
        }
        // 索引只负责定位：必须打开原始日文件读取证据条目。
        final day = await _episodePipeline.readDay(line.date);
        if (!day.readable) {
          diagnostics.add('recall day skipped reason=${line.date}-unreadable');
          continue;
        }
        for (final entry in validEpisodeEntries(day.entries)) {
          final score = _score(cleanQuery, entry.summary);
          if (score < 1) {
            continue;
          }
          if (_matchesBanned(entry.summary, banned)) {
            diagnostics.add(
              'recall entry skipped reason=banned date=${line.date}',
            );
            continue;
          }
          candidates.add(
            _RecallCandidate(date: line.date, entry: entry, score: score),
          );
        }
      }
    }

    if (candidates.isEmpty) {
      diagnostics.add('recall miss reason=no-evidence');
      return RecallSearch(
        status: RecallStatus.miss,
        query: cleanQuery,
        diagnostics: diagnostics,
      );
    }

    // 同一件事在多日重复记录时按规范化摘要折叠，保留最早证据。
    final deduped = <String, _RecallCandidate>{};
    for (final candidate in candidates) {
      final key = normalizeMemoryText(candidate.entry.summary);
      final existing = deduped[key];
      if (existing == null || candidate.date.compareTo(existing.date) < 0) {
        deduped[key] = candidate;
      }
    }
    final distinct = deduped.values.toList()
      ..sort((left, right) => left.date.compareTo(right.date));

    final bestScore = distinct
        .map((candidate) => candidate.score)
        .reduce((left, right) => left > right ? left : right);
    final top = distinct
        .where((candidate) => candidate.score == bestScore)
        .toList();
    if (top.length >= 2) {
      // 多个相似候选或证据冲突：不强行认定，诊断说明未采用原因。
      final dates = top.map((candidate) => candidate.date).join(',');
      final sameTopic = top.every(
        (candidate) => _sameTopic(top.first.entry.summary, candidate.entry.summary),
      );
      final reason = sameTopic ? 'conflict' : 'ambiguous';
      diagnostics.add(
        'recall deferred reason=$reason candidates=${top.length} dates=$dates',
      );
      return RecallSearch(
        status: sameTopic ? RecallStatus.conflict : RecallStatus.ambiguous,
        query: cleanQuery,
        diagnostics: diagnostics,
      );
    }

    final winner = top.single;
    final context = _buildContext(winner);
    _pendingContexts[sessionId] = context;
    return RecallSearch(
      status: RecallStatus.hit,
      query: cleanQuery,
      matchedDate: winner.date,
      memoryContext: context,
      diagnostics: diagnostics,
    );
  }

  /// 月份选择：查询里有明确月份线索时只查线索月份（线索月份不在
  /// 索引中说明没有那段时间的记录，直接 miss，不拿别的月份顶替）；
  /// 没有线索时按关键词命中选择，跨月跨年不设数量上限。
  /// 线索可以是精确月份，也可以带年份或月份的通配（如「7月」匹配
  /// 索引中全部年份的 7 月，「去年」匹配索引中去年全部月份）。
  List<String> _selectMonths(
    String cleanQuery,
    List<MonthIndexLine> topIndex,
    List<String> diagnostics,
  ) {
    final available = topIndex.map((line) => line.month).toSet();
    final hinted = _monthHints(cleanQuery);
    if (hinted.isNotEmpty) {
      final months = <String>{};
      for (final hint in hinted) {
        if (hint.contains('??')) {
          // 通配线索形如 '??-07'（年份未知）或 '2025-??'（月份未知）。
          final parts = hint.split('-');
          final year = parts[0];
          final month = parts[1];
          for (final candidate in available) {
            final yearMatches = year == '??' || candidate.startsWith(year);
            final monthMatches =
                month == '??' || candidate.substring(5) == month;
            if (yearMatches && monthMatches) {
              months.add(candidate);
            }
          }
        } else if (available.contains(hint)) {
          months.add(hint);
        }
      }
      final result = months.toList()..sort();
      if (result.isEmpty) {
        diagnostics.add('recall miss reason=month-hint-not-indexed');
      }
      return result;
    }
    final months = topIndex
        .where((line) => _score(cleanQuery, line.keywords.join(' ')) >= 1)
        .map((line) => line.month)
        .toList()
      ..sort();
    if (months.isEmpty) {
      diagnostics.add('recall miss reason=no-month-match');
    }
    return months;
  }

  /// 从查询中提取月份线索（`YYYY-MM`），相对时间按本机时钟解析。
  List<String> _monthHints(String query) {
    final hints = <String>[];
    final now = _clock();
    for (final match in _explicitYearMonth.allMatches(query)) {
      final month = int.tryParse(match.group(2)!);
      if (month == null || month < 1 || month > 12) {
        continue;
      }
      hints.add('${match.group(1)}-${'$month'.padLeft(2, '0')}');
    }
    for (final match in _monthHyphen.allMatches(query)) {
      hints.add('${match.group(1)}-${match.group(2)}');
    }
    if (hints.isEmpty) {
      for (final match in _explicitMonth.allMatches(query)) {
        final month = int.tryParse(match.group(1)!);
        if (month == null || month < 1 || month > 12) {
          continue;
        }
        final padded = '$month'.padLeft(2, '0');
        // 只有月份没有年份：检索索引中全部年份的同名月份。
        hints.add('??-$padded');
      }
    }
    final monthNow = '${now.year}-${'${now.month}'.padLeft(2, '0')}';
    if (query.contains('去年这时候') ||
        query.contains('去年的现在') ||
        query.contains('这个时候去年')) {
      hints.add('${now.year - 1}-${monthNow.substring(5)}');
    } else if (query.contains('去年')) {
      hints.add('${now.year - 1}-??');
    }
    if (query.contains('前年')) {
      hints.add('${now.year - 2}-??');
    }
    if (query.contains('上个月') || query.contains('上月')) {
      final previous = DateTime(now.year, now.month - 1, 1);
      hints.add(
        '${previous.year}-${'${previous.month}'.padLeft(2, '0')}',
      );
    }
    return hints;
  }

  Future<Set<String>> _bannedTitles() async {
    final store = openLoopStore;
    if (store == null) {
      return const {};
    }
    return store.bannedTitles();
  }

  /// 禁提范围按包含关系匹配：禁提记录存的是事项简称，episode 摘要
  /// 往往是更长的完整句，精确相等会漏。宁可多屏蔽，不可让禁提内容
  /// 绕进注入上下文；冻结/删除的全链路语义匹配归 ticket 18。
  bool _matchesBanned(String summary, Set<String> banned) {
    if (banned.isEmpty) {
      return false;
    }
    final normalized = normalizeMemoryText(summary);
    if (normalized.isEmpty) {
      return false;
    }
    for (final title in banned) {
      if (title.isEmpty) {
        continue;
      }
      if (normalized.contains(title) || title.contains(normalized)) {
        return true;
      }
    }
    return false;
  }

  /// 短期 memory context 内容：压缩后的证据 + 使用纪律。
  /// 只带回与问题相关的压缩结果，不搬运选中文件全文。
  String _buildContext(_RecallCandidate winner) {
    final entry = winner.entry;
    final buffer = StringBuffer()
      ..writeln('此前对话的后台整理记录（临时参考，不是新发生的事）：')
      ..writeln(
        '- ${winner.date}：${clipRunes(entry.summary.trim(), 120)}',
      );
    final evidence = entry.evidence?.trim();
    if (evidence != null && evidence.isNotEmpty) {
      buffer.writeln('  原话摘录：${clipRunes(evidence, 100)}');
    }
    buffer.write(
      '语境合适时自然补上；与当前话题无关就不提；拿不准时保持不确定，不声称一直记得。',
    );
    return buffer.toString();
  }

  /// 查询与文本的相关度：共有词元数量。词元 = 中文二元组 +
  /// 拉丁词（长度≥2，小写）。功能性措辞先剥掉再切词。
  int _score(String query, String text) {
    final queryTokens = _queryTokens(query);
    if (queryTokens.isEmpty) {
      return 0;
    }
    final textTokens = _textTokens(text);
    var score = 0;
    for (final token in queryTokens) {
      if (textTokens.contains(token)) {
        score += 1;
      }
    }
    return score;
  }

  Set<String> _queryTokens(String query) =>
      _textTokens(query.replaceAll(_recallStopPhrases, ' '));

  Set<String> _textTokens(String text) {
    final tokens = <String>{};
    for (final match in RegExp(r'[A-Za-z0-9]{2,}').allMatches(text)) {
      tokens.add(match.group(0)!.toLowerCase());
    }
    for (final match in RegExp(r'[一-鿿]+').allMatches(text)) {
      final run = match.group(0)!;
      if (run.length == 1) {
        tokens.add(run);
      }
      for (var index = 0; index + 2 <= run.length; index += 1) {
        tokens.add(run.substring(index, index + 2));
      }
    }
    return tokens;
  }

  /// 话题相近判断：规范化后一条包含另一条，或共享不少于 5 rune
  /// 的前缀/后缀，视作同一话题（用于区分证据冲突与多候选歧义）。
  /// 阈值取 5 是为了越过「用户提到」「用户聊到」这类公共开头。
  bool _sameTopic(String left, String right) {
    final a = normalizeMemoryText(left);
    final b = normalizeMemoryText(right);
    if (a.isEmpty || b.isEmpty || a == b) {
      return a == b;
    }
    if (a.contains(b) || b.contains(a)) {
      return true;
    }
    return _sharedRunes(a, b) >= 5 ||
        _sharedRunes(
          String.fromCharCodes(a.runes.toList().reversed),
          String.fromCharCodes(b.runes.toList().reversed),
        ) >= 5;
  }

  int _sharedRunes(String left, String right) {
    final leftRunes = left.runes.toList();
    final rightRunes = right.runes.toList();
    var count = 0;
    while (count < leftRunes.length &&
        count < rightRunes.length &&
        leftRunes[count] == rightRunes[count]) {
      count += 1;
    }
    return count;
  }
}

final class _RecallCandidate {
  const _RecallCandidate({
    required this.date,
    required this.entry,
    required this.score,
  });

  final String date;
  final EpisodeEntry entry;
  final int score;
}

