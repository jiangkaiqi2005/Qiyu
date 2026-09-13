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
  r'(?=\s*(?:[,}\]]|$)))'
  r'|(?<=[\[,])\s*("(?:[^\x00-\x1F"\\]|\\.)*")(?=\s*[,\]])'
  r'|("(?:[^\x00-\x1F"\\]|\\.)*")'
  r'(?=\s*:\s*(?:[\[{]|true\b|false\b|null\b))',
);
final _jsonStringPattern = RegExp(r'"(?:[^\x00-\x1F"\\]|\\.)*"');
final _jsonKeySeparatorPattern = RegExp(r'\s*:');
final _jsonArrayOpeningPattern = RegExp(r'\s*:\s*\[');
final _cookieArrayKeyPattern = RegExp(
  r'^(?:set[- ])?cookie$',
  caseSensitive: false,
);

Iterable<JsonScalarField> jsonScalarFields(
  String text, {
  String? stringOwner,
  Iterable<JsonTextReplacement> Function(String text)? textReplacements,
}) sync* {
  final trimmed = text.trim();
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    try {
      final value = jsonDecode(text) as String;
      final start = text.indexOf('"');
      yield JsonScalarField(
        key: stringOwner,
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
  final contexts = _JsonTextContexts(textReplacements?.call(text) ?? const []);
  final owners = _CookieArrayOwners(text);
  for (final match in _jsonScalarFieldPattern.allMatches(text)) {
    if (contexts.splits(match.start, match.end, anchored: true)) continue;
    owners.advanceTo(match.start);
    final rawValue = match.group(2) ?? match.group(3);
    try {
      final rawKey = match.group(1) ?? match.group(4);
      final key = rawKey == null ? owners.owner : jsonDecode(rawKey) as String;
      if (rawKey != null) owners.clearDirectOwner();
      if (rawValue == null && _cookieArrayKeyPattern.hasMatch(key ?? '')) {
        final opening = _jsonArrayOpeningPattern.matchAsPrefix(text, match.end);
        if (opening != null) owners.markArray(opening.end - 1, key!);
      }
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
      yield* _jsonStringValues(
        text,
        cursor,
        match.start,
        contexts,
        textReplacements,
      );
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
    } finally {
      owners.skipTo(match.end);
    }
  }
  yield* _jsonStringValues(
    text,
    cursor,
    text.length,
    contexts,
    textReplacements,
  );
}

// 只追踪直接数组归属；不解析成员、复制数组或改变原始 primitive 值。
final class _CookieArrayOwners {
  _CookieArrayOwners(this.text);

  final String text;
  final _containers = <({int closing, String? owner})>[];
  var _cursor = 0;
  int? _arrayStart;
  String? _arrayOwner;

  String? get owner => _containers.isEmpty ? null : _containers.last.owner;

  void markArray(int start, String key) {
    _arrayStart = start;
    _arrayOwner = key;
  }

  void clearDirectOwner() {
    if (owner != null) {
      _containers[_containers.length - 1] = (closing: 93, owner: null);
    }
  }

  void skipTo(int end) => _cursor = end;

  void advanceTo(int end) {
    while (_cursor < end) {
      final unit = text.codeUnitAt(_cursor);
      if (unit == 34) {
        final quoted = _jsonStringPattern.matchAsPrefix(text, _cursor);
        if (quoted != null && quoted.end <= end) {
          _cursor = quoted.end;
          continue;
        }
      } else if (unit == 91 || unit == 123) {
        _containers.add((
          closing: unit == 91 ? 93 : 125,
          owner: unit == 91 && _cursor == _arrayStart ? _arrayOwner : null,
        ));
      } else if (unit == 93 || unit == 125) {
        if (_containers.isNotEmpty && _containers.last.closing == unit) {
          _containers.removeLast();
        } else {
          _containers.clear();
        }
      }
      _cursor += 1;
    }
  }
}

Iterable<JsonScalarField> _jsonStringValues(
  String text,
  int start,
  int end,
  _JsonTextContexts contexts,
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
    if (contexts.splits(match.start, match.end)) continue;
    // 延续完整值本身的保护；上下文区间额外阻止候选截走凭据键。
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
  const JsonTextReplacement(
    this.start,
    this.end,
    this.value, {
    this.contextStart,
    this.contextEnd,
  });

  final int start;
  final int end;
  final String value;
  // 完整键值上下文可大于实际替换值，结构候选不能把二者拆开。
  final int? contextStart;
  final int? contextEnd;
}

final class _JsonTextContexts {
  _JsonTextContexts(Iterable<JsonTextReplacement> replacements) {
    final ranges = [
      for (final value in replacements)
        if (value.contextStart != null && value.contextEnd != null)
          (start: value.contextStart!, end: value.contextEnd!),
    ]..sort((left, right) => left.start.compareTo(right.start));
    for (final range in ranges) {
      if (_ranges.isNotEmpty && range.start < _ranges.last.end) {
        final previous = _ranges.removeLast();
        _ranges.add((
          start: previous.start,
          end: range.end > previous.end ? range.end : previous.end,
        ));
      } else {
        _ranges.add(range);
      }
    }
  }

  final _ranges = <({int start, int end})>[];

  bool splits(int start, int end, {bool anchored = false}) {
    var left = 0;
    var right = _ranges.length;
    while (left < right) {
      final middle = (left + right) ~/ 2;
      if (_ranges[middle].end <= start) {
        left = middle + 1;
      } else {
        right = middle;
      }
    }
    for (
      var index = left;
      index < _ranges.length && _ranges[index].start < end;
      index += 1
    ) {
      final range = _ranges[index];
      // 先起始的字段/数组成员保有自己的边界，不能被内部伪引号反抢。
      if (anchored && start < range.start) {
        // 本层匹配应交由值内重判，其越界尾部也不能抢占后续字段。
        _ranges[index] = (start: range.end, end: range.end);
        continue;
      }
      // 独立字符串必须完整包住上下文，不能截走凭据键或值。
      if (!(start < range.start && end >= range.end)) return true;
    }
    return false;
  }
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
        stack.add(
          _JsonRewriteFrame(
            field.stringValue!,
            true,
            rewriteText,
            stringOwner: _cookieArrayKeyPattern.hasMatch(field.key ?? '')
                ? field.key
                : null,
          ),
        );
      } else if (field._rawStringValue != null) {
        // 无效字符串仍检查内部原文；不猜测转义，也不递归解码。
        // 使用实际内容规则，避免把字符串外的旧引号边界规则搬入值内。
        for (final replacement in rewriteText(field._rawStringValue, true)) {
          frame.replacements.add(
            JsonTextReplacement(
              field.valueStart + 1 + replacement.start,
              field.valueStart + 1 + replacement.end,
              replacement.value,
            ),
          );
        }
      } else if (rewriteText(
        frame.text.substring(field.valueStart, field.valueEnd),
        true,
      ).isNotEmpty) {
        // 数字也保留内容特征检查；命中时替换完整标量，不能破坏 JSON。
        frame.replacements.add(
          JsonTextReplacement(field.valueStart, field.valueEnd, '"[已脱敏]"'),
        );
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
    rewriteText, {
    String? stringOwner,
  }) : fields = jsonScalarFields(
         text,
         // 只让完整字符串继续解码时继承 Cookie，不扩散给内部对象字段。
         stringOwner: stringOwner,
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
