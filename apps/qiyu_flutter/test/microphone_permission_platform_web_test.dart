@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:qiyu_flutter/features/chat/microphone_permission_platform_web.dart';
import 'package:qiyu_flutter/features/chat/voice_recorder_platform.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

void main() {
  test('浏览器授权仅临时取流，返回前全部轨道已停止', () async {
    final context = web.AudioContext();
    final stream = context.createMediaStreamDestination().stream;
    final devices = web.window.navigator.mediaDevices;
    final original = devices.getProperty<JSFunction>('getUserMedia'.toJS);
    addTearDown(() async {
      devices.setProperty('getUserMedia'.toJS, original);
      await context.close().toDart;
    });
    devices.setProperty(
      'getUserMedia'.toJS,
      ((JSAny _) => Future<web.MediaStream>.value(stream).toJS).toJS,
    );
    final permission = const WebMicrophonePermissionPlatform();
    expect(await permission.preparePermission(), VoicePermissionResult.ready);
    expect(stream.getTracks().toDart, isNotEmpty);
    expect(
      stream.getTracks().toDart.every((track) => track.readyState == 'ended'),
      isTrue,
    );
  });

  test('浏览器拒绝或取消授权如实返回 denied', () async {
    final devices = web.window.navigator.mediaDevices;
    final original = devices.getProperty<JSFunction>('getUserMedia'.toJS);
    addTearDown(() => devices.setProperty('getUserMedia'.toJS, original));
    devices.setProperty(
      'getUserMedia'.toJS,
      ((JSAny _) => Future<web.MediaStream>.error('NotAllowedError').toJS).toJS,
    );
    expect(
      await const WebMicrophonePermissionPlatform().preparePermission(),
      VoicePermissionResult.denied,
    );
  });
}
