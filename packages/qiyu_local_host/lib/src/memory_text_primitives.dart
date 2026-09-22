import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'memory_controls.dart';

/// 长期记忆与关系投影共享的文本原语：文本规范化、受控判定谓词与两个
/// 受管 Markdown 文件（long-memory.md / relationship.md）的解析。读侧
/// 损坏判定与展示侧解析共用同一份实现，理解一行格式只看这一处。

/// 规范化用于文字比较：折叠空白并统一大小写；不改变落盘原文。
String normalizeMemoryText(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').toLowerCase().trim();

/// 记忆原文级的受控筛查谓词：先经 [normalizeMemoryText] 归一化，再按
/// [bannedTitleMatches] 的包含规则匹配。注入过滤、提炼闸门与删除清除
/// 的「原文 + 受控集合」判断统一走这里，不再各自拼组合。
bool bannedMemoryText(String text, Set<String> bannedTitles) =>
    bannedTitleMatches(normalizeMemoryText(text), bannedTitles);

/// long-memory 四分区（T03 定稿，顺序固定）。
const longMemorySections = ['人与关系', '重要事件', '模式与轨迹', '共同过往'];

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

/// 从 relationship.md 解析出的受管结构。
final class ParsedRelationship {
  const ParsedRelationship({
    required this.stage,
    required this.since,
    required this.confirmed,
    required this.probes,
    required this.recentChanges,
  });

  final RelationshipStage stage;
  final String since;
  final List<String> confirmed;
  final List<String> probes;
  final List<String> recentChanges;
}

/// wire 名 → 关系阶段；未知 wire 返回 null（供调用方按各自语义回退）。
/// core 的 fromWireName 失败会抛，与宿主「解析失败退值」口径不同，
/// 这里保持本地实现。
RelationshipStage? relationshipStageFromWire(String value) {
  for (final stage in RelationshipStage.values) {
    if (stage.wireName == value) {
      return stage;
    }
  }
  return null;
}

/// 解析受管结构的 relationship.md；不是受管结构（用户手写其它内容）
/// 返回 null，调用方一切写操作都必须原样保留该文件。
ParsedRelationship? parseRelationshipFile(String contents) {
  final lines = contents.replaceAll('\r\n', '\n').split('\n');
  var sawHeader = false;
  RelationshipStage? stage;
  String? since;
  String? description;
  var section = '';
  var inProbe = false;
  final confirmed = <String>[];
  final probes = <String>[];
  final recent = <String>[];
  for (final rawLine in lines) {
    final trimmed = rawLine.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    if (trimmed == '# relationship') {
      sawHeader = true;
      continue;
    }
    if (!sawHeader || (trimmed.startsWith('#') && !trimmed.startsWith('## '))) {
      return null;
    }
    if (trimmed.startsWith('## ')) {
      section = trimmed;
      inProbe = false;
      continue;
    }
    final stageMatch = RegExp(r'^stage\s*[:：]\s*(.+)$').firstMatch(trimmed);
    if (stageMatch != null) {
      final value = stageMatch.group(1)!.trim();
      final parsed = relationshipStageFromWire(value);
      if (parsed == null) {
        return null;
      }
      stage = parsed;
      continue;
    }
    final sinceMatch = RegExp(
      r'^since\s*[:：]\s*(\d{4}-\d{2}-\d{2})$',
    ).firstMatch(trimmed);
    if (sinceMatch != null) {
      since = sinceMatch.group(1);
      continue;
    }
    if (RegExp(r'^阶段描述\s*[:：]').hasMatch(trimmed)) {
      description = trimmed;
      continue;
    }
    if (section == '## 当前相处方式' &&
        (trimmed == '已确认：' || trimmed == '待试探：')) {
      inProbe = trimmed == '待试探：';
      continue;
    }
    if (trimmed.startsWith('- ')) {
      switch (section) {
        case '## 当前相处方式':
          (inProbe ? probes : confirmed).add(trimmed);
          continue;
        case '## 近期变化':
          recent.add(trimmed);
          continue;
      }
    }
    // 受管结构之外的内容：视为手写文件，整体不可改写。
    return null;
  }
  if (!sawHeader || stage == null || since == null || description == null) {
    return null;
  }
  return ParsedRelationship(
    stage: stage,
    since: since,
    confirmed: confirmed,
    probes: probes,
    recentChanges: recent,
  );
}
