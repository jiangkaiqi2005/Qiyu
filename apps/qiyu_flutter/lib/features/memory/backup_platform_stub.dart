import 'dart:typed_data';

import 'backup_platform.dart';

/// 非 Web 环境（含 widget 测试）的缺省实现：浏览器下载与文件选择
/// 都不可用，调用方必须按 [supported] 如实呈现。
final class UnsupportedBackupPlatform implements BackupPlatform {
  const UnsupportedBackupPlatform();

  @override
  bool get supported => false;

  @override
  Future<bool> downloadBackup(
    String fileName,
    Uint8List bytes, {
    String shareTitle = '栖语备份',
  }) async => false;

  @override
  Future<Uint8List?> pickBackupFile() async => null;
}

BackupPlatform createBackupPlatform() => const UnsupportedBackupPlatform();
