import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'dream.dart';
import 'markdown_memory_repository.dart';
import 'memory_controls.dart';
import 'memory_text_primitives.dart';
import 'model_prompt_builder.dart';
import 'open_loop_store.dart';
import 'persona_tree.dart';
import 'relationship_lifecycle.dart';

/// 热层注入硬上限（设计定稿）：总量超 3000 tokens 先砍再注入。
/// 砍序：先压 long-memory → 再压 persona 投影的可裁节（边界禁区永不
/// 裁）→ 再压 daily-state 的近日状态节；永不砍 relationship 与
/// open-loops。三块的串行读取与跨块预算协调都在本模块内完成
/// （见 [StatePackReader.readHotLayerBlocks]），聊天交付只消费
/// 准备好的结果。
const hotLayerMaxRunes = 3000;

/// 一次热层准备的最终结果：每日状态包、长期印象与用户画像三块的
/// 可注入内容。部分成功语义显式保留——null 表示该块本轮未准备成功，
/// 调用方保持原值；非 null（含空串）表示已按既有规则准备好、可直接
/// 整块替换的内容。
final class HotLayerBlocks {
  const HotLayerBlocks({
    required this.dailyState,
    required this.longMemory,
    required this.persona,
    required this.failure,
  });

  /// 【近况】块内容；读取失败时为 null。
  final String? dailyState;

  /// 【长期印象】块内容；长期印象自身准备（读取与裁剪）失败时为
  /// null。成功时为本轮新值：正常路径含跨块预算裁剪；画像读取失败
  /// 时为未经跨块裁剪的读入值（票 04：画像失败不撤销长期印象，跨块
  /// 裁剪需画像内容参与、未进行）。
  final String? longMemory;

  /// 【用户画像】块内容（含跨块预算裁剪）；本轮未准备成功时为 null。
  final String? persona;

  /// 首个读取阶段失败的错误；三块全部准备成功时为 null。诊断措辞
  /// （state pack unavailable）仍由聊天交付侧落，本模块只负责如实
  /// 上报失败，不改写错误语义。
  final Object? failure;

  /// 把准备结果装配进 [builder]：准备成功的块按近况 → 长期印象 →
  /// 用户画像的既有替换顺序生效；准备失败的块保持 builder 原值
  /// （部分成功：已成功更新的部分不撤销，未成功的块原状态保留）。
  ModelPromptBuilder applyTo(ModelPromptBuilder builder) {
    var next = builder;
    final dailyState = this.dailyState;
    if (dailyState != null) {
      next = next.copyWithDailyState(dailyState);
    }
    final longMemory = this.longMemory;
    if (longMemory != null) {
      next = next.copyWithLongMemory(longMemory);
    }
    final persona = this.persona;
    if (persona != null) {
      next = next.copyWithPersona(persona);
    }
    return next;
  }
}

/// 每日状态包装配（装配图定稿）：服务端每轮读状态包三个文件
/// （open-loops / relationship / daily-state），各带小标题拼成
/// `<daily_state>`【近况】块；空块不输出。
///
/// 跟进门控的确定性部分在 Host 计算（状态/权限/到期/阶段/禁提），
/// 以「主动跟进候选」批注呈现；语境是否自然、是否开口由模型判断。
///
/// 本类同时是热层读取的单一所有者：三块内容读取、既有记忆控制
/// 过滤与跨块预算协调（[readHotLayerBlocks]）都收拢在此。类保持
/// 可继承，仅供测试在读取 seam 上注入故障。
class StatePackReader {
  StatePackReader({
    required this.memoryDirectory,
    OpenLoopStore? openLoopStore,
    Clock? clock,
  }) : _clock = clock ?? DateTime.now,
       _openLoopStore =
           openLoopStore ?? OpenLoopStore(memoryDirectory: memoryDirectory);

  final String memoryDirectory;
  final Clock _clock;
  final OpenLoopStore _openLoopStore;

  File get _relationshipFile =>
      memoryFile(memoryDirectory, relationshipFileName);
  File get _dailyStateFile => memoryFile(memoryDirectory, dailyStateFileName);
  File get _longMemoryFile => memoryFile(memoryDirectory, longMemoryFileName);
  File get _personaFile => memoryFile(memoryDirectory, personaFileName);

  /// 热层读取的单一入口：按既有顺序串行读取每日状态包、长期印象与
  /// 用户画像（各次记忆控制读取保持原次数，不并行、不缓存、不共用
  /// 快照），再按既有砍序做跨块预算协调——三块总量超 [hotLayerMaxRunes]
  /// 时先压长期印象（clipLongMemoryBlock），再压用户画像可裁节
  /// （clipPersonaBlock，边界禁区永不裁）；近况块内部的近日状态已在
  /// [readDailyStateBlock] 内先压过。
  ///
  /// 部分成功语义：近况块读取成功即已成立，后续任何阶段失败都不撤销
  /// 它；长期印象在其自身准备（读取与 clipLongMemoryBlock 裁剪）完成
  /// 时确立本轮新值，其后画像阶段（读取与裁剪）的失败不再撤销它（票
  /// 04：画像失败保留已成功的长期印象），长期印象自身阶段的失败仍保
  /// 持 null（调用方原值）；画像只在自身读取与裁剪成功时成立。首个
  /// 失败记入 [HotLayerBlocks.failure]，其后的读取不再进行。
  Future<HotLayerBlocks> readHotLayerBlocks() async {
    String? dailyState;
    String? longMemory;
    String? persona;
    Object? failure;
    try {
      final dailyStateBlock = await readDailyStateBlock();
      dailyState = dailyStateBlock;
      final longMemoryBlock = await readLongMemoryBlock();
      // 画像读取起属画像阶段：本阶段失败只保持画像原值，不撤销已成功
      // 读入的长期印象（票 04），在此提前收束。
      String personaBlock;
      try {
        personaBlock = await readPersonaBlock();
      } on Object catch (error) {
        return HotLayerBlocks(
          dailyState: dailyState,
          longMemory: longMemoryBlock,
          persona: null,
          failure: error,
        );
      }
      // 裁前与裁长期印象后共用同一溢出公式，收成闭包防两处漂移。
      int overflowOf(int longRunes, int personaRunes) =>
          dailyStateBlock.runes.length + longRunes + personaRunes -
          hotLayerMaxRunes;
      var clippedLongMemory = longMemoryBlock;
      var clippedPersona = personaBlock;
      final overflow = overflowOf(
        longMemoryBlock.runes.length,
        personaBlock.runes.length,
      );
      if (overflow > 0) {
        clippedLongMemory = clipLongMemoryBlock(
          longMemoryBlock,
          longMemoryBlock.runes.length - overflow,
        );
        // 长期印象自身准备（读取与裁剪）到此完成：先确立本轮新值，其后
        // 画像裁剪的失败不再撤销它（票 04）；自身阶段的失败仍走外层
        // catch，长期印象保持 null（语义不变）。
        longMemory = clippedLongMemory;
        final remainingOverflow = overflowOf(
          clippedLongMemory.runes.length,
          personaBlock.runes.length,
        );
        if (remainingOverflow > 0) {
          clippedPersona = clipPersonaBlock(
            personaBlock,
            personaBlock.runes.length - remainingOverflow,
          );
        }
      }
      longMemory = clippedLongMemory;
      persona = clippedPersona;
    } on Object catch (error) {
      failure = error;
    }
    return HotLayerBlocks(
      dailyState: dailyState,
      longMemory: longMemory,
      persona: persona,
      failure: failure,
    );
  }

  /// 返回可直接注入的【长期印象】内容；文件不存在、为空或读取失败
  /// 时返回空串，空块不输出。受控过滤（ticket 18）：封禁（禁提 ∪
  /// 删除）与冻结条目不进注入；无法解析的文件按基线原样注入
  /// （用户裁定 2026-08-18，D3 按基线）。跨块预算裁剪统一在
  /// [readHotLayerBlocks] 执行，单块读取不裁。
  Future<String> readLongMemoryBlock() async {
    final contents = await readFileIfExists(_longMemoryFile);
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
            .where((item) => !bannedMemoryText(item, controlled))
            .toList(),
    };
    return renderLongMemory(sections).trim();
  }

  /// 返回可直接注入的【用户画像】内容（persona.md 稳定根投影）；文件
  /// 不存在、为空或读取失败时返回空串，空块不输出。文件首行的
  /// `# persona` 标题属于文件格式，不进注入内容；命中受控范围的主张
  /// 行不进注入；跨块预算裁剪统一在 [readHotLayerBlocks] 执行。
  Future<String> readPersonaBlock() async {
    final contents = await readFileIfExists(_personaFile);
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
                    !bannedMemoryText(line.trim(), controlled),
              )
              .toList();
    return visible.join('\n').trim();
  }

  /// 注入侧的受控集合，统一按它过滤（并集定义见
  /// [OpenLoopStore.controlledTitles]）。
  Future<Set<String>> _controlledTitles() => _openLoopStore.controlledTitles();

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

    final relationship = filterControlledLines(
      await readFileIfExists(_relationshipFile),
      (text) => bannedMemoryText(text, controlled),
    );
    final stage = parseRelationshipStage(relationship);
    if (relationship != null && relationship.trim().isNotEmpty) {
      sections.add('【关系温度】\n${relationship.trim()}');
      sections.add(_stageBoundaryDiscipline(stage));
    }

    final dailyState = filterControlledLines(
      await readFileIfExists(_dailyStateFile),
      (text) => bannedMemoryText(text, controlled),
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
        '用户要求不再提的事项绝不触碰。';
    if (candidates.isEmpty) {
      return discipline;
    }
    final list = candidates
        .map((item) => '[${item.id}] ${item.title}')
        .join('；');
    return '$discipline\n主动跟进候选（条件已满足，最多选一个，'
        '语境不合适就不问）：$list';
  }
}
