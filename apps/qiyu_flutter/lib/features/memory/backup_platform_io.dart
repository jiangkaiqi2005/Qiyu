import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

import 'backup_platform.dart';

/// 备份交给系统分享 sheet 的通道接缝：真实现走平台通道（真机行为，
/// 不进 dart 测试，归真机冒烟）；dart 测试注入 fake 验证字节交接。
abstract interface class BackupSharer {
  /// 把备份交给系统分享面板。返回 true 表示备份已交出去（用户选择了
  /// 目标，或平台无法区分结果）；返回 false 表示用户取消了分享。
  /// 打不开分享面板等故障以异常抛出，由调用方按可重试失败呈现。
  Future<bool> share(String fileName, Uint8List bytes);
}

/// share_plus 真实现：备份字节经本通道写入系统临时文件并打开分享
/// sheet。发出去、存到哪里完全由用户在系统面板里选择（面板自带
/// 「保存到文件」，即保存到用户可见目录）；除此之外不存在任何自动
/// 外传路径。
final class PluginBackupSharer implements BackupSharer {
  const PluginBackupSharer();

  @override
  Future<bool> share(String fileName, Uint8List bytes) async {
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, mimeType: 'application/zip')],
        // XFile.fromData 的 name 在非 web 平台会被 cross_file 忽略，
        // 备份文件名必须走 fileNameOverrides 才能到分享目标手里。
        fileNameOverrides: [fileName],
        title: '栖语备份',
      ),
    );
    return result.status != ShareResultStatus.dismissed;
  }
}

/// 备份文件选择通道接缝：真实现走平台通道（真机行为，不进 dart
/// 测试，归真机冒烟）。
abstract interface class BackupFilePicker {
  /// 打开系统文件选择器；用户取消返回 null。
  Future<Uint8List?> pickBackupFile();
}

/// file_picker 真实现：系统文件选择器（Android 走 SAF，不需要存储
/// 权限）。选中字节在内存中交给现有预览与导入上传链路；不写日志。
/// 安卓上 file_picker 会把选中文件复制一份中转副本到应用沙盒缓存
/// 目录（cacheDir/file_picker/），随沙盒与系统缓存管理，不出设备。
final class PluginBackupFilePicker implements BackupFilePicker {
  const PluginBackupFilePicker();

  @override
  Future<Uint8List?> pickBackupFile() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (picked == null) {
      return null;
    }
    return picked.readAsBytes();
  }
}

/// io 平台（安卓壳）的备份接缝实现（ticket 07）：导出接系统分享
/// sheet，导入接系统文件选择器。导入语义一行不改——选中字节原样
/// 交给现有上传链路，损坏恢复与记忆控制语义全在 Host 侧不动。
///
/// PC 形态依旧是浏览器跑 web 缝；桌面 io 壳不是产品形态，[supported]
/// 在非安卓 io 平台如实报告不可用，导出与导入都不会真的发起（与
/// stub 的「如实说明」契约一致）。widget 测试跑在桌面宿主上，缺省
/// 构造因此同样拿到不可用，不会碰真通道；接缝行为测试用构造参数
/// 注入 fake 通道并显式指定 [supported]。
final class IoBackupPlatform implements BackupPlatform {
  IoBackupPlatform({
    BackupSharer? sharer,
    BackupFilePicker? picker,
    bool? supported,
  }) : _sharer = sharer ?? const PluginBackupSharer(),
       _picker = picker ?? const PluginBackupFilePicker(),
       _supportedOverride = supported;

  final BackupSharer _sharer;
  final BackupFilePicker _picker;
  final bool? _supportedOverride;

  @override
  bool get supported => _supportedOverride ?? Platform.isAndroid;

  @override
  Future<bool> downloadBackup(String fileName, Uint8List bytes) async {
    if (!supported) {
      return false;
    }
    return _sharer.share(fileName, bytes);
  }

  @override
  Future<Uint8List?> pickBackupFile() async {
    if (!supported) {
      return null;
    }
    return _picker.pickBackupFile();
  }
}

BackupPlatform createBackupPlatform() => IoBackupPlatform();
