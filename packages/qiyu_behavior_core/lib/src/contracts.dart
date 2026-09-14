const contractSchemaVersion = 1;
const maxStateTurns = 80;
const webSearchSystemInstruction =
    '涉及当前时间、天气、新闻或可能变化的事实时，按需调用 `web_search`。'
    '不得将用户的私密对话、密钥或身份信息写入搜索词。';

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
      requestId: json['requestId'] as String,
      text: json['text'] as String,
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
  const ChatTurn({required this.speaker, required this.text, this.at});

  factory ChatTurn.fromJson(Map<String, Object?> json) {
    final rawAt = json['at'] as String?;
    return ChatTurn(
      speaker: Speaker.values.byName(json['speaker'] as String),
      text: json['text'] as String,
      at: rawAt == null ? null : DateTime.parse(rawAt).toUtc(),
    );
  }

  final Speaker speaker;
  final String text;

  /// 消息时刻：本机 Host 落盘时的客观时刻。wire 为 UTC ISO8601
  /// 字符串；可空，缺席即无时刻（与既有契约 JSON 形状兼容）。
  final DateTime? at;

  Map<String, Object?> toJson() => {
    'speaker': speaker.name,
    'text': text,
    if (at != null) 'at': at!.toUtc().toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is ChatTurn &&
      other.speaker == speaker &&
      other.text == text &&
      other.at == at;

  @override
  int get hashCode => Object.hash(speaker, text, at);
}

final class EmotionSnapshot {
  const EmotionSnapshot({required this.kind, required this.intensity});

  factory EmotionSnapshot.fromJson(Map<String, Object?> json) {
    return EmotionSnapshot(
      kind: EmotionKind.values.byName(json['kind'] as String),
      intensity: json['intensity'] as int,
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
    final rawTurns = json['turns'] as List<Object?>;
    return StateSnapshot(
      schemaVersion: json['schemaVersion'] as int? ?? contractSchemaVersion,
      userId: json['userId'] as String,
      relationshipStage: RelationshipStage.fromWireName(
        json['relationshipStage'] as String,
      ),
      turns: rawTurns
          .map((value) => ChatTurn.fromJson(value as Map<String, Object?>))
          .toList(),
      lastEmotion: EmotionSnapshot.fromJson(
        json['lastEmotion'] as Map<String, Object?>,
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
    final rawMessages = json['messages'] as List<Object?>;
    final debug = json['debug'] as Map<String, Object?>;
    final rawFallbackReason = json['fallbackReason'] as String?;
    final rawSafety = debug['safety'] as String?;
    return ChatResult(
      schemaVersion: json['schemaVersion'] as int? ?? contractSchemaVersion,
      requestId: json['requestId'] as String?,
      messages: rawMessages.cast<String>(),
      nextState: StateSnapshot.fromJson(
        json['nextState'] as Map<String, Object?>,
      ),
      source: ReplySource.values.byName(json['source'] as String),
      fallbackReason: rawFallbackReason == null
          ? null
          : FallbackReason.fromWireName(rawFallbackReason),
      mode: debug['mode'] as String,
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
      requestId: json['requestId'] as String,
      code: ChatErrorCode.fromWireName(json['code'] as String),
      message: json['message'] as String,
      retryable: json['retryable'] as bool,
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

/// 每类事件的必填载荷由命名构造约束；可选属性仅用于跨事件读取。
final class ChatDeliveryEvent {
  const ChatDeliveryEvent.accepted({
    required String requestId,
    String? sessionId,
  }) : this._(
         kind: ChatDeliveryEventKind.accepted,
         requestId: requestId,
         sessionId: sessionId,
       );

  const ChatDeliveryEvent.waiting({
    required String requestId,
    String? sessionId,
  }) : this._(
         kind: ChatDeliveryEventKind.waiting,
         requestId: requestId,
         sessionId: sessionId,
       );

  const ChatDeliveryEvent.delta({
    required String requestId,
    String? sessionId,
    required String text,
  }) : this._(
         kind: ChatDeliveryEventKind.delta,
         requestId: requestId,
         sessionId: sessionId,
         text: text,
       );

  const ChatDeliveryEvent.message({
    required String requestId,
    String? sessionId,
    required List<String> messages,
  }) : this._(
         kind: ChatDeliveryEventKind.message,
         requestId: requestId,
         sessionId: sessionId,
         messages: messages,
       );

  const ChatDeliveryEvent.state({
    required String requestId,
    String? sessionId,
    required ReplySource source,
    FallbackReason? fallbackReason,
    String? mode,
    SafetyKind? safety,
  }) : this._(
         kind: ChatDeliveryEventKind.state,
         requestId: requestId,
         sessionId: sessionId,
         source: source,
         fallbackReason: fallbackReason,
         mode: mode,
         safety: safety,
       );

  const ChatDeliveryEvent.fallback({
    required String requestId,
    String? sessionId,
    required FallbackReason fallbackReason,
    String? code,
    String? text,
  }) : this._(
         kind: ChatDeliveryEventKind.fallback,
         requestId: requestId,
         sessionId: sessionId,
         fallbackReason: fallbackReason,
         code: code,
         text: text,
       );

  const ChatDeliveryEvent.cancelled({
    required String requestId,
    String? sessionId,
  }) : this._(
         kind: ChatDeliveryEventKind.cancelled,
         requestId: requestId,
         sessionId: sessionId,
       );

  const ChatDeliveryEvent.error({
    required String requestId,
    String? sessionId,
    required String text,
    required String code,
    required bool retryable,
    FallbackReason? fallbackReason,
  }) : this._(
         kind: ChatDeliveryEventKind.error,
         requestId: requestId,
         sessionId: sessionId,
         text: text,
         code: code,
         retryable: retryable,
         fallbackReason: fallbackReason,
       );

  const ChatDeliveryEvent.done({required String requestId, String? sessionId})
    : this._(
        kind: ChatDeliveryEventKind.done,
        requestId: requestId,
        sessionId: sessionId,
      );

  const ChatDeliveryEvent._({
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
    const invalid = FormatException('Invalid chat delivery event');
    T requiredField<T>(String field) {
      final value = json[field];
      if (value is! T) throw invalid;
      return value;
    }

    T? optionalField<T extends Object>(String field) {
      final value = json[field];
      if (value == null) return null;
      if (value is! T) throw invalid;
      return value;
    }

    T enumValue<T>(String name, Iterable<T> values, String Function(T) wire) =>
        values.firstWhere(
          (value) => wire(value) == name,
          orElse: () => throw invalid,
        );

    final kind = enumValue(
      requiredField<String>('event'),
      ChatDeliveryEventKind.values,
      (value) => value.name,
    );
    final requiredFields = switch (kind) {
      ChatDeliveryEventKind.delta => ['text'],
      ChatDeliveryEventKind.message => ['messages'],
      ChatDeliveryEventKind.state => ['source'],
      ChatDeliveryEventKind.fallback => ['fallbackReason'],
      ChatDeliveryEventKind.error => ['text', 'code', 'retryable'],
      _ => <String>[],
    };
    for (final field in requiredFields) {
      if (json[field] == null) throw invalid;
    }
    final source = optionalField<String>('source');
    final fallbackReason = optionalField<String>('fallbackReason');
    final safety = optionalField<String>('safety');
    final messages = optionalField<List<Object?>>('messages');
    if (messages != null && messages.any((value) => value is! String)) {
      throw invalid;
    }
    return ChatDeliveryEvent._(
      kind: kind,
      requestId: requiredField<String>('requestId'),
      sessionId: optionalField<String>('sessionId'),
      text: optionalField<String>('text'),
      messages: messages == null ? null : List<String>.unmodifiable(messages),
      source: source == null
          ? null
          : enumValue<ReplySource>(
              source,
              ReplySource.values,
              (value) => value.name,
            ),
      fallbackReason: fallbackReason == null
          ? null
          : enumValue<FallbackReason>(
              fallbackReason,
              FallbackReason.values,
              (value) => value.wireName,
            ),
      mode: optionalField<String>('mode'),
      safety: safety == null
          ? null
          : enumValue<SafetyKind>(
              safety,
              SafetyKind.values,
              (value) => value.name,
            ),
      code: optionalField<String>('code'),
      retryable: optionalField<bool>('retryable'),
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
