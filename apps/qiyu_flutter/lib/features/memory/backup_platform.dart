import 'dart:typed_data';

export 'backup_platform_stub.dart'
    if (dart.library.js_interop) 'backup_platform_web.dart'
    if (dart.library.io) 'backup_platform_io.dart';

/// 浏览器能力接缝（ticket 22；ticket 07 添 io/安卓侧第二实现）：
/// 导出落地——web 触发浏览器下载、安卓打开系统分享 sheet；导入选择
/// 文件。Web 构建走真实浏览器 API，io/安卓构建走平台通道实现，其余
/// 平台（含 widget 测试环境）返回不支持，界面如实说明而不是假装成功。
abstract interface class BackupPlatform {
  bool get supported;

  /// 导出落地：web 触发浏览器下载，安卓把备份交给系统分享 sheet。
  /// 已发起（web 开始下载、安卓打开分享面板）返回 true；用户取消
  /// 分享或环境不支持返回 false，故障以异常抛出由调用方呈现。
  Future<bool> downloadBackup(
    String fileName,
    Uint8List bytes, {
    String shareTitle = '栖语备份',
  });

  /// 打开文件选择器让用户选择备份 zip；取消返回 null。
  Future<Uint8List?> pickBackupFile();
}
