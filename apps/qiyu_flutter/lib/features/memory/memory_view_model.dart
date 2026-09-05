import 'dart:async';

import 'package:flutter/foundation.dart';

import '../baseline/host_api_gateway.dart';
import 'memory_client.dart';

/// 记忆中心视图模型：总览加载、详情读取，以及经过确认的记忆动作
/// （ticket 20）。动作成功或部分生效后立即刷新总览，控制状态即刻
/// 反映在界面上；失败时不刷新，旧有效数据保持可用。
final class MemoryCenterViewModel extends ChangeNotifier {
  MemoryCenterViewModel(this._gateway, {bool autoStart = true}) {
    if (autoStart) {
      unawaited(refresh());
    }
  }

  final MemoryGateway _gateway;

  MemoryOverview? _overview;
  bool _loading = false;
  bool _refreshed = false;
  bool _acting = false;
  String? _errorMessage;

  MemoryOverview? get overview => _overview;
  bool get loading => _loading && !_refreshed;
  String? get errorMessage => _errorMessage;

  /// 写入动作执行中（含派生层重建）：界面据此禁用操作入口，
  /// 结果落盘确认前不呈现「已完成」。
  bool get acting => _acting;

  Future<void> refresh() async {
    if (_loading) {
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      _overview = await _gateway.fetchOverview();
      _errorMessage = null;
      _refreshed = true;
    } on Object catch (error) {
      _errorMessage = _readableError(error);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 读取条目详情；条目已不存在或已变化时返回 null。网关异常向上
  /// 抛给视图层区分呈现（「不存在」与「暂时不可用」不合并）。
  Future<MemoryItemDetail?> itemDetail(String id) =>
      _gateway.fetchItemDetail(id);

  // ---------- 记忆动作（ticket 20） ----------

  /// 设置称呼（称呼定稿 2026-09-03）：成功后刷新总览；格式被拒时
  /// 返回带服务端提示的失败结果，界面内联呈现。
  Future<MemoryActionResult> setAppellation(String appellation) =>
      _mutate(() async {
        await _gateway.setAppellation(appellation);
        return const MemoryActionResult(
          status: MemoryActionStatus.success,
          message: '称呼已更新。',
        );
      });

  Future<MemoryActionResult> edit(String id, String text) =>
      _mutate(() => _gateway.editItem(id, text));

  Future<MemoryActionResult> freeze(String id) =>
      _mutate(() => _gateway.freezeItem(id));

  Future<MemoryActionResult> unfreeze(String id) =>
      _mutate(() => _gateway.unfreezeItem(id));

  Future<MemoryActionResult> ban(String id) =>
      _mutate(() => _gateway.banItem(id));

  Future<MemoryActionResult> unban(String id) =>
      _mutate(() => _gateway.unbanItem(id));

  /// 删除影响范围预览：条目已不存在或已变化时返回 null。
  Future<MemoryDeleteImpact?> deletePreview(String id) =>
      _gateway.previewDelete(id);

  Future<MemoryActionResult> delete(String id) =>
      _mutate(() => _gateway.deleteItem(id));

  /// 敏感内容的临时揭示：结果只存在于调用方的临时状态里，视图
  /// 离开或超时后重新遮罩；这里不落任何状态。
  Future<MemoryActionResult> reveal(String id, {String field = 'content'}) =>
      _gateway.revealItem(id, field: field);

  /// 写入动作统一出口：执行期间置忙碌态（界面禁用操作入口）；
  /// 网关异常转成可读的失败结果；成功或部分生效后刷新总览，让
  /// 控制与修正即刻可见。
  Future<MemoryActionResult> _mutate(
    Future<MemoryActionResult> Function() action,
  ) async {
    _acting = true;
    notifyListeners();
    try {
      final MemoryActionResult result;
      try {
        result = await action();
      } on Object catch (error) {
        return MemoryActionResult(
          status: MemoryActionStatus.failed,
          message: _readableError(error),
          retryable: true,
        );
      }
      if (result.status != MemoryActionStatus.failed) {
        unawaited(refresh());
      }
      return result;
    } finally {
      _acting = false;
      notifyListeners();
    }
  }
}

String _readableError(Object error) =>
    readableError(error, fallback: '记忆中心暂时不可用，请稍后重试。');
