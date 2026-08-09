import 'contracts.dart';

const _forbiddenPhrases = [
  '我理解你的感受',
  '谢谢你愿意和我分享',
  '那一定很不容易',
  '你的感受完全合理',
  '如果你需要帮助随时告诉我',
  '你做得已经很好了',
  '我能感受到你的痛苦',
  '每个人都有不好的时候',
  '我在这里陪你',
  '无论怎样我都支持你',
  '让我们来聊聊这件事',
];

final class QiyuBehaviorCore {
  const QiyuBehaviorCore();

  ChatOutcome reply(
    ChatRequest request,
    StateSnapshot state, {
    String? candidateReply,
  }) {
    final text = request.text.trim();
    if (text.isEmpty) {
      return ErrorResult(
        requestId: request.requestId,
        code: ChatErrorCode.invalidRequest,
        message: '消息不能为空',
        retryable: false,
      );
    }

    final safety = _classifySafety(text);
    if (safety != SafetyKind.normal) {
      final messages = _safetyMessages(safety);
      return _result(
        request: request,
        state: state,
        text: text,
        messages: messages,
        source: ReplySource.local,
        fallbackReason: FallbackReason.safety,
        mode: 'safety',
        safety: safety,
        replyAsSingleTurn: true,
      );
    }

    if (candidateReply != null) {
      final candidateMessages = _normalizeMessages(candidateReply);
      if (candidateMessages.isNotEmpty &&
          !_containsForbiddenPhrase(candidateMessages.join('\n'))) {
        return _result(
          request: request,
          state: state,
          text: text,
          messages: candidateMessages,
          source: ReplySource.model,
          mode: 'llm',
          replyAsSingleTurn: true,
        );
      }

      return _localResult(
        request: request,
        state: state,
        text: text,
        fallbackReason: candidateMessages.isEmpty
            ? FallbackReason.llmError
            : FallbackReason.forbiddenPhrases,
      );
    }

    return _localResult(
      request: request,
      state: state,
      text: text,
      fallbackReason: FallbackReason.noLlmConfig,
    );
  }

  ChatResult _localResult({
    required ChatRequest request,
    required StateSnapshot state,
    required String text,
    required FallbackReason fallbackReason,
  }) {
    final localReply = _localReply(text);
    return _result(
      request: request,
      state: state,
      text: text,
      messages: localReply.messages,
      source: ReplySource.local,
      fallbackReason: fallbackReason,
      mode: localReply.mode,
    );
  }

  ChatResult _result({
    required ChatRequest request,
    required StateSnapshot state,
    required String text,
    required List<String> messages,
    required ReplySource source,
    required String mode,
    FallbackReason? fallbackReason,
    SafetyKind? safety,
    bool replyAsSingleTurn = false,
  }) {
    final replyText = replyAsSingleTurn ? messages.join('\n') : messages.single;
    final emotion = safety == SafetyKind.crisis
        ? const EmotionSnapshot(kind: 'heavy', intensity: 3)
        : state.lastEmotion;
    final nextState = state.append(
      userTurn: ChatTurn(speaker: Speaker.user, text: text),
      qiyuTurn: ChatTurn(speaker: Speaker.qiyu, text: replyText),
      emotion: emotion,
    );

    return ChatResult(
      requestId: request.requestId,
      messages: messages,
      nextState: nextState,
      source: source,
      fallbackReason: fallbackReason,
      mode: mode,
      safety: safety,
    );
  }
}

({List<String> messages, String mode}) _localReply(String text) {
  if (RegExp(r'晚安|睡了|先睡').hasMatch(text)) {
    return (messages: const ['晚安'], mode: 'bedtime');
  }
  if (text == '我到家了') {
    return (messages: const ['嗯'], mode: 'minimal');
  }
  if (RegExp(r'累|疲惫|困').hasMatch(text)) {
    return (messages: const ['咋了'], mode: 'fatigue');
  }
  return (messages: const ['嗯？'], mode: 'open');
}

SafetyKind _classifySafety(String text) {
  if (RegExp(
    r'活着没意思|不想活|自杀|伤害自己|想死|自残|割腕|轻生|活不下去|不想醒来|结束生命|撑不下去|离开世界|吃药.*走|吞药|跳楼|烧炭|上吊',
  ).hasMatch(text)) {
    return SafetyKind.crisis;
  }

  final asksAdvice = RegExp(
    r'能不能|要不要|应不应该|可以吗|行不行|该不该|推荐|建议|行吗|能.{0,4}吗|该.{0,4}吗|会不会有问题',
  ).hasMatch(text);
  if (!asksAdvice) {
    return SafetyKind.normal;
  }

  final withoutMedicalExclusions = text.replaceAll('药膳', '');
  if (RegExp(r'药|剂量|诊断|手术|症状|医院|医生').hasMatch(withoutMedicalExclusions)) {
    return SafetyKind.medical;
  }
  if (RegExp(r'合同|起诉|律师|违法|法律|赔偿|签字').hasMatch(text)) {
    return SafetyKind.legal;
  }
  final withoutFinancialExclusions = text
      .replaceAll('硬币', '')
      .replaceAll('纸币', '')
      .replaceAll('金币', '');
  if (RegExp(r'股票|基金|币|投资|买入|卖出|贷款').hasMatch(withoutFinancialExclusions)) {
    return SafetyKind.financial;
  }
  return SafetyKind.normal;
}

List<String> _safetyMessages(SafetyKind safety) {
  return switch (safety) {
    SafetyKind.crisis => const [
      '我听到你了。你现在承受的好多。',
      '这句不是随便说说的那种难过，我会认真对待。',
      '现在先别一个人扛。全国 24 小时心理援助热线 12356，随时都有人在。也可以马上找身边一个真人，别让自己单独待着。',
    ],
    SafetyKind.medical => const ['这个别听我瞎猜。药量这种事要问专业的人，别拿身体赌。'],
    SafetyKind.legal => const ['合同和签字这类事，最好让专业的人看一眼。我能陪你把担心的点列出来，但不能替你下法律判断。'],
    SafetyKind.financial => const ['这个我不能替你做买卖决定。钱的事要按你的风险承受来，我可以陪你把理由和风险拆开看。'],
    SafetyKind.normal => const [],
  };
}

List<String> _normalizeMessages(String text) {
  return text
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
}

bool _containsForbiddenPhrase(String text) {
  return _forbiddenPhrases.any(text.contains);
}
