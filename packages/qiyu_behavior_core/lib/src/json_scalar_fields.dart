import 'dart:convert';

/// JSON 键、标量字段或数组字符串的解码语义与原始位置。
final class JsonScalarField {
  const JsonScalarField({
    required this.key,
    required this.stringValue,
    required this.start,
    required this.valueStart,
    required this.valueEnd,
  }) : _rawStringValue = null;

  const JsonScalarField._invalidString({
    required this.key,
    required String rawValue,
    required this.start,
    required this.valueStart,
    required this.valueEnd,
  }) : stringValue = null,
       _rawStringValue = rawValue;

  // 键自身和普通数组元素没有所属字段名；多项 Cookie 继承其字段名。
  final String? key;
  // 已解码字符串；数字和无效字符串用 null 表示，不改变原始数字精度。
  final String? stringValue;
  // 无效值保留原始内部文本供凭据判断，不当成已解码字符串继续遍历。
  final String? _rawStringValue;
  final int start;
  final int valueStart;
  final int valueEnd;
}

// 只消费完整标量字段；孤立引号和非法裸控制字符不能吞掉后面的 JSON。
final _jsonScalarFieldPattern = RegExp(
  r'("(?:[^\x00-\x1F"\\]|\\.)*")\s*:\s*'
  r'("(?:[^\x00-\x1F"\\]|\\.)*"|'
  r'-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?'
  r'(?=\s*(?:[,}\]]|$))'
  r'|\[\s*(?:"(?:[^\x00-\x1F"\\]|\\.)*"'
  r'(?:\s*,\s*"(?:[^\x00-\x1F"\\]|\\.)*")*)?\s*\])'
  r'|(?<=[\[,])\s*("(?:[^\x00-\x1F"\\]|\\.)*")(?=\s*[,\]])'
  r'|("(?:[^\x00-\x1F"\\]|\\.)*")'
  r'(?=\s*:\s*(?:[\[{]|true\b|false\b|null\b))',
);
final _jsonStringPattern = RegExp(r'"(?:[^\x00-\x1F"\\]|\\.)*"');
final _jsonKeySeparatorPattern = RegExp(r'\s*:');
final _cookieArrayKeyPattern = RegExp(
  r'^(?:set[- ])?cookie$',
  caseSensitive: false,
);

Iterable<JsonScalarField> jsonScalarFields(
  String text, {
  Iterable<JsonTextReplacement> Function(String text)? textReplacements,
}) sync* {
  final trimmed = text.trim();
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    try {
      final value = jsonDecode(text) as String;
      final start = text.indexOf('"');
      yield JsonScalarField(
        key: null,
        stringValue: value,
        start: start,
        valueStart: start,
        valueEnd: start + trimmed.length,
      );
      return;
    } on FormatException {
      // 非完整字符串仍按字段和数组元素定位，不吞掉相邻 JSON 片段。
    }
  }
  var cursor = 0;
  for (final match in _jsonScalarFieldPattern.allMatches(text)) {
    final rawValue = match.group(2) ?? match.group(3);
    try {
      final rawKey = match.group(1) ?? match.group(4);
      final key = rawKey == null ? null : jsonDecode(rawKey) as String;
      // 仅识别完整字符串数组，由 JSON 解码器验证整组语法。
      final arrayValues = rawValue != null && rawValue.startsWith('[')
          ? jsonDecode(rawValue) as List<Object?>
          : null;
      String? value;
      String? invalidValue;
      if (rawValue != null && rawValue.startsWith('"')) {
        try {
          value = jsonDecode(rawValue) as String;
        } on FormatException {
          // 值失败不能丢弃已确认的键语义；不猜测非法转义的解码结果。
          invalidValue = rawValue.substring(1, rawValue.length - 1);
        }
      }
      // 字段优先：普通文本的孤立引号不能与字段开引号拼成候选后吞掉字段。
      yield* _jsonStringValues(text, cursor, match.start, textReplacements);
      cursor = match.end;
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
      if (arrayValues != null) {
        final arrayStart = match.end - rawValue.length;
        // 多项 Cookie 保留所属键；其他数组沿用独立字符串的既有语义。
        final owner = _cookieArrayKeyPattern.hasMatch(key ?? '') ? key : null;
        var index = 0;
        for (final item in _jsonStringPattern.allMatches(rawValue)) {
          yield JsonScalarField(
            key: owner,
            stringValue: arrayValues[index++] as String,
            start: arrayStart + item.start,
            valueStart: arrayStart + item.start,
            valueEnd: arrayStart + item.end,
          );
        }
        continue;
      }
      if (invalidValue != null) {
        yield JsonScalarField._invalidString(
          key: key,
          rawValue: invalidValue,
          start: match.start + (rawKey?.length ?? 0),
          valueStart: match.end - rawValue.length,
          valueEnd: match.end,
        );
        continue;
      }
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
  yield* _jsonStringValues(text, cursor, text.length, textReplacements);
}

Iterable<JsonScalarField> _jsonStringValues(
  String text,
  int start,
  int end,
  Iterable<JsonTextReplacement> Function(String text)? textReplacements,
) sync* {
  if (start == end) return;
  final replacements =
      textReplacements?.call(text.substring(start, end)).toList() ??
      const <JsonTextReplacement>[];
  var replacementIndex = 0;
  for (final match in _jsonStringPattern.allMatches(text, start)) {
    if (match.end > end) break;
    // 字段值含非法转义时，键仍留给原文兜底，不能被独立字符串拆走。
    if (_jsonKeySeparatorPattern.matchAsPrefix(text, match.end) != null) {
      continue;
    }
    // 完整带引号的文本凭据留在原上下文，不能拆开 password: 与其值。
    while (replacementIndex < replacements.length &&
        replacements[replacementIndex].end < match.end - 1 - start) {
      replacementIndex += 1;
    }
    if (replacementIndex < replacements.length &&
        replacements[replacementIndex].start <= match.start + 1 - start) {
      continue;
    }
    try {
      yield JsonScalarField(
        key: null,
        stringValue: jsonDecode(match.group(0)!) as String,
        start: match.start,
        valueStart: match.start,
        valueEnd: match.end,
      );
    } on FormatException {
      // 无效转义保留给既有文本规则。
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
  final stack = [_JsonRewriteFrame(text, false, rewriteText)];
  while (true) {
    final frame = stack.last;
    if (frame.fields.moveNext()) {
      final field = frame.fields.current;
      frame.addTextReplacements(field.start, rewriteText);
      frame.cursor = field.valueEnd;
      if (field.key != null &&
          isSecret(field.key!, field.stringValue ?? field._rawStringValue)) {
        frame.replacements.add(
          JsonTextReplacement(field.valueStart, field.valueEnd, '"[已脱敏]"'),
        );
      } else if (field.stringValue != null) {
        frame.pending = field;
        stack.add(_JsonRewriteFrame(field.stringValue!, true, rewriteText));
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
  _JsonRewriteFrame(
    this.text,
    this.decoded,
    Iterable<JsonTextReplacement> Function(String text, bool decoded)
    rewriteText,
  ) : fields = jsonScalarFields(
        text,
        textReplacements: (value) => rewriteText(value, decoded),
      ).iterator;

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
