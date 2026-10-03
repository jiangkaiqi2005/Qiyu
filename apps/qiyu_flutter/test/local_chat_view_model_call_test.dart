import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';

import 'support/shared_fakes.dart';

void main() {
  /// 通话显示面（OmniCallChatSurface）落在本视图模型上：通话转录进入
  /// 普通聊天流（T04:7），复用流式行装配，不另建消息列表。
  group('LocalChatViewModel 通话显示面（T04）', () {
    LocalChatViewModel buildModel(FakeLocalChatGateway gateway) {
      return LocalChatViewModel(
        gateway,
        hostConnectionProbe: FakeHostConnectionProbe(const [true]),
        autoStart: false,
      );
    }

    test('callUserTurn 入列用户气泡；同 requestId 的后到转录整段覆盖', () {
      final model = buildModel(FakeLocalChatGateway());
      addTearDown(model.dispose);
      model.callUserTurn(requestId: 'voice-1', text: '今晚有点');
      model.callUserTurn(requestId: 'voice-1', text: '今晚有点睡不着。');
      expect(model.messages, hasLength(1));
      expect(model.messages.single.speaker, LocalChatSpeaker.user);
      expect(model.messages.single.text, '今晚有点睡不着。');
    });

    test('callReplyDelta 走流式行装配；callReplyDone 落成栖语气泡', () {
      final model = buildModel(FakeLocalChatGateway());
      addTearDown(model.dispose);
      model.callUserTurn(requestId: 'voice-1', text: '睡不着');
      model.callReplyDelta('嗯，');
      model.callReplyDelta('我在。\n陪你待一会儿。');
      expect(model.streamingText, '嗯，我在。\n陪你待一会儿。');
      expect(model.streamingCompletedLines, ['嗯，我在。']);
      expect(model.streamingTailSegment, '陪你待一会儿。');

      model.callReplyDone(incomplete: false, interrupted: false);
      expect(model.streamingText, isEmpty);
      expect(model.messages, hasLength(2));
      final reply = model.messages.last;
      expect(reply.speaker, LocalChatSpeaker.qiyu);
      expect(reply.text, '嗯，我在。\n陪你待一会儿。');
      expect(reply.incomplete, isFalse);
      expect(reply.interrupted, isFalse);
      expect(reply.deliveryIndex, isNull, reason: '通话回复不出现在朗读队列');
    });

    test('未完成轮保留前缀并如实标记；空文本不落气泡（静默工具轮）', () {
      final model = buildModel(FakeLocalChatGateway());
      addTearDown(model.dispose);
      model.callReplyDelta('我先说到这');
      model.callReplyDone(incomplete: true, interrupted: false);
      expect(model.messages.single.incomplete, isTrue);
      expect(model.messages.single.interrupted, isFalse);
      expect(model.messages.single.text, '我先说到这');

      // 被打断与未完成是两种标记（spec:20）。
      model.callReplyDelta('另一轮');
      model.callReplyDone(incomplete: true, interrupted: true);
      expect(model.messages.last.interrupted, isTrue);

      model.callReplyDone(incomplete: false, interrupted: false);
      expect(model.messages, hasLength(2), reason: '静默工具轮无可显示内容');
    });

    test('callSessionReset 清掉残留流式态', () {
      final model = buildModel(FakeLocalChatGateway());
      addTearDown(model.dispose);
      model.callReplyDelta('旧通话残句');
      model.callSessionReset();
      expect(model.streamingText, isEmpty);
      model.callReplyDone(incomplete: false, interrupted: false);
      expect(model.messages, isEmpty);
    });

    test('resyncAfterCall 以落盘快照替换显示态（含乐观消息对账）', () async {
      final gateway = FakeLocalChatGateway(
        restored: const LocalChatSnapshot(
          sessionId: 'session-1',
          messages: [
            LocalChatMessage(
              requestId: 'voice-1',
              speaker: LocalChatSpeaker.user,
              text: '今晚有点睡不着。',
            ),
            LocalChatMessage(
              requestId: 'voice-1',
              speaker: LocalChatSpeaker.qiyu,
              text: '嗯，我在。',
            ),
          ],
        ),
      );
      final model = buildModel(gateway);
      addTearDown(model.dispose);
      // 通话中乐观入列了一条尚未落盘的打字轮。
      model.callUserTurn(requestId: 'omni-call-x', text: '乐观消息');
      expect(model.messages, hasLength(1));
      await model.resyncAfterCall();
      expect(model.messages, hasLength(2));
      expect(model.messages[0].text, '今晚有点睡不着。');
      expect(model.messages[0].deliveryIndex, isNull);
      expect(model.messages[1].deliveryIndex, 0, reason: '恢复路径标注交付序号');
      expect(
        model.messages.any((m) => m.text == '乐观消息'),
        isFalse,
        reason: '未落盘的乐观消息在对账时归真',
      );
    });
  });
}
