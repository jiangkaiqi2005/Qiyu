import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'voice_player_platform.dart';

/// Android 原生播放通道名（原生侧 VoiceBridge.kt 注册同名处理器）。
const androidVoicePlayerChannelName = 'dev.qiyu.app/voice_player';

/// 原生播放通道的抽缝：生产实现走 [MethodChannel]，dart 测试注入
/// fake（平台通道行为本身归真机冒烟，不在 dart 测试里 mock 平台业务）。
abstract interface class VoicePlayerNativeChannel {
  /// 请求原生播放一段完整音频字节（MediaPlayer + 内存 MediaDataSource，
  /// 不落盘）。容器由原生侧自行嗅探，不经通道传 MIME。返回播放句柄；
  /// 无法开始播放返回 null。
  Future<int?> startPlayback(
    Uint8List bytes, {
    required double volume,
    int? sessionId,
  });

  /// 停止并释放指定句柄的播放（幂等）。
  Future<void> stopPlayback(int playbackId);

  /// 实时调节指定句柄的播放音量（0.0 ~ 1.0）。
  Future<void> setPlaybackVolume(int playbackId, double volume);

  /// 订阅播放完成/出错回调（自然播完或底层出错都会到达，停止不产生
  /// 回调）；返回退订函数。
  void Function() onPlaybackFinished(void Function(int playbackId) handler);
}

abstract interface class InterruptibleVoicePlayerChannel {
  Future<bool> prepareOutput(int sessionId);
  Future<void> endOutput(int sessionId);
  void Function() onOutputInterrupted(void Function(int sessionId) handler);
}

/// [VoicePlayerNativeChannel] 的 MethodChannel 真实现：进程级单例——
/// 聊天朗读与设置页试听共用同一条底层通道，原生完成回调在此统一
/// 分发给全部订阅者（多实例各自注册会互相顶掉底层 handler）。
///
/// 底层 handler 的注册是惰性的（首次订阅回调或首次起播时才发生）：
/// 仅做音量偏好读写的路径不触碰 platform services，纯 dart 单测无需
/// 测试绑定。
final class MethodVoicePlayerChannel
    implements VoicePlayerNativeChannel, InterruptibleVoicePlayerChannel {
  MethodVoicePlayerChannel._();

  static final MethodVoicePlayerChannel instance = MethodVoicePlayerChannel._();

  static const MethodChannel _channel = MethodChannel(
    androidVoicePlayerChannelName,
  );

  bool _registered = false;
  final List<void Function(int)> _handlers = [];
  final List<void Function(int)> _interruptHandlers = [];

  @override
  Future<bool> prepareOutput(int sessionId) async {
    _ensureRegistered();
    try {
      return await _channel.invokeMethod<bool>('prepareOutput', {
            'sessionId': sessionId,
          }) ??
          false;
    } on Object {
      return false;
    }
  }

  @override
  Future<void> endOutput(int sessionId) async {
    try {
      await _channel.invokeMethod<void>('endOutput', {'sessionId': sessionId});
    } on Object {
      /* 原生可能已收尾。 */
    }
  }

  @override
  void Function() onOutputInterrupted(void Function(int sessionId) handler) {
    _ensureRegistered();
    _interruptHandlers.add(handler);
    return () => _interruptHandlers.remove(handler);
  }

  void _ensureRegistered() {
    if (_registered) {
      return;
    }
    _registered = true;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onOutputInterrupted') {
      final session = (call.arguments as Map<Object?, Object?>?)?['sessionId'];
      if (session is int) {
        for (final handler in List.of(_interruptHandlers)) {
          handler(session);
        }
      }
    }
    if (call.method == 'onPlaybackFinished') {
      final id = (call.arguments as Map<Object?, Object?>?)?['id'];
      if (id is int) {
        for (final handler in List.of(_handlers)) {
          handler(id);
        }
      }
    }
  }

  @override
  Future<int?> startPlayback(
    Uint8List bytes, {
    required double volume,
    int? sessionId,
  }) async {
    _ensureRegistered();
    try {
      // 载荷里没有 mimeType：原生 MediaPlayer 从 MediaDataSource 自行嗅探
      // 容器，多送一个键只会被无声忽略，留下「原生认识 MIME」的错觉。
      return await _channel.invokeMethod<int>('startPlayback', {
        'bytes': bytes,
        'volume': volume.clamp(0.0, 1.0),
        'sessionId': ?sessionId,
      });
    } on Object {
      return null;
    }
  }

  @override
  Future<void> stopPlayback(int playbackId) async {
    try {
      await _channel.invokeMethod<void>('stopPlayback', {
        'id': playbackId,
      });
    } on Object {
      // 停止以「不再出声」为准；句柄可能已被原生侧释放，异常吞掉。
    }
  }

  @override
  Future<void> setPlaybackVolume(int playbackId, double volume) async {
    try {
      await _channel.invokeMethod<void>('setPlaybackVolume', {
        'id': playbackId,
        'volume': volume.clamp(0.0, 1.0),
      });
    } on Object {
      // 与 web 侧 setVolume 同语义：调节失败不影响播放继续。
    }
  }

  @override
  void Function() onPlaybackFinished(void Function(int playbackId) handler) {
    _ensureRegistered();
    _handlers.add(handler);
    return () => _handlers.remove(handler);
  }
}

/// 音量偏好的本地存储抽缝：读写的是已序列化的字符串值（形如 "0.80"）。
/// web 侧落在 localStorage（见 [voiceOutputVolumeStorageKey]），安卓侧
/// 落在应用私有目录同名文件——语义完全同构：同步读、失败静默。
abstract interface class VoiceVolumeStore {
  /// 读取存储值；从未存过或读不出来返回 null（调用方退回缺省 1.0）。
  String? read();

  /// 写入存储值；失败静默（音量偏好丢失只是回到缺省，不该打扰用户）。
  void write(String value);
}

/// 安卓实现：应用私有目录（与 provider.json 同级的 runtime 目录）下的
/// 小文本文件。音量偏好与折叠状态同属「本地 UI 状态存储」先例——不进
/// 主持久化链路、不涉网络、不涉凭据。
final class FileVoiceVolumeStore implements VoiceVolumeStore {
  FileVoiceVolumeStore(this.directory);

  final Directory directory;

  File get _file => File(
    '${directory.path}${Platform.pathSeparator}$voiceOutputVolumeStorageKey',
  );

  @override
  String? read() {
    try {
      final file = _file;
      if (!file.existsSync()) {
        return null;
      }
      return file.readAsStringSync();
    } on Object {
      return null;
    }
  }

  @override
  void write(String value) {
    try {
      _file
        ..createSync(recursive: true)
        ..writeAsStringSync(value, flush: true);
    } on Object {
      // 与 web 侧 localStorage 写入异常同语义：静默。
    }
  }
}

/// io 平台（安卓壳）的朗读接缝实现：Host 经 `/api/chat/speak` 返回的
/// 完整 mp3 字节交原生 MediaPlayer 播放（内存 MediaDataSource，整段
/// 播放、不落盘），音量/静音持久化复用 web 的 localStorage 语义——
/// 同一键名、同一序列化格式、同一缺省与钳制规则，重启后保持。
///
/// Android 无浏览器的自动播放手势限制，不实现
/// [UserGestureVoicePlayerPlatform]（扩展函数对其自动退化为空操作）。
///
/// widget 测试跑在桌面宿主上，[supported] 如实报告不可用（与 stub 同
/// 语义）；接缝行为测试用构造参数注入 fake 通道与音量存储。
final class IoVoicePlayerPlatform
    implements VoicePlayerPlatform, InterruptibleVoicePlayerPlatform {
  IoVoicePlayerPlatform({
    VoicePlayerNativeChannel? channel,
    VoiceVolumeStore? volumeStore,
    bool? supported,
  }) : _channel = channel ?? MethodVoicePlayerChannel.instance,
       _injectedVolumeStore = volumeStore,
       _supportedOverride = supported;

  static VoiceVolumeStore? _defaultVolumeStore;

  /// 注入进程级缺省音量存储目录：`getInitialVolume()` 是同步接口，而安卓
  /// 取应用私有目录必须 await，所以只能由启动装配在起 Host 之后、任何
  /// 控制器构造之前把结果交给同步侧。**传 null 即撤销注入**（回到「没有
  /// 任何存储」的状态）——测试据此显式声明前置条件，不靠「这个全局从未被
  /// 写过」的隐式事实。未注入时音量偏好如实回到缺省 1.0、保存静默跳过。
  static void configureDefaultVolumeStore(Directory? directory) {
    _defaultVolumeStore = directory == null
        ? null
        : FileVoiceVolumeStore(directory);
  }

  final VoicePlayerNativeChannel _channel;
  final VoiceVolumeStore? _injectedVolumeStore;
  final bool? _supportedOverride;
  static int _nextSession = 0;
  int? _session;

  @override
  void Function() onOutputInterrupted(void Function() handler) {
    if (!supported) return () {};
    if (_channel case final InterruptibleVoicePlayerChannel channel) {
      return channel.onOutputInterrupted((session) {
        if (_session != session) return;
        endOutput();
        handler();
      });
    }
    return () {};
  }

  @override
  Future<bool> beginOutput() async {
    endOutput();
    // 非安卓宿主沿用既有合成/连接测试结果，再由 play 如实报告不可播放。
    if (!supported) return true;
    final session = ++_nextSession;
    _session = session;
    if (_channel case final InterruptibleVoicePlayerChannel channel) {
      final allowed = await channel.prepareOutput(session);
      if (_session != session) {
        await channel.endOutput(session);
        return false;
      }
      if (!allowed) {
        endOutput();
        return false;
      }
    }
    return true;
  }

  @override
  void endOutput() {
    final session = _session;
    _session = null;
    if (session == null) return;
    if (_channel case final InterruptibleVoicePlayerChannel channel) {
      unawaited(channel.endOutput(session));
    }
  }

  VoiceVolumeStore? get _volumeStore =>
      _injectedVolumeStore ?? _defaultVolumeStore;

  @override
  bool get supported => _supportedOverride ?? Platform.isAndroid;

  @override
  double getInitialVolume() {
    // 解析规则与 web 侧共用一份纯函数；本侧不包 try/catch，存储替身抛出的
    // 异常照旧向外传播，只负责「没有存储 / 文本不可用」时退回缺省 1.0。
    final parsed = parseVoiceVolumePreference(_volumeStore?.read());
    if (parsed != null) {
      return parsed;
    }
    return 1.0;
  }

  @override
  void saveVolume(double volume) {
    // 编码留作 write 的实参：未注入存储时整个调用短路，连编码都不求值。
    _volumeStore?.write(encodeVoiceVolumePreference(volume));
  }

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
    double volume = 1.0,
  }) async {
    if (!supported) {
      return null;
    }
    // mimeType 是接缝（web 需要它选解码器）要求的形参，安卓侧不收下：
    // 原生 MediaPlayer 自己嗅探容器，上送也没有消费方。
    // 直接调用平台的旧入口也遵守焦点策略；控制器在合成前已准备则复用。
    if (_session == null && !await beginOutput()) return null;
    final session = _session;
    final id = await _channel.startPlayback(
      bytes,
      volume: volume,
      sessionId: session,
    );
    if (id == null) {
      if (_session == session) endOutput();
      return null;
    }
    if (_session != session) {
      await _channel.stopPlayback(id);
      return null;
    }
    return _AndroidVoicePlayback(id, _channel);
  }
}

/// 一次安卓播放会话：done 在自然播完、被 stop 或底层出错时完成（不抛，
/// 与 web 契约一致）；stop/setVolume 幂等且对已释放句柄安全。
final class _AndroidVoicePlayback implements VoicePlayback {
  _AndroidVoicePlayback(this._id, this._channel) {
    _unsubscribe = _channel.onPlaybackFinished(_onFinished);
  }

  final int _id;
  final VoicePlayerNativeChannel _channel;
  final Completer<void> _done = Completer<void>();
  late final void Function() _unsubscribe;
  bool _released = false;

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
    _swallow(_channel.setPlaybackVolume(_id, volume.clamp(0.0, 1.0)));
  }

  @override
  void stop() {
    if (_released) {
      return;
    }
    _release();
    // 立即发停止；原生侧释放晚于 done 完成是安全的（幂等）。
    _swallow(_channel.stopPlayback(_id));
  }

  void _release() {
    _released = true;
    _unsubscribe();
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  /// 停止与调音量的通道异常都以「动作意图已生效」收尾，绝不打断聊天。
  static void _swallow(Future<void> future) {
    unawaited(
      future.catchError((Object _) {
        // 静默：与 web 侧对等操作的异常语义一致。
      }),
    );
  }
}

VoicePlayerPlatform createVoicePlayerPlatform() => IoVoicePlayerPlatform();
