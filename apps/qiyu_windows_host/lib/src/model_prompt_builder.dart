import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'model_gateway.dart';

final class ModelPromptBuilder {
  const ModelPromptBuilder(this.productSoul);

  final String productSoul;

  List<ModelMessage> build(StateSnapshot state, String currentText) {
    final recentTurns = state.turns.length <= 8
        ? state.turns
        : state.turns.sublist(state.turns.length - 8);
    final recentState = StringBuffer()
      ..writeln('关系阶段：${state.relationshipStage.name}')
      ..writeln('最近情绪：${state.lastEmotion.kind.name}');
    if (recentTurns.isNotEmpty) {
      recentState.writeln('最近对话会作为独立消息按顺序提供。');
    }
    return [
      ModelMessage(
        ModelMessageRole.system,
        '<product_soul>\n${productSoul.trim()}\n</product_soul>\n'
        '<hard_rules>\n'
        '少说；禁止客服式共情；晚安只收束；安全边界优先。\n'
        '</hard_rules>\n'
        '<recent_state>\n${recentState.toString().trim()}\n</recent_state>',
      ),
      ...recentTurns.map(
        (turn) => ModelMessage(
          turn.speaker == Speaker.user
              ? ModelMessageRole.user
              : ModelMessageRole.assistant,
          turn.text,
        ),
      ),
      ModelMessage(ModelMessageRole.user, currentText),
    ];
  }
}
