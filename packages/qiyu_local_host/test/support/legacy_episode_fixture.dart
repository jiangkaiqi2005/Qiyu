import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';

/// 直接构造旧文件，避免当前写入侧脱敏掩盖读取出口的回归。
Future<void> seedLegacyEpisode(
  String memoryDirectory,
  String date, {
  required String summary,
  String? evidence,
  String? daySummary,
}) async {
  final meta = encodeMarkerPayload({
    'schemaVersion': 1,
    'date': date,
    'updatedAt': '${date}T20:00:00Z',
    'finalized': true,
    'summary': ?daySummary,
  });
  final entry = encodeMarkerPayload({
    'id': 'legacy-entry',
    'sessionId': 'legacy-session',
    'requestId': 'legacy-request',
    'summary': summary,
    'evidence': ?evidence,
    'at': '${date}T20:00:00Z',
  });
  final file = File(
    '$memoryDirectory/episodes/${date.substring(0, 4)}/'
    '${date.substring(5, 7)}/$date.md',
  );
  await file.parent.create(recursive: true);
  await file.writeAsString(
    '# 栖语每日记录\n<!-- qiyu-episode:$meta -->\n'
    '<!-- qiyu-episode-entry:$entry -->\n',
  );
}
