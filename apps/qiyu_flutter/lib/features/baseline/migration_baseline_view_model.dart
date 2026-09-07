import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'host_connection_probe.dart';

final class MigrationBaselineViewModel extends ChangeNotifier {
  MigrationBaselineViewModel({
    QiyuBehaviorCore? behaviorCore,
    HostConnectionProbe? hostConnectionProbe,
    bool autoStartMonitoring = true,
    Duration monitorInterval = const Duration(seconds: 2),
  }) : _behaviorCore = behaviorCore ?? const QiyuBehaviorCore(),
       _hostConnectionProbe = hostConnectionProbe ?? HttpHostConnectionProbe() {
    if (autoStartMonitoring) {
      unawaited(checkHostNow());
      _monitorTimer = Timer.periodic(
        monitorInterval,
        (_) => unawaited(checkHostNow()),
      );
    }
  }

  final QiyuBehaviorCore _behaviorCore;
  final HostConnectionProbe _hostConnectionProbe;
  Timer? _monitorTimer;
  bool? _hostAvailable;
  bool _checkingHost = false;

  bool get hostStopped => _hostAvailable == false;

  Future<void> checkHostNow() async {
    if (_checkingHost) {
      return;
    }
    _checkingHost = true;
    try {
      final available = await _hostConnectionProbe.isHostAvailable();
      if (_hostAvailable == available) {
        return;
      }
      _hostAvailable = available;
      notifyListeners();
    } finally {
      _checkingHost = false;
    }
  }

  /// 行为核心预检：每次调用实跑一次 reply() 探测，非缓存状态。
  bool checkBehaviorCore() {
    final result = _behaviorCore.reply(
      const ChatRequest(requestId: 'flutter-preflight', text: '我到家了'),
      StateSnapshot.initial('local-user'),
    );
    return result is ChatResult && result.messages.single == '嗯';
  }

  @override
  void dispose() {
    _monitorTimer?.cancel();
    super.dispose();
  }
}
