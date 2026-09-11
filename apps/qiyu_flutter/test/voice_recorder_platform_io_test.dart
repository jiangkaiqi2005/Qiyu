import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/chat/voice_recorder_platform.dart';
import 'package:qiyu_flutter/features/chat/voice_recorder_platform_io.dart';

/// 录音平台缝 io（安卓）侧的契约对齐验收（票 06 硬验收）：
///
/// - **录音块格式与 web 契约逐项对齐**：安卓 AudioRecord 直接按契约采样
///   （16kHz、16-bit、单声道、小端 PCM），Dart 侧打包 44 字节 RIFF 头——
///   打包产物与 web 侧 `toWav16kMono`（decodeAudioData → OfflineAudioContext
///   重采样 → Int16 量化 → RIFF 头）的输出逐字段断言同构；
/// - 会话语义与 web 一致：mimeType 即 `audio/wav`、stop 只此一次、
///   discard 丢弃且不产生数据；
/// - 权限拒绝与设备不可用都如实返回 null，调用方按「无法使用麦克风」
///   呈现；转换在安卓上是恒等映射（录音本身已是契约格式）。
///
/// 通道行为（AudioRecord 真采集、权限真弹窗）归真机冒烟；dart 测试注入
/// fake 通道验证我们自己的粘合与契约层。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('原生录音中断经现有通道通知且取消监听后可重新订阅', () async {
    final platform = IoVoiceRecorderPlatform(supported: true);
    var interruptions = 0;
    var subscription = platform.interruptions.listen((_) => interruptions++);
    Future<void> interrupt() async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            androidVoiceRecorderChannelName,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('onRecordingInterrupted'),
            ),
            (_) {},
          );
    }

    await interrupt();
    expect(interruptions, 1);
    await subscription.cancel();
    subscription = platform.interruptions.listen((_) => interruptions++);
    await interrupt();
    expect(interruptions, 2);
    await subscription.cancel();
  });

  /// 逐字段断言 WAV 头与 web `_packWav` 产物同构的共享断言。
  void expectWav16kMonoContract(Uint8List wav, int pcmLength) {
    final view = ByteData.view(wav.buffer);
    // 格式头：RIFF 容器 + WAVE 标记。
    expect(wav[0], 0x52); // 'R'
    expect(wav[1], 0x49); // 'I'
    expect(wav[2], 0x46); // 'F'
    expect(wav[3], 0x46); // 'F'
    expect(view.getUint32(4, Endian.little), 36 + pcmLength);
    expect(wav[8], 0x57); // 'W'
    expect(wav[9], 0x41); // 'A'
    expect(wav[10], 0x56); // 'V'
    expect(wav[11], 0x45); // 'E'
    // fmt 块：16 字节、PCM、单声道、16kHz、位深 16。
    expect(wav.sublist(12, 16), 'fmt '.codeUnits);
    expect(view.getUint32(16, Endian.little), 16);
    expect(view.getUint16(20, Endian.little), 1); // PCM
    expect(view.getUint16(22, Endian.little), 1); // 单声道
    expect(view.getUint32(24, Endian.little), 16000); // 采样率
    expect(view.getUint32(28, Endian.little), 32000); // 字节率 = 16000 × 2
    expect(view.getUint16(32, Endian.little), 2); // 块对齐
    expect(view.getUint16(34, Endian.little), 16); // 位深
    // data 块：紧随 fmt，长度即 PCM 字节数。
    expect(wav.sublist(36, 40), 'data'.codeUnits);
    expect(view.getUint32(40, Endian.little), pcmLength);
    expect(wav.length, 44 + pcmLength);
  }

  group('packWav16kMonoPcm 与 web 契约逐项对齐', () {
    test('RIFF 头字段与 web 打包产物逐字节同构', () {
      final pcm = Uint8List.fromList([1, 2, 3, 4, 5, 6]);

      final wav = packWav16kMonoPcm(pcm);

      expectWav16kMonoContract(wav, pcm.length);
      // 数据体原样后置，不做任何再量化。
      expect(wav.sublist(44), pcm);
    });

    test('空录音也产出合法 WAV（仅 44 字节头）', () {
      final wav = packWav16kMonoPcm(Uint8List(0));

      expectWav16kMonoContract(wav, 0);
    });

    test('60 秒上限体量（1.92MB PCM）打包尺寸正确', () {
      // 16000 Hz × 2 字节 × 60 秒 = 1,920,000 字节，控制器自动收尾上限。
      final pcm = Uint8List(16000 * 2 * 60);

      final wav = packWav16kMonoPcm(pcm);

      expectWav16kMonoContract(wav, pcm.length);
    });

    test('采样值按小端 Int16 语义原样保留', () {
      // 手工构造 -1 与 1 两个 Int16 采样（小端），打包后 data 块原样可读。
      final pcm = Uint8List(4)
        ..[0] = 0xff
        ..[1] =
            0xff // -1
        ..[2] = 0x01
        ..[3] = 0x00; // 1

      final wav = packWav16kMonoPcm(pcm);
      final view = ByteData.view(wav.buffer);

      expect(view.getInt16(44, Endian.little), -1);
      expect(view.getInt16(46, Endian.little), 1);
    });

    test('整段产物等于手写字面字节表（44 字节头 + data 逐字节）', () {
      // 期望值按 RIFF 布局手算，不经过被测实现：8 字节 PCM → RIFF 尺寸
      // 36+8=44(0x2C)、采样率 16000=0x3E80、字节率 32000=0x7D00（均小端）。
      // web 侧量化后的 PCM 走的是同一个函数，这张字面表就是它产物形状的
      // 独立见证——打包器搬家之后字节没有第二位不同。
      final pcm = Uint8List.fromList([1, 2, 3, 4, 5, 6, 0xff, 0x7f]);

      expect(packWav16kMonoPcm(pcm), const [
        0x52, 0x49, 0x46, 0x46, // 'RIFF'
        0x2c, 0x00, 0x00, 0x00, // 44 = 36 + 8
        0x57, 0x41, 0x56, 0x45, // 'WAVE'
        0x66, 0x6d, 0x74, 0x20, // 'fmt '
        0x10, 0x00, 0x00, 0x00, // fmt 块长度 16
        0x01, 0x00, // PCM
        0x01, 0x00, // 单声道
        0x80, 0x3e, 0x00, 0x00, // 16000 Hz
        0x00, 0x7d, 0x00, 0x00, // 32000 字节/秒
        0x02, 0x00, // 块对齐 2
        0x10, 0x00, // 位深 16
        0x64, 0x61, 0x74, 0x61, // 'data'
        0x08, 0x00, 0x00, 0x00, // 数据长 8
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0xff, 0x7f, // PCM 原样后置
      ]);
    });
  });

  group('IoVoiceRecorderPlatform（fake 通道注入）', () {
    late _FakeRecorderChannel channel;
    late IoVoiceRecorderPlatform platform;

    setUp(() {
      channel = _FakeRecorderChannel();
      platform = IoVoiceRecorderPlatform(channel: channel, supported: true);
    });

    test('权限授予 → 原生起录 → stop 返回契约格式 WAV，mimeType 为 audio/wav', () async {
      final session = await platform.start();

      expect(session, isNotNull);
      expect(channel.calls, ['hasMicrophonePermission', 'startRecording']);
      expect(session!.mimeType, 'audio/wav');

      final audio = await session.stop();

      expect(channel.calls.last, 'stopRecording');
      expectWav16kMonoContract(audio, channel.pcmOnNativeSide.length);
    });

    test('首次授权只完成准备，不启动原生采集', () async {
      channel.permissionGranted = false;
      channel.permissionRequestResult = true;
      expect(
        await platform.preparePermission(),
        VoicePermissionResult.grantedNow,
      );
      expect(channel.calls, [
        'hasMicrophonePermission',
        'requestMicrophonePermission',
      ]);
    });

    test('已授权无需弹窗，拒绝也不会启动采集', () async {
      expect(await platform.preparePermission(), VoicePermissionResult.ready);
      channel.permissionGranted = false;
      expect(await platform.preparePermission(), VoicePermissionResult.denied);
      expect(channel.calls, isNot(contains('startRecording')));
    });

    test('权限拒绝：start 返回 null，绝不触碰原生录音', () async {
      channel.permissionGranted = false;

      final session = await platform.start();

      expect(session, isNull);
      expect(channel.calls, ['hasMicrophonePermission']);
    });

    test('权限授予但设备不可用（起录失败）：start 返回 null', () async {
      channel.startSucceeds = false;

      final session = await platform.start();

      expect(session, isNull);
      expect(channel.calls, ['hasMicrophonePermission', 'startRecording']);
    });

    test('discard 丢弃录音：不取字节，原生侧缓冲随通道丢弃', () async {
      final session = await platform.start();

      session!.discard();

      expect(channel.calls.last, 'discardRecording');
      expect(channel.discardCalls, 1);
    });

    test('stop 只此一次：重复 stop 抛 StateError，防止双份转写', () async {
      final session = await platform.start();

      await session!.stop();

      expect(() => session.stop(), throwsA(isA<StateError>()));
    });

    test('通道取不到字节时异常原样上抛，绝不降级成空 WAV', () async {
      final session = await platform.start();
      channel.stopError = true;

      // 吞成空字节会得到一个只有 44 字节头的空 WAV 并照常送去转写，
      // 把「拿不到音频」伪装成「用户没说话」——所以这条不吞。
      expect(() => session!.stop(), throwsA(isA<StateError>()));
    });

    test('toWav16kMono 是恒等映射：录音本身已是 16kHz/16-bit/单声道 WAV', () async {
      final recorded = RecordedAudio(
        bytes: Uint8List.fromList([9, 8, 7]),
        mimeType: 'audio/wav',
      );

      final converted = await platform.toWav16kMono(recorded);

      expect(converted.sameBytesAndType(recorded), isTrue);
    });

    test('supported=false（桌面 io 宿主）如实不可用，start 返回 null', () async {
      final unsupported = IoVoiceRecorderPlatform(
        channel: channel,
        supported: false,
      );

      expect(unsupported.supported, isFalse);
      expect(await unsupported.start(), isNull);
      expect(channel.calls, isEmpty);
    });
  });
}

extension on RecordedAudio {
  bool sameBytesAndType(RecordedAudio other) =>
      mimeType == other.mimeType &&
      bytes.length == other.bytes.length &&
      String.fromCharCodes(bytes) == String.fromCharCodes(other.bytes);
}

/// 录音通道 fake：记录调用序列，PCM 固定返回一小段可断言字节。
final class _FakeRecorderChannel implements VoiceRecorderNativeChannel {
  @override
  Stream<void> get interruptions => const Stream.empty();
  bool permissionGranted = true;
  bool permissionRequestResult = false;
  bool startSucceeds = true;
  bool stopError = false;
  int discardCalls = 0;
  final calls = <String>[];
  final Uint8List pcmOnNativeSide = Uint8List.fromList(
    List.generate(8, (i) => i),
  );

  @override
  Future<bool> hasMicrophonePermission() async {
    calls.add('hasMicrophonePermission');
    return permissionGranted;
  }

  @override
  Future<bool> requestMicrophonePermission() async {
    calls.add('requestMicrophonePermission');
    return permissionRequestResult;
  }

  @override
  Future<bool> startRecording() async {
    calls.add('startRecording');
    return startSucceeds;
  }

  @override
  Future<Uint8List> stopRecording() async {
    calls.add('stopRecording');
    if (stopError) {
      throw StateError('原生停止采集失败');
    }
    return pcmOnNativeSide;
  }

  @override
  Future<void> discardRecording() async {
    calls.add('discardRecording');
    discardCalls += 1;
  }
}
