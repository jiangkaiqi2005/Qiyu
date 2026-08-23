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
      _playerPlatform = playerPlatform ?? createVoicePlayerPlatform();

  final ChatSpeechGateway _gateway;
  final VoicePlayerPlatform _playerPlatform;

  final Queue<VoiceOutputRequest> _queue = Queue();
  var _generation = 0;
  bool _failureNotified = false;
  VoicePlayback? _activePlayback;

  VoiceOutputPhase _phase = VoiceOutputPhase.idle;
  VoiceOutputRequest? _nowReading;
  String? _failureNotice;

  VoiceOutputPhase get phase => _phase;
  VoiceOutputRequest? get nowReading => _nowReading;

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
    _queue.addLast(request);
    _drain();
  }

  /// 手动重听（气泡小喇叭）：用户主动点播优先于自动队列——立即播这
  /// 条，正在播的直接顶掉，清空自动排队（用户要听的是这一句）。
  void playNow(VoiceOutputRequest request) {
    _abandonActive(incrementGeneration: true);
    _phase = VoiceOutputPhase.idle;
    _nowReading = null;
    _queue
      ..clear()
      ..addLast(request);
    _drain();
  }

  /// 停止播放并清空队列（停止按钮 / Esc / 点麦克风立即停播）。
  void stopAll() {
    _abandonActive(incrementGeneration: true);
    _phase = VoiceOutputPhase.idle;
    _nowReading = null;
    notifyListeners();
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
        _notifyFailureOnce();
        continue;
      }
      if (generation != _generation) {
        return;
      }
      final playback = await _playerPlatform.play(
        audio,
        mimeType: 'audio/mpeg',
      );
      if (generation != _generation) {
        playback?.stop();
        return;
      }
      if (playback == null) {
        // 浏览器自动播放被拒或解码失败：与合成失败同款降级。
        _notifyFailureOnce();
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

  void _notifyFailureOnce() {
    if (!_failureNotified) {
      _failureNotified = true;
      _failureNotice = '语音服务连不上，这条读不出来。';
      notifyListeners();
    }
  }
}
