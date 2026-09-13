import 'dart:convert';

/// 文本中 JSON 标量字段的解码语义与原始值位置，供安全边界精确替换。
final class JsonScalarField {
  const JsonScalarField({
    required this.key,
    required this.stringValue,
    required this.valueStart,
    required this.valueEnd,
  });

  final String key;
  // 数字值用 null 表示；识别凭据只依赖键名，不改变原始数字的精度。
  final String? stringValue;
  final int valueStart;
  final int valueEnd;
}

// 只消费完整标量字段；自由文本中的孤立引号不能吞掉后面的 JSON。
final _jsonScalarFieldPattern = RegExp(
  r'("(?:[^"\\]|\\.)*")\s*:\s*'
  r'("(?:[^"\\]|\\.)*"|'
  r'-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?'
  r'(?=\s*(?:[,}\]]|$)))',
);

Iterable<JsonScalarField> jsonScalarFields(String text) sync* {
  for (final match in _jsonScalarFieldPattern.allMatches(text)) {
    final rawValue = match.group(2)!;
    try {
      final key = jsonDecode(match.group(1)!) as String;
      final value = rawValue.startsWith('"')
          ? jsonDecode(rawValue) as String
          : null;
      yield JsonScalarField(
        key: key,
        stringValue: value,
        valueStart: match.end - rawValue.length,
        valueEnd: match.end,
      );
    } on FormatException {
      // 非法 JSON 转义不作语义猜测，由调用方既有文本规则继续处理。
    }
  }
}
