import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'backup_platform.dart';

/// Flutter Web 构建的真实浏览器实现（ticket 22）：导出经 Blob 链接触发
/// 下载，导入经隐藏文件选择器读取用户选中的 zip 字节。
final class WebBackupPlatform implements BackupPlatform {
  const WebBackupPlatform();

  @override
  bool get supported => true;

  @override
  Future<bool> downloadBackup(
    String fileName,
    Uint8List bytes, {
    String shareTitle = '栖语备份',
  }) async {
    try {
      final blob = web.Blob([bytes.toJS].toJS);
      final url = web.URL.createObjectURL(blob);
      final anchor = web.HTMLAnchorElement()
        ..href = url
        ..download = fileName;
      web.document.body?.appendChild(anchor);
      anchor.click();
      anchor.remove();
      web.URL.revokeObjectURL(url);
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<Uint8List?> pickBackupFile() async {
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = '.zip,application/zip';
    final picked = Completer<void>();
    input.addEventListener(
      'change',
      ((web.Event event) {
        if (!picked.isCompleted) {
          picked.complete();
        }
      }).toJS,
    );
    web.document.body?.appendChild(input);
    input.click();
    await picked.future;
    input.remove();
    final files = input.files;
    if (files == null || files.length == 0) {
      return null;
    }
    final file = files.item(0);
    if (file == null) {
      return null;
    }
    try {
      final buffer = await file.arrayBuffer().toDart;
      return buffer.toDart.asUint8List();
    } on Object {
      return null;
    }
  }
}

BackupPlatform createBackupPlatform() => const WebBackupPlatform();
