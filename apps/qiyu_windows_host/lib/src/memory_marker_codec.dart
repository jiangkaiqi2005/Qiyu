import 'dart:convert';

/// 记忆 Markdown 元数据标记（`<!-- qiyu-*:payload -->`）载荷格式的
/// 唯一权威实现：会话、episode、checkpoint、月摘要、备份清单等全部
/// 记忆文件的写入端与解析端共用这一对函数，任何一侧都不允许另写
/// 变体。编码为 base64url 并丢弃 `=` 填充，解码时按 4 字节对齐补回。
String encodeMarkerPayload(Map<String, Object?> value) =>
    base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

/// [encodeMarkerPayload] 的逆变换；载荷非法时抛出解析异常。
Map<String, Object?> decodeMarkerPayload(String value) {
  final padded = value.padRight(value.length + (4 - value.length % 4) % 4, '=');
  return jsonDecode(utf8.decode(base64Url.decode(padded)))
      as Map<String, Object?>;
}
