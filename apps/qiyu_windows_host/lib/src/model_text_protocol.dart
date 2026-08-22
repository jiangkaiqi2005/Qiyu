// 记忆整理域模型调用共用的文本协议工具：输入侧的空分节占位渲染与
// 输出侧的 JSON 对象提取。日终理解（daily_understanding）与 Dream
// （dream）是同一协议的两个消费方，实现只此一份。
import 'dart:convert';

/// 从模型输出中提取 JSON 对象：容忍代码块围栏与前后多余文字，
/// 只取第一个 `{` 到最后一个 `}` 之间的内容；无法解析或不是对象时
/// 返回 null。
Map<String, Object?>? extractJsonObject(String raw) {
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

/// 模型输入的分节内容渲染：空白内容显示占位「（无）」，否则原样
/// 返回去除首尾空白后的正文。
String sectionOrEmpty(String? contents) {
  final trimmed = contents?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return '（无）';
  }
  return trimmed;
}
