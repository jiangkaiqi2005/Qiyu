@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:qiyu_flutter/features/memory/backup_platform_web.dart';
import 'package:test/test.dart';

void main() {
  test('web 接缝维持现状：导出字节经 Blob 链接触发浏览器下载', () async {
    final platform = createBackupPlatform();
    expect(platform.supported, isTrue);

    // 真实浏览器里走 Blob → objectURL → anchor.click() 全链路；
    // 无用户手势的 headless 环境只验证触发不抛错、如实返回成功。
    final done = await platform.downloadBackup(
      'qiyu-backup.zip',
      Uint8List.fromList([1, 2, 3]),
    );
    expect(done, isTrue);
  });
}
