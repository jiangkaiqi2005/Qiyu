const contractSchemaVersion = 1;
const maxStateTurns = 80;

enum ChatErrorCode {
  invalidRequest('invalid_request');

  const ChatErrorCode(this.wireName);

  final String wireName;

  static ChatErrorCode fromWireName(String value) => values.firstWhere(
    (candidate) => candidate.wireName == value,
    orElse: () => throw FormatException('Unknown chat error code: $value'),
  );
}

enum ReplySource { local, llm }

enum FallbackReason {
  safety('safety'),
  noLlmConfig('no_llm_config'),
  forbiddenPhrases('forbidden_phrases'),
  emptyModelReply('empty_model_reply'),
  personaBoundary('persona_boundary'),
  invalidModelResponse('invalid_model_response'),
  modelDns('model_dns'),
  modelTls('model_tls'),
  modelTimeout('model_timeout'),
  modelAuthentication('model_authentication'),
  modelNetwork('model_network'),
  modelNotFound('model_not_found'),
  modelRateLimited('model_rate_limited'),
  incompatibleModelResponse('incompatible_model_response'),
  modelContentParsing('model_content_parsing'),
  modelProvider('model_provider'),
  modelInternal('model_internal'),
  llmError('llm_error');

  const FallbackReason(this.wireName);

  final String wireName;

  static FallbackReason fromWireName(String value) => values.firstWhere(
    (candidate) => candidate.wireName == value,
    orElse: () => throw FormatException('Unknown fallback reason: $value'),
  );
}

enum SafetyKind { normal, crisis, medical, legal, financial }

enum Speaker { user, qiyu }

enum RelationshipStage {
  stranger('初识'),
  familiar('熟悉'),
  friend('朋友'),
  deep('深交');

  const RelationshipStage(this.wireName);

  final String wireName;

  static RelationshipStage fromWireName(String value) => values.firstWhere(
    (candidate) => candidate.wireName == value,
    orElse: () => throw FormatException('Unknown relationship stage: $value'),
  );
}

enum EmotionKind { neutral, quiet, light, soft, heavy }

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
      kind: EmotionKind.values.byName(json['kind']! as String),
      intensity: json['intensity']! as int,
    );
  }

  final EmotionKind kind;
  final int intensity;

  Map<String, Object?> toJson() => {'kind': kind.name, 'intensity': intensity};

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
    relationshipStage: RelationshipStage.stranger,
    turns: const [],
    lastEmotion: const EmotionSnapshot(kind: EmotionKind.neutral, intensity: 0),
  );

  factory StateSnapshot.fromJson(Map<String, Object?> json) {
    final rawTurns = json['turns']! as List<Object?>;
    return StateSnapshot(
      schemaVersion: json['schemaVersion'] as int? ?? contractSchemaVersion,
      userId: json['userId']! as String,
      relationshipStage: RelationshipStage.fromWireName(
        json['relationshipStage']! as String,
      ),
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
  final RelationshipStage relationshipStage;
  final List<ChatTurn> turns;
  final EmotionSnapshot lastEmotion;

  StateSnapshot append({
    required ChatTurn userTurn,
    required ChatTurn qiyuTurn,
    EmotionSnapshot? emotion,
  }) {
    final nextTurns = [...turns, userTurn, qiyuTurn];
    return StateSnapshot(
      schemaVersion: schemaVersion,
      userId: userId,
      relationshipStage: relationshipStage,
      turns: nextTurns.length <= maxStateTurns
          ? nextTurns
          : nextTurns.sublist(nextTurns.length - maxStateTurns),
      lastEmotion: emotion ?? lastEmotion,
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'userId': userId,
    'relationshipStage': relationshipStage.wireName,
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

  factory ChatResult.fromJson(Map<String, Object?> json) {
    final rawMessages = json['messages']! as List<Object?>;
    final debug = json['debug']! as Map<String, Object?>;
    final rawFallbackReason = json['fallbackReason'] as String?;
    final rawSafety = debug['safety'] as String?;
    return ChatResult(
      schemaVersion: json['schemaVersion'] as int? ?? contractSchemaVersion,
      requestId: json['requestId'] as String?,
      messages: rawMessages.cast<String>(),
      nextState: StateSnapshot.fromJson(
        json['nextState']! as Map<String, Object?>,
      ),
      source: ReplySource.values.byName(json['source']! as String),
      fallbackReason: rawFallbackReason == null
          ? null
          : FallbackReason.fromWireName(rawFallbackReason),
      mode: debug['mode']! as String,
      safety: rawSafety == null ? null : SafetyKind.values.byName(rawSafety),
    );
  }

  final int schemaVersion;
  final String? requestId;
  final List<String> messages;
  final StateSnapshot nextState;
  final ReplySource source;
  final FallbackReason? fallbackReason;
  final String mode;
  final SafetyKind? safety;

  @override
  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    if (requestId != null) 'requestId': requestId,
    'messages': messages,
    'nextState': nextState.toJson(),
    'source': source.name,
    if (fallbackReason != null) 'fallbackReason': fallbackReason!.wireName,
    'debug': {
      'mode': mode,
      if (safety != null) 'safety': safety!.name,
      // 迁移兼容的线格式：仅当无安全分类时才携带 relationshipStage，勿改。
      if (safety == null)
        'relationshipStage': nextState.relationshipStage.wireName,
    },
  };

  @override
  bool operator ==(Object other) =>
      other is ChatResult &&
      other.schemaVersion == schemaVersion &&
      other.requestId == requestId &&
      _listsEqual(other.messages, messages) &&
      other.nextState == nextState &&
      other.source == source &&
      other.fallbackReason == fallbackReason &&
      other.mode == mode &&
      other.safety == safety;

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    requestId,
    Object.hashAll(messages),
    nextState,
    source,
    fallbackReason,
    mode,
    safety,
  );
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

enum ChatDeliveryEventKind {
  accepted,
  waiting,
  delta,
  message,
  state,
  fallback,
  cancelled,
  error,
  done,
}

class ChatDeliveryEvent {
  const ChatDeliveryEvent({
    required this.kind,
    required this.requestId,
    this.sessionId,
    this.text,
    this.messages,
    this.source,
    this.fallbackReason,
    this.mode,
    this.safety,
    this.code,
    this.retryable,
  });

  factory ChatDeliveryEvent.fromJson(Map<String, Object?> json) {
    final source = json['source'] as String?;
    final fallbackReason = json['fallbackReason'] as String?;
    final safety = json['safety'] as String?;
    return ChatDeliveryEvent(
      kind: ChatDeliveryEventKind.values.byName(json['event']! as String),
      requestId: json['requestId']! as String,
      sessionId: json['sessionId'] as String?,
      text: json['text'] as String?,
      messages: (json['messages'] as List<Object?>?)?.cast<String>(),
      source: source == null ? null : ReplySource.values.byName(source),
      fallbackReason: fallbackReason == null
          ? null
          : FallbackReason.fromWireName(fallbackReason),
      mode: json['mode'] as String?,
      safety: safety == null ? null : SafetyKind.values.byName(safety),
      code: json['code'] as String?,
      retryable: json['retryable'] as bool?,
    );
  }

  final ChatDeliveryEventKind kind;
  final String requestId;
  final String? sessionId;
  final String? text;
  final List<String>? messages;
  final ReplySource? source;
  final FallbackReason? fallbackReason;
  final String? mode;
  final SafetyKind? safety;
  final String? code;
  final bool? retryable;

  Map<String, Object?> toJson() => {
    'event': kind.name,
    'requestId': requestId,
    if (sessionId != null) 'sessionId': sessionId,
    if (text != null) 'text': text,
    if (messages != null) 'messages': messages,
    if (source != null) 'source': source!.name,
    if (fallbackReason != null) 'fallbackReason': fallbackReason!.wireName,
    if (mode != null) 'mode': mode,
    if (safety != null) 'safety': safety!.name,
    if (code != null) 'code': code,
    if (retryable != null) 'retryable': retryable,
  };
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
