import 'dart:convert';
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
  /// null。成功时为本轮新值：三块齐备时含跨块预算裁剪；近况或画像
  /// 缺席使跨块溢出无从计算时为未经跨块裁剪的读入值（票 04/05：其
  /// 余层照常注入，宁整段带上也不丢内容）。
  final String? longMemory;

  /// 【用户画像】块内容；画像自身准备（读取与裁剪）失败时为 null。
  /// 成功时为本轮新值：三块齐备时含跨块预算裁剪；近况或长期印象缺
  /// 席使跨块溢出无从计算，或三块齐备而长期印象裁剪失败（长期印象
  /// 保持原值、长度不可知，溢出同样无从计算）时，为未经跨块裁剪的
  /// 读入值（票 05 同一原则）。
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

/// 热层源文件指纹：改动时间＋大小（与 stat 的对应字段同义）。文件
/// 缺席是合法指纹（[SourceFileFingerprint.absent]，与任何存在的指纹
/// 都不相等）；同刻同尺寸重写在理论上可漏检（NTFS 改动时间粒度），
/// 属已接受残余风险。相等按改动时间与大小逐字段比较（双缺席即相
/// 等），只作相等比较，不做时间推断。
final class SourceFileFingerprint {
  const SourceFileFingerprint({this.modified, this.size});

  /// 文件缺席（不存在）的指纹。
  static const SourceFileFingerprint absent = SourceFileFingerprint();

  /// 改动时间；缺席为 null。
  final DateTime? modified;

  /// 文件大小（字节）；缺席为 null。
  final int? size;

  @override
  bool operator ==(Object other) =>
      other is SourceFileFingerprint &&
      other.modified == modified &&
      other.size == size;

  @override
  int get hashCode => Object.hash(modified, size);
}

/// 热层源文件 IO seam：指纹与容错读取的统一注入口，仅供测试替换
/// （假指纹、假 stat 错误、假读取错误与读计数）。指纹契约：文件不
/// 存在返回 [SourceFileFingerprint.absent]（缺席是合法指纹）；stat
/// 本身失败（权限/IO 异常，非缺席）时抛出，调用方视为指纹不匹配并
/// 重建。读取契约分两档：[readIfExists] 与 [readFileIfExists] 完全
/// 同口径——不存在或读取失败返回 null；[readExisting] 严格读取——
/// 文件不存在返回 null，读取失败原样上抛（open-loops 条目重建专用，
/// OpenLoopStore.readItems 同口径：存在但不可读不是缺席，近况层如
/// 实记入 failure）。
abstract interface class SourceFileIo {
  Future<SourceFileFingerprint> fingerprint(File file);

  Future<String?> readIfExists(File file);

  Future<String?> readExisting(File file);
}

/// 生产默认实现：File.stat 取指纹（dart:io 的 stat 对不存在与失败
/// 一律回 notFound、不抛，缺席即合法指纹），读取分别走
/// [readFileIfExists] 与「存在才读、失败上抛」的严格口径。
final class DefaultSourceFileIo implements SourceFileIo {
  const DefaultSourceFileIo();

  @override
  Future<SourceFileFingerprint> fingerprint(File file) async {
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.notFound) {
      return SourceFileFingerprint.absent;
    }
    return SourceFileFingerprint(modified: stat.modified, size: stat.size);
  }

  @override
  Future<String?> readIfExists(File file) => readFileIfExists(file);

  @override
  Future<String?> readExisting(File file) async {
    if (!await file.exists()) {
      return null;
    }
    return file.readAsString(encoding: utf8);
  }
}

/// 热层六个源文件：指纹缓存的键。缓存对象是各文件的原始文本与解析
/// 结果；过滤、裁剪、跟进候选与纪律文案等行为逻辑不在缓存内，每轮
/// 照常在活代码里重算。
enum _HotLayerSource {
  openLoops,
  relationship,
  dailyState,
  longMemory,
  persona,
  memoryControls,
}

/// 单源缓存条目：指纹与该代读取的原始文本、解析结果，三者同代——
/// 指纹校验通过即整条复用，任何重建（重读＋重解析）都整条换新。
/// [text] 为 null 表示文件缺席；读取失败在 open-loops 走严格口径时
/// 直接上抛（不入缓存），其余源按 readFileIfExists 口径与缺席同义
/// 返回 null。解析字段为对应空结果；[fingerprint] 为 null 表示 stat
/// 报错路径的临时条目，绝不入缓存。
final class _SourceCacheEntry {
  const _SourceCacheEntry({
    required this.fingerprint,
    required this.text,
    this.openLoopItems = const [],
    this.longMemoryParse = const LongMemoryFile(readable: false),
    this.memoryControls = MemoryControls.empty,
  });

  final SourceFileFingerprint? fingerprint;
  final String? text;

  /// open-loops 条目解析（parseOpenLoopItems 结果）：文本存在而值为
  /// null 表示结构不可识别（与 OpenLoopStore.readItems 同口径）。
  final List<OpenLoopItem>? openLoopItems;

  /// long-memory 分节解析（parseLongMemory 结果）。
  final LongMemoryFile longMemoryParse;

  /// memory-controls 解析快照；文本缺席时为空快照（与
  /// MemoryControlsStore.load 的缺席口径一致）。
  final MemoryControls memoryControls;
}

/// 每日状态包装配（装配图定稿）：服务端每轮读状态包三个文件
/// （open-loops / relationship / daily-state），各带小标题拼成
/// `<daily_state>`【近况】块；空块不输出。
///
/// 跟进门控的确定性部分在 Host 计算（状态/权限/到期/阶段/禁提），
/// 以「主动跟进候选」批注呈现；语境是否自然、是否开口由模型判断。
///
/// 本类同时是热层读取的单一所有者：三块内容读取、既有记忆控制
/// 过滤与跨块预算协调（[readHotLayerBlocks]）都收拢在此。
///
/// 源文件读取经进程内指纹缓存（[SourceFileIo] 可注入）：每轮回复先
/// 对六个源文件取指纹（改动时间＋大小），未变复用缓存文本与解析结
/// 果、跳过磁盘读取，变了（含从有到无）才重建；缓存只到解析层，
/// 行为逻辑每轮重算，受控集合单次装配共享一次解析。缓存不持久化、
/// 不跨 Host 重启，冷启动第一轮全量读取；写路径无需失效点——任何
/// 写入自动改变指纹。类保持可继承，仅供测试在读取与 IO seam 上注入
/// 故障。
class StatePackReader {
  StatePackReader({
    required this.memoryDirectory,
    OpenLoopStore? openLoopStore,
    Clock? clock,
    SourceFileIo? sourceIo,
  }) : _clock = clock ?? DateTime.now,
       _sourceIo = sourceIo ?? const DefaultSourceFileIo(),
       _openLoopStore =
           openLoopStore ?? OpenLoopStore(memoryDirectory: memoryDirectory);

  final String memoryDirectory;
  final Clock _clock;
  final SourceFileIo _sourceIo;
  final OpenLoopStore _openLoopStore;

  File get _relationshipFile =>
      memoryFile(memoryDirectory, relationshipFileName);
  File get _dailyStateFile => memoryFile(memoryDirectory, dailyStateFileName);
  File get _longMemoryFile => memoryFile(memoryDirectory, longMemoryFileName);
  File get _personaFile => memoryFile(memoryDirectory, personaFileName);
  // open-loops.md 无共享常量：本字面量与 OpenLoopStore、本包测试的
  // _sourceFileNames 共三份副本，同步受本次改动「仅两文件可改」约束，
  // TODO 收敛为单一出处。controls 文件直接复用控制存储的公开句柄，
  // 读写路径永不漂移。
  File get _openLoopsFile => memoryFile(memoryDirectory, 'open-loops.md');
  File get _memoryControlsFile => _openLoopStore.memoryControls.controlsFile;

  /// 指纹缓存：键为热层源文件，值为最近一次指纹校验通过的条目。仅
  /// 注入路径（[readHotLayerBlocks]，唯一消费方是聊天交付）使用；记
  /// 忆中心等展示面不走此缓存。
  final Map<_HotLayerSource, _SourceCacheEntry> _sourceCache = {};

  /// 单次装配共享的受控集合：三次消费共用一次指纹校验与至多一次读
  /// 取解析；装配开场清空、收场即弃，不跨装配共享实例。
  Set<String>? _assemblyControlledTitles;
  bool _inAssembly = false;

  /// 热层读取的单一入口：按既有顺序串行读取每日状态包、长期印象与
  /// 用户画像（源文件读取走指纹缓存：未变复用文本与解析结果、跳过
  /// 磁盘读取，变了含从有到无才重建；文件缺席是合法指纹；stat 报错
  /// 视为指纹不匹配重建且该轮不入缓存——异常路径绝不冒旧），再按
  /// 既有砍序做跨块预算协调——三块总量超 [hotLayerMaxRunes]
  /// 时先压长期印象（clipLongMemoryBlock），再压用户画像可裁节
  /// （clipPersonaBlock，边界禁区永不裁）；近况块内部的近日状态已在
  /// [readDailyStateBlock] 内先压过。缓存只到解析层：过滤、跨块裁
  /// 剪、跟进候选与纪律文案每轮照常在活代码里重算；受控集合在单次
  /// 装配内三次消费共享一次解析（开场清空、收场即弃），候选计算内
  /// 部的读取属 OpenLoopStore 自有逻辑，保持原样。
  ///
  /// 部分成功语义（票 05：三层完全独立）：某层读取或裁剪失败只跳过
  /// 该层（该块保持 null，调用方原值），不再中断其后各层；近况块读
  /// 取成功即已成立，长期印象在其自身裁剪成功时确立本轮新值，画像在
  /// 其自身裁剪成功时成立。跨块裁剪只在三块全部读取成功时进行：溢出
  /// 公式需要三块各自的 rune 数，缺席槽位由 builder 原值占据、其长
  /// 度本层不可知，按 0 计会基于虚假前提丢内容，故任一层缺席时已成
  /// 功读取的层整段注入、不做跨块裁剪（宁可整段带上也不丢内容，票
  /// 04 先例同一原则）；三块齐备而长期印象裁剪失败时同理：长期印象
  /// 保持原值，其长度不可知使溢出无从计算，画像整段注入。首个失败
  /// 记入 [HotLayerBlocks.failure]，其后各层照常读取。
  Future<HotLayerBlocks> readHotLayerBlocks() async {
    // 单次装配一个受控集合：开场清空、收场即弃；装配内三次消费共享
    // 一次解析（指纹校验一次）。并发装配各自重建，同值幂等——单
    // isolate 无锁，后写覆盖。
    _assemblyControlledTitles = null;
    _inAssembly = true;
    try {
      String? dailyState;
      String? longMemory;
      String? persona;
      Object? failure;
      try {
        // 三层读取彼此独立（票 05）：某层失败只跳过该层，其后各层照常
        // 读取；failure 保持串行顺序中的首个失败。
        String? dailyStateBlock;
        try {
          dailyStateBlock = await readDailyStateBlock();
          dailyState = dailyStateBlock;
        } on Object catch (error) {
          failure ??= error;
        }
        String? longMemoryBlock;
        try {
          longMemoryBlock = await readLongMemoryBlock();
        } on Object catch (error) {
          failure ??= error;
        }
        String? personaBlock;
        try {
          personaBlock = await readPersonaBlock();
        } on Object catch (error) {
          failure ??= error;
        }
        if (dailyStateBlock != null &&
            longMemoryBlock != null &&
            personaBlock != null) {
          // 闭包捕获的变量不做类型提升，收成 final 局部量供公式读取。
          final dailyBlock = dailyStateBlock;
          // 裁前与裁长期印象后共用同一溢出公式，收成闭包防两处漂移。
          int overflowOf(int longRunes, int personaRunes) =>
              dailyBlock.runes.length +
              longRunes +
              personaRunes -
              hotLayerMaxRunes;
          var clippedLongMemory = longMemoryBlock;
          var clippedPersona = personaBlock;
          final overflow = overflowOf(
            longMemoryBlock.runes.length,
            personaBlock.runes.length,
          );
          if (overflow > 0) {
            // 长期印象裁剪是否成功的显式信号；不借结果槽位非空兼作
            // 成功判断，避免依赖槽位仅在此处赋值的隐含约定。
            var longMemoryClipped = false;
            try {
              clippedLongMemory = clipLongMemoryBlock(
                longMemoryBlock,
                longMemoryBlock.runes.length - overflow,
              );
              // 长期印象自身准备（读取与裁剪）到此完成：先确立本轮新
              // 值，其后画像阶段的失败不再撤销它（票 04）；自身裁剪失
              // 败时本赋值不发生、长期印象保持原值（票 05）。
              longMemory = clippedLongMemory;
              longMemoryClipped = true;
            } on Object catch (error) {
              failure ??= error;
            }
            if (longMemoryClipped) {
              // 画像按长期印象裁剪后的实际长度照常裁剪；长期印象裁剪
              // 失败时其最终槽位是 builder 原值（长度不可知），溢出无
              // 从计算，画像整段注入（与缺席层同律）。
              try {
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
                // 画像自身准备（读取与裁剪）到此完成；裁剪失败时本赋
                // 值不发生、画像保持原值，已确立的长期印象不受影响
                // （票 04 语义）。
                persona = clippedPersona;
              } on Object catch (error) {
                failure ??= error;
              }
            } else {
              persona = personaBlock;
            }
          } else {
            longMemory = clippedLongMemory;
            persona = clippedPersona;
          }
        } else {
          // 任一层缺席使跨块溢出无从计算：已成功读取的层整段注入，
          // 缺席层保持原值（宁可整段带上也不丢内容）。
          longMemory = longMemoryBlock;
          persona = personaBlock;
        }
      } on Object catch (error) {
        // 兜底：热层读取绝不外抛，未预期异常同样按部分成功收束。
        failure ??= error;
      }
      return HotLayerBlocks(
        dailyState: dailyState,
        longMemory: longMemory,
        persona: persona,
        failure: failure,
      );
    } finally {
      _inAssembly = false;
      _assemblyControlledTitles = null;
    }
  }

  /// 返回可直接注入的【长期印象】内容；文件不存在、为空或读取失败
  /// 时返回空串，空块不输出。受控过滤（ticket 18）：封禁（禁提 ∪
  /// 删除）与冻结条目不进注入；无法解析的文件按基线原样注入
  /// （用户裁定 2026-08-18，D3 按基线）。跨块预算裁剪统一在
  /// [readHotLayerBlocks] 执行，单块读取不裁。
  Future<String> readLongMemoryBlock() async {
    final entry = await _sourceEntry(
      _HotLayerSource.longMemory,
      _longMemoryFile,
    );
    final trimmed = entry.text?.trim() ?? '';
    if (trimmed.isEmpty) {
      return '';
    }
    // 解析结果随文本同代缓存：指纹未变时不重复解析；过滤每轮照常。
    final parsed = entry.longMemoryParse;
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
    final entry = await _sourceEntry(_HotLayerSource.persona, _personaFile);
    final contents = entry.text;
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
  /// [OpenLoopStore.controlledTitles]）。单次装配内三次消费（近况/
  /// 长期印象/画像）共享一次解析：首个消费者经指纹缓存解析一次，其
  /// 余复用同一集合实例（集合只读共享）；装配外的直连调用按调用解
  /// 析，仍走指纹校验。proactiveCandidates 内部的控制读取属
  /// OpenLoopStore 自有逻辑，保持原样、不在此共享范围。
  Future<Set<String>> _controlledTitles() async {
    final shared = _assemblyControlledTitles;
    if (shared != null) {
      return shared;
    }
    final entry = await _sourceEntry(
      _HotLayerSource.memoryControls,
      _memoryControlsFile,
    );
    final titles = entry.memoryControls.controlledSummaries;
    if (_inAssembly) {
      _assemblyControlledTitles = titles;
    }
    return titles;
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

    final relationshipEntry = await _sourceEntry(
      _HotLayerSource.relationship,
      _relationshipFile,
    );
    final relationship = filterControlledLines(
      relationshipEntry.text,
      (text) => bannedMemoryText(text, controlled),
    );
    final stage = parseRelationshipStage(relationship);
    if (relationship != null && relationship.trim().isNotEmpty) {
      sections.add('【关系温度】\n${relationship.trim()}');
      sections.add(_stageBoundaryDiscipline(stage));
    }

    final dailyStateEntry = await _sourceEntry(
      _HotLayerSource.dailyState,
      _dailyStateFile,
    );
    final dailyState = filterControlledLines(
      dailyStateEntry.text,
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

    // 候选素材三类平级：未闭环事项或近日状态任一在座即追加纪律段
    // （共同过往属长期印象块，本方法不感知其有无，不在此判断）。
    if (loopsText != null || dailySection != null) {
      // 主动跟进候选属行为逻辑，每轮在 OpenLoopStore 内重算；其内部
      // 对 open-loops 与 controls 的读取保持原样，不经指纹缓存。
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
    final items = await _cachedOpenLoopItems();
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

  /// open-loops 条目的缓存读取与解析（OpenLoopStore.readItems 同口径：
  /// 文件缺席返回空表，结构不可识别返回 null，存在但读取失败原样上
  /// 抛、由近况层如实记入 failure）。读取经指纹缓存，解析结果随文本
  /// 同代复用；写入仍全部走 OpenLoopStore，任何写入自动改变指纹。
  Future<List<OpenLoopItem>?> _cachedOpenLoopItems() async {
    final entry = await _sourceEntry(_HotLayerSource.openLoops, _openLoopsFile);
    return entry.text == null ? const <OpenLoopItem>[] : entry.openLoopItems;
  }

  /// 带指纹校验的源文件条目入口：先取指纹——stat 报错视为指纹不匹
  /// 配，绝不在该路径沿用缓存；未变即整条复用缓存（跳过磁盘读取）；
  /// 变化（含从有到无）、无缓存与 stat 报错一律重建（重读＋重解析）。
  /// 文件缺席是合法指纹，按空文本入缓存；重建读取分两档：open-loops
  /// 条目走 [SourceFileIo.readExisting] 严格口径——存在但读取失败原
  /// 样上抛（OpenLoopStore.readItems 同口径，由近况层如实记入
  /// failure），其余源走 [readFileIfExists] 既有口径——不存在或读取
  /// 失败返回 null。
  Future<_SourceCacheEntry> _sourceEntry(
    _HotLayerSource source,
    File file,
  ) async {
    SourceFileFingerprint? fingerprint;
    try {
      fingerprint = await _sourceIo.fingerprint(file);
    } on Object {
      // stat 报错（权限/IO 异常，非缺席）：本轮重建，且结果不入缓存
      // （无指纹可凭，下一轮重新试探）——异常路径上绝不冒旧。
      fingerprint = null;
    }
    final cached = _sourceCache[source];
    if (cached != null && fingerprint != null) {
      final cachedFingerprint = cached.fingerprint;
      if (cachedFingerprint != null && cachedFingerprint == fingerprint) {
        return cached;
      }
    }
    final text = source == _HotLayerSource.openLoops
        ? await _sourceIo.readExisting(file)
        : await _sourceIo.readIfExists(file);
    final entry = _buildSourceEntry(source, fingerprint, text);
    if (fingerprint != null) {
      _sourceCache[source] = entry;
    }
    return entry;
  }

  /// 重建：按源文件重读文本并同步重解析（解析字段只服务各自消费方，
  /// 其余源保持空缺省值）。stat 报错路径的临时条目不带指纹、不入缓存。
  _SourceCacheEntry _buildSourceEntry(
    _HotLayerSource source,
    SourceFileFingerprint? fingerprint,
    String? text,
  ) {
    final trimmed = text?.trim() ?? '';
    switch (source) {
      case _HotLayerSource.openLoops:
        // 与 OpenLoopStore.readItems 同口径：缺席（严格读取返回 null）
        // 返回空表，结构不可识别返回 null；存在但读取失败已在读取时
        // 上抛，走不到这里。
        return _SourceCacheEntry(
          fingerprint: fingerprint,
          text: text,
          openLoopItems: text == null
              ? const <OpenLoopItem>[]
              : parseOpenLoopItems(text),
        );
      case _HotLayerSource.longMemory:
        return _SourceCacheEntry(
          fingerprint: fingerprint,
          text: text,
          longMemoryParse: parseLongMemory(trimmed),
        );
      case _HotLayerSource.memoryControls:
        return _SourceCacheEntry(
          fingerprint: fingerprint,
          text: text,
          memoryControls: text == null
              ? MemoryControls.empty
              : parseMemoryControls(text),
        );
      case _HotLayerSource.relationship:
      case _HotLayerSource.dailyState:
      case _HotLayerSource.persona:
        return _SourceCacheEntry(fingerprint: fingerprint, text: text);
    }
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

  /// 主动打开新话题纪律 + 确定性门控通过的候选池（状态 active、允许
  /// 主动、due 已到、关系阶段允许且未被禁提）。候选池三类平级：未闭环
  /// 事项、近日活跃与当前近况、共同过往与梗；不设固定顺序、分数、轮换、
  /// 等待加权或超时强制。候选只表示「可以进入候选池」，是否开口、怎么
  /// 开口仍由模型结合当前语境选择。
  String _followUpDiscipline(List<OpenLoopItem> candidates) {
    const discipline =
        '主动打开新话题纪律：候选池只有三类且完全平级——【未闭环事项】里'
        '满足既有主动条件的事项、【近日状态】里的近日活跃与当前近况、'
        '【长期印象】里的共同过往与梗；不设固定顺序、分数、轮换、等待'
        '加权或超时强制。命中多个候选时只选一个：结合用户当前一句话、近日'
        '气氛、关系阶段与话题自然度挑最自然的那件，每轮最多主动跟进一件事。'
        '【关系温度】里的「待试探」不提供话题，只在其他合法素材自然带到'
        '相关领域时约束试探边界。没有自然候选时不得编造话题或深查 episodes；'
        '用户只说「在吗」时简短回应并等待；没有用户输入时保持沉默，不'
        '主动发送消息。只有用户当前没有明确任务、语境自然且不打断当前'
        '话题时才开口；初识阶段不主动翻旧事；用户要求不再提的事项绝不'
        '触碰。';
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
