import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'dream.dart';
import 'episode_index.dart';
import 'markdown_memory_repository.dart';
import 'open_loop_store.dart';
import 'relationship_lifecycle.dart';

/// 热层注入硬上限（设计定稿）：总量超 3000 tokens 先砍再注入。
/// 砍序：先压 long-memory → 再压 persona 投影的可裁节（边界禁区永不
/// 裁）→ 再压 daily-state 的近日状态节；永不砍 relationship 与
/// open-loops。注入关在聊天服务侧按剩余预算裁剪（clipLongMemoryBlock
/// / clipPersonaBlock）。
const hotLayerMaxRunes = 3000;

/// 每日状态包装配（装配图定稿）：服务端每轮读状态包三个文件
/// （open-loops / relationship / daily-state），各带小标题拼成
/// `<daily_state>`【近况】块；空块不输出。
///
/// 跟进门控的确定性部分在 Host 计算（状态/权限/到期/阶段/禁提），
/// 以「主动跟进候选」批注呈现；语境是否自然、是否开口由模型判断。
final class StatePackReader {
  StatePackReader({
    required this.memoryDirectory,
    OpenLoopStore? openLoopStore,
    Clock? clock,
  }) : _clock = clock ?? DateTime.now,
       _openLoopStore = openLoopStore ??
           OpenLoopStore(memoryDirectory: memoryDirectory);

  final String memoryDirectory;
  final Clock _clock;
  final OpenLoopStore _openLoopStore;

  File get _relationshipFile =>
      File(path.join(memoryDirectory, 'relationship.md'));
  File get _dailyStateFile => File(path.join(memoryDirectory, 'daily-state.md'));
  File get _longMemoryFile =>
      File(path.join(memoryDirectory, 'long-memory.md'));
  File get _personaFile => File(path.join(memoryDirectory, 'persona.md'));

  /// 返回可直接注入的【长期印象】内容；文件不存在、为空或读取失败
  /// 时返回空串，空块不输出。受控过滤（ticket 18）：封禁（禁提 ∪
  /// 删除）与冻结条目不进注入；无法解析的文件按基线原样注入
  /// （用户裁定 2026-08-18，D3 按基线）。预算裁剪由注入关按剩余
  /// 热层预算执行，不在这里。
  Future<String> readLongMemoryBlock() async {
    final contents = await _readIfExists(_longMemoryFile);
    final trimmed = contents?.trim() ?? '';
    if (trimmed.isEmpty) {
      return '';
    }
    final parsed = parseLongMemory(trimmed);
    if (!parsed.readable) {
      return trimmed;
    }
    final controlled = await _controlledTitles();
    if (controlled.isEmpty) {
      return trimmed;
    }
    final sections = <String, List<String>>{
      for (final section in longMemorySections)
        section: (parsed.sections[section] ?? const <String>[])
            .where(
              (item) =>
                  !bannedTitleMatches(normalizeMemoryText(item), controlled),
            )
            .toList(),
    };
    return renderLongMemory(sections).trim();
  }

  /// 返回可直接注入的【用户画像】内容（persona.md 稳定根投影）；文件
  /// 不存在、为空或读取失败时返回空串，空块不输出。文件首行的
  /// `# persona` 标题属于文件格式，不进注入内容；命中受控范围的主张
  /// 行不进注入；预算裁剪归注入关。
  Future<String> readPersonaBlock() async {
    final contents = await _readIfExists(_personaFile);
    final trimmed = contents?.trim() ?? '';
    if (trimmed.isEmpty) {
      return '';
    }
    final lines = trimmed.split('\n');
    final body = lines.first.trim() == '# persona'
        ? lines.skip(1).toList()
        : lines;
    final controlled = await _controlledTitles();
    final visible = controlled.isEmpty
        ? body
        : body
              .where(
                (line) =>
                    !line.trim().startsWith('- ') ||
                    !bannedTitleMatches(
                      normalizeMemoryText(line.trim()),
                      controlled,
                    ),
              )
              .toList();
    return visible.join('\n').trim();
  }

  /// 受控集合 = 封禁（禁提 ∪ 删除）∪ 冻结：注入侧统一按它过滤。
  Future<Set<String>> _controlledTitles() async {
    final controls = await _openLoopStore.memoryControls.load();
    return {...controls.blockedSummaries, ...controls.frozenSummaries};
  }

  /// 返回可直接注入的【近况】内容；无任何可用内容时返回空串。
  /// 受控内容不出现在注入中（ticket 18）：open-loop 投影按标题过滤，
  /// relationship 与 daily-state 按行过滤；状态包与 open-loop 不直接
  /// 受控，但绝不引用受控内容（T24 定稿）。
  Future<String> readDailyStateBlock() async {
    final now = _clock();
    final sections = <String>[];
    final controlled = await _controlledTitles();

    final loopsText = await _renderLoops(controlled);
    if (loopsText != null) {
      sections.add('【未闭环事项】\n$loopsText');
    }

    final relationship = _filterControlledLines(
      await _readIfExists(_relationshipFile),
      controlled,
    );
    final stage = parseRelationshipStage(relationship);
    if (relationship != null && relationship.trim().isNotEmpty) {
      sections.add('【关系温度】\n${relationship.trim()}');
      sections.add(_stageBoundaryDiscipline(stage));
    }

    final dailyState = _filterControlledLines(
      await _readIfExists(_dailyStateFile),
      controlled,
    );
    final dailySection = dailyState == null || dailyState.trim().isEmpty
        ? null
        : '【近日状态】\n${dailyState.trim()}';
    if (dailySection != null) {
      sections.add(dailySection);
    }

    if (sections.isEmpty) {
      return '';
    }

    if (loopsText != null) {
      final candidates = await _openLoopStore.proactiveCandidates(now, stage);
      sections.add(_followUpDiscipline(candidates));
    }

    var block = sections.join('\n\n');
    // 注入关：超预算先砍近日状态（关系与未闭环事项永不砍）。
    if (block.runes.length > hotLayerMaxRunes && dailySection != null) {
      sections.remove(dailySection);
      block = sections.join('\n\n');
    }
    return block;
  }

  /// open-loop 投影：过滤受控事项后按原样注入 active/paused 条目。
  /// 控制匹配按包含关系（与其余管线同律），受控事项绝不进注入。
  Future<String?> _renderLoops(Set<String> controlled) async {
    final items = await _openLoopStore.readItems();
    if (items == null || items.isEmpty) {
      return null;
    }
    final visible = items
        .where(
          (item) =>
              !bannedTitleMatches(normalizeLoopTitle(item.title), controlled),
        )
        .toList();
    if (visible.isEmpty) {
      return null;
    }
    return visible.map((item) => item.raw).join('\n');
  }

  /// 行级受控过滤：列表行（`- ` 开头）命中受控范围即丢弃，其余内容
  /// 原样保留。relationship 与 daily-state 都是按行投影，逐行过滤
  /// 即可保证不引用受控内容。
  String? _filterControlledLines(String? contents, Set<String> controlled) {
    if (contents == null || controlled.isEmpty) {
      return contents;
    }
    final kept = <String>[];
    for (final line in contents.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('- ') &&
          bannedTitleMatches(normalizeMemoryText(trimmed), controlled)) {
        continue;
      }
      kept.add(line);
    }
    return kept.join('\n');
  }

  /// 阶段边界纪律：权限由阶段决定，温度（近期变化）只能影响语气冷暖，
  /// 不能绕过阶段限制的调侃、主动性与旧事引用；用户边界、安全规则与
  /// 禁提永远压在关系亲密度之上。
  String _stageBoundaryDiscipline(RelationshipStage stage) {
    const prefix =
        '阶段边界（权限由关系阶段决定，关系温度不能绕过；'
        '用户边界、安全规则与禁提事项始终高于关系亲密度）：';
    final permissions =
        '当前${stage.wireName}：${relationshipStageBehaviorLine(stage)}';
    return '$prefix\n$permissions';
  }

  /// 跟进纪律 + 确定性门控通过的候选池（状态 active、允许主动、
  /// due 已到、关系阶段允许且未被禁提）。候选只表示「可以进入候选池」，
  /// 是否开口、怎么开口仍由模型结合当前语境选择。
  String _followUpDiscipline(List<OpenLoopItem> candidates) {
    const discipline =
        '主动跟进纪律：每轮最多主动跟进一件事；只有用户当前没有明确任务、'
        '语境自然且不打断当前话题时才轻轻问起；初识阶段不主动翻旧事；'
        '晚安收束时不发起跟进；用户要求不再提的事项绝不触碰。';
    if (candidates.isEmpty) {
      return discipline;
    }
    final list = candidates
        .map((item) => '[${item.id}] ${item.title}')
        .join('；');
    return '$discipline\n主动跟进候选（条件已满足，最多选一个，'
        '语境不合适就不问）：$list';
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
}
