import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_view_model.dart';

void main() {
  test('试听订阅播放完成信号，让平台能在结束时释放内存音频', () async {
    final playback = _RecordingPlayback();
    final viewModel = TtsSettingsViewModel(
      const _PreviewGateway(),
      playerPlatform: _PreviewPlayer(playback),
      autoStart: false,
    );

    await viewModel.testConnection(
      const TtsSettingsDraft(
        baseUrl: 'https://tts.example.com/v1',
        model: 'tts-test',
      ),
    );

    expect(playback.doneReads, 1);
    playback.finish();
    await Future<void>.delayed(Duration.zero);
    viewModel.dispose();
  });
}

final class _PreviewGateway implements TtsSettingsGateway {
  const _PreviewGateway();

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) async =>
      TtsConnectionTest(
        succeeded: true,
        message: '连接成功。',
        audio: Uint8List.fromList([1, 2, 3]),
      );

  @override
  Future<TtsSettings> read() => throw UnimplementedError();

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) =>
      throw UnimplementedError();

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) => throw UnimplementedError();

  @override
  Future<TtsSettings> forgetApiKey() => throw UnimplementedError();
}

final class _PreviewPlayer implements VoicePlayerPlatform {
  const _PreviewPlayer(this.playback);

  final VoicePlayback playback;

  @override
  bool get supported => true;

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
  }) async => playback;
}

final class _RecordingPlayback implements VoicePlayback {
  final Completer<void> _done = Completer<void>();
  int doneReads = 0;

  void finish() => _done.complete();

  @override
  Future<void> get done {
    doneReads += 1;
    return _done.future;
  }

  @override
  void stop() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}
