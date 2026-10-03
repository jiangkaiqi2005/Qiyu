import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'omni_call_usage_state.dart';

const _key = 'qiyu_omni_auto_start_suppressed';
OmniCallUsageState? _state;

/// sessionStorage 自然按 tab 隔离且在关页后清除；新导航还要丢弃
/// opener 复制的标记。reload/back_forward 延续本次使用，隐藏不清标记。
OmniCallUsageState createOmniCallUsageState() {
  return _state ??= WebOmniCallUsageState(web.window);
}

bool _readSuppressed(web.Window window) {
  var suppressed = false;
  try {
    final entries = window.performance.getEntriesByType('navigation').toDart;
    final type = entries.isEmpty
        ? null
        : (entries.first as web.PerformanceNavigationTiming).type;
    if (type == 'navigate') {
      window.sessionStorage.removeItem(_key);
    } else {
      suppressed = window.sessionStorage.getItem(_key) == 'true';
    }
  } on Object {
    // 存储受限时保守禁用本次自动启动，手动入口仍可用。
    suppressed = true;
  }
  return suppressed;
}

/// Window 是实际平台边界；测试可用同源新 tab 验证刷新与重开。
class WebOmniCallUsageState extends OmniCallUsageState {
  WebOmniCallUsageState(this._window)
    : super(suppressed: _readSuppressed(_window));

  final web.Window _window;

  @override
  void suppressAutoStart() {
    super.suppressAutoStart();
    try {
      _window.sessionStorage.setItem(_key, 'true');
    } on Object {
      // 内存中的本次抑制仍然生效。
    }
  }
}
