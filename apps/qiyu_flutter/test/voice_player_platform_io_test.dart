import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform_io.dart';

/// 播放平台缝 io（安卓）侧的契约对齐验收（票 06 硬验收）：
///
/// - **播放器音量/静音持久化读写**：与 web 的 localStorage 语义逐条
///   同构——同一键名常量、同一 "0.00"~"1.00" 序列化格式、可解析且有限
///   且在 0..1 内才采纳、缺省 1.0、保存钳制、读写失败静默；新建实例
///   重读即「重启后保持」；
/// - 播放会话语义与 web 一致：done 在自然播完/被停止/底层出错时完成
///   （不抛），stop 幂等，setVolume 实时生效且对已释放句柄安全；
/// - 通道行为（MediaPlayer 真发声）归真机冒烟；dart 测试注入 fake
///   通道与临时目录音量存储。
void main() {
  group('音量/静音持久化（与 web localStorage 语义同构）', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('qiyu_voice_volume_test');
      // 显式声明前置：本组用例跑在「没有进程级缺省音量存储」的状态下，
      // 不靠「这个全局从未被写过」的隐式事实。
      IoVoicePlayerPlatform.configureDefaultVolumeStore(null);
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('保存后可读回，文件内容与 web 的序列化格式一致（toStringAsFixed(2)）',
        () {
      final store = FileVoiceVolumeStore(tempDir);

      store.write(0.4.toStringAsFixed(2));

      expect(store.read(), '0.40');
      expect(
        File(
          '${tempDir.path}${Platform.pathSeparator}$voiceOutputVolumeStorageKey',
        ).readAsStringSync(),
        '0.40',
      );
    });

    test('从未存过：read 返回 null，getInitialVolume 退回缺省 1.0', () {
      final platform = IoVoicePlayerPlatform(
        supported: true,
        volumeStore: FileVoiceVolumeStore(tempDir),
      );

      expect(FileVoiceVolumeStore(tempDir).read(), isNull);
      expect(platform.getInitialVolume(), 1.0);
    });

    test('保存 0.0 即一键静音持久化：重启（新实例）后仍是静音', () {
      final first = IoVoicePlayerPlatform(
        supported: true,
        volumeStore: FileVoiceVolumeStore(tempDir),
      );

      first.saveVolume(0.0);

      // 模拟重启：全新实例重读同一存储。
      final second = IoVoicePlayerPlatform(
        supported: true,
        volumeStore: FileVoiceVolumeStore(tempDir),
      );
      expect(second.getInitialVolume(), 0.0);
    });

    test('任意档位保存→新实例重读往返无损，重启后保持', () {
      final first = IoVoicePlayerPlatform(
        supported: true,
        volumeStore: FileVoiceVolumeStore(tempDir),
      );

      const volumes = [1.0, 0.8, 0.5, 0.05];
      for (final volume in volumes) {
        first.saveVolume(volume);
        final second = IoVoicePlayerPlatform(
          supported: true,
          volumeStore: FileVoiceVolumeStore(tempDir),
        );
        expect(second.getInitialVolume(), volume);
      }
    });

    test('越界值保存前钳制到 0..1（与 web 保存语义一致）', () {
      final store = FileVoiceVolumeStore(tempDir);

      IoVoicePlayerPlatform(supported: true, volumeStore: store)
        ..saveVolume(1.7)
        ..saveVolume(-0.5);

      // 两次连续保存，后者生效且都已钳制。
      expect(store.read(), '0.00');
    });

    test('存储内容非法（不可解析/越界/NaN）按缺省 1.0 呈现', () {
      final store = FileVoiceVolumeStore(tempDir);
      final platform = IoVoicePlayerPlatform(
        supported: true,
        volumeStore: store,
      );

      for (final broken in ['abc', '', '1.5', '-0.2', 'NaN', 'Infinity']) {
        store.write(broken);
        expect(platform.getInitialVolume(), 1.0, reason: '内容 "$broken" 应退回缺省');
      }
    });

    test('保存目录不存在时自动创建并往返成功；读不存在的内容返回 null', () {
      final store = FileVoiceVolumeStore(Directory('${tempDir.path}/nested/deep'));

      // 读：从未写过，返回 null。
      expect(store.read(), isNull);

      // 写：递归建目录后落盘，读回一致。
      store.write('0.30');
      expect(store.read(), '0.30');
    });

    test('未注入任何音量存储时缺省 1.0、保存静默不炸', () {
      // 前置由本组 setUp 显式撤销进程级注入保证（桌面 io 宿主与纯 dart
      // 测试正是这个状态），不是碰巧没人写过这个全局。
      final platform = IoVoicePlayerPlatform(supported: true);

      expect(platform.getInitialVolume(), 1.0);
      expect(() => platform.saveVolume(0.5), returnsNormally);
      expect(platform.getInitialVolume(), 1.0);
    });

    test('装配注入目录后，未显式传存储的实例即用该目录（重启后保持）', () {
      IoVoicePlayerPlatform.configureDefaultVolumeStore(tempDir);
      addTearDown(
        () => IoVoicePlayerPlatform.configureDefaultVolumeStore(null),
      );

      // 生产里控制器走的就是这条缺省工厂路径（拿不到注入点）。
      IoVoicePlayerPlatform(supported: true).saveVolume(0.3);

      expect(
        File(
          '${tempDir.path}${Platform.pathSeparator}$voiceOutputVolumeStorageKey',
        ).readAsStringSync(),
        '0.30',
      );
      expect(IoVoicePlayerPlatform(supported: true).getInitialVolume(), 0.3);
    });
  });

  group('IoVoicePlayerPlatform（fake 通道注入）', () {
    late _FakePlayerChannel channel;

    setUp(() {
      channel = _FakePlayerChannel();
    });

    IoVoicePlayerPlatform platform() =>
        IoVoicePlayerPlatform(channel: channel, supported: true);

    test('play 把完整音频字节与音量交给原生，返回播放会话', () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);

      final playback = await platform().play(
        bytes,
        mimeType: 'audio/mpeg',
        volume: 0.4,
      );

      expect(playback, isNotNull);
      expect(channel.started, hasLength(1));
      expect(channel.started.single.bytes, bytes);
      expect(channel.started.single.volume, 0.4);
    });

    test('通道载荷里没有 mimeType 键：容器由原生自行嗅探', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(androidVoicePlayerChannelName),
            (call) async {
              calls.add(call);
              return 7;
            },
          );

      final id = await MethodVoicePlayerChannel.instance.startPlayback(
        Uint8List.fromList([1, 2, 3]),
        volume: 0.4,
      );

      expect(id, 7);
      final args = calls.single.arguments as Map<Object?, Object?>;
      expect(args.keys, unorderedEquals(['bytes', 'volume']));
      expect(args['volume'], 0.4);
    });

    test('原生无法开始播放：play 返回 null，调用方按读不出来降级', () async {
      channel.startFails = true;

      final playback = await platform().play(
        Uint8List.fromList([1]),
        mimeType: 'audio/mpeg',
      );

      expect(playback, isNull);
    });

    test('整段自然播完：原生完成回调使 done 完成，不抛异常', () async {
      final playback = (await platform().play(
        Uint8List.fromList([1]),
        mimeType: 'audio/mpeg',
      ))!;

      var doneCompleted = false;
      unawaited(
        playback.done.then((_) => doneCompleted = true),
      );
      await _pumpMicrotask();

      expect(doneCompleted, isFalse);

      channel.emitFinished(id: channel.started.single.id);
      await _pumpMicrotask();

      expect(doneCompleted, isTrue);
    });

    test('stop 立即完成 done 并通知原生停止，多次 stop 幂等', () async {
      final playback = (await platform().play(
        Uint8List.fromList([1]),
        mimeType: 'audio/mpeg',
      ))!;

      playback.stop();
      await playback.done;

      playback.stop();
      playback.stop();
      expect(channel.stopCalls, 1);
      await playback.done; // done 已完成且不再抛。
    });

    test('setVolume 实时转发给原生并钳制；释放后再调是空操作', () async {
      final playback = (await platform().play(
        Uint8List.fromList([1]),
        mimeType: 'audio/mpeg',
      ))!;

      playback.setVolume(0.25);
      playback.setVolume(2.0);

      expect(channel.volumeCalls, [
        (id: channel.started.single.id, volume: 0.25),
        (id: channel.started.single.id, volume: 1.0),
      ]);

      playback.stop();
      channel.volumeCalls.clear();
      playback.setVolume(0.5);

      expect(channel.volumeCalls, isEmpty);
    });

    test('底层播放出错同样完成 done（错误不外抛，由调用方呈现）', () async {
      final playback = (await platform().play(
        Uint8List.fromList([1]),
        mimeType: 'audio/mpeg',
      ))!;

      channel.emitFinished(id: channel.started.single.id);

      expect(playback.done, completes);
    });

    test('完成回调只认自己的句柄：别的播放结束不会提前完成本会话', () async {
      final playback = (await platform().play(
        Uint8List.fromList([1]),
        mimeType: 'audio/mpeg',
      ))!;

      var doneCompleted = false;
      unawaited(playback.done.then((_) => doneCompleted = true));
      channel.emitFinished(id: 99999);
      await _pumpMicrotask();

      expect(doneCompleted, isFalse);
    });

    test('supported=false（桌面 io 宿主）如实不可用：play 返回 null', () async {
      final unsupported = IoVoicePlayerPlatform(
        channel: channel,
        supported: false,
      );

      expect(unsupported.supported, isFalse);
      expect(
        await unsupported.play(Uint8List.fromList([1]), mimeType: 'audio/mpeg'),
        isNull,
      );
      expect(channel.started, isEmpty);
    });
  });
}

Future<void> _pumpMicrotask() => Future<void>.delayed(Duration.zero);

/// 播放通道 fake：记录起播参数与控制调用，手动派发完成回调。
final class _FakePlayerChannel implements VoicePlayerNativeChannel {
  bool startFails = false;
  final started = <_StartedPlayback>[];
  final volumeCalls = <({int id, double volume})>[];
  int stopCalls = 0;
  final _handlers = <void Function(int)>[];
  var _nextId = 1;

  void emitFinished({required int id}) {
    for (final handler in List.of(_handlers)) {
      handler(id);
    }
  }

  @override
  void Function() onPlaybackFinished(void Function(int playbackId) handler) {
    _handlers.add(handler);
    return () => _handlers.remove(handler);
  }

  @override
  Future<int?> startPlayback(Uint8List bytes, {required double volume}) async {
    if (startFails) {
      return null;
    }
    final id = _nextId++;
    started.add(_StartedPlayback(id: id, bytes: bytes, volume: volume));
    return id;
  }

  @override
  Future<void> stopPlayback(int playbackId) async {
    stopCalls += 1;
  }

  @override
  Future<void> setPlaybackVolume(int playbackId, double volume) async {
    volumeCalls.add((id: playbackId, volume: volume));
  }
}

final class _StartedPlayback {
  const _StartedPlayback({
    required this.id,
    required this.bytes,
    required this.volume,
  });

  final int id;
  final Uint8List bytes;
  final double volume;
}
