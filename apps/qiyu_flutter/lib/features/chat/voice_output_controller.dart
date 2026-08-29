import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'local_chat_client.dart';
import 'voice_player_platform.dart';

/// 一条待朗读的栖语交付段定位：Host 按 (requestId, deliveryIndex) 从已
/// 落盘 session 取文字（浏览器只传定位符，Host 是文字真相源）。
final class VoiceOutputRequest {
  const VoiceOutputRequest({
    required this.requestId,
    required this.deliveryIndex,
    this.sessionId,
  });

  final String requestId;
  final int deliveryIndex;
  final String? sessionId;
}

enum VoiceOutputPhase { idle, synthesizing, playing }

/// 语音朗读的播放队列（ADR 0002）：按序全播、不抢占正在播的一段；
/// 停止按钮 / Esc / 点麦克风清空全部队列；点小喇叭重听则立即顶播。
/// 合成或播放失败：同一页面生命周期内首次以人话提示一次，之后安静
/// 跳过——文字早已交付，读不出来绝不打断聊天主链路。
final class VoiceOutputController extends ChangeNotifier {
  VoiceOutputController(this._gateway, {VoicePlayerPlatform? playerPlatform})
    : // 缺省走平台接缝：web 真播放，其余环境如实「不支持」降级。
      _playerPlatform = playerPlatform ?? createVoicePlayerPlatform() {
    _volume = _playerPlatform.getInitialVolume();
  }

  final ChatSpeechGateway _gateway;
  final VoicePlayerPlatform _playerPlatform;

  late double _volume;
  final Queue<VoiceOutputRequest> _queue = Queue();
  var _generation = 0;
  bool _failureNotified = false;
  bool _sessionInitialized = false;
  String? _sessionId;
  VoicePlayback? _activePlayback;

  VoiceOutputPhase _phase = VoiceOutputPhase.idle;
  VoiceOutputRequest? _nowReading;
  String? _failureNotice;

  /// 控制器是否已释放：[stopAllForLeavingPage] 的通知排在微任务里，可能落在
  /// 释放之后，那时再 notifyListeners 会撞 ChangeNotifier 的释放断言。
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  VoiceOutputPhase get phase => _phase;
  VoiceOutputRequest? get nowReading => _nowReading;
  double get volume => _volume;

  void setVolume(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if ((_volume - clamped).abs() < 0.001) {
      return;
    }
    _volume = clamped;
    _playerPlatform.saveVolume(_volume);
    _activePlayback?.setVolume(_volume);
    notifyListeners();
  }

  /// 最近一次失败的人话提示：同一生命周期最多置一次（首次提示后续
  /// 静默），UI 展示后调用 [consumeFailureNotice] 清除。
  String? get failureNotice => _failureNotice;

  bool get isReading => _phase != VoiceOutputPhase.idle;

  /// 自动朗读入口（message 事件 diff 出的新 bubble）。朗读开关关闭
  /// （enabled=false）时直接丢弃，不排队。
  void offer(VoiceOutputRequest request, {required bool enabled}) {
    if (!enabled) {
      return;
    }
    _enterSession(request.sessionId);
    _queue.addLast(request);
    _drain();
  }

  /// 手动重听（气泡小喇叭）：用户主动点播优先于自动队列——立即播这
  /// 条，正在播的直接顶掉，清空自动排队（用户要听的是这一句）。
  void playNow(VoiceOutputRequest request) {
    prepareForUserInitiatedPlayback();
    _enterSession(request.sessionId);
    _abandonActive(incrementGeneration: true);
    _phase = VoiceOutputPhase.idle;
    _nowReading = null;
    _queue
      ..clear()
      ..addLast(request);
    _drain();
  }

  /// 用户发送消息或主动点播时调用；必须发生在第一个 await 前。
  void prepareForUserInitiatedPlayback() {
    _playerPlatform.prepareForUserGesturePlayback();
  }

  /// 停止播放并清空队列（停止按钮 / Esc / 点麦克风立即停播）。
  void stopAll() {
    _haltNow();
    notifyListeners();
  }

  /// 离开聊天页时的停播（ADR 0002）：动作与 [stopAll] **完全一致**（同走
  /// [_haltNow]）——立刻停声、清掉排队的气泡、作废在途合成——只有通知时机不同。
  ///
  /// 页面卸载跑在框架锁定树的阶段，而卸载顺序是「先子后父」：轮到 `State.dispose`
  /// 时本页的 `AnimatedBuilder` 已经 defunct 却可能还没解除订阅，同步
  /// [notifyListeners] 会打在它们身上抛「setState() or markNeedsBuild() called
  /// when widget tree was locked」。「只在 isReading 时才停」是靠削弱这条语义来
  /// 绕开崩溃，代价是排队的 bubble 跨页继续朗读。改成把通知延到本帧之后：正在
  /// 消失的监听者届时已解除订阅，还活着的监听者（例如路由过渡期同时挂着的另一个
  /// 聊天页）照常收到更新。
  void stopAllForLeavingPage() {
    _haltNow();
    scheduleMicrotask(() {
      if (_disposed) {
        return;
      }
      notifyListeners();
    });
  }

  /// 立即停播的公共动作：作废在途的合成/播放并清队，状态回到 idle。
  /// 唯一的差别（要不要通知、什么时候通知）留在两个调用方身上。
  void _haltNow() {
    _abandonActive(incrementGeneration: true);
    _phase = VoiceOutputPhase.idle;
    _nowReading = null;
  }

  void consumeFailureNotice() {
    if (_failureNotice == null) {
      return;
    }
    _failureNotice = null;
    notifyListeners();
  }

  /// 作废当前活动播放/合成并清空队列；generation 递增让在途异步结果
  /// 完成时能识别出自己已被作废。
  void _abandonActive({required bool incrementGeneration}) {
    if (incrementGeneration) {
      _generation += 1;
    }
    _queue.clear();
    _activePlayback?.stop();
    _activePlayback = null;
  }

  Future<void> _drain() async {
    if (_phase != VoiceOutputPhase.idle) {
      // 已有一段在读/在合成：新项已在队列里，按序等它读完。
      return;
    }
    while (_queue.isNotEmpty) {
      final request = _queue.removeFirst();
      final generation = _generation;
      _phase = VoiceOutputPhase.synthesizing;
      _nowReading = request;
      notifyListeners();
      final Uint8List audio;
      try {
        audio = await _gateway.speak(
          requestId: request.requestId,
          deliveryIndex: request.deliveryIndex,
          sessionId: request.sessionId,
        );
      } on Object {
        if (generation != _generation) {
          return;
        }
        _notifyFailureOnce('语音服务连不上，这条读不出来。');
        continue;
      }
      if (generation != _generation) {
        return;
      }
      final playback = await _playerPlatform.play(
        audio,
        mimeType: 'audio/mpeg',
        volume: _volume,
      );
      if (generation != _generation) {
        playback?.stop();
        return;
      }
      if (playback == null) {
        // 合成已成功；浏览器策略、解码或音频设备失败不能冒充服务断线。
        _notifyFailureOnce('浏览器没能播放，点小喇叭再听一次。');
        continue;
      }
      _activePlayback = playback;
      _phase = VoiceOutputPhase.playing;
      notifyListeners();
      await playback.done;
      if (generation != _generation) {
        return;
      }
      _activePlayback = null;
    }
    _phase = VoiceOutputPhase.idle;
    _nowReading = null;
    notifyListeners();
  }

  void _notifyFailureOnce(String message) {
    if (!_failureNotified) {
      _failureNotified = true;
      _failureNotice = message;
      notifyListeners();
    }
  }

  void _enterSession(String? sessionId) {
    if (_sessionInitialized && _sessionId == sessionId) {
      return;
    }
    _sessionInitialized = true;
    _sessionId = sessionId;
    _failureNotified = false;
    _failureNotice = null;
  }
}
