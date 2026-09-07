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

/// 各 qiyu-* 元数据标记的读取端正则（同样唯一权威）：会话、episode、
/// checkpoint、dream-state、恢复报告等解析端共用这一组具名正则，
/// 任何文件都不允许另写变体副本。
final sessionMetaMarkerPattern = RegExp(
  r'^<!-- qiyu-session:([A-Za-z0-9_-]+) -->\r?$',
  multiLine: true,
);
final sessionTurnMarkerPattern = RegExp(
  r'^<!-- qiyu-turn:([A-Za-z0-9_-]+) -->\r?$',
  multiLine: true,
);
final episodeMetaPattern = RegExp(
  r'^<!-- qiyu-episode:([A-Za-z0-9_-]+) -->\r?$',
  multiLine: true,
);

/// 日文件「存在栖语元数据标记」的快速判断（只匹配标记前缀）。
final episodeMetaPresentPattern = RegExp(
  r'^<!-- qiyu-episode:',
  multiLine: true,
);
final episodeEntryMarkerPattern = RegExp(
  r'^<!-- qiyu-episode-entry:([A-Za-z0-9_-]+) -->\r?$',
  multiLine: true,
);
final dreamStateMarkerPattern = RegExp(
  r'^<!-- qiyu-dream-state:([A-Za-z0-9_-]+) -->\r?$',
  multiLine: true,
);
final checkpointMetaPattern = RegExp(
  r'^<!-- qiyu-checkpoint:([A-Za-z0-9_-]+) -->\r?$',
  multiLine: true,
);
final recoveryReportMarkerPattern = RegExp(
  r'^<!-- qiyu-recovery-report:([A-Za-z0-9_-]+) -->\r?$',
  multiLine: true,
);
