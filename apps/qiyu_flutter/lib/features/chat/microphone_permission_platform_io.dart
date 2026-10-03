import 'voice_recorder_platform.dart';
import 'voice_recorder_platform_io.dart';

// 复用既有 Android 权限通道，只查/请权限，不准备或启动录音。
PermissionAwareVoiceRecorderPlatform createMicrophonePermissionPlatform() =>
    IoVoiceRecorderPlatform();
