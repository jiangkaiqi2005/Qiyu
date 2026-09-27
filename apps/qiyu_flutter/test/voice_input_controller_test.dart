import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/voice_input_controller.dart';
import 'package:qiyu_flutter/features/chat/voice_recorder_platform.dart';

void main() {
  test('取消重试立即释放保留音频，重复重试与迟到结果不发送', () async {
    final sent = <String>[];
    final late = Completer<String>();
    var calls = 0;
    final controller = _pumpController(
      onTranscribed: sent.add,
      transcribe: (_, _) async {
        calls++;
        if (calls == 1) throw const LocalChatGatewayException('连接语音服务超时。');
        return late.future;
      },
    );
    await controller.initialize();
    await controller.startRecording();
    await controller.stopAndTranscribe();
    expect(controller.hasRetainedAudio, isTrue);
    final retry = controller.retryTranscribe();
    await controller.retryTranscribe();
    expect(calls, 2);
    controller.discard();
    controller.discard();
    expect(controller.hasRetainedAudio, isFalse);
    expect(controller.status, VoiceInputStatus.idle);
    late.complete('旧录音');
    await retry;
    expect(controller.hasRetainedAudio, isFalse);
    expect(sent, isEmpty);
    controller.dispose();
  });

  test('浏览器不支持时停在 unsupported，不进入录音', () async {
    final controller = _pumpController(
      platform: _FakeRecorderPlatform(supported: false),
    );

    await controller.initialize();

    expect(controller.status, VoiceInputStatus.unsupported);
    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.unsupported);
    controller.dispose();
  });

  test('未配置语音服务时停在 notConfigured，引导去设置页', () async {
    final controller = _pumpController(configured: false);
    await controller.initialize();

    expect(controller.status, VoiceInputStatus.notConfigured);
    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.notConfigured);
    controller.dispose();
  });

  test('置灰态重查：配置完成后回到 idle，无需重建页面', () async {
    var configured = false;
    final controller = VoiceInputController(
      _FakeRecorderPlatform(),
      () async => (configured: configured, wantsWavAudio: false),
      (audio, mimeType) async => '配置完成后的第一句',
      onTranscribed: (_) {},
    );
    await controller.initialize();
    expect(controller.status, VoiceInputStatus.notConfigured);

    // 用户在设置页配好语音服务后回到聊天页点麦克风。
    configured = true;
    await controller.refreshConfigured();
    expect(controller.status, VoiceInputStatus.idle);

    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.recording);
    controller.dispose();
  });

  test('完整成功路径：录音 → 转写 → 回 idle 并触发一次发送', () async {
    final platform = _FakeRecorderPlatform();
    final sent = <String>[];
    final controller = _pumpController(
      platform: platform,
      onTranscribed: sent.add,
    );
    await controller.initialize();
    expect(controller.status, VoiceInputStatus.idle);

    controller.handleMicTap(); // 开始录音
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.recording);
    expect(controller.hasRetainedAudio, isFalse);

    controller.handleMicTap(); // 结束并转写
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.idle);
    expect(sent, ['今天有点累']);
    expect(platform.session!.stopCalls, 1);
    expect(controller.hasRetainedAudio, isFalse);
    controller.dispose();
  });

  test('麦克风授权失败留在 idle 并给出人话提示', () async {
    final controller = _pumpController(
      platform: _FakeRecorderPlatform(sessionEnabled: false),
    );
    await controller.initialize();

    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);

    expect(controller.status, VoiceInputStatus.idle);
    expect(controller.errorMessage, contains('麦克风'));
    controller.dispose();
  });

  test('60 秒上限自动结束录音并照常转写发送', () async {
    final platform = _FakeRecorderPlatform();
    final sent = <String>[];
    final controller = VoiceInputController(
      platform,
      () async => (configured: true, wantsWavAudio: false),
      (_, _) async => '自动收尾的内容',
      onTranscribed: sent.add,
      autoStopAfter: const Duration(milliseconds: 20),
    );
    await controller.initialize();

    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.recording);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(controller.status, VoiceInputStatus.idle);
    expect(sent, ['自动收尾的内容']);
    expect(platform.session!.stopCalls, 1);
    controller.dispose();
  });

  test('转写失败进可重试态：音频保留，重试不重录、成功后清空', () async {
    final platform = _FakeRecorderPlatform();
    final attempts = <List<int>>[];
    var failures = 1;
    final controller = _pumpController(
      platform: platform,
      transcribe: (audio, mimeType) async {
        attempts.add(audio);
        if (failures > 0) {
          failures -= 1;
          throw const LocalChatGatewayException('没有识别到语音，可以再说一次。');
        }
        return '重试成功的话';
      },
    );
    await controller.initialize();

    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);

    expect(controller.status, VoiceInputStatus.retryable);
    expect(controller.errorMessage, contains('没有识别到语音'));
    expect(controller.hasRetainedAudio, isTrue);
    expect(platform.session!.stopCalls, 1); // 没有重录。

    controller.handleMicTap(); // 重试
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.idle);
    expect(attempts, hasLength(2));
    // 重传的是同一段音频字节。
    expect(attempts[0], attempts[1]);
    expect(controller.hasRetainedAudio, isFalse);
    controller.dispose();
  });

  test('豆包类型只在转写前调用一次 WAV 转换，转换后的字节与 mime 上送', () async {
    final platform = _FakeRecorderPlatform()
      ..wavBytes = Uint8List.fromList([9, 9, 9, 9, 9, 9]);
    final uploads = <(Uint8List, String)>[];
    final controller = VoiceInputController(
      platform,
      () async => (configured: true, wantsWavAudio: true),
      (audio, mimeType) async {
        uploads.add((audio, mimeType));
        return '今天有点累';
      },
      onTranscribed: (_) {},
    );
    await controller.initialize();

    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);

    expect(controller.status, VoiceInputStatus.idle);
    // 转换被调用且只调用一次：上送的是 fake 预置的 WAV 字节与 audio/wav。
    expect(platform.toWavCalls, 1);
    expect(uploads.single.$1, platform.wavBytes);
    expect(uploads.single.$2, 'audio/wav');
    controller.dispose();
  });

  test('OpenAI 类型不调用 WAV 转换：webm 原样上送', () async {
    final platform = _FakeRecorderPlatform();
    final uploads = <(Uint8List, String)>[];
    final controller = VoiceInputController(
      platform,
      () async => (configured: true, wantsWavAudio: false),
      (audio, mimeType) async {
        uploads.add((audio, mimeType));
        return '今天有点累';
      },
      onTranscribed: (_) {},
    );
    await controller.initialize();

    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);

    expect(controller.status, VoiceInputStatus.idle);
    expect(platform.toWavCalls, 0);
    // 原样字节与录音容器类型。
    expect(uploads.single.$1, platform.session!.bytes);
    expect(uploads.single.$2, 'audio/webm');
    controller.dispose();
  });

  test('豆包类型重试不重新转换，仍上送同一段 WAV 字节', () async {
    final platform = _FakeRecorderPlatform()
      ..wavBytes = Uint8List.fromList([7, 7, 7]);
    final attempts = <List<int>>[];
    var failures = 1;
    final controller = VoiceInputController(
      platform,
      () async => (configured: true, wantsWavAudio: true),
      (audio, mimeType) async {
        attempts.add(audio);
        if (failures > 0) {
          failures -= 1;
          throw const LocalChatGatewayException('连接语音服务超时。');
        }
        return '重试的话';
      },
      onTranscribed: (_) {},
    );
    await controller.initialize();

    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.retryable);

    controller.handleMicTap(); // 重试
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(controller.status, VoiceInputStatus.idle);
    expect(platform.toWavCalls, 1); // 重试不重新转换。
    expect(attempts, hasLength(2));
    expect(attempts[0], attempts[1]);
    expect(attempts[0], platform.wavBytes);
    controller.dispose();
  });

  test('WAV 转换失败进可重试态并给人话提示，重试可恢复', () async {
    final platform = _FakeRecorderPlatform()..wavError = true;
    var transcribed = 0;
    final controller = VoiceInputController(
      platform,
      () async => (configured: true, wantsWavAudio: true),
      (audio, mimeType) async {
        transcribed += 1;
        return '不应出现';
      },
      onTranscribed: (_) {},
    );
    await controller.initialize();

    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);

    expect(controller.status, VoiceInputStatus.retryable);
    expect(controller.errorMessage, contains('无法转换'));
    expect(transcribed, 0); // 转换失败绝不发起转写。

    // 重试：转换恢复后照常完成。
    platform.wavError = false;
    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.idle);
    expect(transcribed, 1);
    controller.dispose();
  });

  test('停止录音失败：留在 idle 就地提示重说，绝不带空音频去转写', () async {
    final platform = _FakeRecorderPlatform();
    var transcribed = 0;
    final controller = _pumpController(
      platform: platform,
      transcribe: (audio, mimeType) async {
        transcribed += 1;
        return '不应出现';
      },
    );
    await controller.initialize();

    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    platform.session!.stopError = true;
    await controller.stopAndTranscribe();

    // 通道异常在这里收成人话并回 idle：上层收得好，录音通道才敢不吞异常
    // （吞成空字节只会把一个 44 字节头的空 WAV 送去转写）。
    expect(controller.status, VoiceInputStatus.idle);
    expect(controller.errorMessage, '录音结束失败，请重新说一次。');
    expect(controller.hasRetainedAudio, isFalse);
    expect(transcribed, 0);
    controller.dispose();
  });

  test('Esc 在录音中丢弃：不转写、不留字节', () async {
    final platform = _FakeRecorderPlatform();
    var transcribed = 0;
    final controller = _pumpController(
      platform: platform,
      transcribe: (audio, mimeType) async {
        transcribed += 1;
        return '不应出现';
      },
    );
    await controller.initialize();

    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    controller.handleEscape();
    await Future<void>.delayed(Duration.zero);

    expect(controller.status, VoiceInputStatus.idle);
    expect(transcribed, 0);
    expect(platform.session!.discardCalls, 1);
    expect(controller.hasRetainedAudio, isFalse);
    controller.dispose();
  });

  test('Esc 在转写中中止：回可重试态且迟到的结果作废', () async {
    final platform = _FakeRecorderPlatform();
    final sent = <String>[];
    late Completer<String> pending;
    final controller = _pumpController(
      platform: platform,
      transcribe: (audio, mimeType) {
        pending = Completer<String>();
        return pending.future;
      },
      onTranscribed: sent.add,
    );
    await controller.initialize();

    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.transcribing);

    controller.handleEscape();
    expect(controller.status, VoiceInputStatus.retryable);
    expect(controller.hasRetainedAudio, isTrue);

    // 迟到的成功不会触发发送，也不会把状态拽回 idle。
    pending.complete('迟到的话');
    await Future<void>.delayed(Duration.zero);
    expect(sent, isEmpty);
    expect(controller.status, VoiceInputStatus.retryable);

    // 重试开启新一次转写，完成即回 idle。
    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.transcribing);
    pending.complete('重试的话');
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.idle);
    expect(sent, ['重试的话']);
    controller.dispose();
  });

  test('停止录音等待期间按 Esc：不发起转写，音频保留且重试只发生一次', () async {
    final platform = _FakeRecorderPlatform();
    final transcriptions = <List<int>>[];
    final sent = <String>[];
    final controller = _pumpController(
      platform: platform,
      transcribe: (audio, mimeType) async {
        transcriptions.add(audio.toList());
        return '停止期间被中止后重试的话';
      },
      onTranscribed: sent.add,
    );
    await controller.initialize();

    // 让 session.stop() 挂起，制造「停止录音在途」的时间窗。
    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.recording);
    platform.session!.stopGate = Completer<void>();
    controller.handleMicTap(); // 触发 stopAndTranscribe，stop 挂起中。
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.transcribing);

    // 等待期间按 Esc：作废令牌并进入可重试态。
    controller.handleEscape();
    expect(controller.status, VoiceInputStatus.retryable);

    // stop 返回后绝不发起转写（Esc 不被吞），音频保留供重试。
    platform.session!.stopGate!.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(transcriptions, isEmpty);
    expect(sent, isEmpty);
    expect(controller.status, VoiceInputStatus.retryable);
    expect(controller.hasRetainedAudio, isTrue);

    // 可重试态点麦克风：只发生一次转写并成功收尾。
    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(transcriptions, hasLength(1));
    expect(sent, ['停止期间被中止后重试的话']);
    expect(controller.status, VoiceInputStatus.idle);
    controller.dispose();
  });

  test('停止录音等待期间连按两次 Esc：音频彻底丢弃、不发起任何转写', () async {
    final platform = _FakeRecorderPlatform();
    final transcriptions = <List<int>>[];
    final controller = _pumpController(
      platform: platform,
      transcribe: (audio, mimeType) async {
        transcriptions.add(audio.toList());
        return '不应出现';
      },
    );
    await controller.initialize();

    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.recording);
    platform.session!.stopGate = Completer<void>();
    controller.handleMicTap(); // stop 挂起中。
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.transcribing);

    // 第一次 Esc：中止上传回可重试态；第二次 Esc：丢弃回 idle。
    controller.handleEscape();
    expect(controller.status, VoiceInputStatus.retryable);
    controller.handleEscape();
    expect(controller.status, VoiceInputStatus.idle);
    expect(controller.hasRetainedAudio, isFalse);

    // stop 返回后不得把音频写回内存（取消即丢弃）。
    platform.session!.stopGate!.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.idle);
    expect(controller.hasRetainedAudio, isFalse);
    expect(transcriptions, isEmpty);

    // 可重试通道也不复用该音频：idle 态点麦克风是重新录音而非重传。
    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.recording);
    controller.discard();
    controller.dispose();
  });

  test('Esc 在可重试态丢弃音频并回 idle', () async {
    final platform = _FakeRecorderPlatform();
    final controller = _pumpController(
      platform: platform,
      transcribe: (audio, mimeType) async =>
          throw const LocalChatGatewayException('连接语音服务超时。'),
    );
    await controller.initialize();
    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.retryable);

    controller.handleEscape();
    expect(controller.status, VoiceInputStatus.idle);
    expect(controller.hasRetainedAudio, isFalse);
    controller.dispose();
  });

  test('dispose 丢弃在途录音，不再触发任何回调', () async {
    final platform = _FakeRecorderPlatform();
    final sent = <String>[];
    final controller = _pumpController(
      platform: platform,
      onTranscribed: sent.add,
    );
    await controller.initialize();
    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, VoiceInputStatus.recording);

    controller.dispose();
    expect(platform.session!.discardCalls, 1);
    controller.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    expect(sent, isEmpty);
  });
}

VoiceInputController _pumpController({
  _FakeRecorderPlatform? platform,
  bool configured = true,
  Future<String> Function(Uint8List audio, String mimeType)? transcribe,
  void Function(String text)? onTranscribed,
}) {
  return VoiceInputController(
    platform ?? _FakeRecorderPlatform(),
    () async => (configured: configured, wantsWavAudio: false),
    transcribe ?? ((audio, mimeType) async => '今天有点累'),
    onTranscribed: onTranscribed ?? (_) {},
  );
}

final class _FakeRecorderPlatform implements VoiceRecorderPlatform {
  _FakeRecorderPlatform({this.supported = true, this.sessionEnabled = true});

  @override
  final bool supported;
  final bool sessionEnabled;

  /// WAV 转换的可控预置结果：测试注入确定字节。
  Uint8List wavBytes = Uint8List.fromList([1, 1]);
  bool wavError = false;
  int toWavCalls = 0;
  _FakeRecordingSession? session;

  @override
  Future<VoiceRecordingSession?> start() async {
    if (!supported || !sessionEnabled) {
      return null;
    }
    return session = _FakeRecordingSession();
  }

  @override
  Future<RecordedAudio> toWav16kMono(RecordedAudio audio) async {
    toWavCalls += 1;
    if (wavError) {
      throw StateError('decode failed');
    }
    return RecordedAudio(bytes: wavBytes, mimeType: 'audio/wav');
  }
}

final class _FakeRecordingSession implements VoiceRecordingSession {
  final bytes = Uint8List.fromList([1, 2, 3, 4]);
  int stopCalls = 0;
  int discardCalls = 0;

  /// 置 true 后 stop() 抛错：模拟「原生停止采集时取不回字节」。
  bool stopError = false;

  /// 非空时 stop() 先等待该闸门，模拟「停止录音在途」的时间窗。
  Completer<void>? stopGate;

  @override
  String get mimeType => 'audio/webm';

  @override
  Future<Uint8List> stop() async {
    if (stopGate case final gate?) {
      await gate.future;
    }
    if (stopError) {
      throw StateError('原生停止采集失败');
    }
    stopCalls += 1;
    return bytes;
  }

  @override
  void discard() {
    discardCalls += 1;
  }
}
