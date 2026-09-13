import 'dart:convert';

/// JSON 标量字段或数组字符串的解码语义与原始位置。
final class JsonScalarField {
  const JsonScalarField({
    required this.key,
    required this.stringValue,
    required this.start,
    required this.valueStart,
    required this.valueEnd,
  });

  // 数组元素没有键。
  final String? key;
  // 数字值用 null 表示；识别凭据只依赖键名，不改变原始数字的精度。
  final String? stringValue;
  final int start;
  final int valueStart;
  final int valueEnd;
}

// 只消费完整标量字段；自由文本中的孤立引号不能吞掉后面的 JSON。
final _jsonScalarFieldPattern = RegExp(
  r'("(?:[^"\\]|\\.)*")\s*:\s*'
  r'("(?:[^"\\]|\\.)*"|'
  r'-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?'
  r'(?=\s*(?:[,}\]]|$)))'
  r'|(?<=[\[,])\s*("(?:[^"\\]|\\.)*")(?=\s*[,\]])',
);

Iterable<JsonScalarField> jsonScalarFields(String text) sync* {
  for (final match in _jsonScalarFieldPattern.allMatches(text)) {
    final rawValue = (match.group(2) ?? match.group(3))!;
    try {
      final rawKey = match.group(1);
      final key = rawKey == null ? null : jsonDecode(rawKey) as String;
      final value = rawValue.startsWith('"')
          ? jsonDecode(rawValue) as String
          : null;
      yield JsonScalarField(
        key: key,
        stringValue: value,
        start: match.start,
        valueStart: match.end - rawValue.length,
        valueEnd: match.end,
      );
    } on FormatException {
      // 非法 JSON 转义不作语义猜测，由调用方既有文本规则继续处理。
    }
  }
}

/// 检查解码后的字符串，包括字符串中再次序列化的 JSON。
/// 已解析的键和值不会再次进入文本兜底；仅变化的值重新编码。
String rewriteJsonStringValues(
  String text, {
  required bool Function(String key, String? value) isSecret,
  required String Function(String text, bool decoded) rewriteText,
}) {
  final stack = [_JsonRewriteFrame(text, decoded: false)];
  while (true) {
    final frame = stack.last;
    if (frame.fields.moveNext()) {
      final field = frame.fields.current;
      frame.buffer.write(
        rewriteText(
          frame.text.substring(frame.cursor, field.start),
          frame.decoded,
        ),
      );
      frame.buffer.write(frame.text.substring(field.start, field.valueStart));
      frame.cursor = field.valueEnd;
      if (field.key != null && isSecret(field.key!, field.stringValue)) {
        frame.buffer.write('"[已脱敏]"');
      } else if (field.stringValue != null) {
        frame.pending = field;
        stack.add(_JsonRewriteFrame(field.stringValue!, decoded: true));
      } else {
        frame.buffer.write(
          frame.text.substring(field.valueStart, field.valueEnd),
        );
      }
      continue;
    }
    frame.buffer.write(
      rewriteText(frame.text.substring(frame.cursor), frame.decoded),
    );
    final result = frame.buffer.toString();
    stack.removeLast();
    if (stack.isEmpty) return result;
    final parent = stack.last;
    final field = parent.pending!;
    parent.buffer.write(
      result == field.stringValue
          ? parent.text.substring(field.valueStart, field.valueEnd)
          : jsonEncode(result),
    );
    parent.pending = null;
  }
}

// 用显式栈遍历逐层解码的字符串，避免输入嵌套深度消耗调用栈。
final class _JsonRewriteFrame {
  _JsonRewriteFrame(this.text, {required this.decoded})
    : fields = jsonScalarFields(text).iterator;

  final String text;
  final bool decoded;
  final Iterator<JsonScalarField> fields;
  final buffer = StringBuffer();
  var cursor = 0;
  JsonScalarField? pending;
}
