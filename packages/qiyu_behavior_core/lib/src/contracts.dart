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

/// 可向界面公开的服务故障类别，不包含服务商响应或诊断文本。
enum ServiceErrorCategory {
  authentication,
  modelNotFound,
  rateLimited,
  client,
  server,
  network;

  static ServiceErrorCategory fromWireName(String value) => values.firstWhere(
    (candidate) => candidate.name == value,
    orElse: () => throw const FormatException('Invalid service error category'),
  );
}

enum FallbackReason {
  safety('safety'),
  noLlmConfig('no_llm_config'),
  emptyModelReply('empty_model_reply'),
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
  modelInternal('model_internal');

  const FallbackReason(this.wireName);

  final String wireName;

  /// 已退役的兜底原因 wire name（ADR 0017 输出侧裁决退场）。删除前命中
  /// 两张判决名单的轮次会把这些名字写进本机 Markdown 会话，而会话本地
  /// 永久保留——读侧必须继续认得，否则整个会话文件会被标记为不可读。
  /// 历史数据兼容专用：映射到现行的就近值，不再产生新值。
  static const _retiredWireNames = <String, FallbackReason>{
    'forbidden_phrases': FallbackReason.invalidModelResponse,
    'persona_boundary': FallbackReason.invalidModelResponse,
    // 迁移基线时代的笼统「LLM 调用异常」：产生点已被 model* 细分类
    // 取代，旧盘会话仍可能携带；就近映射到 Provider 侧通用错误。
    'llm_error': FallbackReason.modelProvider,
  };

  static FallbackReason fromWireName(String value) {
    final retired = _retiredWireNames[value];
    if (retired != null) {
      return retired;
    }
    return values.firstWhere(
      (candidate) => candidate.wireName == value,
      orElse: () => throw FormatException('Unknown fallback reason: $value'),
    );
  }
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

sealed class ChatOutcome {
  const ChatOutcome();

  Map<String, Object?> toJson();
}

final class ChatRequest {
  const ChatRequest({
    required this.requestId,
    required this.text,
    this.schemaVersion = contractSchemaVersion,
    this.locale = 'zh',
  });

  factory ChatRequest.fromJson(Map<String, Object?> json) {
    return ChatRequest(
      schemaVersion: json['schemaVersion'] as int? ?? contractSchemaVersion,
      requestId: json['requestId'] as String,
      text: json['text'] as String,
      locale: json['locale'] as String? ?? 'zh',
    );
  }

  final int schemaVersion;
  final String requestId;
  final String text;
  final String locale;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'requestId': requestId,
    'text': text,
    'locale': locale,
  };

  @override
  bool operator ==(Object other) =>
      other is ChatRequest &&
      other.schemaVersion == schemaVersion &&
      other.requestId == requestId &&
      other.text == text &&
      other.locale == locale;

  @override
  int get hashCode => Object.hash(schemaVersion, requestId, text, locale);
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

final class StateSnapshot {
  StateSnapshot({
    required this.userId,
    required this.relationshipStage,
    required List<ChatTurn> turns,
    this.schemaVersion = contractSchemaVersion,
  }) : turns = List.unmodifiable(turns);

  factory StateSnapshot.initial(String userId) => StateSnapshot(
    userId: userId,
    relationshipStage: RelationshipStage.stranger,
    turns: const [],
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
    );
  }

  final int schemaVersion;
  final String userId;
  final RelationshipStage relationshipStage;
  final List<ChatTurn> turns;

  StateSnapshot append({
    required ChatTurn userTurn,
    required ChatTurn qiyuTurn,
  }) {
    final nextTurns = [...turns, userTurn, qiyuTurn];
    return StateSnapshot(
      schemaVersion: schemaVersion,
      userId: userId,
      relationshipStage: relationshipStage,
      turns: nextTurns.length <= maxStateTurns
          ? nextTurns
          : nextTurns.sublist(nextTurns.length - maxStateTurns),
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'userId': userId,
    'relationshipStage': relationshipStage.wireName,
    'turns': turns.map((turn) => turn.toJson()).toList(),
  };

  @override
  bool operator ==(Object other) =>
      other is StateSnapshot &&
      other.schemaVersion == schemaVersion &&
      other.userId == userId &&
      other.relationshipStage == relationshipStage &&
      _listsEqual(other.turns, turns);

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    userId,
    relationshipStage,
    Object.hashAll(turns),
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
    this.serviceError,
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
      serviceError: json['serviceError'] == null
          ? null
          : ServiceErrorCategory.fromWireName(json['serviceError'] as String),
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
  final ServiceErrorCategory? serviceError;
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
    if (serviceError != null) 'serviceError': serviceError!.name,
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
      other.serviceError == serviceError &&
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
    serviceError,
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
  /// 语音块（票二）：PCM 音频块搭车聊天事件流，与文字增量同连接同序。
  voiceChunk,

  /// 语音失败（票二）：某句合成失败即本段语音结束（D1）。只作信号，
  /// 不阻断文字交付，也不结束事件流。
  voiceError,
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
    bool incomplete = false,
  }) : this._(
         kind: ChatDeliveryEventKind.message,
         requestId: requestId,
         sessionId: sessionId,
         messages: messages,
         incomplete: incomplete,
       );

  const ChatDeliveryEvent.state({
    required String requestId,
    String? sessionId,
    required ReplySource source,
    FallbackReason? fallbackReason,
    ServiceErrorCategory? serviceError,
    String? mode,
    SafetyKind? safety,
  }) : this._(
         kind: ChatDeliveryEventKind.state,
         requestId: requestId,
         sessionId: sessionId,
         source: source,
         fallbackReason: fallbackReason,
         serviceError: serviceError,
         mode: mode,
         safety: safety,
       );

  const ChatDeliveryEvent.fallback({
    required String requestId,
    String? sessionId,
    required FallbackReason fallbackReason,
    ServiceErrorCategory? serviceError,
  }) : this._(
         kind: ChatDeliveryEventKind.fallback,
         requestId: requestId,
         sessionId: sessionId,
         fallbackReason: fallbackReason,
         serviceError: serviceError,
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

  /// 语音块（票二）：[data] 是 base64 编码的 PCM16 单声道字节，
  /// [sampleRate] 是本块的协商采样率（播放端按它初始化，不猜）。
  /// [deliveryIndex] 是该块所属的栖语交付段序号（与朗读定位同口径），
  /// [chunkIndex] 是段内块序号（从 0 起，按序全播）。
  ///
  /// E1 降级（票二）：拿不到音频块的档位按句子级顺序播——[mimeType]
  /// 非空即这是一段已合成完的完整音频（容器由服务定义，不包 WAV 头），
  /// 播放端走既有整段播放器；此时不带 [sampleRate]。两者恰居其一。
  const ChatDeliveryEvent.voiceChunk({
    required String requestId,
    String? sessionId,
    required int deliveryIndex,
    required int chunkIndex,
    int? sampleRate,
    String? mimeType,
    required String data,
  }) : this._(
         kind: ChatDeliveryEventKind.voiceChunk,
         requestId: requestId,
         sessionId: sessionId,
         deliveryIndex: deliveryIndex,
         chunkIndex: chunkIndex,
         sampleRate: sampleRate,
         audioMimeType: mimeType,
         audioData: data,
       );

  /// 语音失败（票二）：[deliveryIndex] 是失败的交付段。已播句子照常
  /// standing，同会话首次失败由界面提示一次（之后静默）。
  const ChatDeliveryEvent.voiceError({
    required String requestId,
    String? sessionId,
    required int deliveryIndex,
  }) : this._(
         kind: ChatDeliveryEventKind.voiceError,
         requestId: requestId,
         sessionId: sessionId,
         deliveryIndex: deliveryIndex,
       );

  const ChatDeliveryEvent._({
    required this.kind,
    required this.requestId,
    this.sessionId,
    this.text,
    this.messages,
    this.source,
    this.fallbackReason,
    this.serviceError,
    this.mode,
    this.safety,
    this.code,
    this.retryable,
    this.incomplete,
    this.deliveryIndex,
    this.chunkIndex,
    this.sampleRate,
    this.audioMimeType,
    this.audioData,
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
      ChatDeliveryEventKind.voiceChunk => const [
        'deliveryIndex',
        'chunkIndex',
        'data',
      ],
      ChatDeliveryEventKind.voiceError => const ['deliveryIndex'],
      _ => <String>[],
    };
    for (final field in requiredFields) {
      if (json[field] == null) throw invalid;
    }
    if (kind == ChatDeliveryEventKind.voiceChunk) {
      // PCM 块与完整容器块（E1）恰居其一：块带 mimeType 即容器块（不
      // 带采样率）；否则必须带协商采样率（播放端按它初始化，不猜）。
      final hasMime = json['mimeType'] != null;
      final hasRate = json['sampleRate'] != null;
      if (hasMime == hasRate) throw invalid;
    }
    final source = optionalField<String>('source');
    final fallbackReason = optionalField<String>('fallbackReason');
    final serviceError = optionalField<String>('serviceError');
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
      serviceError: serviceError == null
          ? null
          : ServiceErrorCategory.fromWireName(serviceError),
      safety: safety == null
          ? null
          : enumValue<SafetyKind>(
              safety,
              SafetyKind.values,
              (value) => value.name,
            ),
      code: optionalField<String>('code'),
      retryable: optionalField<bool>('retryable'),
      incomplete: optionalField<bool>('incomplete'),
      deliveryIndex: optionalField<int>('deliveryIndex'),
      chunkIndex: optionalField<int>('chunkIndex'),
      sampleRate: optionalField<int>('sampleRate'),
      audioMimeType: optionalField<String>('mimeType'),
      audioData: optionalField<String>('data'),
    );
  }

  final ChatDeliveryEventKind kind;
  final String requestId;
  final String? sessionId;
  final String? text;
  final List<String>? messages;
  final ReplySource? source;
  final FallbackReason? fallbackReason;
  final ServiceErrorCategory? serviceError;
  final String? mode;
  final SafetyKind? safety;
  final String? code;
  final bool? retryable;

  /// 协议失败时留下的半句标记（票一）：true 表示这条 message 是该轮
  /// 的最终回复，但模型没有正常说完——内容如实，不补全不伪装。缺席
  /// 即完整回复。
  final bool? incomplete;

  /// 语音块/语音失败事件所属的栖语交付段序号（票二，与朗读定位同口径）。
  final int? deliveryIndex;

  /// 语音块在交付段内的序号（票二）：从 0 起严格递增，按序全播。
  final int? chunkIndex;

  /// 语音块的协商采样率（票二，Hz）：播放端按它初始化，块边界任意
  /// （PCM 无帧对齐问题，16-bit 样本完整且有序连续即可）。完整容器块
  /// （E1）不带它。
  final int? sampleRate;

  /// 完整容器块的 MIME（票二 E1）：非空即这是一段已合成完的完整音频
  /// （容器由服务定义），播放端走既有整段播放器。为空即 PCM 流式块。
  final String? audioMimeType;

  /// 语音块的 base64 音频字节（票二）：wire 键名 `data`，与文字增量
  /// 的 `text` 分开，读侧不混淆两种载荷。
  final String? audioData;

  Map<String, Object?> toJson() => {
    'event': kind.name,
    'requestId': requestId,
    if (sessionId != null) 'sessionId': sessionId,
    if (text != null) 'text': text,
    if (messages != null) 'messages': messages,
    if (source != null) 'source': source!.name,
    if (fallbackReason != null) 'fallbackReason': fallbackReason!.wireName,
    if (serviceError != null) 'serviceError': serviceError!.name,
    if (mode != null) 'mode': mode,
    if (safety != null) 'safety': safety!.name,
    if (code != null) 'code': code,
    if (retryable != null) 'retryable': retryable,
    if (incomplete == true) 'incomplete': true,
    if (deliveryIndex != null) 'deliveryIndex': deliveryIndex,
    if (chunkIndex != null) 'chunkIndex': chunkIndex,
    if (sampleRate != null) 'sampleRate': sampleRate,
    if (audioMimeType != null) 'mimeType': audioMimeType,
    if (audioData != null) 'data': audioData,
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
