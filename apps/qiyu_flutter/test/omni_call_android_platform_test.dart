import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/chat/omni_call_native_channel.dart';
import 'package:qiyu_flutter/features/chat/omni_call_player_platform_io.dart';
import 'package:qiyu_flutter/features/chat/voice_capture_platform_io.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform_io.dart';

/// Omni 通话平台缝 io（安卓）侧的契约验收（T05）：
///
/// - **采集**：权限先查后请、拒绝/起采失败都如实返回 null 且不留监听；
///   成功后块与中断原样转发，setMuted 与 stop 幂等转发原生；
/// - **播放**：起流失败返回 null，append/end/setVolume/stop 转发，
///   done 在原生收口回调（onPlaybackFinished）时完成，显式 stop 之后
///   不再转发；
/// - 音量偏好与朗读链路读同一份存储（同一解析规则），未注入时缺省 1.0。
///
/// 通道行为（AudioRecord/AudioTrack/前台服务/权限弹窗）归真机冒烟；
/// dart 测试注入 fake 通道验证我们自己的粘合与契约层。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeOmniCallChannel channel;

  setUp(() {
    channel = _FakeOmniCallChannel();
  });

  group('Omni 连续采集平台（AndroidVoiceCapturePlatform）', () {
    test('不支持的平台如实返回 null，不触碰通道', () async {
      final platform = AndroidVoiceCapturePlatform(
        channel: channel,
        supported: false,
      );

      final session = await platform.start(
        onChunk: (_) => fail('不应收到块'),
        onUnavailable: (_) => fail('不应收到中断'),
      );

      expect(session, isNull);
      expect(channel.hasPermissionCalls, 0);
      expect(channel.startCaptureCalls, 0);
    });

    test('权限被拒不开始采集', () async {
      channel
        ..micPermission = false
        ..requestResult = false;
      final platform = AndroidVoiceCapturePlatform(
        channel: channel,
        supported: true,
      );

      final session = await platform.start(
        onChunk: (_) => fail('不应收到块'),
        onUnavailable: (_) => fail('不应收到中断'),
      );

      expect(session, isNull);
      expect(channel.requestPermissionCalls, 1);
      expect(channel.startCaptureCalls, 0);
    });

    test('已授权直接起采：块与中断原样转发', () async {
      final chunks = <Uint8List>[];
      final unavailable = <String>[];
      final platform = AndroidVoiceCapturePlatform(
        channel: channel,
        supported: true,
      );
      final session = await platform.start(
        onChunk: chunks.add,
        onUnavailable: unavailable.add,
      );

      expect(session, isNotNull);
      expect(channel.hasPermissionCalls, 1);
      expect(channel.requestPermissionCalls, 0);
      expect(channel.startCaptureCalls, 1);

      final pcm = Uint8List(3200);
      channel.emitChunk(pcm);
      channel.emitUnavailable('microphone device removed');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(chunks, hasLength(1));
      expect(identical(chunks.single, pcm), isTrue);
      expect(unavailable, ['microphone device removed']);
    });

    test('原生起采失败返回 null 且已建订阅被摘除', () async {
      channel.startCaptureResult = false;
      final chunks = <Uint8List>[];
      final platform = AndroidVoiceCapturePlatform(
        channel: channel,
        supported: true,
      );

      final session = await platform.start(
        onChunk: chunks.add,
        onUnavailable: (_) => fail('不应收到中断'),
      );

      expect(session, isNull);
      expect(channel.startCaptureCalls, 1);
      channel.emitChunk(Uint8List(2));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(chunks, isEmpty);
    });

    test('setMuted 转发原生；stop 幂等且收口后不再转发', () async {
      final chunks = <Uint8List>[];
      final platform = AndroidVoiceCapturePlatform(
        channel: channel,
        supported: true,
      );
      final session = await platform.start(
        onChunk: chunks.add,
        onUnavailable: (_) => fail('不应收到中断'),
      );

      session!.setMuted(true);
      await Future<void>.delayed(Duration.zero);
      expect(channel.muteCalls, [true]);

      session.stop();
      session.stop();
      await Future<void>.delayed(Duration.zero);
      expect(channel.stopCaptureCalls, 1);

      channel.emitChunk(Uint8List(2));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(chunks, isEmpty);
    });
  });

  group('Omni 通话播放平台（AndroidOmniCallPlayerPlatform）', () {
    test('不支持的平台起流返回 null，不触碰通道', () async {
      final platform = AndroidOmniCallPlayerPlatform(
        channel: channel,
        supported: false,
      );

      expect(
        await platform.startStream(sampleRate: 24000),
        isNull,
      );
      expect(channel.streamStarts, isEmpty);
    });

    test('起流失败返回 null', () async {
      channel.startStreamId = null;
      final platform = AndroidOmniCallPlayerPlatform(
        channel: channel,
        supported: true,
      );

      expect(
        await platform.startStream(sampleRate: 24000),
        isNull,
      );
      expect(channel.streamStarts, hasLength(1));
    });

    test('append/end/setVolume 转发；显式 stop 转发且此后静默', () async {
      final platform = AndroidOmniCallPlayerPlatform(
        channel: channel,
        supported: true,
      );
      final playback = await platform.startStream(sampleRate: 24000);

      expect(playback, isNotNull);
      expect(channel.streamStarts.single.$1, 24000);
      expect(channel.streamStarts.single.$2, 1.0);

      final pcm = Uint8List(48);
      playback!.append(pcm);
      playback.setVolume(0.5);
      await Future<void>.delayed(Duration.zero);
      expect(identical(channel.appended.single, pcm), isTrue);
      expect(channel.volumeCalls.single, (channel.startStreamId!, 0.5));

      playback.stop();
      await Future<void>.delayed(Duration.zero);
      expect(channel.stops, [channel.startStreamId]);

      // 已释放：append 与 stop 都不再转发。
      playback.append(pcm);
      playback.stop();
      await Future<void>.delayed(Duration.zero);
      expect(channel.appended, hasLength(1));
      expect(channel.stops, hasLength(1));
    });

    test('end 后 append 不再转发；原生收口回调完成 done', () async {
      final platform = AndroidOmniCallPlayerPlatform(
        channel: channel,
        supported: true,
      );
      final playback = (await platform.startStream(sampleRate: 24000))!;

      playback.append(Uint8List(48));
      playback.end();
      await Future<void>.delayed(Duration.zero);
      expect(channel.ends, [channel.startStreamId]);
      expect(channel.appended, hasLength(1));

      var doneResolved = false;
      unawaited(playback.done.then((_) => doneResolved = true));
      await Future<void>.delayed(Duration.zero);
      expect(doneResolved, isFalse);

      channel.emitFinished(channel.startStreamId!);
      await Future<void>.delayed(Duration.zero);
      expect(doneResolved, isTrue);
    });

    test('音量偏好与朗读链路同一份存储与解析规则', () async {
      final store = _FakeVolumeStore('0.80');
      final platform = AndroidOmniCallPlayerPlatform(
        channel: channel,
        volumeStore: store,
      );
      expect(platform.getInitialVolume(), 0.8);

      final fallback = AndroidOmniCallPlayerPlatform(channel: channel);
      expect(fallback.getInitialVolume(), 1.0);

      // 越界与不可解析文本都退回缺省（与共享解析函数同一口径）。
      expect(
        AndroidOmniCallPlayerPlatform(
          channel: channel,
          volumeStore: _FakeVolumeStore('1.50'),
        ).getInitialVolume(),
        1.0,
      );
    });
  });

  test('条件出口工厂在 io 构建上装配安卓通话平台', () {
    expect(createVoiceCapturePlatform(), isA<AndroidVoiceCapturePlatform>());
    expect(createOmniCallPlayerPlatform(), isA<AndroidOmniCallPlayerPlatform>());
  });

  group('MethodOmniCallChannel（真通道粘合，mock 平台回包）', () {
    const channelName = MethodChannel(androidOmniCallChannelName);

    Future<void> deliver(MethodCall call) async {
      await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
            androidOmniCallChannelName,
            const StandardMethodCodec().encodeMethodCall(call),
            (_) {},
          );
      await Future<void>.delayed(Duration.zero);
    }

    test('dart→原生方法逐条按约定载荷发送并解析回包', () async {
      final sent = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channelName, (call) async {
        sent.add(call);
        switch (call.method) {
          case 'hasMicrophonePermission':
          case 'requestMicrophonePermission':
          case 'startCapture':
            return true;
          case 'startStream':
            return 7;
          default:
            return null;
        }
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channelName, null),
      );

      final channel = MethodOmniCallChannel.instance;
      expect(await channel.hasMicrophonePermission(), isTrue);
      expect(await channel.requestMicrophonePermission(), isTrue);
      expect(await channel.startCapture(), isTrue);
      await channel.stopCapture();
      await channel.setMuted(true);
      expect(await channel.startStream(sampleRate: 24000, volume: 0.5), 7);
      final pcm = Uint8List.fromList([1, 2, 3, 4]);
      await channel.appendStreamChunk(7, pcm);
      await channel.endStream(7);
      await channel.setStreamVolume(7, 0.5);
      await channel.stopStream(7);

      final byMethod = {for (final call in sent) call.method: call.arguments};
      expect(byMethod['setMuted'], isTrue);
      expect(byMethod['startStream'], {'sampleRate': 24000, 'volume': 0.5});
      expect(byMethod['appendStreamChunk'], {'id': 7, 'bytes': pcm});
      expect(byMethod['endStream'], {'id': 7});
      expect(byMethod['setStreamVolume'], {'id': 7, 'volume': 0.5});
      expect(byMethod['stopStream'], {'id': 7});
      expect(byMethod['stopCapture'], isNull);
    });

    test('通道异常按降级语义收口：布尔归 false、句柄归 null、void 不抛', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channelName, (call) async {
        throw PlatformException(code: 'DOWN');
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channelName, null),
      );

      final channel = MethodOmniCallChannel.instance;
      expect(await channel.hasMicrophonePermission(), isFalse);
      expect(await channel.requestMicrophonePermission(), isFalse);
      expect(await channel.startCapture(), isFalse);
      expect(
        await channel.startStream(sampleRate: 24000, volume: 1.0),
        isNull,
      );
      await channel.stopCapture();
      await channel.setMuted(true);
      await channel.appendStreamChunk(1, Uint8List(2));
      await channel.endStream(1);
      await channel.setStreamVolume(1, 0.5);
      await channel.stopStream(1);
    });

    test('原生下行三路分发：块/中断/播放收口；退订后静默，未知方法忽略', () async {
      final channel = MethodOmniCallChannel.instance;
      final chunks = <Uint8List>[];
      final reasons = <String>[];
      final finished = <int>[];
      final unsubscribeChunk = channel.onCaptureChunk(chunks.add);
      final unsubscribeUnavailable = channel.onCaptureUnavailable(reasons.add);
      final unsubscribeFinished = channel.onPlaybackFinished(finished.add);
      addTearDown(() {
        unsubscribeChunk();
        unsubscribeUnavailable();
        unsubscribeFinished();
      });

      final pcm = Uint8List.fromList([9, 8]);
      await deliver(MethodCall('onCaptureChunk', pcm));
      await deliver(
        const MethodCall('onCaptureUnavailable', {'reason': 'mic removed'}),
      );
      await deliver(const MethodCall('onPlaybackFinished', {'id': 9}));

      expect(chunks.single, pcm);
      expect(reasons, ['mic removed']);
      expect(finished, [9]);

      unsubscribeChunk();
      unsubscribeUnavailable();
      unsubscribeFinished();
      await deliver(MethodCall('onCaptureChunk', pcm));
      await deliver(const MethodCall('onCaptureUnavailable', {'reason': 'y'}));
      await deliver(const MethodCall('onPlaybackFinished', {'id': 9}));
      await deliver(const MethodCall('onUnknownNativeMethod'));

      expect(chunks, hasLength(1));
      expect(reasons, ['mic removed']);
      expect(finished, [9]);
    });
  });
}

final class _FakeOmniCallChannel implements OmniCallNativeChannel {
  bool micPermission = true;
  bool requestResult = true;
  bool startCaptureResult = true;
  int? startStreamId = 42;

  int hasPermissionCalls = 0;
  int requestPermissionCalls = 0;
  int startCaptureCalls = 0;
  int stopCaptureCalls = 0;
  final List<bool> muteCalls = [];
  final List<(int, double)> streamStarts = [];
  final List<Uint8List> appended = [];
  final List<int> ends = [];
  final List<int> stops = [];
  final List<(int, double)> volumeCalls = [];

  final _chunks = StreamController<Uint8List>.broadcast();
  final _unavailable = StreamController<String>.broadcast();
  final _finished = StreamController<int>.broadcast();

  void emitChunk(Uint8List pcm) => _chunks.add(pcm);
  void emitUnavailable(String reason) => _unavailable.add(reason);
  void emitFinished(int id) => _finished.add(id);

  @override
  Future<bool> hasMicrophonePermission() async {
    hasPermissionCalls++;
    return micPermission;
  }

  @override
  Future<bool> requestMicrophonePermission() async {
    requestPermissionCalls++;
    return requestResult;
  }

  @override
  Future<bool> startCapture() async {
    startCaptureCalls++;
    return startCaptureResult;
  }

  @override
  Future<void> stopCapture() async {
    stopCaptureCalls++;
  }

  @override
  Future<void> setMuted(bool muted) async {
    muteCalls.add(muted);
  }

  @override
  void Function() onCaptureChunk(void Function(Uint8List pcm) handler) =>
      _chunks.stream.listen(handler).cancel;

  @override
  void Function() onCaptureUnavailable(
    void Function(String reason) handler,
  ) => _unavailable.stream.listen(handler).cancel;

  @override
  Future<int?> startStream({
    required int sampleRate,
    required double volume,
  }) async {
    streamStarts.add((sampleRate, volume));
    return startStreamId;
  }

  @override
  Future<void> appendStreamChunk(int streamId, Uint8List pcm) async {
    appended.add(pcm);
  }

  @override
  Future<void> endStream(int streamId) async {
    ends.add(streamId);
  }

  @override
  Future<void> setStreamVolume(int streamId, double volume) async {
    volumeCalls.add((streamId, volume));
  }

  @override
  Future<void> stopStream(int streamId) async {
    stops.add(streamId);
  }

  @override
  void Function() onPlaybackFinished(void Function(int streamId) handler) =>
      _finished.stream.listen(handler).cancel;
}

final class _FakeVolumeStore implements VoiceVolumeStore {
  _FakeVolumeStore(this.value);

  final String value;

  @override
  String? read() => value;

  @override
  void write(String value) {}
}
