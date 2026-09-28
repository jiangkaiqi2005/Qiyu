import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/memory/backup_platform_io.dart';

void main() {
  final bundle = Uint8List.fromList(List.generate(16, (i) => i));

  group('io 接缝导出：把 Host 备份字节交给分享器', () {
    test('备份字节与文件名原样交给分享器，完成后如实返回', () async {
      final sharer = _RecordingSharer(result: true);
      final platform = IoBackupPlatform(sharer: sharer, supported: true);

      final done = await platform.downloadBackup('qiyu-backup.zip', bundle);

      expect(done, isTrue);
      expect(sharer.calls, 1);
      expect(sharer.sharedName, 'qiyu-backup.zip');
      expect(sharer.sharedBytes, bundle);
      expect(sharer.sharedTitle, '栖语备份');
    });

    test('英文界面把英文标题交给系统分享面板', () async {
      final sharer = _RecordingSharer(result: true);
      final platform = IoBackupPlatform(sharer: sharer, supported: true);

      await platform.downloadBackup(
        'qiyu-backup.zip',
        bundle,
        shareTitle: 'Qiyu backup',
      );

      expect(sharer.sharedTitle, 'Qiyu backup');
    });

    test('用户取消分享时如实返回未完成，不假装成功', () async {
      final platform = IoBackupPlatform(
        sharer: _RecordingSharer(result: false),
        supported: true,
      );

      expect(await platform.downloadBackup('qiyu-backup.zip', bundle), isFalse);
    });

    test('分享器故障向上抛出，不吞错也不假装成功（界面呈现归 widget 层）', () async {
      final platform = IoBackupPlatform(
        sharer: _ThrowingSharer(),
        supported: true,
      );

      await expectLater(
        platform.downloadBackup('qiyu-backup.zip', bundle),
        throwsException,
      );
    });

    test('不支持导出的 io 环境不发起分享', () async {
      final sharer = _RecordingSharer(result: true);
      final platform = IoBackupPlatform(sharer: sharer, supported: false);

      expect(await platform.downloadBackup('qiyu-backup.zip', bundle), isFalse);
      expect(sharer.calls, 0);
    });
  });

  group('io 接缝导入：把用户文件交给现有上传链路', () {
    test('选中文件的字节原样透传', () async {
      final picker = _FixedPicker(bytes: bundle);
      final platform = IoBackupPlatform(picker: picker, supported: true);

      expect(await platform.pickBackupFile(), same(bundle));
      expect(picker.calls, 1);
    });

    test('用户取消选择时返回空，导入停在原地', () async {
      final platform = IoBackupPlatform(
        picker: _FixedPicker(bytes: null),
        supported: true,
      );

      expect(await platform.pickBackupFile(), isNull);
    });

    test('不支持选择文件的 io 环境不发起选择器', () async {
      final picker = _FixedPicker(bytes: bundle);
      final platform = IoBackupPlatform(picker: picker, supported: false);

      expect(await platform.pickBackupFile(), isNull);
      expect(picker.calls, 0);
    });
  });
}

/// share_plus 通道的替身：记录交给系统分享器的文件名与字节。
final class _RecordingSharer implements BackupSharer {
  _RecordingSharer({required this.result});

  final bool result;
  int calls = 0;
  String? sharedName;
  String? sharedTitle;
  Uint8List? sharedBytes;

  @override
  Future<bool> share(
    String fileName,
    Uint8List bytes, {
    String shareTitle = '栖语备份',
  }) async {
    calls += 1;
    sharedName = fileName;
    sharedTitle = shareTitle;
    sharedBytes = bytes;
    return result;
  }
}

/// 故障注入的分享器替身：模拟 share_plus 打不开分享面板。
final class _ThrowingSharer implements BackupSharer {
  @override
  Future<bool> share(
    String fileName,
    Uint8List bytes, {
    String shareTitle = '栖语备份',
  }) async {
    throw Exception('分享面板打不开');
  }
}

/// file_picker 通道的替身：固定返回预置字节（null 表示用户取消）。
final class _FixedPicker implements BackupFilePicker {
  _FixedPicker({required this.bytes});

  final Uint8List? bytes;
  int calls = 0;

  @override
  Future<Uint8List?> pickBackupFile() async {
    calls += 1;
    return bytes;
  }
}
