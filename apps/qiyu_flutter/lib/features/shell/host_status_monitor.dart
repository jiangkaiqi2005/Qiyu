import 'dart:async';

import 'package:flutter/foundation.dart';

import '../baseline/background_status_client.dart';
import '../baseline/host_connection_probe.dart';
import '../settings/embedding_settings_client.dart';

/// 本机 Host 状态监控（阶段 C 收拢）：既有连接探测轮询、连接三态、后台
/// 失败快照、记忆召回状态与恢复提示计时集中在这一个模块，是这些旁路
/// 状态的唯一所有者。
///
/// 职责边界：
/// - 连接三态（未探明/可用/不可用）：探测结果回来之前 [hostAvailable] 为
///   null，「未探明」既不能被读成正常、也不能被读成故障。
/// - 仍只有一条周期轮询：默认 2 秒，随 [autoStart] 启动；手动探测
///   [checkHostNow] 与周期轮询共用同一条路径与重入保护，迁移过程中不得
///   出现第二个计时器。
/// - 后台失败快照（ticket 21）：只在 Host 可达时读取；读取失败保留上一份
///   快照，绝不打扰聊天主链路；状态未变化不重复通知。
/// - 记忆召回状态（票 03）：与后台失败快照同一节拍、同一让路规则；未
///   注入网关时安静位整体不工作。
/// - 恢复提示窗口：只有此前实际展示过失败才开启，默认 4 秒后隐去。
///
/// 本模块不接管聊天服务异常弹窗、会话频控、语音错误回调或约 300ms 缓冲
/// ——那些是页面错误反馈；2 秒轮询与 4 秒恢复窗口也只服务于连接/后台
/// 状态，不清空、不触发那些状态。
///
/// 释放语义：[dispose] 照旧取消两个计时器；在途的连接探测或状态读取
/// **不被取消**（探测适配器没有取消能力，与基线一致的不等待），但其
/// 结果到达时被**静默丢弃**——不改连接三态与快照、不通知、不
/// 开恢复提示窗口、不记诊断。释放后的手动探测 [checkHostNow] 是安全
/// 空操作。理由：释放后在途结果再通知监听者会撞 ChangeNotifier 的
/// 释放断言（debug 下抛「used after being disposed」），而这些旁路
/// 状态此刻已没有任何展示去处。
final class HostStatusMonitor extends ChangeNotifier {
  HostStatusMonitor({
    HostConnectionProbe? hostConnectionProbe,
    BackgroundStatusGateway? backgroundStatusGateway,
    MemoryRecallStatusGateway? memoryRecallStatusGateway,
    bool autoStart = true,
    Duration monitorInterval = const Duration(seconds: 2),
  }) : _hostConnectionProbe = hostConnectionProbe ?? HttpHostConnectionProbe(),
       // ignore: prefer_initializing_formals
       _backgroundStatusGateway = backgroundStatusGateway,
       // ignore: prefer_initializing_formals
       _memoryRecallStatusGateway = memoryRecallStatusGateway {
    if (autoStart) {
      _monitorTimer = Timer.periodic(monitorInterval, (_) {
        unawaited(checkHostNow());
      });
    }
  }

  final HostConnectionProbe _hostConnectionProbe;

  /// 后台失败状态网关（ticket 21）：null 时安静位整体不工作（缺省关闭）。
  final BackgroundStatusGateway? _backgroundStatusGateway;

  /// 记忆召回状态网关（票 03）：null 时不轮询召回状态。
  final MemoryRecallStatusGateway? _memoryRecallStatusGateway;

  Timer? _monitorTimer;
  bool? _hostAvailable;
  bool _checkingHost = false;

  /// 监控是否已释放：dispose 置位。置位后在途结果静默丢弃——在途探测
  /// 与状态读取无法取消，只能等结果到达时不再让它生效；每次 await 恢复
  /// 处先查这一位，避免向已释放的监听者 notifyListeners。
  bool _disposed = false;

  /// 后台失败状态（ticket 21）：随既有连接探测轮询取用的只读快照；
  /// 取不到时保持原样。
  BackgroundFailureStatus? _backgroundFailure;
  bool _backgroundFailureChecking = false;
  bool _backgroundRecoveredNotice = false;
  Timer? _backgroundRecoveredTimer;

  /// 「已恢复」提示的停留时长：够读到一句话，不久留成常驻。
  static const Duration _backgroundRecoveredNoticeDuration = Duration(
    seconds: 4,
  );

  /// 记忆召回状态（票 03）：只取需要打扰用户的三种（准备中/需重建/
  /// 暂不可用）；未启用、已就绪与取不到时安静，不在聊天输入旁占位。
  MemoryRecallStatus? _memoryRecallStatus;
  bool _memoryRecallChecking = false;

  /// 连接探测三态的原始值：null=未探明，true=可用，false=不可用。
  /// 「已探过一次」之后结论才可信，调用方据此派生正常/故障/进行时措辞。
  bool? get hostAvailable => _hostAvailable;

  /// 当前需要提示的后台失败（ticket 21，未恢复才计）：null 即没有，
  /// 壳层安静位整体不出现。
  BackgroundFailureStatus? get backgroundFailure =>
      _backgroundFailure == null || _backgroundFailure!.recovered
      ? null
      : _backgroundFailure;

  /// 失败恢复后的短暂提示窗口：「已恢复」展示一会儿再隐去，由本模块
  /// 计时；窗口只在「此前真的展示过失败」时开启。
  bool get backgroundRecoveredNotice => _backgroundRecoveredNotice;

  /// 聊天输入旁的记忆召回简短状态（票 03）：准备中显示进度，需重建/
  /// 暂不可用提示不可用；未启用与已就绪安静（不占位）。
  MemoryRecallStatus? get memoryRecallStatus {
    final status = _memoryRecallStatus;
    if (status == null) {
      return null;
    }
    return switch (status.state) {
      'preparing' || 'rebuildNeeded' || 'unavailable' => status,
      _ => null,
    };
  }

  /// 探测一次连接并在 Host 可达时顺带取后台失败状态：手动探测与周期
  /// 轮询共用这一条路径，进行中再次触发直接忽略（重入保护）。
  ///
  /// 释放后调用是安全空操作：不启动新请求、不改状态、不抛错、不通知；
  /// 在途探测在释放之后完成时，结果（含顺带的状态读取）整体静默
  /// 丢弃。
  Future<void> checkHostNow() async {
    if (_disposed || _checkingHost) {
      return;
    }
    _checkingHost = true;
    try {
      final available = await _hostConnectionProbe.isHostAvailable();
      if (_disposed) {
        // 释放后到达的探测结果：静默丢弃，不触碰已释放的三态与监听者。
        return;
      }
      if (_hostAvailable != available) {
        _hostAvailable = available;
        notifyListeners();
      }
      // Host 可达时顺带取一次旁路状态（ticket 21 / 票 03）：不新开轮询，
      // 随既有探测节奏走。
      if (available) {
        await _refreshBackgroundFailure();
        await _refreshMemoryRecallStatus();
      }
    } finally {
      _checkingHost = false;
    }
  }

  /// 取一次后台失败状态并推进安静位的显示状态（ticket 21）：有失败未
  /// 恢复时持续展示；该任务重试成功时回报一次「已恢复」，短暂展示后
  /// 隐去；无失败时整块不占位。状态取不到时保持原样；释放之后到达的
  /// 读取结果静默丢弃——不写快照、不开恢复窗口、不通知。
  Future<void> _refreshBackgroundFailure() async {
    final gateway = _backgroundStatusGateway;
    if (gateway == null || _backgroundFailureChecking) {
      return;
    }
    _backgroundFailureChecking = true;
    try {
      final status = await gateway.read();
      if (_disposed) {
        // 释放后到达的后台状态：静默丢弃，失败快照与恢复窗口保持原样。
        return;
      }
      final previous = _backgroundFailure;
      _backgroundFailure = status;
      if (status != null && !status.recovered) {
        // 有失败未恢复：撤掉恢复提示（若有），安静位持续展示失败。
        _backgroundRecoveredTimer?.cancel();
        _backgroundRecoveredTimer = null;
        _backgroundRecoveredNotice = false;
      } else if (previous != null &&
          !previous.recovered &&
          status != null &&
          status.recovered) {
        // 该任务重试成功：回报一次「已恢复」，短暂展示后隐去。
        _backgroundRecoveredNotice = true;
        _backgroundRecoveredTimer?.cancel();
        _backgroundRecoveredTimer = Timer(
          _backgroundRecoveredNoticeDuration,
          () {
            _backgroundRecoveredNotice = false;
            notifyListeners();
          },
        );
      } else if (status == null) {
        _backgroundRecoveredTimer?.cancel();
        _backgroundRecoveredTimer = null;
        _backgroundRecoveredNotice = false;
      }
      if (previous != status) {
        notifyListeners();
      }
    } on Object {
      // 安静提示是旁路：状态取不到时保持原样。
    } finally {
      _backgroundFailureChecking = false;
    }
  }

  /// 取一次记忆召回状态并推进聊天旁的简短展示（票 03）：状态取不到时
  /// 保持原样；释放之后到达的读取结果静默丢弃。未启用/已就绪时安静。
  Future<void> _refreshMemoryRecallStatus() async {
    final gateway = _memoryRecallStatusGateway;
    if (gateway == null || _memoryRecallChecking) {
      return;
    }
    _memoryRecallChecking = true;
    try {
      final settings = await gateway.read();
      if (_disposed) {
        return;
      }
      final previous = _memoryRecallStatus;
      _memoryRecallStatus = settings?.rag;
      if (previous != _memoryRecallStatus) {
        notifyListeners();
      }
    } on Object {
      // 旁路提示：状态取不到时保持原样，绝不打扰聊天主链路。
    } finally {
      _memoryRecallChecking = false;
    }
  }

  @override
  void dispose() {
    // 先置释放标志：在途探测/后台读取不被取消（适配器无取消能力），其
    // 结果到达时在各 await 恢复处静默丢弃——不改状态、不通知、不开恢
    // 复提示窗口。两个计时器照旧取消。
    _disposed = true;
    _monitorTimer?.cancel();
    _backgroundRecoveredTimer?.cancel();
    super.dispose();
  }
}
