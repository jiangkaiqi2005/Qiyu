import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/chat/microphone_permission_platform.dart';
import 'package:qiyu_flutter/features/chat/voice_recorder_platform.dart';
import 'package:qiyu_flutter/features/chat/voice_recorder_platform_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final existing in [true, false]) {
    for (final allowed in [true, false]) {
      test(
        'Android 授权 existing=$existing allowed=$allowed 仅用权限通道，不起录放/服务',
        () async {
          final calls = <String>[];
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(
            const MethodChannel(androidVoiceRecorderChannelName),
            (call) async {
              calls.add(call.method);
              return switch (call.method) {
                'hasMicrophonePermission' => existing,
                'requestMicrophonePermission' => allowed,
                _ => throw StateError('不应开始或停止录音：${call.method}'),
              };
            },
          );
          addTearDown(
            () => messenger.setMockMethodCallHandler(
              const MethodChannel(androidVoiceRecorderChannelName),
              null,
            ),
          );
          final result = await createMicrophonePermissionPlatform()
              .preparePermission();
          expect(
            result,
            existing
                ? VoicePermissionResult.ready
                : allowed
                ? VoicePermissionResult.grantedNow
                : VoicePermissionResult.denied,
          );
          expect(
            calls,
            existing
                ? ['hasMicrophonePermission']
                : ['hasMicrophonePermission', 'requestMicrophonePermission'],
          );
        },
      );
    }
  }
}
