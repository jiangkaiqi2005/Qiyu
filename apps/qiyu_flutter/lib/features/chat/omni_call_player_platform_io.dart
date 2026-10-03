// Omni 通话播放平台的 io（安卓壳）实现（T05）：原生通话桥的专用流式
// 播放（AudioTrack MODE_STREAM），焦点由整通通话持有，生命周期锚在前台
// 服务上——锁屏／切 App 期间照常播（spec:23），不被通用朗读平台的前台
// 闸挡住。音频只在内存流转。
//
// 音量：实现 [VoicePlayerPlatform] 的偏好面（[getInitialVolume]），与
// 朗读链路读同一份持久化音量偏好（voice_output_volume 存储键）——T04
// 的「通话播放沿用朗读音量偏好」在安卓同样成立。整段 [play] 不属于
// 通话链路（通话只消费流式接口），恒返回 null。
//
// widget 测试跑在桌面宿主上，[supported] 如实报告不可用（startStream
// 返回 null，声音如实缺席）；接缝行为测试用构造参数注入 fake 通道并
// 显式指定 [supported]。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'omni_call_native_channel.dart';
import 'voice_player_platform.dart';
import 'voice_player_platform_io.dart';

final class AndroidOmniCallPlayerPlatform
    implements StreamingVoicePlayerPlatform, VoicePlayerPlatform,
        AutoStartVoicePlayerPlatform {
  AndroidOmniCallPlayerPlatform({
    OmniCallNativeChannel? channel,
    VoiceVolumeStore? volumeStore,
    bool? supported,
  }) : _channel = channel ?? MethodOmniCallChannel.instance,
       _injectedVolumeStore = volumeStore,
       _supportedOverride = supported;

  final OmniCallNativeChannel _channel;
  final VoiceVolumeStore? _injectedVolumeStore;
  final bool? _supportedOverride;

  /// 生产装配从朗读平台读同一份进程级音量存储（见 createOmniCallPlayer
  /// Platform）；未注入时偏好如实回到缺省 1.0。
  VoiceVolumeStore? get _volumeStore =>
      _injectedVolumeStore ?? IoVoicePlayerPlatform.sharedVolumeStore;

  @override
  bool get supported => _supportedOverride ?? Platform.isAndroid;

  @override
  Future<bool> prepareForAutoPlayback() async =>
      supported && await _channel.prepareForAutoPlayback();

  @override
  Future<VoiceStreamPlayback?> startStream({
    required int sampleRate,
    double volume = 1.0,
  }) async {
    if (!supported) {
      return null;
    }
    final id = await _channel.startStream(
      sampleRate: sampleRate,
      volume: volume.clamp(0.0, 1.0),
    );
    if (id == null) {
      return null;
    }
    return _AndroidOmniCallStreamPlayback(id, _channel);
  }

  @override
  Future<VoicePlayback?> play(Uint8List bytes, {required String mimeType, double volume = 1.0}) async =>
      null;

  @override
  double getInitialVolume() {
    final parsed = parseVoiceVolumePreference(_volumeStore?.read());
    return parsed ?? 1.0;
  }

  @override
  void saveVolume(double volume) {
    // 通话不新增音量控件；偏好写入仍落同一份存储（控件出现前无消费方）。
    _volumeStore?.write(encodeVoiceVolumePreference(volume));
  }
}

/// 一次安卓通话流式播放会话：块经通道进原生写队列，end 之后播完即
/// done；stop/setVolume 幂等且对已释放句柄安全。焦点打断等原生收口以
/// onPlaybackFinished 通知到达（done 随之完成），下一路回复才能开流。
final class _AndroidOmniCallStreamPlayback implements VoiceStreamPlayback {
  _AndroidOmniCallStreamPlayback(this._id, this._channel) {
    _unsubscribe = _channel.onPlaybackFinished(_onFinished);
  }

  final int _id;
  final OmniCallNativeChannel _channel;
  final Completer<void> _done = Completer<void>();
  late final void Function() _unsubscribe;
  bool _released = false;
  bool _ended = false;

  @override
  void append(Uint8List pcm) {
    if (_released || _ended || pcm.isEmpty) {
      return;
    }
    _swallow(_channel.appendStreamChunk(_id, pcm));
  }

  @override
  void end() {
    if (_released || _ended) {
      return;
    }
    _ended = true;
    _swallow(_channel.endStream(_id));
  }

  @override
  Future<void> get done => _done.future;

  void _onFinished(int id) {
    if (id != _id || _released) {
      return;
    }
    _release();
  }

  @override
  void setVolume(double volume) {
    if (_released) {
      return;
    }
    _swallow(_channel.setStreamVolume(_id, volume.clamp(0.0, 1.0)));
  }

  @override
  void stop() {
    if (_released) {
      return;
    }
    _release();
    // 立即发停止；原生侧释放晚于 done 完成是安全的（幂等）。
    _swallow(_channel.stopStream(_id));
  }

  void _release() {
    _released = true;
    _unsubscribe();
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  /// 停止与调音量的通道异常都以「动作意图已生效」收尾，绝不打断通话。
  static void _swallow(Future<void> future) {
    unawaited(
      future.catchError((Object _) {
        // 静默：与 web 侧对等操作的异常语义一致。
      }),
    );
  }
}

StreamingVoicePlayerPlatform? createOmniCallPlayerPlatform() =>
    AndroidOmniCallPlayerPlatform();
