import 'dart:async';

import 'package:flutter/foundation.dart';

import '../baseline/host_api_gateway.dart';
import 'settings_client.dart';

/// 设置页数据模型（ticket 23）：体验选项、记忆控制总览、清除产品
/// 数据与开发者诊断。清除是危险操作：必须先取影响概览，用户确认
/// 后才真正执行。
final class SettingsViewModel extends ChangeNotifier {
  SettingsViewModel(this._gateway);

  final SettingsGateway _gateway;

  ExperiencePreferences? _preferences;
  MemoryControlsOverview? _controls;
  ClearPreview? _clearPreview;
  DiagnosticsSnapshot? _diagnostics;
  bool _busy = false;
  bool _clearing = false;
  String? _errorMessage;

  ExperiencePreferences? get preferences => _preferences;
  MemoryControlsOverview? get controls => _controls;
  ClearPreview? get clearPreview => _clearPreview;
  DiagnosticsSnapshot? get diagnostics => _diagnostics;
  bool get busy => _busy;
  bool get clearing => _clearing;
  String? get errorMessage => _errorMessage;
  bool get developerMode => _preferences?.developerMode ?? false;

  Future<void> loadPreferences() async {
    try {
      _preferences = await _gateway.readPreferences();
      _errorMessage = null;
    } on Object catch (error) {
      _errorMessage = _readableError(error);
    }
    notifyListeners();
  }

  Future<void> setDeveloperMode(bool enabled) async {
    if (_busy) {
      return;
    }
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      _preferences = await _gateway.savePreferences(developerMode: enabled);
    } on Object catch (error) {
      _errorMessage = _readableError(error);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 以下加载方法只在异步完成后通知监听者：它们可能在 build 阶段
  /// （didChangeDependencies）被触发，同步 notifyListeners 会违反
  /// Flutter 的构建期约束。
  Future<void> loadMemoryControls() async {
    MemoryControlsOverview? controls;
    String? error;
    try {
      controls = await _gateway.readMemoryControls();
    } on Object catch (e) {
      error = _readableError(e);
    }
    _controls = controls;
    _errorMessage = error;
    notifyListeners();
  }

  /// 取清除影响概览（本地数据位置与各计数），供确认对话框展示。
  Future<bool> loadClearPreview() async {
    ClearPreview? preview;
    String? error;
    try {
      preview = await _gateway.readClearPreview();
    } on Object catch (e) {
      error = _readableError(e);
    }
    _clearPreview = preview;
    _errorMessage = error;
    notifyListeners();
    return preview != null;
  }

  /// 确认后清除产品数据；成功返回 true，调用方负责导航回首页。
  Future<bool> clearData() async {
    if (_clearing) {
      return false;
    }
    _clearing = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _gateway.clearData();
      _clearPreview = null;
      return true;
    } on Object catch (error) {
      _errorMessage = _readableError(error);
      return false;
    } finally {
      _clearing = false;
      notifyListeners();
    }
  }

  /// 诊断页的初始加载与刷新共用此方法：busy 期间重复触发直接忽略，
  /// 诊断页刷新按钮的禁用因此生效。初始加载可能在 build 阶段
  /// （didChangeDependencies）被触发，busy 的界面状态先让出一个微任务
  /// 再通知，绝不在构建期同步 notifyListeners。
  Future<void> loadDiagnostics() async {
    if (_busy) {
      return;
    }
    _busy = true;
    await Future<void>.microtask(() {});
    notifyListeners();
    DiagnosticsSnapshot? snapshot;
    String? error;
    try {
      snapshot = await _gateway.readDiagnostics();
    } on Object catch (e) {
      error = _readableError(e);
    }
    _diagnostics = snapshot;
    _errorMessage = error;
    _busy = false;
    notifyListeners();
  }
}

String _readableError(Object error) =>
    readableError(error, fallback: '设置服务暂时不可用，请稍后重试。');
