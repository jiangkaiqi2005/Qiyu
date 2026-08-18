import 'dart:io';

import 'package:path/path.dart' as path;

import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_backup.dart';
import 'memory_controls.dart';
import 'provider_settings_service.dart';

final class LocalDataException implements Exception {
  const LocalDataException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// 本机数据管理（ticket 23）：数据位置概览与「清除产品数据」。
///
/// 清除范围与边界：
/// - 清除前先创建一份可回滚备份快照（与导入同一条快照链），快照
///   保留在 `backups/` 目录，清除后可随时恢复；
/// - 删除记忆目录内除 `backups/` 外的全部内容：原始会话、整理后的
///   每日记录与索引、长期印象、画像树、关系与近日状态、记忆控制、
///   Dream 状态与损坏隔离区；
/// - 删除首次见面状态，清除后重新进入初见引导；
/// - 模型连接设置与 API Key 不属于产品数据，清除不动它们；体验
///   选项（开发者模式）同样保留。
final class LocalDataService {
  LocalDataService({
    required this.memoryDirectory,
    required this.repository,
    required this.backupService,
    required this.providerSettingsService,
    required this.onboardingFilePath,
    this.episodePipeline,
    this.memoryControls,
  });

  final String memoryDirectory;
  final MemoryRepository repository;
  final MemoryBackupService backupService;
  final ProviderSettingsService providerSettingsService;
  final String onboardingFilePath;
  final EpisodeMemoryPipeline? episodePipeline;
  final MemoryControlsStore? memoryControls;

  /// 清除前的影响概览，同时承担设置页「本地数据位置」展示。
  Future<Map<String, Object?>> clearPreview() async {
    var sessionCount = 0;
    try {
      final listing = await repository.readHistory();
      sessionCount = listing.sessions.length;
    } on Object {
      // 会话目录不可读时按 0 展示，清除本身仍会删除目录。
    }
    var episodeDayCount = 0;
    final pipeline = episodePipeline;
    if (pipeline != null) {
      try {
        episodeDayCount = (await pipeline.listEpisodeDates()).length;
      } on Object {
        // 同上。
      }
    }
    var frozenCount = 0;
    var bannedCount = 0;
    var deletedCount = 0;
    final controls = memoryControls;
    if (controls != null) {
      try {
        final snapshot = await controls.load();
        frozenCount = snapshot.frozen.length;
        bannedCount = snapshot.banned.length;
        deletedCount = snapshot.deleted.length;
      } on Object {
        // 控制文件不可读时计数保持 0，清除仍会删除文件。
      }
    }
    final provider = await providerSettingsService.read();
    final snapshots = await backupService.listSnapshots();
    return {
      'memoryDirectory': memoryDirectory,
      'sessionCount': sessionCount,
      'episodeDayCount': episodeDayCount,
      'frozenCount': frozenCount,
      'bannedCount': bannedCount,
      'deletedCount': deletedCount,
      'snapshotCount': snapshots.length,
      'providerConfigured': provider.configured,
      'keySet': provider.keySet,
    };
  }

  /// 执行清除：先落快照，再删产品数据。任一步失败抛出
  /// [LocalDataException]，绝不留下「快照没建成却已删数据」的状态。
  Future<Map<String, Object?>> clear() async {
    final String snapshotId;
    try {
      snapshotId = await backupService.createSnapshot();
    } on Object catch (error) {
      throw LocalDataException('清除前快照创建失败，本次未删除任何数据。', error);
    }
    final root = Directory(memoryDirectory);
    if (await root.exists()) {
      try {
        await for (final entity in root.list(followLinks: false)) {
          if (path.basename(entity.path) == 'backups') {
            continue;
          }
          await entity.delete(recursive: true);
        }
      } on Object catch (error) {
        throw LocalDataException('本机数据清除未完成，请稍后重试。', error);
      }
    }
    final onboarding = File(onboardingFilePath);
    if (await onboarding.exists()) {
      try {
        await onboarding.delete();
      } on Object catch (error) {
        throw LocalDataException('本机数据清除未完成，请稍后重试。', error);
      }
    }
    return {'cleared': true, 'snapshotId': snapshotId};
  }
}
