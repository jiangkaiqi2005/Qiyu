@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:async';

import 'package:qiyu_flutter/features/chat/voice_capture_platform.dart'
    hide createVoiceCapturePlatform;
import 'package:qiyu_flutter/features/chat/voice_capture_platform_web.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

void main() {
  test('自动前检只接受当前 grant 与可用麦克风，不申请权限', () async {
    final platform = createVoiceCapturePlatform();
    expect(platform, isA<AutoStartVoiceCapturePlatform>());
    final automatic = platform as AutoStartVoiceCapturePlatform;
    final permissions = web.window.navigator.permissions;
    final devices = web.window.navigator.mediaDevices;
    final query = permissions.getProperty<JSFunction>('query'.toJS);
    final enumerate = devices.getProperty<JSFunction>('enumerateDevices'.toJS);
    final getUserMedia = devices.getProperty<JSFunction>('getUserMedia'.toJS);
    addTearDown(() {
      permissions.setProperty('query'.toJS, query);
      devices.setProperty('enumerateDevices'.toJS, enumerate);
      devices.setProperty('getUserMedia'.toJS, getUserMedia);
    });
    devices.setProperty(
      'getUserMedia'.toJS,
      ((JSAny _) {
                fail('自动前检不能触发授权或采集');
              }
              as JSAny? Function(JSAny))
          .toJS,
    );
    var state = 'granted';
    var microphone = true;
    permissions.setProperty(
      'query'.toJS,
      ((JSAny _) => Future<JSObject>.value(
        {'state': state}.jsify()! as JSObject,
      ).toJS).toJS,
    );
    devices.setProperty(
      'enumerateDevices'.toJS,
      (() => Future<JSArray<web.MediaDeviceInfo>>.value(
        [
              if (microphone) {'kind': 'audioinput'},
            ].jsify()!
            as JSArray<web.MediaDeviceInfo>,
      ).toJS).toJS,
    );
    expect(await automatic.canAutoStart(), isTrue);
    state = 'prompt';
    expect(await automatic.canAutoStart(), isFalse);
    state = 'denied';
    expect(await automatic.canAutoStart(), isFalse);
    state = 'granted';
    microphone = false;
    expect(await automatic.canAutoStart(), isFalse);
    microphone = true;
    _defineProperty(
      web.document,
      'visibilityState'.toJS,
      {'value': 'hidden', 'configurable': true}.jsify()! as JSObject,
    );
    addTearDown(() => web.document.delete('visibilityState'.toJS));
    expect(await automatic.canAutoStart(), isFalse);
    web.document.delete('visibilityState'.toJS);
    permissions.setProperty(
      'query'.toJS,
      ((JSAny _) => Future<JSObject>.error(
        'permissions API unsupported',
      ).toJS).toJS,
    );
    expect(await automatic.canAutoStart(), isFalse);
  });

  for (final reason in [
    'NotAllowedError',
    'NotReadableError',
    'NotFoundError',
  ]) {
    test('授权撤销或设备不可用 $reason 不启动采集', () async {
      final devices = web.window.navigator.mediaDevices;
      final original = devices.getProperty<JSFunction>('getUserMedia'.toJS);
      addTearDown(() => devices.setProperty('getUserMedia'.toJS, original));
      devices.setProperty(
        'getUserMedia'.toJS,
        ((JSAny _) => Future<web.MediaStream>.error(reason).toJS).toJS,
      );
      expect(
        await createVoiceCapturePlatform().start(
          onChunk: (_) => fail('失败采集不能送 PCM'),
          onUnavailable: (_) {},
        ),
        isNull,
      );
    });
  }

  test('采集 AudioContext 未能恢复时释放已取得轨道', () async {
    final context = web.AudioContext();
    final stream = context.createMediaStreamDestination().stream;
    final devices = web.window.navigator.mediaDevices;
    final original = devices.getProperty<JSFunction>('getUserMedia'.toJS);
    final prototype = globalContext
        .getProperty<JSFunction>('AudioContext'.toJS)
        .getProperty<JSObject>('prototype'.toJS);
    final resume = prototype.getProperty<JSFunction>('resume'.toJS);
    addTearDown(() async {
      devices.setProperty('getUserMedia'.toJS, original);
      prototype.setProperty('resume'.toJS, resume);
      await context.close().toDart;
    });
    devices.setProperty(
      'getUserMedia'.toJS,
      ((JSAny _) => Future<web.MediaStream>.value(stream).toJS).toJS,
    );
    prototype.setProperty(
      'resume'.toJS,
      (() => Future<JSAny?>.error('capture context rejected').toJS).toJS,
    );
    expect(
      await createVoiceCapturePlatform().start(
        onChunk: (_) => fail('未运行采集不能送 PCM'),
        onUnavailable: (_) {},
      ),
      isNull,
    );
    expect(stream.getAudioTracks().toDart.single.readyState, 'ended');
  });

  test('连续采集交出 PCM 才算就绪，停止后轨道和回调都释放', () async {
    final context = web.AudioContext();
    final oscillator = context.createOscillator();
    final destination = context.createMediaStreamDestination();
    oscillator.connect(destination);
    oscillator.start();
    final stream = destination.stream;
    final devices = web.window.navigator.mediaDevices;
    final original = devices.getProperty<JSFunction>('getUserMedia'.toJS);
    addTearDown(() async {
      devices.setProperty('getUserMedia'.toJS, original);
      oscillator.stop();
      await context.close().toDart;
    });
    devices.setProperty(
      'getUserMedia'.toJS,
      ((JSAny _) => Future<web.MediaStream>.value(stream).toJS).toJS,
    );
    var chunks = 0;
    var chunkLength = 0;
    final session = await createVoiceCapturePlatform().start(
      onChunk: (pcm) {
        chunkLength = pcm.length;
        chunks++;
      },
      onUnavailable: (_) => fail('合成的连续媒体流不应失效'),
    );
    expect(session, isNotNull);
    expect(chunks, greaterThan(0), reason: '返回会话时必须已验证采集链路真正运行');
    expect(chunkLength, 3200);
    session!.stop();
    final stoppedChunks = chunks;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(chunks, stoppedChunks);
    expect(stream.getAudioTracks().toDart.single.readyState, 'ended');
  });
}

@JS('Object.defineProperty')
external JSObject _defineProperty(
  JSObject object,
  JSString name,
  JSObject value,
);
