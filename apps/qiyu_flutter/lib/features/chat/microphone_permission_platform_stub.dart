import 'voice_recorder_platform.dart';

final class _UnavailableMicrophonePermission
    implements PermissionAwareVoiceRecorderPlatform {
  const _UnavailableMicrophonePermission();

  @override
  Future<VoicePermissionResult> preparePermission() async =>
      VoicePermissionResult.denied;
}

PermissionAwareVoiceRecorderPlatform createMicrophonePermissionPlatform() =>
    const _UnavailableMicrophonePermission();
