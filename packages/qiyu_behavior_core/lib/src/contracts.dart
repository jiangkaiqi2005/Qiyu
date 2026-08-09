const contractSchemaVersion = 1;

enum ChatErrorCode {
  invalidRequest('invalid_request');

  const ChatErrorCode(this.wireName);

  final String wireName;

  static ChatErrorCode fromWireName(String value) => values.firstWhere(
    (candidate) => candidate.wireName == value,
    orElse: () => throw FormatException('Unknown chat error code: $value'),
  );
}

enum ReplySource { local, model }

enum FallbackReason {
  safety('safety'),
  noLlmConfig('no_llm_config'),
  forbiddenPhrases('forbidden_phrases'),
  llmError('llm_error');

  const FallbackReason(this.wireName);

  final String wireName;
}

enum SafetyKind { normal, crisis, medical, legal, financial }

enum Speaker { user, qiyu }

sealed class ChatOutcome {
  const ChatOutcome();

  Map<String, Object?> toJson();
}

final class ChatRequest {
  const ChatRequest({
    required this.requestId,
    required this.text,
    this.schemaVersion = contractSchemaVersion,
  });

  factory ChatRequest.fromJson(Map<String, Object?> json) {
    return ChatRequest(
      schemaVersion: json['schemaVersion'] as int? ?? contractSchemaVersion,
      requestId: json['requestId']! as String,
      text: json['text']! as String,
    );
  }

  final int schemaVersion;
  final String requestId;
  final String text;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'requestId': requestId,
    'text': text,
  };

  @override
  bool operator ==(Object other) =>
      other is ChatRequest &&
      other.schemaVersion == schemaVersion &&
      other.requestId == requestId &&
      other.text == text;

  @override
  int get hashCode => Object.hash(schemaVersion, requestId, text);
}

final class ChatTurn {
  const ChatTurn({required this.speaker, required this.text});

  factory ChatTurn.fromJson(Map<String, Object?> json) {
    return ChatTurn(
      speaker: Speaker.values.byName(json['speaker']! as String),
      text: json['text']! as String,
    );
  }

  final Speaker speaker;
  final String text;

  Map<String, Object?> toJson() => {'speaker': speaker.name, 'text': text};

  @override
  bool operator ==(Object other) =>
      other is ChatTurn && other.speaker == speaker && other.text == text;

  @override
  int get hashCode => Object.hash(speaker, text);
}

final class EmotionSnapshot {
  const EmotionSnapshot({required this.kind, required this.intensity});

  factory EmotionSnapshot.fromJson(Map<String, Object?> json) {
    return EmotionSnapshot(
      kind: json['kind']! as String,
      intensity: json['intensity']! as int,
    );
  }

  final String kind;
  final int intensity;

  Map<String, Object?> toJson() => {'kind': kind, 'intensity': intensity};

  @override
  bool operator ==(Object other) =>
      other is EmotionSnapshot &&
      other.kind == kind &&
      other.intensity == intensity;

  @override
  int get hashCode => Object.hash(kind, intensity);
}

final class StateSnapshot {
  StateSnapshot({
    required this.userId,
    required this.relationshipStage,
    required List<ChatTurn> turns,
    required this.lastEmotion,
    this.schemaVersion = contractSchemaVersion,
  }) : turns = List.unmodifiable(turns);

  factory StateSnapshot.initial(String userId) => StateSnapshot(
    userId: userId,
    relationshipStage: '初识',
    turns: const [],
    lastEmotion: const EmotionSnapshot(kind: 'neutral', intensity: 0),
  );

  factory StateSnapshot.fromJson(Map<String, Object?> json) {
    final rawTurns = json['turns']! as List<Object?>;
    return StateSnapshot(
      schemaVersion: json['schemaVersion'] as int? ?? contractSchemaVersion,
      userId: json['userId']! as String,
      relationshipStage: json['relationshipStage']! as String,
      turns: rawTurns
          .map((value) => ChatTurn.fromJson(value! as Map<String, Object?>))
          .toList(),
      lastEmotion: EmotionSnapshot.fromJson(
        json['lastEmotion']! as Map<String, Object?>,
      ),
    );
  }

  final int schemaVersion;
  final String userId;
  final String relationshipStage;
  final List<ChatTurn> turns;
  final EmotionSnapshot lastEmotion;

  StateSnapshot append({
    required ChatTurn userTurn,
    required ChatTurn qiyuTurn,
    EmotionSnapshot? emotion,
  }) {
    return StateSnapshot(
      schemaVersion: schemaVersion,
      userId: userId,
      relationshipStage: relationshipStage,
      turns: [...turns, userTurn, qiyuTurn],
      lastEmotion: emotion ?? lastEmotion,
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'userId': userId,
    'relationshipStage': relationshipStage,
    'turns': turns.map((turn) => turn.toJson()).toList(),
    'lastEmotion': lastEmotion.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is StateSnapshot &&
      other.schemaVersion == schemaVersion &&
      other.userId == userId &&
      other.relationshipStage == relationshipStage &&
      _listsEqual(other.turns, turns) &&
      other.lastEmotion == lastEmotion;

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    userId,
    relationshipStage,
    Object.hashAll(turns),
    lastEmotion,
  );
}

final class ChatResult extends ChatOutcome {
  ChatResult({
    required this.requestId,
    required List<String> messages,
    required this.nextState,
    required this.source,
    required this.mode,
    this.fallbackReason,
    this.safety,
    this.schemaVersion = contractSchemaVersion,
  }) : messages = List.unmodifiable(messages);

  final int schemaVersion;
  final String requestId;
  final List<String> messages;
  final StateSnapshot nextState;
  final ReplySource source;
  final FallbackReason? fallbackReason;
  final String mode;
  final SafetyKind? safety;

  @override
  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'requestId': requestId,
    'messages': messages,
    'nextState': nextState.toJson(),
    'source': source.name,
    'fallbackReason': fallbackReason?.wireName,
    'mode': mode,
    'safety': safety?.name,
  };
}

final class ErrorResult extends ChatOutcome {
  const ErrorResult({
    required this.requestId,
    required this.code,
    required this.message,
    required this.retryable,
    this.schemaVersion = contractSchemaVersion,
  });

  factory ErrorResult.fromJson(Map<String, Object?> json) {
    return ErrorResult(
      schemaVersion: json['schemaVersion'] as int? ?? contractSchemaVersion,
      requestId: json['requestId']! as String,
      code: ChatErrorCode.fromWireName(json['code']! as String),
      message: json['message']! as String,
      retryable: json['retryable']! as bool,
    );
  }

  final int schemaVersion;
  final String requestId;
  final ChatErrorCode code;
  final String message;
  final bool retryable;

  @override
  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'requestId': requestId,
    'code': code.wireName,
    'message': message,
    'retryable': retryable,
  };

  @override
  bool operator ==(Object other) =>
      other is ErrorResult &&
      other.schemaVersion == schemaVersion &&
      other.requestId == requestId &&
      other.code == code &&
      other.message == message &&
      other.retryable == retryable;

  @override
  int get hashCode =>
      Object.hash(schemaVersion, requestId, code, message, retryable);
}

bool _listsEqual<T>(List<T> left, List<T> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}
