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
        '<recent_state>\n${recentState.toString().trim()}\n</recent_state>\n'
        '<memory_actions>\n'
        '每次回复后，先判断本轮是否出现值得长期记住的内容：稳定偏好、'
        '过敏与忌口、重要事件、待跟进事项、明确纠正。若有，在回复最后'
        '另起一行追加隐藏块，格式固定为：\n'
        '<qiyu-actions>\n'
        '[{"action":"memory_signal","summary":"不超过60字的事实概括",'
        '"evidence":"用户原话摘录，不超过80字"}]\n'
        '</qiyu-actions>\n'
        '示例：用户说「我对芒果过敏」时，回复后追加\n'
        '<qiyu-actions>\n'
        '[{"action":"memory_signal","summary":"用户对芒果过敏",'
        '"evidence":"我对芒果过敏"}]\n'
        '</qiyu-actions>\n'
        '规则：数组最多两个对象；本阶段 action 只允许 memory_signal，'
        '没有值得记住的内容时不加隐藏块；summary 与 evidence 绝不包含'
        '密码、API Key、令牌、验证码、私钥、证件号或银行卡号；'
        '隐藏块不属于可见回复，用户永远看不到，但必须原样输出完整标签。\n'
        '</memory_actions>',
      ),
      ...recentTurns.map(
        (turn) => ModelMessage(
          turn.speaker == Speaker.user
              ? ModelMessageRole.user
              : ModelMessageRole.assistant,
          turn.text,
        ),
      ),
      // 靠近生成位置的格式提醒，显著提升隐藏块协议遵从率。
      ModelMessage(
        ModelMessageRole.system,
        '回复格式提醒：输出可见回复后，若本轮出现值得长期记住的内容'
        '（偏好、过敏忌口、重要事件、待跟进、纠正），必须在最后另起一行'
        '追加 <qiyu-actions>[{"action":"memory_signal","summary":"…",'
        '"evidence":"…"}]</qiyu-actions>；普通闲聊不追加。',
      ),
      ModelMessage(ModelMessageRole.user, currentText),
    ];
  }
}
