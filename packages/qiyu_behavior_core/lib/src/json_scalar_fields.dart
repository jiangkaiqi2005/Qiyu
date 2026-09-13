import 'dart:convert';

/// 文本中 JSON 标量字段的解码语义与原始值位置，供安全边界精确替换。
final class JsonScalarField {
  const JsonScalarField({
    required this.key,
    required this.stringValue,
    required this.keyStart,
    required this.keyEnd,
    required this.valueStart,
    required this.valueEnd,
  });

  final String key;
  // 数字值用 null 表示；识别凭据只依赖键名，不改变原始数字的精度。
  final String? stringValue;
  final int keyStart;
  final int keyEnd;
  final int valueStart;
  final int valueEnd;
}

// 非字段字符串也整段消费，避免把普通字符串中的转义引号误当字段。
final _jsonScalarFieldPattern = RegExp(
  r'("(?:[^"\\]|\\.)*")'
  r'(?:\s*:\s*("(?:[^"\\]|\\.)*"|'
  r'-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?'
  r'(?=\s*(?:[,}\]]|$))))?',
);

Iterable<JsonScalarField> jsonScalarFields(String text) sync* {
  for (final match in _jsonScalarFieldPattern.allMatches(text)) {
    final rawValue = match.group(2);
    if (rawValue == null) continue;
    try {
      final key = jsonDecode(match.group(1)!) as String;
      final value = rawValue.startsWith('"')
          ? jsonDecode(rawValue) as String
          : null;
      yield JsonScalarField(
        key: key,
        stringValue: value,
        keyStart: match.start,
        keyEnd: match.start + match.group(1)!.length,
        valueStart: match.end - rawValue.length,
        valueEnd: match.end,
      );
    } on FormatException {
      // 非法 JSON 转义不作语义猜测，由调用方既有文本规则继续处理。
    }
  }
}
