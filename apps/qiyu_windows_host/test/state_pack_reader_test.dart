import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

/// 读取阶段故障在外层 Host 入口无法跨平台稳定构造（Dart 的
/// File.exists 对目录返回 false，readFileIfExists 又把不可读吞成
/// null），按 Spec 预案在热层 seam 注入最小故障：只检查准备出的
/// 内容与失败结果，不断言私有调用步骤。
enum _FaultStage { dailyState, longMemory, persona }

class _FaultInjectedReader extends StatePackReader {
  _FaultInjectedReader({
    required super.memoryDirectory,
    _FaultStage? stage,
    Set<_FaultStage>? stages,
  }) : stages = {?stage, ...?stages};

  final Set<_FaultStage> stages;

  @override
  Future<String> readDailyStateBlock() async {
    if (stages.contains(_FaultStage.dailyState)) {
      throw StateError('注入的近况读取故障');
    }
    return super.readDailyStateBlock();
  }

  @override
  Future<String> readLongMemoryBlock() async {
    if (stages.contains(_FaultStage.longMemory)) {
      throw StateError('注入的长期印象读取故障');
    }
    return super.readLongMemoryBlock();
  }

  @override
  Future<String> readPersonaBlock() async {
    if (stages.contains(_FaultStage.persona)) {
      throw StateError('注入的画像读取故障');
    }
    return super.readPersonaBlock();
  }
}

Future<Directory> _seedMemory(
  FutureOr<void> Function(Directory memoryDirectory) seed,
) async {
  final directory = await Directory.systemTemp.createTemp('qiyu-state-pack-');
  final memoryDirectory = Directory(
    '${directory.path}${Platform.pathSeparator}memories',
  )..createSync(recursive: true);
  await seed(memoryDirectory);
  return memoryDirectory;
}

/// 源文件路径（与 memoryFile 的拼装同式），供指纹脚本与读计数按键查找。
String _sourcePath(Directory memoryDirectory, String name) =>
    p.join(memoryDirectory.path, name);

/// 热层六个源文件名：指纹脚本与读计数断言的统一清单。
const _sourceFileNames = [
  'open-loops.md',
  'relationship.md',
  'daily-state.md',
  'long-memory.md',
  'persona.md',
  'memory-controls.md',
];

/// 指纹脚本假 IO：指纹可按路径固定或强制 stat 抛错，未脚本化路径按
/// 真实 stat；读取走真实磁盘并按路径计数，可按路径注入读取错误——
/// 读计数用于断言缓存确实跳过了磁盘读取。
class _ScriptedSourceIo implements SourceFileIo {
  /// 键为源文件路径；值 null 表示该路径 stat 抛错（指纹不匹配路径）。
  final Map<String, SourceFileFingerprint?> scriptedFingerprints;

  /// 键为源文件路径：命中即抛注入的读取错误（「存在但不可读」无法
  /// 跨平台稳定构造，见本文件顶部说明，按预案在 seam 注入）。
  final Map<String, Object> scriptedReadErrors;

  _ScriptedSourceIo({
    Map<String, SourceFileFingerprint?>? fingerprints,
    Map<String, Object>? readErrors,
  }) : scriptedFingerprints = fingerprints ?? {},
       scriptedReadErrors = readErrors ?? {};

  int statCalls = 0;
  int readCalls = 0;
  final Map<String, int> readsByPath = {};

  @override
  Future<SourceFileFingerprint> fingerprint(File file) async {
    statCalls += 1;
    if (scriptedFingerprints.containsKey(file.path)) {
      final scripted = scriptedFingerprints[file.path];
      if (scripted == null) {
        throw StateError('注入的 stat 故障');
      }
      return scripted;
    }
    return const DefaultSourceFileIo().fingerprint(file);
  }

  @override
  Future<String?> readIfExists(File file) => _countedRead(file);

  @override
  Future<String?> readExisting(File file) => _countedRead(file);

  Future<String?> _countedRead(File file) async {
    readCalls += 1;
    readsByPath[file.path] = (readsByPath[file.path] ?? 0) + 1;
    final error = scriptedReadErrors[file.path];
    if (error != null) {
      throw error;
    }
    return readFileIfExists(file);
  }
}

void _writeRelationship(Directory memoryDirectory) => File(
  '${memoryDirectory.path}/relationship.md',
).writeAsStringSync(
  '# relationship\n\nstage: 初识\nsince: 2026-08-01\n'
  '阶段描述: 初识阶段：以回应当前话题、倾听为主；不调侃、不翻旧账、不引用共同过往、不主动追问私事。\n',
  encoding: utf8,
);

/// 带初始内容的三块 builder：部分成功断言必须以非空初始值验证
/// 「未被更新的块保持原值」，不能只以全空初始状态验证。
ModelPromptBuilder get _initialBuilder => const ModelPromptBuilder(
  '测试人格宪法',
  dailyState: '原近况',
  longMemory: '原长期印象',
  persona: '原画像',
);

void main() {
  test('三块全部准备成功时内容齐备且无失败', () async {
    final memoryDirectory = await _seedMemory((memoryDirectory) async {
      _writeRelationship(memoryDirectory);
      File('${memoryDirectory.path}/long-memory.md').writeAsStringSync(
        '# long-memory\n\n## 重要事件\n- 用户完成过一次公开演讲\n',
        encoding: utf8,
      );
      File('${memoryDirectory.path}/persona.md').writeAsStringSync(
        '# persona\n\n## 身份与客观事实\n- 用户在互联网行业工作\n',
        encoding: utf8,
      );
    });
    addTearDown(() => memoryDirectory.parent.delete(recursive: true));

    final prepared = await StatePackReader(
      memoryDirectory: memoryDirectory.path,
    ).readHotLayerBlocks();

    expect(prepared.failure, isNull);
    expect(prepared.dailyState, isNotNull);
    expect(prepared.dailyState, contains('【关系温度】'));
    expect(prepared.longMemory, contains('- 用户完成过一次公开演讲'));
    expect(prepared.persona, contains('- 用户在互联网行业工作'));
  });

  test('长期印象读取失败时保留部分成功：长期印象保持原值，画像照常读取注入', () async {
    final memoryDirectory = await _seedMemory((memoryDirectory) async {
      _writeRelationship(memoryDirectory);
      File('${memoryDirectory.path}/persona.md').writeAsStringSync(
        '# persona\n\n## 身份与客观事实\n- 用户在互联网行业工作\n',
        encoding: utf8,
      );
    });
    addTearDown(() => memoryDirectory.parent.delete(recursive: true));

    final prepared = await _FaultInjectedReader(
      memoryDirectory: memoryDirectory.path,
      stage: _FaultStage.longMemory,
    ).readHotLayerBlocks();

    // 近况已准备成立；长期印象未准备成功保持 null，failure 如实上报；
    // 画像不再被连坐（票 05），照常读取并注入。
    expect(prepared.dailyState, isNotNull);
    expect(prepared.dailyState, contains('【关系温度】'));
    expect(prepared.longMemory, isNull);
    expect(prepared.persona, contains('- 用户在互联网行业工作'));
    expect(prepared.failure, isA<StateError>());

    // 装配进带初始内容的 builder：近况与画像替换为本轮新值，长期
    // 印象原值保留。
    final builder = prepared.applyTo(_initialBuilder);
    expect(builder.dailyState, prepared.dailyState);
    expect(builder.longMemory, '原长期印象');
    expect(builder.persona, contains('- 用户在互联网行业工作'));
  });

  test('画像读取失败时长期印象保留本轮新值，画像保持原值', () async {
    final memoryDirectory = await _seedMemory((memoryDirectory) async {
      _writeRelationship(memoryDirectory);
      File('${memoryDirectory.path}/long-memory.md').writeAsStringSync(
        '# long-memory\n\n## 重要事件\n- 用户完成过一次公开演讲\n',
        encoding: utf8,
      );
    });
    addTearDown(() => memoryDirectory.parent.delete(recursive: true));

    final prepared = await _FaultInjectedReader(
      memoryDirectory: memoryDirectory.path,
      stage: _FaultStage.persona,
    ).readHotLayerBlocks();

    // 票 04 修复语义：长期印象读取成功后，画像阶段的失败只保持画像
    // 原值（null），不再撤销已读入的长期印象（本轮新值）。
    expect(prepared.dailyState, isNotNull);
    expect(prepared.longMemory, contains('- 用户完成过一次公开演讲'));
    expect(prepared.persona, isNull);
    expect(prepared.failure, isA<StateError>());

    // 带初始内容的 builder：长期印象应用本轮新值，画像保持原值，
    // 每日状态包保留本轮已成立的近况。
    final builder = prepared.applyTo(_initialBuilder);
    expect(builder.dailyState, contains('【关系温度】'));
    expect(builder.longMemory, contains('- 用户完成过一次公开演讲'));
    expect(builder.persona, '原画像');
  });

  test('画像读取失败且长期印象超预算时保留未经跨块裁剪的完整读入值', () async {
    // 跨块裁剪的溢出公式需要画像内容的 rune 数参与；画像读取失败时
    // 裁剪无从进行，长期印象按设计笔记「受损层暂时跳过，其他有效记忆
    // 继续使用」保留未经裁剪的完整读入值——rune 数允许超过
    // hotLayerMaxRunes（字段文档锁定的权衡），不因预算压力丢弃内容。
    final overflowItem = '超预算长条目${'记' * 3050}';
    final memoryDirectory = await _seedMemory((memoryDirectory) async {
      _writeRelationship(memoryDirectory);
      // 长期印象块单独已超 hotLayerMaxRunes（无画像失败时必触发跨块
      // 裁剪的量级）；超长条目置于末尾——若发生裁剪必被从尾部丢弃。
      File('${memoryDirectory.path}/long-memory.md').writeAsStringSync(
        renderLongMemory({
          '重要事件': ['用户完成过一次公开演讲', overflowItem],
        }),
        encoding: utf8,
      );
    });
    addTearDown(() => memoryDirectory.parent.delete(recursive: true));

    final prepared = await _FaultInjectedReader(
      memoryDirectory: memoryDirectory.path,
      stage: _FaultStage.persona,
    ).readHotLayerBlocks();

    // 未经跨块裁剪的完整读入值：rune 数超过预算，且首条印象与末尾超长
    // 条目完整保留（裁剪会把结果压回预算内并从尾部丢条目，二者任一
    // 发生即断言失败）。
    expect(prepared.longMemory, isNotNull);
    expect(prepared.longMemory!.runes.length, greaterThan(hotLayerMaxRunes));
    expect(prepared.longMemory, contains('- 用户完成过一次公开演讲'));
    expect(prepared.longMemory, contains(overflowItem));
    // 画像保持原值（null），failure 如实上报，近况保留本轮已成立值。
    expect(prepared.persona, isNull);
    expect(prepared.failure, isA<StateError>());
    expect(prepared.dailyState, contains('【关系温度】'));

    // 带初始内容的 builder：长期印象应用本轮完整新值，近况替换为本轮
    // 已成立值，画像保持原值。
    final builder = prepared.applyTo(_initialBuilder);
    expect(builder.longMemory, prepared.longMemory);
    expect(builder.dailyState, prepared.dailyState);
    expect(builder.persona, '原画像');
  });

  test('近况读取失败时近况保持原值，其余两层照常读取注入', () async {
    final memoryDirectory = await _seedMemory((memoryDirectory) async {
      _writeRelationship(memoryDirectory);
      File('${memoryDirectory.path}/long-memory.md').writeAsStringSync(
        '# long-memory\n\n## 重要事件\n- 用户完成过一次公开演讲\n',
        encoding: utf8,
      );
      File('${memoryDirectory.path}/persona.md').writeAsStringSync(
        '# persona\n\n## 身份与客观事实\n- 用户在互联网行业工作\n',
        encoding: utf8,
      );
    });
    addTearDown(() => memoryDirectory.parent.delete(recursive: true));

    final prepared = await _FaultInjectedReader(
      memoryDirectory: memoryDirectory.path,
      stage: _FaultStage.dailyState,
    ).readHotLayerBlocks();

    // 票 05：近况失败不再连坐其后各层——长期印象与画像照常读取注入
    //（近况缺席使跨块溢出无从计算，两层均为未经跨块裁剪的整段值）。
    expect(prepared.dailyState, isNull);
    expect(prepared.longMemory, contains('- 用户完成过一次公开演讲'));
    expect(prepared.persona, contains('- 用户在互联网行业工作'));
    expect(prepared.failure, isA<StateError>());

    final builder = prepared.applyTo(_initialBuilder);
    expect(builder.dailyState, '原近况');
    expect(builder.longMemory, contains('- 用户完成过一次公开演讲'));
    expect(builder.persona, contains('- 用户在互联网行业工作'));
  });

  test('近况读取失败且长期印象超预算时其余两层整段注入', () async {
    // 可计算性对照（票 05）：三块齐备时同量级溢出必触发跨块裁剪（见
    // 「溢出时先裁长期印象再裁画像」与画像失败组合用例）；近况缺席使
    // 溢出公式缺近况字数、无从计算，已读层按票 04 同一原则整段注入，
    // 不因预算压力丢弃内容。
    final overflowItem = '超预算长条目${'记' * 3050}';
    final memoryDirectory = await _seedMemory((memoryDirectory) async {
      File('${memoryDirectory.path}/long-memory.md').writeAsStringSync(
        renderLongMemory({
          '重要事件': ['用户完成过一次公开演讲', overflowItem],
        }),
        encoding: utf8,
      );
      File('${memoryDirectory.path}/persona.md').writeAsStringSync(
        '# persona\n\n## 身份与客观事实\n- 用户在互联网行业工作\n',
        encoding: utf8,
      );
    });
    addTearDown(() => memoryDirectory.parent.delete(recursive: true));

    final prepared = await _FaultInjectedReader(
      memoryDirectory: memoryDirectory.path,
      stage: _FaultStage.dailyState,
    ).readHotLayerBlocks();

    // 长期印象整段注入：rune 数超过预算，首条与末尾超长条目完整保留
    //（若发生裁剪必被压回预算内并从尾部丢条目）；画像同样整段注入。
    expect(prepared.dailyState, isNull);
    expect(prepared.longMemory, isNotNull);
    expect(prepared.longMemory!.runes.length, greaterThan(hotLayerMaxRunes));
    expect(prepared.longMemory, contains('- 用户完成过一次公开演讲'));
    expect(prepared.longMemory, contains(overflowItem));
    expect(prepared.persona, contains('- 用户在互联网行业工作'));
    expect(prepared.failure, isA<StateError>());

    final builder = prepared.applyTo(_initialBuilder);
    expect(builder.dailyState, '原近况');
    expect(builder.longMemory, prepared.longMemory);
    expect(builder.persona, prepared.persona);
  });

  test('多层同时失败时各层独立跳过且失败记首个', () async {
    final memoryDirectory = await _seedMemory((memoryDirectory) async {
      File('${memoryDirectory.path}/long-memory.md').writeAsStringSync(
        '# long-memory\n\n## 重要事件\n- 用户完成过一次公开演讲\n',
        encoding: utf8,
      );
    });
    addTearDown(() => memoryDirectory.parent.delete(recursive: true));

    final prepared = await _FaultInjectedReader(
      memoryDirectory: memoryDirectory.path,
      stages: {_FaultStage.dailyState, _FaultStage.persona},
    ).readHotLayerBlocks();

    // 近况与画像各自保持原值，长期印象独立读入；failure 是串行顺序
    // 中的首个失败（近况），其后画像故障不覆盖它。
    expect(prepared.dailyState, isNull);
    expect(prepared.longMemory, contains('- 用户完成过一次公开演讲'));
    expect(prepared.persona, isNull);
    expect(prepared.failure, isA<StateError>());
    expect((prepared.failure as StateError).message, '注入的近况读取故障');

    final builder = prepared.applyTo(_initialBuilder);
    expect(builder.dailyState, '原近况');
    expect(builder.longMemory, contains('- 用户完成过一次公开演讲'));
    expect(builder.persona, '原画像');
  });

  test('溢出时先裁长期印象再裁画像，边界禁区保留', () async {
    final memoryDirectory = await _seedMemory((memoryDirectory) async {
      File('${memoryDirectory.path}/relationship.md').writeAsStringSync(
        '# relationship\n\nstage: 初识\nsince: 2026-08-01\n'
        '阶段描述: 初识阶段：以回应当前话题、倾听为主；不调侃、不翻旧账、不引用共同过往、不主动追问私事。\n'
        '\n## 近期变化\n- ${'关' * 2500}\n',
        encoding: utf8,
      );
      File('${memoryDirectory.path}/long-memory.md').writeAsStringSync(
        renderLongMemory({
          '重要事件': ['用户完成过一次公开演讲'],
        }),
        encoding: utf8,
      );
      final preferences = [
        for (var i = 1; i <= 12; i += 1) '- 用户偏好第$i项${'长' * 53}',
      ].join('\n');
      File('${memoryDirectory.path}/persona.md').writeAsStringSync(
        '# persona\n\n## 偏好与习惯\n$preferences\n\n'
        '## 边界与禁区\n- 家庭话题只接不探\n',
        encoding: utf8,
      );
    });
    addTearDown(() => memoryDirectory.parent.delete(recursive: true));

    final prepared = await StatePackReader(
      memoryDirectory: memoryDirectory.path,
    ).readHotLayerBlocks();

    expect(prepared.failure, isNull);
    final total =
        prepared.dailyState!.runes.length +
        prepared.longMemory!.runes.length +
        prepared.persona!.runes.length;
    expect(total, lessThanOrEqualTo(hotLayerMaxRunes));
    // 边界禁区永不裁；偏好可裁节被压缩。
    expect(prepared.persona, contains('- 家庭话题只接不探'));
    expect('- 用户偏好第'.allMatches(prepared.persona!).length, lessThan(12));
  });

  test('热层读取是纯读取：全成功与部分失败路径都不新增、不改写记忆文件', () async {
    final memoryDirectory = await _seedMemory((memoryDirectory) async {
      _writeRelationship(memoryDirectory);
      File('${memoryDirectory.path}/daily-state.md').writeAsStringSync(
        '# daily-state\n\n## 近日状态\n- 用户睡前有点累\n',
        encoding: utf8,
      );
      File('${memoryDirectory.path}/open-loops.md').writeAsStringSync(
        '# open-loops\n\n'
        '- [o1] 用户明早想早起跑步\n'
        '  proactive: yes\n'
        '  status: active\n'
        '  due: 2026-08-10\n',
        encoding: utf8,
      );
      File('${memoryDirectory.path}/memory-controls.md').writeAsStringSync(
        '# memory-controls\n'
        '## frozen\n'
        '- [MC001] chat | 用户家的具体地址\n'
        '## banned\n'
        '## deleted\n',
        encoding: utf8,
      );
      File('${memoryDirectory.path}/long-memory.md').writeAsStringSync(
        renderLongMemory({
          '重要事件': ['用户完成过一次公开演讲'],
        }),
        encoding: utf8,
      );
      File('${memoryDirectory.path}/persona.md').writeAsStringSync(
        '# persona\n\n## 身份与客观事实\n- 用户在互联网行业工作\n',
        encoding: utf8,
      );
    });
    addTearDown(() => memoryDirectory.parent.delete(recursive: true));

    // 锁定的行为事实（票 02 验收第 9 条）：热层整理是纯读取，不新增
    // 记忆写入。读取前逐字节记录目录内全部条目（文件集合 + 每个文件
    // 的字节内容 + 子目录），读取后逐一比对：多一个文件、少一个文件、
    // 任何字节变化都会失败。
    Map<String, List<int>> snapshot() {
      final snapshot = <String, List<int>>{};
      for (final entity in memoryDirectory.listSync(recursive: true)) {
        final relative = entity.path.substring(memoryDirectory.path.length + 1);
        if (entity is File) {
          snapshot[relative] = entity.readAsBytesSync();
        } else {
          snapshot['$relative/'] = const <int>[];
        }
      }
      return snapshot;
    }

    final before = snapshot();

    // 全成功路径：六文件齐备，三块与跟进候选全部走真实读取。
    final prepared = await StatePackReader(
      memoryDirectory: memoryDirectory.path,
      clock: () => DateTime(2026, 8, 12, 21),
    ).readHotLayerBlocks();
    expect(prepared.failure, isNull);
    expect(prepared.dailyState, contains('【关系温度】'));
    expect(prepared.dailyState, contains('【未闭环事项】'));
    expect(prepared.longMemory, contains('- 用户完成过一次公开演讲'));
    expect(prepared.persona, contains('- 用户在互联网行业工作'));
    expect(snapshot(), equals(before));

    // 部分失败路径：画像读取失败只保持画像原值，长期印象保留本轮
    // 读入的新值（票 04），同样不落任何写入——失败路径与成功路径
    // 同律。
    final faulted = await _FaultInjectedReader(
      memoryDirectory: memoryDirectory.path,
      stage: _FaultStage.persona,
    ).readHotLayerBlocks();
    expect(faulted.failure, isA<StateError>());
    expect(faulted.dailyState, isNotNull);
    expect(faulted.longMemory, contains('- 用户完成过一次公开演讲'));
    expect(faulted.persona, isNull);
    expect(snapshot(), equals(before));
  });

  group('热层读取指纹缓存', () {
    /// 缓存测试的标准三文件：近况（关系温度）、长期印象与画像。
    Future<Directory> seedThreeLayers() => _seedMemory((memoryDirectory) async {
      _writeRelationship(memoryDirectory);
      File('${memoryDirectory.path}/long-memory.md').writeAsStringSync(
        '# long-memory\n\n## 重要事件\n- 用户完成过一次公开演讲\n',
        encoding: utf8,
      );
      File('${memoryDirectory.path}/persona.md').writeAsStringSync(
        '# persona\n\n## 身份与客观事实\n- 用户在互联网行业工作\n',
        encoding: utf8,
      );
    });

    /// 六源全部脚本化为同一固定指纹：未变即命中，与磁盘实况无关。
    Map<String, SourceFileFingerprint> fixedFingerprints(
      Directory memoryDirectory,
      SourceFileFingerprint fingerprint,
    ) => {
      for (final name in _sourceFileNames)
        _sourcePath(memoryDirectory, name): fingerprint,
    };

    test('指纹未变时整轮复用缓存：零重读、注入逐字节不变', () async {
      final memoryDirectory = await seedThreeLayers();
      addTearDown(() => memoryDirectory.parent.delete(recursive: true));

      final io = _ScriptedSourceIo(
        fingerprints: fixedFingerprints(
          memoryDirectory,
          SourceFileFingerprint(modified: DateTime(2026, 9, 1, 12), size: 42),
        ),
      );
      final reader = StatePackReader(
        memoryDirectory: memoryDirectory.path,
        sourceIo: io,
      );

      final first = await reader.readHotLayerBlocks();
      expect(first.failure, isNull);
      // 单次装配六个源文件各读取一次：受控集合三次消费共享一次解析。
      expect(io.readCalls, 6);
      expect(io.statCalls, 6);

      // 磁盘内容在指纹不变的掩护下被改写：若发生重读必然暴露。
      File(_sourcePath(memoryDirectory, 'long-memory.md')).writeAsStringSync(
        '# long-memory\n\n## 重要事件\n- 用户学会了冲浪\n',
        encoding: utf8,
      );

      final second = await reader.readHotLayerBlocks();
      // 指纹校验每轮照常（stat 六次），但文本零重读——命中缓存。
      expect(io.statCalls, 12);
      expect(io.readCalls, 6);
      // 注入与上一轮逐字节一致（仍是旧内容），绝不冒出新内容。
      expect(second.dailyState, first.dailyState);
      expect(second.longMemory, first.longMemory);
      expect(second.longMemory, contains('- 用户完成过一次公开演讲'));
      expect(second.persona, first.persona);
      expect(second.failure, isNull);
    });

    test('单文件变化只重建该层，其余层命中缓存', () async {
      final memoryDirectory = await seedThreeLayers();
      addTearDown(() => memoryDirectory.parent.delete(recursive: true));

      final longMemoryPath = _sourcePath(memoryDirectory, 'long-memory.md');
      final io = _ScriptedSourceIo(
        fingerprints: fixedFingerprints(
          memoryDirectory,
          SourceFileFingerprint(modified: DateTime(2026, 9, 1, 12), size: 42),
        ),
      );
      final reader = StatePackReader(
        memoryDirectory: memoryDirectory.path,
        sourceIo: io,
      );

      final first = await reader.readHotLayerBlocks();
      expect(first.failure, isNull);
      expect(io.readCalls, 6);

      // 只翻新 long-memory 的指纹脚本；磁盘上 long-memory 与 persona
      // 同时改写——重建的层必须读到新内容，命中的层绝不能暴露新内容。
      io.scriptedFingerprints[longMemoryPath] = SourceFileFingerprint(
        modified: DateTime(2026, 9, 2, 8),
        size: 43,
      );
      File(longMemoryPath).writeAsStringSync(
        '# long-memory\n\n## 重要事件\n- 用户学会了冲浪\n',
        encoding: utf8,
      );
      File(_sourcePath(memoryDirectory, 'persona.md')).writeAsStringSync(
        '# persona\n\n## 身份与客观事实\n- 用户改行做音乐了\n',
        encoding: utf8,
      );

      final second = await reader.readHotLayerBlocks();
      expect(second.failure, isNull);
      // 该层重建：新内容进注入。
      expect(second.longMemory, contains('- 用户学会了冲浪'));
      // 其余层命中：persona 仍是旧内容（磁盘新内容被指纹挡住）。
      expect(second.persona, first.persona);
      expect(second.persona, isNot(contains('用户改行做音乐了')));
      expect(second.dailyState, first.dailyState);
      // 只重读 long-memory 一层，其余五源零读取。
      expect(io.readCalls, 7);
      expect(io.readsByPath[longMemoryPath], 2);
      expect(io.readsByPath[_sourcePath(memoryDirectory, 'persona.md')], 1);
    });

    test('文件从有到无：缺席是合法指纹，空缺态照常入缓存', () async {
      final memoryDirectory = await seedThreeLayers();
      addTearDown(() => memoryDirectory.parent.delete(recursive: true));

      final longMemoryPath = _sourcePath(memoryDirectory, 'long-memory.md');
      final io = _ScriptedSourceIo();
      final reader = StatePackReader(
        memoryDirectory: memoryDirectory.path,
        sourceIo: io,
      );

      final first = await reader.readHotLayerBlocks();
      expect(first.failure, isNull);
      expect(first.longMemory, contains('- 用户完成过一次公开演讲'));
      expect(io.readCalls, 6);

      // 从有到无：指纹失配 → 重建 → 读取返回 null。缺席按空文本入
      // 缓存，不当作错误：该块空缺、其余层照常。
      File(longMemoryPath).deleteSync();
      final second = await reader.readHotLayerBlocks();
      expect(second.failure, isNull);
      expect(second.longMemory, '');
      expect(second.dailyState, contains('【关系温度】'));
      expect(second.persona, contains('- 用户在互联网行业工作'));
      expect(io.readCalls, 7);

      // 缺席态命中缓存：继续缺席的下一轮不再重读。
      final third = await reader.readHotLayerBlocks();
      expect(third.failure, isNull);
      expect(third.longMemory, '');
      expect(third.dailyState, contains('【关系温度】'));
      expect(io.readCalls, 7);
    });

    test('stat 报错视为指纹不匹配：重建且异常路径绝不沿用缓存', () async {
      final memoryDirectory = await seedThreeLayers();
      addTearDown(() => memoryDirectory.parent.delete(recursive: true));

      final longMemoryPath = _sourcePath(memoryDirectory, 'long-memory.md');
      final io = _ScriptedSourceIo(fingerprints: {longMemoryPath: null});
      final reader = StatePackReader(
        memoryDirectory: memoryDirectory.path,
        sourceIo: io,
      );

      // stat 报错 → 重建：内容照常读到并注入。
      final first = await reader.readHotLayerBlocks();
      expect(first.failure, isNull);
      expect(first.longMemory, contains('- 用户完成过一次公开演讲'));
      expect(io.readsByPath[longMemoryPath], 1);

      // stat 持续报错 + 磁盘换内容：必须重读出新内容，绝不冒旧。
      File(longMemoryPath).writeAsStringSync(
        '# long-memory\n\n## 重要事件\n- 用户学会了冲浪\n',
        encoding: utf8,
      );
      final second = await reader.readHotLayerBlocks();
      expect(second.failure, isNull);
      expect(second.longMemory, contains('- 用户学会了冲浪'));
      expect(io.readsByPath[longMemoryPath], 2);

      // 异常路径不入缓存：stat 恢复前每轮重新试探读取。
      final third = await reader.readHotLayerBlocks();
      expect(third.failure, isNull);
      expect(third.longMemory, contains('- 用户学会了冲浪'));
      expect(io.readsByPath[longMemoryPath], 3);

      // stat 恢复后重建一次并入缓存，随后不再重读。
      io.scriptedFingerprints.remove(longMemoryPath);
      final fourth = await reader.readHotLayerBlocks();
      expect(fourth.failure, isNull);
      expect(fourth.longMemory, contains('- 用户学会了冲浪'));
      expect(io.readsByPath[longMemoryPath], 4);
      final fifth = await reader.readHotLayerBlocks();
      expect(fifth.failure, isNull);
      expect(fifth.longMemory, contains('- 用户学会了冲浪'));
      expect(io.readsByPath[longMemoryPath], 4);
    });

    test('重建的读取也失败时该块空缺、其余层照常（部分成功语义）', () async {
      final memoryDirectory = await seedThreeLayers();
      addTearDown(() => memoryDirectory.parent.delete(recursive: true));

      final longMemoryPath = _sourcePath(memoryDirectory, 'long-memory.md');
      final io = _ScriptedSourceIo();
      final reader = StatePackReader(
        memoryDirectory: memoryDirectory.path,
        sourceIo: io,
      );

      final first = await reader.readHotLayerBlocks();
      expect(first.failure, isNull);
      expect(first.longMemory, contains('- 用户完成过一次公开演讲'));

      // stat 报错迫使重建，而文件已消失：重建的读取按 readFileIfExists
      // 口径返回 null（缺席与读取失败同义——「存在但不可读」无法跨平
      // 台稳定构造，见本文件顶部说明）。该块空缺、其余层照常注入。
      io.scriptedFingerprints[longMemoryPath] = null;
      File(longMemoryPath).deleteSync();
      final second = await reader.readHotLayerBlocks();
      expect(second.failure, isNull);
      expect(second.longMemory, '');
      expect(second.dailyState, contains('【关系温度】'));
      expect(second.persona, contains('- 用户在互联网行业工作'));

      // 异常路径不入缓存：下一轮照常重试，仍空缺。
      final third = await reader.readHotLayerBlocks();
      expect(third.failure, isNull);
      expect(third.longMemory, '');
      expect(io.readsByPath[longMemoryPath], 3);
    });

    test('并发未命中各自重建：不崩、不脏读，结果同值幂等', () async {
      final memoryDirectory = await _seedMemory((memoryDirectory) async {
        _writeRelationship(memoryDirectory);
        File('${memoryDirectory.path}/daily-state.md').writeAsStringSync(
          '# daily-state\n\n## 近日状态\n- 用户睡前有点累\n',
          encoding: utf8,
        );
        File('${memoryDirectory.path}/open-loops.md').writeAsStringSync(
          '# open-loops\n\n'
          '- [o1] 用户明早想早起跑步\n'
          '  proactive: yes\n'
          '  status: active\n'
          '  due: 2026-08-10\n',
          encoding: utf8,
        );
        File('${memoryDirectory.path}/memory-controls.md').writeAsStringSync(
          '# memory-controls\n## frozen\n## banned\n## deleted\n',
          encoding: utf8,
        );
        File('${memoryDirectory.path}/long-memory.md').writeAsStringSync(
          '# long-memory\n\n## 重要事件\n- 用户完成过一次公开演讲\n',
          encoding: utf8,
        );
        File('${memoryDirectory.path}/persona.md').writeAsStringSync(
          '# persona\n\n## 身份与客观事实\n- 用户在互联网行业工作\n',
          encoding: utf8,
        );
      });
      addTearDown(() => memoryDirectory.parent.delete(recursive: true));

      final reader = StatePackReader(
        memoryDirectory: memoryDirectory.path,
        clock: () => DateTime(2026, 8, 12, 21),
      );

      // 冷缓存上并发六次装配：全部未命中、各自重建，同值幂等。
      final results = await Future.wait([
        for (var i = 0; i < 6; i += 1) reader.readHotLayerBlocks(),
      ]);
      final first = results.first;
      for (final prepared in results) {
        expect(prepared.failure, isNull);
        expect(prepared.dailyState, contains('【关系温度】'));
        expect(prepared.dailyState, contains('【未闭环事项】'));
        expect(prepared.longMemory, contains('- 用户完成过一次公开演讲'));
        expect(prepared.persona, contains('- 用户在互联网行业工作'));
        expect(prepared.longMemory, first.longMemory);
        expect(prepared.dailyState, first.dailyState);
        expect(prepared.persona, first.persona);
      }
    });

    test('open-loops 存在但不可读时近况层如实失败，其余层照常', () async {
      // 恢复 OpenLoopStore.readItems 的既有上抛口径（评审裁定
      // 2026-09-08）：「存在但读取失败」不是缺席，近况层整层失败并
      // 如实记入 failure，绝不吞成空投影；文件缺席才按空表处理。
      final memoryDirectory = await _seedMemory((memoryDirectory) async {
        _writeRelationship(memoryDirectory);
        File('${memoryDirectory.path}/open-loops.md').writeAsStringSync(
          '# open-loops\n\n'
          '- [o1] 用户明早想早起跑步\n'
          '  proactive: yes\n'
          '  status: active\n',
          encoding: utf8,
        );
        File('${memoryDirectory.path}/long-memory.md').writeAsStringSync(
          '# long-memory\n\n## 重要事件\n- 用户完成过一次公开演讲\n',
          encoding: utf8,
        );
        File('${memoryDirectory.path}/persona.md').writeAsStringSync(
          '# persona\n\n## 身份与客观事实\n- 用户在互联网行业工作\n',
          encoding: utf8,
        );
      });
      addTearDown(() => memoryDirectory.parent.delete(recursive: true));

      final loopsPath = _sourcePath(memoryDirectory, 'open-loops.md');
      final readError = const FileSystemException('注入的 open-loops 读取故障');
      final io = _ScriptedSourceIo(readErrors: {loopsPath: readError});
      final reader = StatePackReader(
        memoryDirectory: memoryDirectory.path,
        sourceIo: io,
      );

      final prepared = await reader.readHotLayerBlocks();
      // 近况层失败保持原值（null），failure 是原样上抛的读取错误；
      // 票 05：其余两层照常读取注入。
      expect(prepared.dailyState, isNull);
      expect(prepared.failure, same(readError));
      expect(prepared.longMemory, contains('- 用户完成过一次公开演讲'));
      expect(prepared.persona, contains('- 用户在互联网行业工作'));

      final builder = prepared.applyTo(_initialBuilder);
      expect(builder.dailyState, '原近况');
      expect(builder.longMemory, contains('- 用户完成过一次公开演讲'));
      expect(builder.persona, contains('- 用户在互联网行业工作'));
    });

    test('指纹未变且有可见 open-loop 时缓存路径零重读；OpenLoopStore 内部直读不在覆盖范围', () async {
      final memoryDirectory = await _seedMemory((memoryDirectory) async {
        _writeRelationship(memoryDirectory);
        File('${memoryDirectory.path}/open-loops.md').writeAsStringSync(
          '# open-loops\n\n'
          '- [o1] 买牛奶\n'
          '  proactive: yes\n'
          '  status: active\n',
          encoding: utf8,
        );
        File('${memoryDirectory.path}/long-memory.md').writeAsStringSync(
          '# long-memory\n\n## 重要事件\n- 用户完成过一次公开演讲\n',
          encoding: utf8,
        );
        File('${memoryDirectory.path}/persona.md').writeAsStringSync(
          '# persona\n\n## 身份与客观事实\n- 用户在互联网行业工作\n',
          encoding: utf8,
        );
      });
      addTearDown(() => memoryDirectory.parent.delete(recursive: true));

      final loopsPath = _sourcePath(memoryDirectory, 'open-loops.md');
      final io = _ScriptedSourceIo(
        fingerprints: fixedFingerprints(
          memoryDirectory,
          SourceFileFingerprint(modified: DateTime(2026, 9, 1, 12), size: 42),
        ),
      );
      final reader = StatePackReader(
        memoryDirectory: memoryDirectory.path,
        sourceIo: io,
      );

      final first = await reader.readHotLayerBlocks();
      expect(first.failure, isNull);
      expect(first.dailyState, contains('【未闭环事项】'));
      expect(first.dailyState, contains('- [o1] 买牛奶'));
      expect(first.dailyState, contains('主动跟进纪律'));
      // 缓存路径单次装配六源各读一次（seam 计数）。
      expect(io.readCalls, 6);
      expect(io.statCalls, 6);

      // 指纹掩护下改写 open-loops 磁盘内容：命中轮绝不暴露新内容。
      File(loopsPath).writeAsStringSync(
        '# open-loops\n\n'
        '- [o1] 买酱油\n'
        '  proactive: yes\n'
        '  status: active\n',
        encoding: utf8,
      );

      final second = await reader.readHotLayerBlocks();
      expect(second.failure, isNull);
      expect(second.dailyState, first.dailyState);
      expect(second.dailyState, contains('- [o1] 买牛奶'));
      expect(second.dailyState, isNot(contains('买酱油')));
      // 覆盖边界：OpenLoopStore 为 final 类、不在本次允许改动清单内，
      // proactiveCandidates 每轮内部对 open-loops 与 memory-controls
      // 各有一次真实直读，不经本 seam 计数、缓存也不覆盖。本断言只锁
      // 缓存路径（指纹校验每轮照常、缓存文本零重读），不声称全源零
      // 磁盘读取。
      expect(io.statCalls, 12);
      expect(io.readCalls, 6);
    });
  });
}
