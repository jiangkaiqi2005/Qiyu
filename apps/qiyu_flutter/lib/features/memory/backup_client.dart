import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../baseline/host_api_gateway.dart';

/// 导入预览中单个文件的归类（ticket 22）：与 Host 侧 wire 一一对应。
/// 冲突与不可恢复的项目一律不会写入本机。
enum BackupItemCategory {
  added('新增'),
  replaced('替换'),
  conflict('冲突'),
  skipped('跳过'),
  unrecoverable('不可恢复');

  const BackupItemCategory(this.label);

  final String label;

  static BackupItemCategory fromWire(Object? value) => switch (value) {
    'added' => BackupItemCategory.added,
    'replaced' => BackupItemCategory.replaced,
    'conflict' => BackupItemCategory.conflict,
    'skipped' => BackupItemCategory.skipped,
    'unrecoverable' => BackupItemCategory.unrecoverable,
    _ => BackupItemCategory.unrecoverable,
  };
}

final class BackupPreviewItem {
  const BackupPreviewItem({
    required this.path,
    required this.category,
    this.note,
  });

  factory BackupPreviewItem.fromJson(Map<String, Object?> json) =>
      BackupPreviewItem(
        path: json['path']! as String,
        category: BackupItemCategory.fromWire(json['category']),
        note: json['note'] as String?,
      );

  final String path;
  final BackupItemCategory category;
  final String? note;
}

/// 导入前验证与差异结果：结构、版本、完整性全部通过才有效。
final class BackupPreview {
  const BackupPreview({
    required this.generatedAt,
    required this.controlsMerge,
    required this.counts,
    required this.items,
  });

  factory BackupPreview.fromJson(Map<String, Object?> json) => BackupPreview(
    generatedAt: DateTime.parse(json['generatedAt']! as String),
    controlsMerge: json['controlsMerge']! as String,
    counts: (json['counts']! as Map<String, Object?>).map(
      (key, value) => MapEntry(key, value! as int),
    ),
    items: (json['items']! as List<Object?>)
        .map(
          (item) => BackupPreviewItem.fromJson(item! as Map<String, Object?>),
        )
        .toList(),
  );

  final DateTime generatedAt;

  /// none=备份中没有控制记录；identical=与本机一致；union=按并集合并。
  final String controlsMerge;
  final Map<String, int> counts;
  final List<BackupPreviewItem> items;

  int countOf(BackupItemCategory category) => counts[category.name] ?? 0;

  String get controlsMergeText => switch (controlsMerge) {
    'union' => '控制记录将与本机按并集合并，保留更保守的隐私结果',
    'identical' => '控制记录与本机一致',
    _ => '备份中没有控制记录，本机现有控制保持不变',
  };
}

final class BackupImportResult {
  const BackupImportResult({
    required this.added,
    required this.replaced,
    required this.skipped,
    required this.conflicts,
    required this.unrecoverable,
    required this.controlsMerged,
    required this.snapshotId,
  });

  factory BackupImportResult.fromJson(Map<String, Object?> json) =>
      BackupImportResult(
        added: json['added']! as int,
        replaced: json['replaced']! as int,
        skipped: json['skipped']! as int,
        conflicts: json['conflicts']! as int,
        unrecoverable: json['unrecoverable']! as int,
        controlsMerged: json['controlsMerged']! as bool,
        snapshotId: json['snapshotId']! as String,
      );

  final int added;
  final int replaced;
  final int skipped;
  final int conflicts;
  final int unrecoverable;
  final bool controlsMerged;
  final String snapshotId;
}

final class BackupSnapshotInfo {
  const BackupSnapshotInfo({
    required this.id,
    required this.createdAt,
    required this.fileCount,
  });

  factory BackupSnapshotInfo.fromJson(Map<String, Object?> json) =>
      BackupSnapshotInfo(
        id: json['id']! as String,
        createdAt: DateTime.parse(json['createdAt']! as String),
        fileCount: json['fileCount']! as int,
      );

  final String id;
  final DateTime createdAt;
  final int fileCount;
}

final class BackupRollbackResult {
  const BackupRollbackResult({
    required this.snapshotId,
    required this.restoredFiles,
    required this.safetySnapshotId,
  });

  factory BackupRollbackResult.fromJson(Map<String, Object?> json) =>
      BackupRollbackResult(
        snapshotId: json['snapshotId']! as String,
        restoredFiles: json['restoredFiles']! as int,
        safetySnapshotId: json['safetySnapshotId']! as String,
      );

  final String snapshotId;
  final int restoredFiles;
  final String safetySnapshotId;
}

final class BackupGatewayException implements Exception {
  const BackupGatewayException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 备份网关（ticket 22）：导出只拉字节流；预览与导入都携带会话
/// Cookie 与 CSRF；任何验证失败都转为带用户语言的异常。
abstract interface class BackupGateway {
  /// 返回 zip 字节与建议文件名。
  Future<({Uint8List bytes, String fileName})> exportBundle();

  Future<BackupPreview> previewBundle(Uint8List bundle);

  Future<BackupImportResult> importBundle(Uint8List bundle);

  Future<List<BackupSnapshotInfo>> snapshots();

  Future<BackupRollbackResult> rollback({String? snapshotId});
}

final class HttpBackupGateway extends HostApiGateway implements BackupGateway {
  HttpBackupGateway({super.client, super.baseUri});

  @override
  Object errorFor(String message) => BackupGatewayException(message);

  @override
  String get unavailableMessage => '备份操作没有成功，可稍后重试。';

  @override
  Future<({Uint8List bytes, String fileName})> exportBundle() async {
    final response = await httpClient.get(resolve('/api/backup/export'));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const BackupGatewayException('备份导出没有成功，可稍后重试。');
    }
    return (bytes: response.bodyBytes, fileName: _fileName(response));
  }

  String _fileName(http.Response response) {
    final disposition = response.headers['content-disposition'];
    if (disposition != null) {
      final match = RegExp('filename="?([^";]+)"?').firstMatch(disposition);
      if (match != null) {
        return match.group(1)!;
      }
    }
    return 'qiyu-backup.zip';
  }

  @override
  Future<BackupPreview> previewBundle(Uint8List bundle) async {
    final json = await _post('/api/backup/preview', bundle);
    return BackupPreview.fromJson(json);
  }

  @override
  Future<BackupImportResult> importBundle(Uint8List bundle) async {
    final json = await _post('/api/backup/import', bundle);
    return BackupImportResult.fromJson(json);
  }

  @override
  Future<List<BackupSnapshotInfo>> snapshots() async {
    final response = await httpClient.get(resolve('/api/backup/snapshots'));
    final json = decodeSuccess(response);
    return (json['snapshots']! as List<Object?>)
        .map(
          (snapshot) =>
              BackupSnapshotInfo.fromJson(snapshot! as Map<String, Object?>),
        )
        .toList();
  }

  @override
  Future<BackupRollbackResult> rollback({String? snapshotId}) async {
    final response = await httpClient.post(
      resolve('/api/backup/rollback'),
      headers: await modifyingHeaders(),
      body: jsonEncode({'snapshotId': ?snapshotId}),
    );
    return BackupRollbackResult.fromJson(decodeSuccess(response));
  }

  Future<Map<String, Object?>> _post(String path, Uint8List bundle) async {
    final response = await httpClient.post(
      resolve(path),
      headers: await modifyingHeaders(),
      body: jsonEncode({'dataBase64': base64.encode(bundle)}),
    );
    return decodeSuccess(response);
  }
}
