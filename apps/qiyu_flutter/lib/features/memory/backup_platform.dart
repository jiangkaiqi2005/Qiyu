import 'dart:typed_data';

export 'backup_platform_stub.dart'
    if (dart.library.js_interop) 'backup_platform_web.dart';

/// 浏览器能力接缝（ticket 22）：导出触发下载、导入选择文件。Web
/// 构建走真实浏览器 API；其他平台（含 widget 测试环境）返回不支持，
/// 界面如实说明而不是假装成功。
abstract interface class BackupPlatform {
  bool get supported;

  /// 触发浏览器下载备份文件；成功返回 true。
  Future<bool> downloadBackup(String fileName, Uint8List bytes);

  /// 打开文件选择器让用户选择备份 zip；取消返回 null。
  Future<Uint8List?> pickBackupFile();
}
