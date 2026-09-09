import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

import 'api_http.dart';
import 'local_chat_service.dart';
import 'local_data_service.dart';
import 'memory_backup.dart';

/// 备份与数据管理领域路由：Markdown 备份的导出/导入/预览/快照/回滚，
/// 以及「清除产品数据」的影响预览与执行。
///
/// 本模块持有该领域的路径匹配、备份包（base64 zip）payload 解析、
/// 序列化与错误翻译；删除本模块，这些职责会整体摊回路由总控。
final class BackupRoutes implements ApiRoutes {
  BackupRoutes({
    required this.memoryBackup,
    required this.localDataService,
    required this._chatService,
  });

  final MemoryBackupService memoryBackup;
  final LocalDataService localDataService;
  final LocalChatService _chatService;

  @override
  Future<Response?> handle(Request request) async {
    // 领域差异只有备份包校验失败；请求体不可读、invalid_request、
    // Provider 配置与凭据库故障、本地数据与记忆仓储故障走共享翻译前导。
    return runApiRoute(
      () => _route(request),
      translateDomainError: (error) => error is BackupValidationException
          ? jsonError(
              HttpStatus.badRequest,
              code: error.code,
              message: error.message,
              retryable: false,
            )
          : null,
    );
  }

  Future<Response?> _route(Request request) async {
    final method = request.method;
    final path = request.url.path;
    if (method == 'GET' && path == 'api/backup/export') {
      final export = await memoryBackup.exportBundle();
      return Response.ok(
        export.bytes,
        headers: {
          HttpHeaders.contentTypeHeader: 'application/zip',
          'content-disposition': 'attachment; filename="${export.fileName}"',
          HttpHeaders.cacheControlHeader: 'no-store',
        },
      );
    }
    if (method == 'POST' && path == 'api/backup/preview') {
      final bundle = await _readBackupBundle(request);
      final preview = await memoryBackup.previewImport(bundle);
      return Response.ok(jsonEncode(preview.toJson()), headers: jsonHeaders);
    }
    if (method == 'POST' && path == 'api/backup/import') {
      final bundle = await _readBackupBundle(request);
      final result = await memoryBackup.importBundle(bundle);
      return Response.ok(jsonEncode(result.toJson()), headers: jsonHeaders);
    }
    if (method == 'GET' && path == 'api/backup/snapshots') {
      final snapshots = await memoryBackup.listSnapshots();
      return Response.ok(
        jsonEncode({
          'snapshots': [for (final snapshot in snapshots) snapshot.toJson()],
        }),
        headers: jsonHeaders,
      );
    }
    if (method == 'POST' && path == 'api/backup/rollback') {
      final payload = await readJsonObject(request, maxBytes: 4 * 1024);
      final snapshotId = payload['snapshotId'];
      if (snapshotId != null && snapshotId is! String) {
        throw invalidRequest('回滚请求格式不正确。');
      }
      final result = await memoryBackup.rollbackTo(snapshotId as String?);
      return Response.ok(jsonEncode(result.toJson()), headers: jsonHeaders);
    }
    if (method == 'GET' && path == 'api/data/clear-preview') {
      final preview = await localDataService.clearPreview();
      return Response.ok(jsonEncode(preview), headers: jsonHeaders);
    }
    if (method == 'POST' && path == 'api/data/clear') {
      final payload = await readJsonObject(request, maxBytes: 4 * 1024);
      if (payload['confirm'] != true) {
        throw invalidRequest('清除本机数据需要明确确认。');
      }
      // 经聊天服务的独占槽执行：等全部在途交付与后台任务完成，
      // 期间没有新交付并发，清除才不会丢写入或复活已清除的数据。
      final result = await _chatService.runExclusively(
        () => localDataService.clear(),
      );
      return Response.ok(jsonEncode(result), headers: jsonHeaders);
    }
    return null;
  }
}

/// 备份请求体上限：base64 编码后的 zip。本机记忆是纯文本，正常备份
/// 远小于该值；超限直接拒绝，不进入验证与写入。
const _backupBundleMaxBytes = 96 * 1024 * 1024;

Future<Uint8List> _readBackupBundle(Request request) async {
  final payload = await readJsonObject(
    request,
    maxBytes: _backupBundleMaxBytes,
  );
  final data = payload['dataBase64'];
  if (data is! String || data.isEmpty) {
    throw invalidRequest('备份请求格式不正确。');
  }
  try {
    return base64.decode(data);
  } on Object {
    throw invalidRequest('备份文件读不出来，请重新选择。');
  }
}
