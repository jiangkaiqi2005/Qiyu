export 'omni_call_usage_state_stub.dart'
    if (dart.library.js_interop) 'omni_call_usage_state_web.dart';

/// 一次页面/进程使用内的抑制；仅 Web 将这一位留到同 tab 刷新。
class OmniCallUsageState {
  OmniCallUsageState({this._suppressed = false});

  bool _suppressed;
  bool get autoStartSuppressed => _suppressed;

  void suppressAutoStart() => _suppressed = true;
}
