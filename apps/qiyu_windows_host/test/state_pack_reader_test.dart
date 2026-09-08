import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

/// 读取阶段故障在外层 Host 入口无法跨平台稳定构造（Dart 的
/// File.exists 对目录返回 false，readFileIfExists 又把不可读吞成
/// null），按 Spec 预案在热层 seam 注入最小故障：只检查准备出的
/// 内容与失败结果，不断言私有调用步骤。
enum _FaultStage { dailyState, longMemory, persona }

class _FaultInjectedReader extends StatePackReader {
  _FaultInjectedReader({required super.memoryDirectory, required this.stage});

  final _FaultStage stage;

  @override
  Future<String> readDailyStateBlock() async {
    if (stage == _FaultStage.dailyState) {
      throw StateError('注入的近况读取故障');
    }
    return super.readDailyStateBlock();
  }

  @override
  Future<String> readLongMemoryBlock() async {
    if (stage == _FaultStage.longMemory) {
      throw StateError('注入的长期印象读取故障');
    }
    return super.readLongMemoryBlock();
  }

  @override
  Future<String> readPersonaBlock() async {
    if (stage == _FaultStage.persona) {
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

  test('近况成功而长期印象读取失败时保留部分成功并保持原值', () async {
    final memoryDirectory = await _seedMemory((memoryDirectory) async {
      _writeRelationship(memoryDirectory);
    });
    addTearDown(() => memoryDirectory.parent.delete(recursive: true));

    final prepared = await _FaultInjectedReader(
      memoryDirectory: memoryDirectory.path,
      stage: _FaultStage.longMemory,
    ).readHotLayerBlocks();

    // 近况已准备成立；长期印象与画像未准备成功，failure 如实上报。
    expect(prepared.dailyState, isNotNull);
    expect(prepared.dailyState, contains('【关系温度】'));
    expect(prepared.longMemory, isNull);
    expect(prepared.persona, isNull);
    expect(prepared.failure, isA<StateError>());

    // 装配进带初始内容的 builder：只有近况被替换，其余两块原值保留。
    final builder = prepared.applyTo(_initialBuilder);
    expect(builder.dailyState, prepared.dailyState);
    expect(builder.longMemory, '原长期印象');
    expect(builder.persona, '原画像');
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

  test('近况读取失败时三块全部保持原值', () async {
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
      stage: _FaultStage.dailyState,
    ).readHotLayerBlocks();

    expect(prepared.dailyState, isNull);
    expect(prepared.longMemory, isNull);
    expect(prepared.persona, isNull);
    expect(prepared.failure, isA<StateError>());

    final builder = prepared.applyTo(_initialBuilder);
    expect(builder.dailyState, '原近况');
    expect(builder.longMemory, '原长期印象');
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

    // 部分失败路径：画像读取在近况与长期印象之后中断，同样不落任何
    // 写入——失败路径与成功路径同律。画像失败只保持画像原值，长期
    // 印象保留本轮读入的新值（票 04）。
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
}
