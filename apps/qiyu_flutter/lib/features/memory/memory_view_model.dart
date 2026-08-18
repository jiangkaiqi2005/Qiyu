import 'dart:async';

import 'package:flutter/foundation.dart';

import 'memory_client.dart';

/// 记忆中心视图模型：只承载总览加载与详情读取。接口面没有任何写入
/// 动作，浏览与展开证据不会触发整理、模型调用或关系变化。
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
  String? _errorMessage;

  MemoryOverview? get overview => _overview;
  bool get loading => _loading && !_refreshed;
  String? get errorMessage => _errorMessage;

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
}

String _readableError(Object error) => switch (error) {
  MemoryGatewayException() => error.message,
  _ => '记忆中心暂时不可用，请稍后重试。',
};
