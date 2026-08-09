import 'dart:convert';
import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:test/test.dart';

void main() {
  final fixtureDocument =
      jsonDecode(
            File(
              '../../contracts/qiyu_behavior_contracts.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final fixtures = fixtureDocument['cases']! as List<Object?>;

  for (final value in fixtures) {
    final fixture = value! as Map<String, Object?>;
    test('Dart behavior matches shared fixture: ${fixture['id']}', () {
      final requestJson = fixture['request']! as Map<String, Object?>;
      final providerJson = fixture['provider']! as Map<String, Object?>;
      final expected = fixture['expected']! as Map<String, Object?>;
      final core = QiyuBehaviorCore();
      final outcome = core.reply(
        ChatRequest.fromJson(requestJson),
        StateSnapshot.initial('fixture-user'),
        candidateReply: providerJson['configured'] == true
            ? providerJson['candidateReply']! as String
            : null,
      );

      expect(outcome, isA<ChatResult>());
      final result = outcome as ChatResult;
      expect(result.messages, expected['messages']);
      expect(result.source.name, expected['source']);
      expect(result.fallbackReason?.wireName, expected['fallbackReason']);
      expect(result.mode, expected['mode']);
      expect(result.safety?.name, expected['safety']);
      expect(
        result.nextState.relationshipStage.wireName,
        expected['relationshipStage'],
      );
      expect(
        result.nextState.turns.map((turn) => turn.toJson()).toList(),
        expected['turns'],
      );
    });
  }

  test('stable contracts round-trip through JSON', () {
    final request = ChatRequest(requestId: 'round-trip', text: '晚安');
    final state = StateSnapshot.initial('fixture-user');
    final error = ErrorResult(
      requestId: request.requestId,
      code: ChatErrorCode.invalidRequest,
      message: '消息不能为空',
      retryable: false,
    );
    final result = QiyuBehaviorCore().reply(request, state) as ChatResult;

    expect(ChatRequest.fromJson(request.toJson()), request);
    expect(StateSnapshot.fromJson(state.toJson()), state);
    expect(ChatResult.fromJson(result.toJson()), result);
    expect(result.toJson(), containsPair('debug', isA<Map<String, Object?>>()));
    expect(result.toJson(), isNot(contains('mode')));
    expect(result.toJson(), isNot(contains('safety')));
    expect(ErrorResult.fromJson(error.toJson()), error);
  });

  test('ChatResult accepts the migration-period JavaScript wire shape', () {
    final result =
        QiyuBehaviorCore().reply(
              const ChatRequest(requestId: 'legacy-js', text: '我到家了'),
              StateSnapshot.initial('fixture-user'),
            )
            as ChatResult;
    final legacyWire = Map<String, Object?>.from(result.toJson())
      ..remove('schemaVersion')
      ..remove('requestId');

    final decoded = ChatResult.fromJson(legacyWire);

    expect(decoded.requestId, isNull);
    expect(decoded.messages, result.messages);
    expect(decoded.nextState, result.nextState);
    expect(decoded.source, ReplySource.local);
    expect(decoded.mode, 'minimal');
  });

  test('state contracts reject unknown relationship and emotion values', () {
    expect(
      () => StateSnapshot.fromJson({
        ...StateSnapshot.initial('fixture-user').toJson(),
        'relationshipStage': '陌生值',
      }),
      throwsFormatException,
    );
    expect(
      () => EmotionSnapshot.fromJson({'kind': 'unknown', 'intensity': 0}),
      throwsA(isA<ArgumentError>()),
    );
  });
}
