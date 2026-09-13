import 'dart:convert';

final _bareCookieTextValuePattern = RegExp(r'^[A-Za-z0-9._~+/=-]{10,}');

/// 延续文本 Cookie 的长裸值规则，不用于 JSON Cookie 字段的食品描述。
bool isBareCookieTextValue(String value, {bool quoted = false}) {
  final match = _bareCookieTextValuePattern.firstMatch(value);
  return match != null && (!quoted || match.end == value.length);
}

/// 三个捕获组依次为前缀、键名、完整值；成对引号内允许空白与分隔符。
RegExp credentialTextPattern(String keys) => RegExp(
  '(($keys)'
  r'\s*[:=：]\s*)('
  r""""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"""
  r'|\[已脱敏\]'
  r"""(?=$|[\s；;，,。.!！?？）)\]}"'])"""
  r'|[^\s；;，,]+)',
  caseSensitive: false,
);

final _cookieContinuationSeparator = RegExp(r'[ \t]*[;；][ \t]*');
// Cookie 名采用 HTTP token 词法，点号等合法名称字符不应终止后续检查。
const _cookieName = r"[!#$%&'*+.^_`|~0-9A-Za-z-]+";
final _cookieContinuationName = RegExp(
  '($_cookieName)'
  r'[ \t]*(=)?[ \t]*',
);
final _cookieContinuationBoundary = RegExp(r'(?=[;；,，\r\n]|$)');
final _cookieContinuationValue = credentialTextPattern(_cookieName);

/// 从已确认的引号 Cookie 值之后继续检查分号项，逗号或换行结束归属。
Iterable<({int start, int end})> cookieTextContinuationValues(
  String text,
  int offset,
) sync* {
  while (offset < text.length) {
    final separator = _cookieContinuationSeparator.matchAsPrefix(text, offset);
    if (separator == null) return;
    offset = separator.end;
    if (_cookieContinuationBoundary.matchAsPrefix(text, offset) != null) {
      continue;
    }
    final name = _cookieContinuationName.matchAsPrefix(text, offset);
    if (name == null) return;
    if (name.group(2) == null ||
        _cookieContinuationBoundary.matchAsPrefix(text, name.end) != null) {
      // 空项、空值及无值标志保持原文，但不能取消后续分号项的归属。
      offset = name.end;
      continue;
    }
    final match = _cookieContinuationValue.matchAsPrefix(text, offset);
    if (match == null) return;
    final rawValue = match.group(3)!;
    final value = credentialTextValue(rawValue);
    if (value.text.trim().isNotEmpty && value.text != '[已脱敏]') {
      final start = match.end - rawValue.length;
      yield (start: start + value.start, end: start + value.end);
    }
    offset = match.end;
  }
}

/// 返回值语义与引号内的替换区间；普通未加引号值使用整个区间。
({String text, int start, int end}) credentialTextValue(String rawValue) {
  final quoted =
      rawValue.length >= 2 &&
      ((rawValue.startsWith('"') && rawValue.endsWith('"')) ||
          (rawValue.startsWith("'") && rawValue.endsWith("'")));
  if (!quoted) return (text: rawValue, start: 0, end: rawValue.length);
  final inner = rawValue.substring(1, rawValue.length - 1);
  var text = inner;
  if (rawValue.startsWith('"')) {
    try {
      text = jsonDecode(rawValue) as String;
    } on FormatException {
      // 不完整 JSON 转义仍按原有文本凭据检查，不因解码失败放行。
    }
  } else {
    text = inner.replaceAllMapped(
      RegExp(r"\\(['\\])"),
      (match) => match.group(1)!,
    );
  }
  return (text: text, start: 1, end: rawValue.length - 1);
}
