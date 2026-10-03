@TestOn('browser')
library;

import 'dart:typed_data';
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:qiyu_flutter/features/chat/voice_player_platform.dart'
    hide createVoicePlayerPlatform;
import 'package:qiyu_flutter/features/chat/voice_player_platform_web.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

void main() {
  test('自动输出只在真实 running 后就绪，复用通话 PCM 上下文', () async {
    final platform = createVoicePlayerPlatform() as WebVoicePlayerPlatform;
    expect(platform, isA<AutoStartVoicePlayerPlatform>());
    final automatic = platform as AutoStartVoicePlayerPlatform;
    expect(await automatic.prepareForAutoPlayback(), isTrue);
    final stream = await platform.startStream(sampleRate: 24000);
    expect(stream, isNotNull);
    expect(platform.debugLastStreamContext?.state, 'running');
    expect(platform.debugLastStreamContext?.sampleRate, 24000);
    stream!.stop();
    (platform as InterruptibleVoicePlayerPlatform).endOutput();
    expect(platform.debugLastStreamContext?.state, 'closed');
  });

  test('resume 成功返回但输出仍 suspended，自动输出失败并关闭资源', () async {
    final restore = _restrictResume(() => Future<JSAny?>.value(null).toJS);
    final platform = WebVoicePlayerPlatform();
    final ready = platform.prepareForAutoPlayback();
    final context = platform.debugAudioContext!;
    expect(await ready, isFalse);
    restore();
    expect(context.state, 'closed');
    expect(platform.debugAudioContext, isNull);
  });

  test('AudioContext running 但 PCM 处理器加载失败不能算自动输出就绪', () async {
    final platform = WebVoicePlayerPlatform();
    final ready = platform.prepareForAutoPlayback();
    final context = platform.debugAudioContext!;
    context.audioWorklet.setProperty('addModule'.toJS, ((JSAny _) =>
      Future<JSAny?>.error('worklet unavailable').toJS).toJS);
    expect(await ready, isFalse);
    expect(context.state, 'closed');
  });

  test('挂断 pending PCM 模块准备立即结束，迟到模块不能重建播放器', () async {
    final module = Completer<JSAny?>();
    final platform = WebVoicePlayerPlatform();
    final ready = platform.prepareForAutoPlayback();
    final context = platform.debugAudioContext!;
    context.audioWorklet.setProperty('addModule'.toJS,
      ((JSAny _) => module.future.toJS).toJS);
    await Future<void>.delayed(Duration.zero);
    platform.endOutput();
    expect(await ready.timeout(const Duration(milliseconds: 200)), isFalse);
    module.complete(null);
    await Future<void>.delayed(Duration.zero);
    expect(context.state, 'closed');
    expect(platform.debugAudioContext, isNull);
    expect(platform.debugLastStreamContext, isNull);
  });

  test('浏览器 pending resume 有界失败，迟到许可不能重建输出', () async {
    final resume = Completer<JSAny?>();
    final restore = _restrictResume(() => resume.future.toJS);
    final platform = WebVoicePlayerPlatform();
    final ready = platform.prepareForAutoPlayback();
    final context = platform.debugAudioContext!;
    expect(await ready.timeout(const Duration(seconds: 2)), isFalse);
    restore();
    resume.complete(null);
    await Future<void>.delayed(Duration.zero);
    expect(context.state, 'closed');
    expect(platform.debugAudioContext, isNull);
  });

  test('endOutput 立即取消 pending 准备，旧许可不能关闭新手动输出', () async {
    final resume = Completer<JSAny?>();
    final restore = _restrictResume(() => resume.future.toJS);
    final platform = WebVoicePlayerPlatform();
    final ready = platform.prepareForAutoPlayback();
    final context = platform.debugAudioContext!;
    platform.endOutput();
    expect(await ready.timeout(const Duration(milliseconds: 200)), isFalse);
    restore();
    platform.prepareForPlayback();
    final manualContext = platform.debugAudioContext!;
    final playback = await platform.startStream(
      sampleRate: manualContext.sampleRate.round(),
    );
    expect(playback, isNotNull);
    resume.complete(null);
    await Future<void>.delayed(Duration.zero);
    expect(context.state, 'closed');
    expect(manualContext.state, 'running');
    playback!.stop();
    platform.debugCloseContext();
  });
  test('真实 Web Audio 跨异步边界解码并播放内存音频，并能自然结束', () async {
    final platform = createVoicePlayerPlatform();
    final gesturePlayer = platform as UserGestureVoicePlayerPlatform;
    gesturePlayer.prepareForPlayback();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final playback = await platform.play(
      _silentWav(sampleCount: 800),
      mimeType: 'audio/wav',
    );
    expect(playback, isNotNull);
    await playback!.done;
  });

  test('流式 PCM 采样率与手势主上下文一致时复用已唤醒上下文', () async {
    final platform = createVoicePlayerPlatform() as WebVoicePlayerPlatform;
    platform.prepareForPlayback();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final mainContext = platform.debugAudioContext!;
    final sampleRate = mainContext.sampleRate.round();
    final playback = await platform.startStream(sampleRate: sampleRate);
    expect(playback, isNotNull);
    expect(identical(platform.debugLastStreamContext, mainContext), isTrue);
    expect(platform.debugAudioContext?.state, 'running');

    playback!.append(Uint8List.fromList([0, 0]));
    playback.end();
    await playback.done;
    // 流式会话结束不能关掉复用的主上下文，整段重听仍可继续使用。
    expect(platform.debugAudioContext?.state, 'running');
  });

  test('同一主上下文连续两次 startStream 均能自然 drain', () async {
    final platform = createVoicePlayerPlatform() as WebVoicePlayerPlatform;
    platform.prepareForPlayback();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final mainContext = platform.debugAudioContext!;
    final sampleRate = mainContext.sampleRate.round();

    for (var round = 0; round < 2; round += 1) {
      final playback = await platform.startStream(sampleRate: sampleRate);
      expect(playback, isNotNull, reason: '第 ${round + 1} 次开流失败');
      expect(identical(platform.debugLastStreamContext, mainContext), isTrue);
      expect(platform.debugAudioContext?.state, 'running');

      playback!.append(Uint8List.fromList([0, 0]));
      playback.end();
      await playback.done;
    }
    // 两次都能自然 drain，且主上下文没有被第二次 addModule 破坏。
    expect(platform.debugAudioContext?.state, 'running');
  });

  test('流式 PCM 采样率不同于主上下文时保留协商采样率并隔离上下文', () async {
    final platform = createVoicePlayerPlatform() as WebVoicePlayerPlatform;
    platform.prepareForPlayback();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final mainContext = platform.debugAudioContext!;
    final alternateRate = mainContext.sampleRate.round() == 24000
        ? 48000
        : 24000;
    final playback = await platform.startStream(sampleRate: alternateRate);
    expect(playback, isNotNull);
    expect(
      (platform.debugLastStreamContext!.sampleRate - alternateRate).abs(),
      lessThan(0.5),
    );
    expect(identical(platform.debugLastStreamContext, mainContext), isFalse);

    playback!.append(Uint8List.fromList([0, 0]));
    playback.end();
    await playback.done;
    // 专用上下文由流会话真正关闭；用户手势唤醒的主上下文仍保持可用。
    await Future<void>.delayed(Duration.zero);
    expect(platform.debugLastStreamContext?.state, 'closed');
    expect(platform.debugAudioContext?.state, 'running');
  });

  test('stop() 立即中止播放并结束 playback.done，且多次 stop() 保持幂等', () async {
    final platform = createVoicePlayerPlatform();
    final gesturePlayer = platform as UserGestureVoicePlayerPlatform;
    gesturePlayer.prepareForPlayback();
    final playback = await platform.play(
      _silentWav(sampleCount: 16000),
      mimeType: 'audio/wav',
    );
    expect(playback, isNotNull);
    playback!.stop();
    await playback.done;
    // 多次调用 stop() 不应抛出异常
    playback.stop();
    playback.stop();
    expect(playback.done, completes);
  });

  test('AudioContext 显式 closed 后，后续 play() 透明自愈重建并继续播放', () async {
    final platform = createVoicePlayerPlatform() as WebVoicePlayerPlatform;
    platform.prepareForPlayback();
    final playback1 = await platform.play(_silentWav(), mimeType: 'audio/wav');
    expect(playback1, isNotNull);
    playback1!.stop();
    await playback1.done;

    // 显式关闭当前 context 模拟设备失效/待机休眠导致的 closed 状态
    platform.debugCloseContext();
    expect(platform.debugAudioContext?.state, 'closed');

    // 后续再次调用 prepareForPlayback() 与 play()，应自愈重建新的 context 并正常播放
    platform.prepareForPlayback();
    final playback2 = await platform.play(_silentWav(), mimeType: 'audio/wav');
    expect(playback2, isNotNull);
    expect(platform.debugAudioContext?.state, 'running');
    playback2!.stop();
    await playback2.done;
  });

  test('prepareForPlayback() 清除旧的 resumeAttempt 并在手势内触发新唤醒', () async {
    final platform = createVoicePlayerPlatform() as WebVoicePlayerPlatform;
    platform.prepareForPlayback();
    platform.prepareForPlayback();
    final playback = await platform.play(_silentWav(), mimeType: 'audio/wav');
    expect(playback, isNotNull);
    playback!.stop();
    await playback.done;
  });

  test('损坏的音频字节解码失败时安全降级返回 null', () async {
    final platform = createVoicePlayerPlatform() as WebVoicePlayerPlatform;
    platform.prepareForPlayback();
    final playback = await platform.play(
      Uint8List.fromList([1, 2, 3, 4]),
      mimeType: 'audio/wav',
    );
    expect(playback, isNull);
  });

  /// 音量偏好的真实浏览器现状矩阵（票 04）：与
  /// `voice_player_platform_io_test.dart` 同一输入集，逐条对照 localStorage
  /// 与安卓应用内文件的解析/编码结果。跑在真 `window.localStorage` 上，
  /// 改键前记下旧值、用例结束原样放回（不清空整个存储，别的键属于别人）。
  group('播放音量偏好（真实 localStorage）', () {
    late WebVoicePlayerPlatform platform;
    late String? storedBefore;

    setUp(() {
      storedBefore = _rawStoredVolume();
      web.window.localStorage.removeItem(voiceOutputVolumeStorageKey);
      platform = WebVoicePlayerPlatform();
    });

    tearDown(() {
      final before = storedBefore;
      if (before == null) {
        web.window.localStorage.removeItem(voiceOutputVolumeStorageKey);
      } else {
        web.window.localStorage.setItem(voiceOutputVolumeStorageKey, before);
      }
    });

    test('从未存过：退回缺省 1.0，且不凭空写出键', () {
      expect(platform.getInitialVolume(), 1.0);
      expect(_rawStoredVolume(), isNull);
    });

    test('解析矩阵：合法文本逐条读回对应音量（含静音 0）', () {
      const legal = {
        '0': 0.0,
        '0.00': 0.0,
        '0.05': 0.05,
        '0.40': 0.4,
        '1': 1.0,
        '1.00': 1.0,
      };
      for (final entry in legal.entries) {
        _storeRawVolume(entry.key);
        expect(
          platform.getInitialVolume(),
          entry.value,
          reason: '内容 "${entry.key}" 应原样采纳',
        );
      }
    });

    test('解析矩阵：非法文本退回 1.0，越界值不被 clamp 后采纳', () {
      const illegal = [
        '',
        'abc',
        '1.5',
        '-0.2',
        '1.0000000000000002',
        'NaN',
        'nan',
        'Infinity',
        'infinity',
        '-Infinity',
        '1e400',
        '0x0.8',
      ];
      for (final text in illegal) {
        _storeRawVolume(text);
        expect(
          platform.getInitialVolume(),
          1.0,
          reason: '内容 "$text" 应退回缺省，而不是收进 0..1 后采纳',
        );
      }
    });

    test('解析矩阵：现状就接受的写法继续接受（空格、.5、科学计数、区间上沿内极值）', () {
      const accepted = {
        ' 0.5': 0.5,
        '0.5 ': 0.5,
        '.5': 0.5,
        '5e-1': 0.5,
        '1e-3': 0.001,
        '0.9999999999999999': 0.9999999999999999,
      };
      for (final entry in accepted.entries) {
        _storeRawVolume(entry.key);
        expect(
          platform.getInitialVolume(),
          entry.value,
          reason: '内容 "${entry.key}" 按旧解析规则本就可采纳',
        );
      }
    });

    test('解析矩阵："-0.00" 读回的是负零音量（等于 0 但符号保留）', () {
      _storeRawVolume('-0.00');

      final volume = platform.getInitialVolume();

      expect(volume, 0.0);
      expect(volume.toString(), '-0.0');
    });

    test('编码矩阵：落盘文本逐条钉住（上下界、负零、非有限值、两位小数舍入临界）', () {
      const encoded = <({double volume, String stored})>[
        (volume: 0.0, stored: '0.00'),
        (volume: 0.4, stored: '0.40'),
        (volume: 1.0, stored: '1.00'),
        (volume: 1.7, stored: '1.00'),
        (volume: -0.5, stored: '0.00'),
        (volume: -0.0, stored: '0.00'),
        (volume: double.nan, stored: '1.00'),
        (volume: double.infinity, stored: '1.00'),
        (volume: double.negativeInfinity, stored: '0.00'),
        (volume: 0.005, stored: '0.01'),
        (volume: 0.015, stored: '0.01'),
        (volume: 0.025, stored: '0.03'),
        (volume: 0.125, stored: '0.13'),
        (volume: 0.375, stored: '0.38'),
        (volume: 0.995, stored: '0.99'),
        (volume: 0.9949999999999999, stored: '0.99'),
        (volume: 0.999, stored: '1.00'),
        (volume: 0.004999999999999999, stored: '0.00'),
        (volume: 1e-7, stored: '0.00'),
      ];
      for (final entry in encoded) {
        _storeRawVolume('sentinel-before-save');
        platform.saveVolume(entry.volume);
        expect(
          _rawStoredVolume(),
          entry.stored,
          reason: 'saveVolume(${entry.volume}) 的落盘文本是旧表达式的实际结果',
        );
      }
    });

    test('编码矩阵：两位小数是有损的，新建平台对象后读回落盘文本', () {
      platform.saveVolume(0.125);

      expect(_rawStoredVolume(), '0.13');
      expect(WebVoicePlayerPlatform().getInitialVolume(), 0.13);
    });

    test('保存 0.4 与 0 后重建对象可读回；只认自己那一枚键', () {
      platform.saveVolume(0.4);
      expect(WebVoicePlayerPlatform().getInitialVolume(), 0.4);

      platform.saveVolume(0);
      expect(WebVoicePlayerPlatform().getInitialVolume(), 0.0);

      web.window.localStorage.removeItem(voiceOutputVolumeStorageKey);
      web.window.localStorage.setItem(
        '${voiceOutputVolumeStorageKey}_neighbor',
        '0.20',
      );
      expect(platform.getInitialVolume(), 1.0, reason: '读到了别的键名，说明键名不是单一定位');
      web.window.localStorage.removeItem(
        '${voiceOutputVolumeStorageKey}_neighbor',
      );
    });
  });
}

// 浏览器原生 API 是测试接缝：模拟未获 autoplay 放行；处理器仍用真实
// Chrome AudioContext。qiyu_chrome 的 autoplay flag 不能验收默认策略。
void Function() _restrictResume(JSPromise<JSAny?> Function() resume) {
  final audioPrototype = globalContext
      .getProperty<JSFunction>('AudioContext'.toJS)
      .getProperty<JSObject>('prototype'.toJS);
  final basePrototype = globalContext
      .getProperty<JSFunction>('BaseAudioContext'.toJS)
      .getProperty<JSObject>('prototype'.toJS);
  final originalResume = audioPrototype.getProperty<JSFunction>('resume'.toJS);
  final state = _getDescriptor(basePrototype, 'state'.toJS);
  _defineProperty(
    basePrototype,
    'state'.toJS,
    {'get': (() => 'suspended'.toJS).toJS, 'configurable': true}.jsify()!
        as JSObject,
  );
  audioPrototype.setProperty('resume'.toJS, resume.toJS);
  var restored = false;
  void restore() {
    if (restored) return;
    restored = true;
    audioPrototype.setProperty('resume'.toJS, originalResume);
    _defineProperty(basePrototype, 'state'.toJS, state);
  }

  addTearDown(restore);
  return restore;
}

@JS('Object.getOwnPropertyDescriptor')
external JSObject _getDescriptor(JSObject object, JSString name);
@JS('Object.defineProperty')
external JSObject _defineProperty(
  JSObject object,
  JSString name,
  JSObject value,
);

void _storeRawVolume(String value) =>
    web.window.localStorage.setItem(voiceOutputVolumeStorageKey, value);

String? _rawStoredVolume() =>
    web.window.localStorage.getItem(voiceOutputVolumeStorageKey);

Uint8List _silentWav({int sampleCount = 1600, int sampleRate = 16000}) {
  final bytes = Uint8List(44 + sampleCount * 2);
  final data = ByteData.view(bytes.buffer);
  var offset = 0;

  void ascii(String value) {
    for (final unit in value.codeUnits) {
      data.setUint8(offset++, unit);
    }
  }

  void u16(int value) {
    data.setUint16(offset, value, Endian.little);
    offset += 2;
  }

  void u32(int value) {
    data.setUint32(offset, value, Endian.little);
    offset += 4;
  }

  ascii('RIFF');
  u32(bytes.length - 8);
  ascii('WAVE');
  ascii('fmt ');
  u32(16);
  u16(1);
  u16(1);
  u32(sampleRate);
  u32(sampleRate * 2);
  u16(2);
  u16(16);
  ascii('data');
  u32(sampleCount * 2);
  return bytes;
}
