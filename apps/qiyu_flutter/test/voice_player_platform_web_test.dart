@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:qiyu_flutter/features/chat/voice_player_platform.dart'
    hide createVoicePlayerPlatform;
import 'package:qiyu_flutter/features/chat/voice_player_platform_web.dart';
import 'package:test/test.dart';

void main() {
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
}

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
