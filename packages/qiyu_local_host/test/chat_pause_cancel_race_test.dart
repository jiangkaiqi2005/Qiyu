import 'dart:async';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/in_process_chat_host.dart';

/// 取消与分片停顿的竞速回归（票 09 评审补）：把取消精确压进 70ms 停顿
/// 窗内，验证 beforeChunk 竞速由取消胜出——在途片丢弃、无第二片 delta
/// 上屏、整轮按既有取消语义落定（只交付 cancelled 事件，不落盘）。
void main() {
  group('交付节奏与取消竞速', () {
    test('取消落在停顿窗内：竞速取消胜出，在途片丢弃，整轮取消落定', () async {
      final gateway = ScriptedModelGateway(
        streamScript: [const ScriptedLiveStream()],
      );
      // 停顿闩：第一次停顿调用（第二片的 beforeChunk 竞速）挂起，直到
      // 取消发出后才放行——没有闩，70ms 停顿早已走完，压不进窗内。
      final pauseArmed = Completer<void>();
      Completer<void>? releasePause;
      final harness = await InProcessChatHost.start(
        modelGateway: gateway,
        clock: () => DateTime(2026, 9, 26, 22, 30),
        deliveryPause: (duration) {
          if (pauseArmed.isCompleted) {
            return Future<void>.value();
          }
          releasePause = Completer<void>();
          pauseArmed.complete();
          return releasePause!.future;
        },
      );
      addTearDown(harness.dispose);

      final stream = harness.openChat(
        requestId: 'pause-cancel-1',
        text: '先别说',
      );
      await gateway.awaitStreamOpened();
      // 18 runes：首片 12 立即上屏，第二片（6 runes）的停顿进闩。
      const reply = '一二三四五六七八九十十一十二十三十四';
      final firstChunk = String.fromCharCodes(reply.runes.take(12));
      gateway.liveController.add(ModelStreamEvent.delta(reply));
      await pauseArmed.future;
      expect(await harness.cancelChat('pause-cancel-1'), isTrue);
      releasePause!.complete();
      await stream.done;

      expect(stream.received.last.kind, ChatDeliveryEventKind.cancelled);
      // 只有首片上屏：第二片连同尾片在停顿窗内被竞速丢弃，不补发、
      // 不重复上屏。
      final deltas = stream.received
          .where((event) => event.kind == ChatDeliveryEventKind.delta)
          .map((event) => event.text!)
          .toList();
      expect(deltas, [firstChunk]);
      // 取消语义与既有取消用例同口径：绝不交付最终回复、不落盘。
      for (final kind in const [
        ChatDeliveryEventKind.message,
        ChatDeliveryEventKind.state,
        ChatDeliveryEventKind.done,
      ]) {
        expect(
          stream.received,
          isNot(
            contains(
              predicate<ChatDeliveryEvent>((event) => event.kind == kind),
            ),
          ),
        );
      }
      final sessionId = stream.received.first.sessionId!;
      final restored = await harness.storedSession(sessionId);
      expect(restored.turns.map((turn) => turn.speaker), [Speaker.user]);
      await gateway.liveController.close();
    });
  });
}
