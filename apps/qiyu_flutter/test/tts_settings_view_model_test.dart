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

  test('连接成功但浏览器播放失败时明确提示，不能假装试听成功', () async {
    final viewModel = TtsSettingsViewModel(
      const _PreviewGateway(),
      playerPlatform: const _RefusingPreviewPlayer(),
      autoStart: false,
    );

    await viewModel.testConnection(
      const TtsSettingsDraft(
        baseUrl: 'https://tts.example.com/v1',
        model: 'tts-test',
      ),
    );

    expect(viewModel.testResult?.succeeded, isTrue);
    expect(viewModel.errorMessage, '语音服务已连接，但浏览器没能播放试听。点「再听一次试听」重试。');
    viewModel.dispose();
  });

  test('测试按钮先取得浏览器播放许可，异步连接后仍能播放试听', () async {
    final gateway = _PendingPreviewGateway();
    final player = _GestureLockedPreviewPlayer();
    final viewModel = TtsSettingsViewModel(
      gateway,
      playerPlatform: player,
      autoStart: false,
    );

    player.gestureActive = true;
    final testing = viewModel.testConnection(
      const TtsSettingsDraft(
        baseUrl: 'https://tts.example.com/v1',
        model: 'tts-test',
      ),
    );
    player.gestureActive = false;
    gateway.complete();
    await testing;

    expect(viewModel.errorMessage, isNull);
    expect(player.started, isTrue);
    player.finish();
    viewModel.dispose();
  });
}

final class _PendingPreviewGateway implements TtsSettingsGateway {
  final Completer<TtsConnectionTest> _result = Completer<TtsConnectionTest>();

  void complete() {
    _result.complete(
      TtsConnectionTest(
        succeeded: true,
        message: '连接成功。',
        audio: Uint8List.fromList([1, 2, 3]),
      ),
    );
  }

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) =>
      _result.future;

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
  double getInitialVolume() => 1.0;

  @override
  void saveVolume(double volume) {}

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
    double volume = 1.0,
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
  void setVolume(double volume) {}

  @override
  void stop() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}

final class _RefusingPreviewPlayer implements VoicePlayerPlatform {
  const _RefusingPreviewPlayer();

  @override
  bool get supported => true;

  @override
  double getInitialVolume() => 1.0;

  @override
  void saveVolume(double volume) {}

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
    double volume = 1.0,
  }) async => null;
}

final class _GestureLockedPreviewPlayer
    implements VoicePlayerPlatform, UserGestureVoicePlayerPlatform {
  bool gestureActive = false;
  bool _prepared = false;
  bool started = false;
  _RecordingPlayback? _playback;

  @override
  bool get supported => true;

  @override
  double getInitialVolume() => 1.0;

  @override
  void saveVolume(double volume) {}

  @override
  void prepareForPlayback() {
    if (gestureActive) {
      _prepared = true;
    }
  }

  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
    double volume = 1.0,
  }) async {
    if (!_prepared) {
      return null;
    }
    started = true;
    return _playback = _RecordingPlayback();
  }

  void finish() => _playback?.finish();
}
