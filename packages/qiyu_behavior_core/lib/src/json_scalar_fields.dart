import 'dart:convert';

/// JSON 键、标量字段或数组字符串的解码语义与原始位置。
final class JsonScalarField {
  const JsonScalarField({
    required this.key,
    required this.stringValue,
    required this.start,
    required this.valueStart,
    required this.valueEnd,
  });

  // 键自身和数组元素没有所属字段名。
  final String? key;
  // 数字值用 null 表示；识别凭据只依赖键名，不改变原始数字的精度。
  final String? stringValue;
  final int start;
  final int valueStart;
  final int valueEnd;
}

// 只消费完整标量字段；孤立引号和非法裸控制字符不能吞掉后面的 JSON。
final _jsonScalarFieldPattern = RegExp(
  r'("(?:[^\x00-\x1F"\\]|\\.)*")\s*:\s*'
  r'("(?:[^\x00-\x1F"\\]|\\.)*"|'
  r'-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?'
  r'(?=\s*(?:[,}\]]|$)))'
  r'|(?<=[\[,])\s*("(?:[^\x00-\x1F"\\]|\\.)*")(?=\s*[,\]])'
  r'|("(?:[^\x00-\x1F"\\]|\\.)*")'
  r'(?=\s*:\s*(?:[\[{]|true\b|false\b|null\b))',
);

Iterable<JsonScalarField> jsonScalarFields(String text) sync* {
  for (final match in _jsonScalarFieldPattern.allMatches(text)) {
    final rawValue = match.group(2) ?? match.group(3);
    try {
      final rawKey = match.group(1) ?? match.group(4);
      final key = rawKey == null ? null : jsonDecode(rawKey) as String;
      final value = rawValue != null && rawValue.startsWith('"')
          ? jsonDecode(rawValue) as String
          : null;
      if (rawKey != null) {
        yield JsonScalarField(
          key: null,
          stringValue: key,
          start: match.start,
          valueStart: match.start,
          valueEnd: match.start + rawKey.length,
        );
      }
      if (rawValue == null) continue;
      yield JsonScalarField(
        key: key,
        stringValue: value,
        start: match.start + (rawKey?.length ?? 0),
        valueStart: match.end - rawValue.length,
        valueEnd: match.end,
      );
    } on FormatException {
      // 非法 JSON 转义不作语义猜测，由调用方既有文本规则继续处理。
    }
  }
}

/// 当前文本中需要替换的半开区间；位置按 Dart 字符串的 UTF-16 计。
final class JsonTextReplacement {
  const JsonTextReplacement(this.start, this.end, this.value);

  final int start;
  final int end;
  final String value;
}

/// 检查解码后的字符串，包括字符串中再次序列化的 JSON。
/// 只把实际替换映射回原串，保留每处未改变文本的转义和排版。
String rewriteJsonStringValues(
  String text, {
  required bool Function(String key, String? value) isSecret,
  required Iterable<JsonTextReplacement> Function(String text, bool decoded)
  rewriteText,
}) {
  final stack = [_JsonRewriteFrame(text, decoded: false)];
  while (true) {
    final frame = stack.last;
    if (frame.fields.moveNext()) {
      final field = frame.fields.current;
      frame.addTextReplacements(field.start, rewriteText);
      frame.cursor = field.valueEnd;
      if (field.key != null && isSecret(field.key!, field.stringValue)) {
        frame.replacements.add(
          JsonTextReplacement(field.valueStart, field.valueEnd, '"[已脱敏]"'),
        );
      } else if (field.stringValue != null) {
        frame.pending = field;
        stack.add(_JsonRewriteFrame(field.stringValue!, decoded: true));
      }
      continue;
    }
    frame.addTextReplacements(frame.text.length, rewriteText);
    stack.removeLast();
    if (stack.isEmpty) {
      final buffer = StringBuffer();
      var cursor = 0;
      for (final replacement in frame.replacements) {
        buffer.write(text.substring(cursor, replacement.start));
        buffer.write(replacement.value);
        cursor = replacement.end;
      }
      buffer.write(text.substring(cursor));
      return buffer.toString();
    }
    final parent = stack.last;
    final field = parent.pending!;
    // jsonDecode 已确认该字符串有效；只扫描替换端点，不分配逐字符映射表。
    var rawOffset = field.valueStart + 1;
    var decodedOffset = 0;
    int rawEndpoint(int endpoint) {
      while (decodedOffset < endpoint) {
        rawOffset += parent.text.codeUnitAt(rawOffset) != 92
            ? 1
            : parent.text.codeUnitAt(rawOffset + 1) == 117
            ? 6
            : 2;
        decodedOffset += 1;
      }
      return rawOffset;
    }

    for (final replacement in frame.replacements) {
      final start = rawEndpoint(replacement.start);
      final end = rawEndpoint(replacement.end);
      final encoded = jsonEncode(replacement.value);
      parent.replacements.add(
        JsonTextReplacement(
          start,
          end,
          encoded.substring(1, encoded.length - 1),
        ),
      );
    }
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
  final replacements = <JsonTextReplacement>[];
  var cursor = 0;
  JsonScalarField? pending;

  void addTextReplacements(
    int end,
    Iterable<JsonTextReplacement> Function(String text, bool decoded)
    rewriteText,
  ) {
    for (final replacement in rewriteText(
      text.substring(cursor, end),
      decoded,
    )) {
      replacements.add(
        JsonTextReplacement(
          cursor + replacement.start,
          cursor + replacement.end,
          replacement.value,
        ),
      );
    }
  }
}
