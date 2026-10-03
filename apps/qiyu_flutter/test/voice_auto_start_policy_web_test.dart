@TestOn('browser')
library;

import 'package:qiyu_flutter/features/chat/voice_player_platform_web.dart';
import 'package:test/test.dart';

void main() {
  test('默认 Chrome 策略下无活跃采集及手势时如实退回手动', () async {
    // 专用默认 chrome runner，不加 no-user-gesture-required；本用例
    // 只验证受限分支，不拿无麦克风场景宣称活跃采集自动播放已验收。
    final player = WebVoicePlayerPlatform();
    final ready = player.prepareForAutoPlayback();
    final context = player.debugAudioContext!;
    expect(await ready.timeout(const Duration(seconds: 2)), isFalse);
    expect(context.state, 'closed');
    expect(player.debugAudioContext, isNull);
  });
}
