@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:qiyu_flutter/features/chat/voice_player_platform.dart';
import 'package:test/test.dart';

void main() {
  test('真实 Web Audio 跨异步边界解码并播放内存音频', () async {
    final platform = createVoicePlayerPlatform();
    final gesturePlayer = platform as UserGestureVoicePlayerPlatform;
    gesturePlayer.prepareForPlayback();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final playback = await platform.play(_silentWav(), mimeType: 'audio/wav');
    expect(playback, isNotNull);
    playback!.stop();
    await playback.done;
  });
}

Uint8List _silentWav() {
  const sampleRate = 16000;
  const sampleCount = 1600;
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
