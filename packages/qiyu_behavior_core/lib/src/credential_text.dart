import 'dart:convert';

final _bareCookieTextValuePattern = RegExp(r'^[A-Za-z0-9._~+/=-]{10,}');

/// 延续文本 Cookie 的长裸值规则，不用于 JSON Cookie 字段的食品描述。
bool isBareCookieTextValue(String value) =>
    _bareCookieTextValuePattern.hasMatch(value);

/// 三个捕获组依次为前缀、键名、完整值；成对引号内允许空白与分隔符。
RegExp credentialTextPattern(String keys) => RegExp(
  '(($keys)'
  r'\s*[:=：]\s*)('
  r"""(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\[已脱敏\])"""
  r"""(?=$|[\s；;，,。.!！?？）)\]}"'])"""
  r'|[^\s；;，,]+)',
  caseSensitive: false,
);

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
