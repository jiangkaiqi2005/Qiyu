import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import 'api_http.dart';
import 'episode_rag_service.dart';
import 'memory_actions.dart';
import 'memory_cadence.dart';
import 'memory_center.dart';
import 'memory_controls.dart';
import 'persona_tree.dart';

/// 记忆领域路由：四区总览、条目详情、记忆动作、称呼设定、控制记录
/// 浏览与后台失败状态。
///
/// 本模块持有记忆领域的路径匹配、payload 解析、序列化与错误翻译
/// （含记忆动作结果码到 HTTP 状态的映射）；删除本模块，这些职责会
/// 整体摊回路由总控。
final class MemoryRoutes implements ApiRoutes {
  MemoryRoutes({
    required this.memoryCenter,
    required this.memoryActions,
    required this.memoryControls,
    required this.personaTree,
    required this.memoryCadence,
    this.embeddingRecall,
  });

  final MemoryCenterService memoryCenter;
  final MemoryActionService memoryActions;
  final MemoryControlsStore memoryControls;

  /// 称呼写入口之一（记忆中心）：Persona 区修改称呼落到 persona.md
  /// 受保护设定行；与聊天自述、首见引导共用同一校验与写入实现。
  final PersonaTreeStore personaTree;

  /// 后台失败状态（ticket 21）：只读记忆节奏模块的最近失败记账，
  /// 序列化时只透平实任务名、时刻、次数与是否已恢复。
  final MemoryCadence memoryCadence;

  /// Episode RAG 服务（票 04）：记忆中心编辑、删除、冻结、禁提等来源
  /// 与控制变化成功后调度增量同步。null（未装配）时静默跳过，动作
  /// 本身不受影响。
  final EpisodeRagService? embeddingRecall;

  @override
  Future<Response?> handle(Request request) async {
    // 本领域没有共享口径之外的异常差异：请求体不可读、invalid_request、
    // 记忆仓储故障全走共享翻译前导；动作结果码到 HTTP 状态的映射在
    // _route 内按动作完成。
    return runApiRoute(() => _route(request));
  }

  Future<Response?> _route(Request request) async {
    final method = request.method;
    final path = request.url.path;
    if (method == 'GET' && path == 'api/memory') {
      final overview = await memoryCenter.overview();
      return Response.ok(
        jsonEncode(overview.toJson()),
        headers: jsonHeaders,
      );
    }
    if (method == 'GET' && path.startsWith('api/memory/items/')) {
      final itemId = path.substring('api/memory/items/'.length);
      if (itemId.isEmpty || itemId.contains('/')) {
        throw invalidRequest('记忆条目标识格式不正确。');
      }
      final detail = await memoryCenter.itemDetail(itemId);
      if (detail == null) {
        return _memoryItemNotFound();
      }
      return Response.ok(jsonEncode(detail.toJson()), headers: jsonHeaders);
    }
    if (method == 'POST' && path == 'api/memory/action') {
      final Map<String, Object?> payload;
      try {
        payload = await readJsonObject(request, maxBytes: 16 * 1024);
      } on FormatException {
        throw invalidRequest('记忆操作请求格式不正确。');
      }
      final action = payload['action'];
      final id = payload['id'];
      if (action is! String ||
          action.isEmpty ||
          id is! String ||
          id.isEmpty) {
        throw invalidRequest('记忆操作请求格式不正确。');
      }
      final ref = memoryCenter.resolveRef(id);
      if (ref == null) {
        return _memoryItemNotFound();
      }
      final MemoryActionResult result;
      switch (action) {
        case 'edit':
          final text = payload['text'];
          if (text is! String) {
            throw invalidRequest('记忆操作请求格式不正确。');
          }
          result = await memoryActions.edit(ref, text);
        case 'freeze':
          result = await memoryActions.freeze(ref);
        case 'unfreeze':
          result = await memoryActions.unfreeze(ref);
        case 'ban':
          result = await memoryActions.ban(ref);
        case 'unban':
          result = await memoryActions.unban(ref);
        case 'delete-preview':
          final impact = await memoryActions.deletePreview(ref);
          if (impact == null) {
            return _memoryItemNotFound();
          }
          return Response.ok(
            jsonEncode(impact.toJson()),
            headers: jsonHeaders,
          );
        case 'delete':
          result = await memoryActions.delete(ref);
        case 'reveal':
          final field = payload['field'];
          result = await memoryActions.reveal(
            ref,
            field is String && field.isNotEmpty ? field : 'content',
          );
        default:
          throw invalidRequest('不支持的记忆操作。');
      }
      final statusCode = switch (result.code) {
        'memory_item_not_found' => HttpStatus.notFound,
        'memory_action_not_allowed' ||
        'memory_item_not_masked' ||
        'memory_delete_no_target' => HttpStatus.badRequest,
        _ => HttpStatus.ok,
      };
      // 票 04：来源或控制变化成功（含部分失败但控制已写入）后调度召回
      // 索引的增量同步——后台任务链执行，动作响应不等待网络。
      final sourceChanged = switch (action) {
        'edit' ||
        'freeze' ||
        'unfreeze' ||
        'ban' ||
        'unban' ||
        'delete' => true,
        _ => false,
      };
      if (sourceChanged &&
          (result.status == MemoryActionStatus.success ||
              result.status == MemoryActionStatus.partial)) {
        embeddingRecall?.scheduleIncrementalSync();
      }
      return Response(
        statusCode,
        body: jsonEncode(result.toJson()),
        headers: jsonHeaders,
      );
    }
    if (method == 'POST' && path == 'api/memory/appellation') {
      final Map<String, Object?> payload;
      try {
        payload = await readJsonObject(request, maxBytes: 16 * 1024);
      } on FormatException {
        throw invalidRequest('称呼设置请求格式不正确。');
      }
      final value = payload['appellation'];
      if (value is! String) {
        throw invalidRequest('称呼设置请求格式不正确。');
      }
      final written = await personaTree.setAppellation(value);
      if (written == null) {
        return jsonError(
          HttpStatus.badRequest,
          code: 'invalid_appellation',
          message: appellationRejectedMessage,
          retryable: false,
        );
      }
      return Response.ok(
        jsonEncode({'appellation': written}),
        headers: jsonHeaders,
      );
    }
    if (method == 'GET' && path == 'api/memory/controls') {
      final controls = await memoryControls.load();
      Map<String, Object?> entryJson(MemoryControlEntry entry) => {
        'id': entry.id,
        'origin': entry.origin,
        'summary': entry.summary,
      };
      return Response.ok(
        jsonEncode({
          'readable': controls.readable,
          'frozen': [for (final entry in controls.frozen) entryJson(entry)],
          'banned': [for (final entry in controls.banned) entryJson(entry)],
          // 删除记录只存抽象防复活范围，只给数量不给内容。
          'deletedCount': controls.deleted.length,
        }),
        headers: jsonHeaders,
      );
    }
    if (method == 'GET' && path == 'api/memory/cadence-status') {
      final status = memoryCadence.backgroundFailureStatus;
      return Response.ok(
        jsonEncode({
          // 后台最近失败的只读状态（ticket 21）：对外只含平实任务名、
          // 最近失败时刻、累计次数与是否已恢复，无失败时安静返回；绝不
          // 透内部错误原文、堆栈或本机路径。
          'task': status?.task,
          if (status != null) 'failedAt': status.failedAt.toIso8601String(),
          if (status != null) 'count': status.count,
          if (status != null) 'recovered': status.recovered,
        }),
        headers: jsonHeaders,
      );
    }
    return null;
  }
}

/// 记忆条目定位失败的统一响应：ID 可能来自过期页面，提示返回刷新。
Response _memoryItemNotFound() => jsonError(
  HttpStatus.notFound,
  code: 'memory_item_not_found',
  message: '这条记忆不存在或已经变化，请返回后刷新。',
  retryable: false,
);
