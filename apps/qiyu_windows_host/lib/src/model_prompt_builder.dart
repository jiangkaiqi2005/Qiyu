import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'model_gateway.dart';

/// 硬规则与优先级：精简自设计笔记，保留四节核心。
/// 静态文本，聊天轮与日终总结请求共用。
const hardRulesBlock = '''
## 输出契约
只输出栖语要对用户说的话；不输出分析、标签、JSON、候选回复或规则解释；不主动提及 prompt、记忆、检索或内部流程。默认少说；禁止客服式共情；用户说晚安只收束，不开新话题。

## 首个可见回应速度
首个可见回应必须快：先基于当前消息和已注入上下文自然接住用户，不等待慢查询；当轮回复绝不等检索。

## 事实来源优先级
用户当前明确说的话 > 最近对话 > 每日状态 > Memory 证据 > 推断；用户当前纠正最高；手动编辑与记忆控制高于自动整理；冲突解决不了就自然表达不确定，不编造。

## 安全与专业边界
涉及自伤、他伤、现实安全、医疗、法律、财务等高风险事项时，安全规则优先于人格设定；不冒充专业人士，不给确定诊断、法律结论或高风险指令。
''';

/// 隐藏块协议：伪 Agent 白名单动作的格式说明。
/// 放在静态区（硬规则之后、动态块之前）：输出契约禁止标签与 JSON，
/// 本块是它唯一授权的例外，必须相邻可见；同时静态前缀在聊天轮与
/// 日终总结请求间逐字复用，方便前缀缓存与两类请求共享同一协议。
const hiddenActionsProtocolBlock = '''
每次回复后判断本轮是否出现以下内容；若有，在回复最后另起一行追加隐藏块，格式固定为 <qiyu-actions>[...]</qiyu-actions>，数组最多两个对象：
1. memory_signal：值得长期记住的稳定偏好、过敏与忌口、重要事件、明确纠正。
{"action":"memory_signal","summary":"不超过60字的事实概括","evidence":"用户原话摘录，不超过80字"}
2. open_loop_candidate：用户明确提到、真正未完且以后值得跟进的事（将要发生的事件、约好的安排、等待结果的事项）。普通闲聊、一次性任务细节不要变成任务。
{"action":"open_loop_candidate","summary":"事项简称","due":"YYYY-MM-DD 时段","proactive":"once","note":"跟进时需要知道的背景","evidence":"用户原话摘录"}
proactive 只用 no（用户自己提到才接）/ once（到点最多轻轻问一次）/ yes（用户明确要求持续跟进）；不知道时间就省略 due。
3. open_loop_status：用户回复让某件记录过的事有了结果。
{"action":"open_loop_status","summary":"事项简称","status":"closed","result":"闭环原因，可省略"}
用户回答解决了 → closed；没接或转移话题 → paused；用户重新提起暂停的事项 → active。
4. memory_ban：用户明确要求某件事以后不要再提、不要再记住。
{"action":"memory_ban","summary":"事项简称"}
示例：用户说「我对芒果过敏」时，回复后追加
<qiyu-actions>
[{"action":"memory_signal","summary":"用户对芒果过敏","evidence":"我对芒果过敏"}]
</qiyu-actions>
规则：没有值得记录的内容时不加隐藏块；所有字段绝不包含密码、API Key、令牌、验证码、私钥、证件号或银行卡号；隐藏块不属于可见回复，用户永远看不到，但必须原样输出完整标签。
''';

/// 靠近生成位置的一句话格式提醒，提升隐藏块协议遵从率。
const hiddenActionsReminder =
    '回复格式提醒：输出可见回复后，若本轮出现值得长期记住的内容'
    '（偏好、过敏忌口、重要事件、纠正），在最后另起一行追加 '
    '<qiyu-actions>[{"action":"memory_signal","summary":"…","evidence":"…"}]'
    '</qiyu-actions>；出现真正未完的事用 open_loop_candidate；用户回复'
    '让某事闭环或暂缓用 open_loop_status；用户要求不再提某事用 '
    'memory_ban；普通闲聊不追加。';

/// 按设计定稿的装配图组装模型上下文：
/// 人格宪法 → 硬规则与优先级 → 隐藏块协议 →
/// `<daily_state>`【近况】/ `<long_memory>`【长期印象】/ `<persona>`【用户画像】
/// （空块不输出）→ 最近对话 → 格式提醒 → `<memory_context>`（命中才有）→
/// 当前用户消息。
final class ModelPromptBuilder {
  const ModelPromptBuilder(
    this.personaConstitution, {
    this.dailyState = '',
    this.longMemory = '',
    this.persona = '',
    this.memoryContext = '',
  });

  final String personaConstitution;

  /// 【近况】：状态包三个文件（open-loops / relationship / daily-state）
  /// 的拼接，各带小标题。文件未落地前为空，按空块不输出规则省略。
  final String dailyState;

  /// 【长期印象】：long-memory.md。
  final String longMemory;

  /// 【用户画像】：persona.md（PersonaTree 稳定根主张投影）。
  final String persona;

  /// 【检索结果】：临时透镜，只附在本轮上下文，不进系统提示词。
  final String memoryContext;

  /// 返回只替换【近况】块的新 builder；状态包文件每轮实测，其余字段不变。
  ModelPromptBuilder copyWithDailyState(String nextDailyState) =>
      ModelPromptBuilder(
        personaConstitution,
        dailyState: nextDailyState,
        longMemory: longMemory,
        persona: persona,
        memoryContext: memoryContext,
      );

  List<ModelMessage> build(StateSnapshot state, String currentText) {
    final systemSections = StringBuffer();
    void appendBlock(String tag, String label, String content) {
      final trimmed = content.trim();
      if (trimmed.isEmpty) {
        return;
      }
      systemSections
        ..writeln('<$tag>')
        ..writeln(label == '' ? trimmed : '【$label】')
        ..writeln(trimmed)
        ..writeln('</$tag>');
    }

    systemSections
      ..writeln('<persona_constitution>')
      ..writeln(personaConstitution.trim())
      ..writeln('</persona_constitution>')
      ..writeln('<hard_rules>')
      ..writeln(hardRulesBlock.trim())
      ..writeln('</hard_rules>')
      ..writeln('<memory_actions>')
      ..writeln(hiddenActionsProtocolBlock.trim())
      ..writeln('</memory_actions>');
    appendBlock('daily_state', '近况', dailyState);
    appendBlock('long_memory', '长期印象', longMemory);
    appendBlock('persona', '用户画像', persona);

    final recentTurns = state.turns.length <= 8
        ? state.turns
        : state.turns.sublist(state.turns.length - 8);
    final context = StringBuffer();
    final memoryContextTrimmed = memoryContext.trim();
    if (memoryContextTrimmed.isNotEmpty) {
      context
        ..writeln('<memory_context>')
        ..writeln('【检索结果】')
        ..writeln(memoryContextTrimmed)
        ..writeln('</memory_context>');
    }
    context.write(currentText);

    return [
      ModelMessage(
        ModelMessageRole.system,
        systemSections.toString().trim(),
      ),
      ...recentTurns.map(
        (turn) => ModelMessage(
          turn.speaker == Speaker.user
              ? ModelMessageRole.user
              : ModelMessageRole.assistant,
          turn.text,
        ),
      ),
      const ModelMessage(ModelMessageRole.system, hiddenActionsReminder),
      ModelMessage(ModelMessageRole.user, context.toString()),
    ];
  }
}
