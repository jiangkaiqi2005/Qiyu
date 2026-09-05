import 'dart:async';

import 'package:flutter/foundation.dart';

import '../baseline/host_api_gateway.dart';

/// 带钥匙设置域（模型服务、语音识别、语音合成、联网搜索）的视图模型
/// 基类：加载/保存/遗忘钥匙的状态机——互斥位、清空时机、加载中语义、
/// 人话错误通道与通知编排——只写一遍。历史上新增设置域曾照抄这套状
/// 态机三次，收拢后子类只留各自的网关、DTO 与兜底文案。
abstract base class KeyedSettingsViewModel<S, D> extends ChangeNotifier {
  KeyedSettingsViewModel({bool autoStart = true}) {
    if (autoStart) {
      unawaited(initialize());
    }
  }

  S? _settings;
  String? _errorMessage;
  bool _loading = false;
  bool _saving = false;
  bool _initialized = false;

  S? get settings => _settings;
  String? get errorMessage => _errorMessage;
  bool get loading => _loading && !_initialized;
  bool get saving => _saving;

  /// 网关异常透不出人话时的兜底文案，各域用自己的名字（「模型设置」
  /// 「语音设置」……）。
  @protected
  String get errorFallback;

  /// 保存与遗忘共用 [_saving] 互斥；互斥守卫通过后、错误位清空前调
  /// 用。带连接测试位的域在此清掉上一次测试结果，无测试位的域保持
  /// 空实现。
  @protected
  void resetTransientResults() {}

  /// 以下差异操作由子类一行委托各自网关。
  @protected
  Future<S> readSettings();
  @protected
  Future<S> saveSettings(D draft);
  @protected
  Future<S> forgetKeySettings();

  /// 子类跟进动作（如试听播放失败提示）需要直接写错误位。
  @protected
  set errorMessage(String? value) => _errorMessage = value;

  Future<void> initialize() async {
    if (_loading || _initialized) {
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      _settings = await readSettings();
      _errorMessage = null;
      _initialized = true;
    } on Object catch (error) {
      _errorMessage = readableError(error, fallback: errorFallback);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<bool> save(D draft) async {
    if (_saving) {
      return false;
    }
    _saving = true;
    resetTransientResults();
    _errorMessage = null;
    notifyListeners();
    try {
      _settings = await saveSettings(draft);
      return true;
    } on Object catch (error) {
      _errorMessage = readableError(error, fallback: errorFallback);
      return false;
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  Future<void> forgetApiKey() async {
    if (_saving) {
      return;
    }
    _saving = true;
    resetTransientResults();
    _errorMessage = null;
    notifyListeners();
    try {
      _settings = await forgetKeySettings();
    } on Object catch (error) {
      _errorMessage = readableError(error, fallback: errorFallback);
    } finally {
      _saving = false;
      notifyListeners();
    }
  }
}

/// 在加载/保存/遗忘之外还带连接测试位的设置域（模型服务、语音识别、
/// 语音合成）：测试互斥与结果位的编排也只写一遍。联网搜索没有测试
/// 位，直接继承 [KeyedSettingsViewModel]，不背上这份契约。
abstract base class TestableKeyedSettingsViewModel<S, D, R>
    extends KeyedSettingsViewModel<S, D> {
  TestableKeyedSettingsViewModel({super.autoStart});

  R? _testResult;
  bool _testing = false;

  R? get testResult => _testResult;
  bool get testing => _testing;

  @override
  void resetTransientResults() {
    _testResult = null;
  }

  /// 连接测试由子类委托各自网关。
  @protected
  Future<R> runConnectionTest(D draft);

  /// 在测试互斥守卫通过后、任何状态改变与第一个 await 之前同步调用；
  /// 浏览器播放许可（prepareForUserGesturePlayback）等必须在用户手势
  /// 的同步调用栈里完成的动作在此挂接。
  @protected
  void beforeConnectionTest() {}

  /// 测试结果落地后的跟进动作（如用返回音频试听）。返回 null 表示无
  /// 跟进，收尾保持与原本无跟进域完全相同的同步节奏；非 null 时在
  /// try 块内等待，跟进抛错与网关失败走同一条错误通道。
  @protected
  Future<void>? afterConnectionTest(R? result) => null;

  Future<void> testConnection(D draft) async {
    if (_testing) {
      return;
    }
    beforeConnectionTest();
    _testing = true;
    _testResult = null;
    _errorMessage = null;
    notifyListeners();
    try {
      _testResult = await runConnectionTest(draft);
      final followUp = afterConnectionTest(_testResult);
      if (followUp != null) {
        await followUp;
      }
    } on Object catch (error) {
      _errorMessage = readableError(error, fallback: errorFallback);
    } finally {
      _testing = false;
      notifyListeners();
    }
  }
}
