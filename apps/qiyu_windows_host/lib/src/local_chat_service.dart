import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'markdown_memory_repository.dart';
import 'model_gateway.dart';
import 'model_prompt_builder.dart';
import 'provider_settings_service.dart';

final class LocalChatException implements Exception {
  const LocalChatException({
    required this.code,
    required this.message,
    required this.retryable,
  });

  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

final class LocalChatSnapshot {
  const LocalChatSnapshot(this.session);

  final RawSession session;

  Map<String, Object?> toJson() => {
    'sessionId': session.id,
    'turns': session.turns.map(_turnToPublicJson).toList(),
    'limits': {
      'maxTurnsPerSegment': maxRawSessionTurns,
      'activeHistoryDays': activeSessionHistoryWindow.inDays,
    },
  };
}

final class LocalChatExchange {
  const LocalChatExchange({required this.session, required this.result});

  final RawSession session;
  final ChatResult result;

  Map<String, Object?> toJson() => {
    ...result.toJson(),
    'sessionId': session.id,
  };
}

final class LocalChatService {
  LocalChatService(
    this._repository, {
    QiyuBehaviorCore? behaviorCore,
    this.providerChatClient,
    this.modelPromptBuilder = const ModelPromptBuilder(''),
    Clock? clock,
  }) : _behaviorCore = behaviorCore ?? const QiyuBehaviorCore(),
       _clock = clock ?? DateTime.now;

  final MemoryRepository _repository;
  final QiyuBehaviorCore _behaviorCore;
  final ProviderChatClient? providerChatClient;
  final ModelPromptBuilder modelPromptBuilder;
  final Clock _clock;
  Future<void> _pending = Future.value();

  Future<void> initialize() => _repository.initialize();

  Future<LocalChatSnapshot> restore({String? sessionId}) => _serialized(
    () async =>
        LocalChatSnapshot(await _repository.openSession(sessionId: sessionId)),
  );

  Future<LocalChatExchange> send({
    required String requestId,
    required String text,
    String? sessionId,
  }) => _serialized(() async {
    final trimmedRequestId = requestId.trim();
    final trimmedText = sanitizeUserInput(text);
    if (trimmedRequestId.isEmpty || trimmedText.isEmpty) {
      throw const LocalChatException(
        code: 'invalid_request',
        message: '消息不能为空。',
        retryable: false,
      );
    }

    var session = await _repository.openSession(sessionId: sessionId);
    final existingUser = _findTurn(
      session.turns,
      requestId: trimmedRequestId,
      speaker: Speaker.user,
    );
    final existingReply = _findTurn(
      session.turns,
      requestId: trimmedRequestId,
      speaker: Speaker.qiyu,
    );
    if (existingUser != null &&
        existingUser.text != redactSessionText(trimmedText)) {
      throw const LocalChatException(
        code: 'request_id_conflict',
        message: '这条消息标识已被另一条内容使用，请重新发送。',
        retryable: false,
      );
    }
    if (existingReply != null) {
      return LocalChatExchange(
        session: session,
        result: _storedResult(session, existingReply),
      );
    }

    if (existingUser == null) {
      if (session.turns.length > maxRawSessionTurns - 2 ||
          session.date != localSessionDate(_clock())) {
        session = await _repository.createSession();
      }
      session = await _repository.appendTurn(
        session,
        RawSessionTurn.user(
          requestId: trimmedRequestId,
          text: trimmedText,
          at: _clock(),
        ),
      );
    }

    final state = _stateFromCompletedTurns(session.turns, trimmedRequestId);
    final localOutcome = _behaviorCore.reply(
      ChatRequest(requestId: trimmedRequestId, text: trimmedText),
      state,
    );
    if (localOutcome is! ChatResult) {
      final error = localOutcome as ErrorResult;
      throw LocalChatException(
        code: error.code.wireName,
        message: error.message,
        retryable: error.retryable,
      );
    }
    var outcome = localOutcome;
    if (localOutcome.safety == null && providerChatClient != null) {
      ModelCompletion? completion;
      try {
        completion = await providerChatClient!.complete(
          modelPromptBuilder.build(state, trimmedText),
        );
      } on Object {
        completion = const ModelCompletion.failure(ModelFailureKind.provider);
      }
      if (completion != null) {
        outcome =
            _behaviorCore.reply(
                  ChatRequest(requestId: trimmedRequestId, text: trimmedText),
                  state,
                  candidateReply: completion.text,
                  modelFailure: completion.failure == null
                      ? null
                      : _fallbackReasonFor(completion.failure!),
                )
                as ChatResult;
      }
    }

    final completed = await _repository.appendTurn(
      session,
      RawSessionTurn.qiyu(
        requestId: trimmedRequestId,
        messages: outcome.messages,
        at: _clock(),
        source: outcome.source,
        fallbackReason: outcome.fallbackReason,
        mode: outcome.mode,
        safety: outcome.safety,
      ),
    );
    return LocalChatExchange(session: completed, result: outcome);
  });

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}

StateSnapshot _stateFromCompletedTurns(
  List<RawSessionTurn> turns,
  String pendingRequestId,
) {
  final completed = <ChatTurn>[];
  RawSessionTurn? pendingUser;
  for (final turn in turns) {
    if (turn.requestId == pendingRequestId && turn.speaker == Speaker.user) {
      continue;
    }
    if (turn.speaker == Speaker.user) {
      pendingUser = turn;
      continue;
    }
    if (pendingUser != null && pendingUser.requestId == turn.requestId) {
      completed
        ..add(ChatTurn(speaker: Speaker.user, text: pendingUser.text))
        ..add(ChatTurn(speaker: Speaker.qiyu, text: turn.text));
      pendingUser = null;
    }
  }
  final recent = completed.length <= maxStateTurns
      ? completed
      : completed.sublist(completed.length - maxStateTurns);
  return StateSnapshot(
    userId: 'local-user',
    relationshipStage: RelationshipStage.stranger,
    turns: recent,
    lastEmotion: const EmotionSnapshot(kind: EmotionKind.neutral, intensity: 0),
  );
}

ChatResult _storedResult(RawSession session, RawSessionTurn reply) {
  return ChatResult(
    requestId: reply.requestId,
    messages: reply.messages.isEmpty ? [reply.text] : reply.messages,
    nextState: _stateFromCompletedTurns(session.turns, ''),
    source: reply.source ?? ReplySource.local,
    fallbackReason: reply.fallbackReason,
    mode: reply.mode ?? 'local',
    safety: reply.safety,
  );
}

Map<String, Object?> _turnToPublicJson(RawSessionTurn turn) => {
  'requestId': turn.requestId,
  'speaker': turn.speaker.name,
  'text': turn.text,
  'at': turn.at.toUtc().toIso8601String(),
  if (turn.source != null) 'source': turn.source!.name,
  if (turn.fallbackReason != null)
    'fallbackReason': turn.fallbackReason!.wireName,
};

RawSessionTurn? _findTurn(
  List<RawSessionTurn> turns, {
  required String requestId,
  required Speaker speaker,
}) {
  for (final turn in turns) {
    if (turn.requestId == requestId && turn.speaker == speaker) {
      return turn;
    }
  }
  return null;
}

FallbackReason _fallbackReasonFor(ModelFailureKind failure) =>
    switch (failure) {
      ModelFailureKind.dns => FallbackReason.modelDns,
      ModelFailureKind.tls => FallbackReason.modelTls,
      ModelFailureKind.timeout => FallbackReason.modelTimeout,
      ModelFailureKind.authentication => FallbackReason.modelAuthentication,
      ModelFailureKind.network => FallbackReason.modelNetwork,
      ModelFailureKind.modelNotFound => FallbackReason.modelNotFound,
      ModelFailureKind.rateLimited => FallbackReason.modelRateLimited,
      ModelFailureKind.incompatibleResponse =>
        FallbackReason.incompatibleModelResponse,
      ModelFailureKind.contentParsing => FallbackReason.modelContentParsing,
      ModelFailureKind.provider => FallbackReason.modelProvider,
    };
