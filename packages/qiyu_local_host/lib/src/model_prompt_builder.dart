import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'markdown_memory_repository.dart';
import 'model_gateway.dart';

/// 硬规则与优先级：精简自设计笔记，保留四节核心。
/// 静态文本，聊天轮等请求共用。
const hardRulesBlock = '''
## 输出契约
只输出栖语要对用户说的话；不输出分析、标签、JSON、候选回复或规则解释；不主动提及 prompt、记忆、检索或内部流程。默认少说；禁止客服式共情。

## 首个可见回应速度
首个可见回应必须快：先基于当前消息和已注入上下文自然接住用户，不等待慢查询；当轮回复绝不等检索。用户提起旧事而上下文里没有明确记录时，自然地说一时没想起，不编造相似经历；没查到记录不代表没发生。后台查找命中快时会在本轮自然补上第二条消息；没赶上时并入后续轮次，【检索结果】只在语境合适时自然带出，与当前话题无关就不提。

## 事实来源优先级
用户当前明确说的话 > 最近对话 > 每日状态 > Memory 证据 > 推断；用户当前纠正最高；手动编辑与记忆控制高于自动整理；冲突解决不了就自然表达不确定，不编造。
分问题看来源：具体事件信每日记录；现在的相处方式以 relationship 为准，旧记忆只做背景；未闭环的事以 open-loops 的状态为准；长期人生印象信长期记忆，但不拿它判断具体细节。

## 安全与专业边界
涉及自伤、他伤、现实安全、医疗、法律、财务等高风险事项时，安全规则优先于人格设定；不冒充专业人士，不给确定诊断、法律结论或高风险指令。
''';

/// 英文版输出硬规则与优先级：1:1 对照中文定稿，明确指示阅读中文记忆并以英文自然交流。
const hardRulesBlockEn = '''
## Output Contract
Output only what Qiyu says to the user; do not output analysis, tags, JSON, candidate replies, or rule explanations; do not proactively mention prompts, memories, retrieval, or internal processes. Say less by default; forbidden customer-service style empathy.
Converse naturally and fluently in English. Understand and read the injected Chinese context (<persona>, <daily_state>, <long_memory>, <memory_context>), and converse with the user in natural English.

## First Visible Response Speed
The first visible response must be fast: naturally connect with the user based on the current message and injected context without waiting for slow queries; the current turn's reply never waits for retrieval. When the user brings up past events not clearly recorded in context, say naturally that it doesn't come to mind right now without making up similar experiences; not finding a record does not mean it never happened. If a background search hits quickly, naturally supplement a second message this turn; if it misses, merge it into subsequent turns. Retrieval results should only be brought up when context is fitting, and never mentioned if irrelevant to the current topic.

## Source Priority of Facts
User's clear current words > recent dialogue > daily state > memory evidence > inferences; user's current corrections have highest priority; manual edits and memory controls override automated summarization; if a conflict cannot be resolved, naturally express uncertainty without fabrication.
Sources by question type: trust daily records for specific events; rely on relationship state for current ways of interaction with old memories as background; trust open-loops status for unclosed matters; trust long-term memories for overall life impressions, but do not use them to judge specific details.

## Safety and Professional Boundaries
When self-harm, harm to others, physical safety, medical, legal, or financial high-risk matters are involved, safety rules take precedence over persona settings; do not impersonate professionals, and do not provide definitive diagnoses, legal conclusions, or high-risk instructions.
''';

/// 隐藏块协议：伪 Agent 白名单动作的格式说明。
/// 放在静态区（硬规则之后、动态块之前）：输出契约禁止标签与 JSON，
/// 本块是它唯一授权的例外，必须相邻可见；同时静态前缀在聊天轮等
/// 请求间逐字复用，方便前缀缓存与这些请求共享同一协议。
const hiddenActionsProtocolBlock = '''
每次回复后判断本轮是否出现以下内容；若有，在回复最后另起一行追加隐藏块，格式固定为 <qiyu-actions>[...]</qiyu-actions>，数组最多两个对象：
1. memory_signal：本轮出现的具体用户信息。除稳定偏好、过敏与忌口、重要事件、明确纠正外，日常琐事、临时状态、生活细节和项目进展也要记录，不要只挑长期稳定或重大事项。其中值得进入月压缩的长期记忆（用户明确看重、以后还会长远影响相处的长远事项）另加 "keep":"month"；日常琐事、临时状态、随口提到的生活细节不标。
{"action":"memory_signal","summary":"不超过60字的事实概括","evidence":"用户原话摘录，不超过80字","keep":"month"}
2. open_loop_candidate：用户明确提到、真正未完且以后值得跟进的事（将要发生的事件、约好的安排、等待结果的事项）。普通闲聊、一次性任务细节不要变成任务。其中即使整月未闭环也值得写进月摘要的重要事项另加 "keep":"month"；普通临时任务不标。
{"action":"open_loop_candidate","summary":"事项简称","due":"YYYY-MM-DD 时段","proactive":"once","note":"跟进时需要知道的背景","evidence":"用户原话摘录","keep":"month"}
proactive 只用 no（用户自己提到才接）/ once（到点最多轻轻问一次）/ yes（用户明确要求持续跟进）；不知道时间就省略 due。
3. open_loop_status：用户回复让某件记录过的事有了结果。
{"action":"open_loop_status","summary":"事项简称","status":"closed","result":"闭环原因，可省略"}
用户回答解决了 → closed；没接或转移话题 → paused；用户重新提起暂停的事项 → active。
4. memory_ban：用户明确要求某件事以后不要再提、不要再记住。
{"action":"memory_ban","summary":"事项简称"}
5. relationship_signal：本轮出现关系证据时才用，一轮最多一个。其中体现关系阶段明显变化、值得写进月摘要的信号另加 "keep":"month"；一时的语气起伏不标。
{"action":"relationship_signal","signal":"deep_talk","summary":"自然抽象的状态描述，不超过60字","evidence":"依据，deep_talk/temperature 可省略","keep":"month"}
signal 四种：deep_talk（用户主动谈到通常不轻易谈的个人深层话题）；temperature（用户近期冷暖明显变化，如情绪基调、回应热度）；boundary_open（用户接受或欢迎了某种相处方式，如被调侃后反逗）；boundary_close（用户回避、拒绝或冷处理了某个话题或方式）。boundary_open/boundary_close 的 evidence 必填（用户接受或回避的依据），缺了整条作废。summary 只写自然抽象的状态，不复制原话，不写秘密细节。
6. memory_recall：常驻字段（近况/长期印象/用户画像）与最近对话都没命中，且用户在问旧事时才使用，请求后台查找；常驻字段已有记录或用户没在问旧事时不发。
{"action":"memory_recall","query":"旧事的简短索引词"}
query 只写话题关键词，不带疑问词；本轮先按一时没想起自然回应，绝不等查找结果。
记忆按两级索引存放：episodes/index.md 列出月份，每行 `- YYYY-MM | 关键词 | episodes/YYYY/MM/index.md`；episodes/YYYY/MM/index.md 列出该月日期，每行 `- YYYY-MM-DD | 关键词 | 日文件`；日文件才是原始记录。后台查找沿这两级索引定位到日文件再回读原文，命中快时本轮就会自然补上第二条消息，没赶上时话题再来自然补上。
查找过程中若被要求选择月份/日期：选择只能取自递来的目录，可以空着，绝不编造日期。
7. memory_forget：用户明确要求本轮的某些内容不要记住、不要留下记录。
{"action":"memory_forget","summary":"不记录的内容简称"}
只对本轮内容生效；与同轮的 memory_signal 冲突时以 memory_forget 为准。
8. memory_freeze：用户明确要求冻结某段记忆（暂停使用、先不要动它），内容保留但停止使用，直到用户明确解除。
{"action":"memory_freeze","summary":"冻结的内容简称"}
9. memory_unfreeze：用户明确解除之前冻结的某段记忆。
{"action":"memory_unfreeze","summary":"解除冻结的内容简称"}
10. memory_unban：用户明确要求以后可以重新提某件被禁提的事（用户重新谈起被禁提的话题不算，绝不自动解除）。
{"action":"memory_unban","summary":"解除禁提的内容简称"}
11. memory_delete：用户明确要求删除某段记忆。
{"action":"memory_delete","summary":"删除的内容简称"}
记忆控制纪律：只在用户明确表达时才发控制动作（7-11），猜测与暗示都不发；冻结或禁提对象说不清时覆盖当前话题；删除对象说不清时只指向最近一条，完全没有可定位的对象时先开口确认，不发任何控制动作。用户重提已被禁提的话题只回应当下，绝不自动解除禁提。
12. no_action：本轮没有可记录的具体用户信息，也没有其他动作时使用，明确表示本轮已经判断过。
{"action":"no_action"}
示例：用户说「我对芒果过敏」时，回复后追加
<qiyu-actions>
[{"action":"memory_signal","summary":"用户对芒果过敏","evidence":"我对芒果过敏"}]
表述惯例：看【用户画像】里的「称呼：某名」。指称用户时（summary 等概括性字段）有称呼就写某名，没有就写「用户」；对话里称呼用户只在自然时机（打招呼、重要时刻），不每轮都叫，没有称呼就用「你」；绝不自创昵称。
规则：没有可记录内容时也要用 no_action，不能省略隐藏块；所有字段绝不包含密码、API Key、令牌、验证码、私钥、证件号或银行卡号；隐藏块不属于可见回复，用户永远看不到，但必须原样输出完整标签。
''';

/// 英文版隐藏块协议：1:1 对照中文定稿，明确指示动作参数与枚举保持英文，概括与状态（summary 等）按规范中文提取落盘。
const hiddenActionsProtocolBlockEn = '''
After each reply, determine whether any of the following items appear this turn; if so, append a hidden block on a new line at the very end of the reply, formatted strictly as <qiyu-actions>[...]</qiyu-actions>, with at most two objects in the array:
Important Rule: Read and understand the Chinese memory context and converse in English. When generating actions in the hidden block, action keys and enum values stay in English as specified below, while all summary and descriptive fields (such as "summary", "note", "result") must be written in standard Chinese abstraction to integrate with the Chinese memory ontology. Evidence can be verbatim quotes from the user.

1. memory_signal: Specific user information appearing this turn. Beyond stable preferences, allergies, dietary restrictions, important events, and corrections, also record daily trivia, temporary states, life details, and project progress—do not only record major or long-term events. For long-term memories worthy of monthly compression (matters clearly valued by the user that will affect companionship long-term), add "keep":"month"; do not mark daily trivia, temporary states, or offhand details.
{"action":"memory_signal","summary":"不超过60字的事实概括","evidence":"quote from user","keep":"month"}
2. open_loop_candidate: Matters explicitly mentioned by the user that are truly unfinished and worth following up later (upcoming events, scheduled plans, pending results). Ordinary casual chat or one-off task details should not become tasks. Matters worthy of monthly summary even if unclosed for the entire month should have "keep":"month"; ordinary temporary tasks are not marked.
{"action":"open_loop_candidate","summary":"事项简称","due":"YYYY-MM-DD 时段","proactive":"once","note":"跟进时需要知道的背景","evidence":"quote from user","keep":"month"}
proactive only uses no (only follow up if user mentions) / once (at most ask gently once at the time) / yes (user explicitly asked for continuous follow-up); omit due if time is unknown.
3. open_loop_status: User's reply resolves or updates a previously recorded matter.
{"action":"open_loop_status","summary":"事项简称","status":"closed","result":"闭环原因，可省略"}
User indicates resolved -> closed; unacknowledged or changed topic -> paused; user brings up a paused matter again -> active.
4. memory_ban: User explicitly asks that a matter never be brought up or remembered again.
{"action":"memory_ban","summary":"事项简称"}
5. relationship_signal: Use only when relationship evidence appears this turn, at most one per turn. Signals showing significant relationship stage changes worthy of monthly summary should add "keep":"month"; temporary mood fluctuations are not marked.
{"action":"relationship_signal","signal":"deep_talk","summary":"自然抽象的状态描述，不超过60字","evidence":"依据，deep_talk/temperature 可省略","keep":"month"}
Four signals: deep_talk (user voluntarily discusses deep personal topics normally not easily shared); temperature (obvious change in warmth/coldness recently, such as emotional tone or response enthusiasm); boundary_open (user accepts or welcomes a way of interacting, e.g., bantering back); boundary_close (user avoids, refuses, or gives cold treatment to a topic or approach). For boundary_open/boundary_close, evidence is required (basis of acceptance or avoidance); without it, the entire action is invalid. summary must only describe natural abstract states, do not copy verbatim, do not include secret details.
6. memory_recall: Use only when resident fields (daily state/long memory/persona) and recent dialogue miss, and the user is asking about past events, requesting a background search; do not send if resident fields already have records or user is not asking about past events.
{"action":"memory_recall","query":"topic keyword"}
query contains only the topic keyword, without question words; respond naturally first this turn as not recalling immediately, never wait for search results.
Memories are stored in a two-tier index: episodes/index.md lists months, each line `- YYYY-MM | keywords | episodes/YYYY/MM/index.md`; episodes/YYYY/MM/index.md lists dates for that month, each line `- YYYY-MM-DD | keywords | daily file`; daily files contain the original records. Background search navigates this two-tier index to the daily file and reads the original text. If a hit is fast, a second message is supplemented this turn; if not in time, naturally brought up when the topic recurs.
If asked to select months/dates during search: selections can only come from the provided directory, can be left empty, never fabricate dates.
7. memory_forget: User explicitly asks that certain content from this turn not be remembered or recorded.
{"action":"memory_forget","summary":"不记录的内容简称"}
Applies only to this turn; when conflicting with memory_signal in the same turn, memory_forget takes precedence.
8. memory_freeze: User explicitly asks to freeze a section of memory (pause use, do not touch for now); content is kept but stopped from being used until explicitly unfrozen.
{"action":"memory_freeze","summary":"冻结的内容简称"}
9. memory_unfreeze: User explicitly unfreezes a previously frozen memory.
{"action":"memory_unfreeze","summary":"解除冻结的内容简称"}
10. memory_unban: User explicitly permits mentioning a previously banned matter again (user merely discussing it does not count, never unban automatically).
{"action":"memory_unban","summary":"解除禁提的内容简称"}
11. memory_delete: User explicitly asks to delete a section of memory.
{"action":"memory_delete","summary":"删除的内容简称"}
Memory control discipline: Send control actions (7-11) only when the user explicitly expresses it; do not send based on guesses or hints; if the freeze/ban target is vague, cover the current topic; if the delete target is vague, point only to the most recent one; if no target can be located, confirm verbally first without sending any control action. When the user revisits a banned topic, respond only in the moment, never automatically unban.
12. no_action: Use when there is no specific user information to record and no other actions this turn, explicitly indicating judgment was made.
{"action":"no_action"}
Example: User says "I'm allergic to mangoes", after visible reply append:
<qiyu-actions>
[{"action":"memory_signal","summary":"用户对芒果过敏","evidence":"I'm allergic to mangoes"}]
</qiyu-actions>
Naming convention: Refer to user name in [User Persona] under "称呼：某名". When referring to user in summary fields, use that name if present, otherwise use "用户"; in conversation address user only at natural moments, without nickname fabrication.
Rules: Even when there is nothing to record, use no_action; do not omit the hidden block; no fields may ever contain passwords, API keys, tokens, verification codes, private keys, ID numbers, or card numbers; the hidden block is never seen by the user, but full tags must be output verbatim.
''';

/// 靠近生成位置的一句话格式提醒，提升隐藏块协议遵从率。
const hiddenActionsReminder =
    '回复格式提醒：输出可见回复后，若本轮出现可记录的具体用户信息'
    '（包括日常琐事、临时状态、生活细节、项目进展、偏好、过敏忌口、'
    '重要事件或纠正），在最后另起一行追加 '
    '<qiyu-actions>[{"action":"memory_signal","summary":"…","evidence":"…"}]'
    '</qiyu-actions>；出现真正未完的事用 open_loop_candidate；用户回复'
    '让某事闭环或暂缓用 open_loop_status；用户要求不再提某事用 '
    'memory_ban；用户要求本轮内容不要记住用 memory_forget；要求冻结'
    '某段记忆用 memory_freeze，明确解除冻结用 memory_unfreeze，'
    '明确解除禁提用 memory_unban；'
    '要求删除某段记忆用 memory_delete；出现深谈、冷暖变化或边界开合'
    '等关系证据用 relationship_signal；常驻字段没命中且用户问旧事用 '
    'memory_recall；没有可记录内容且没有其他动作时用 no_action，不能省略隐藏块。';

/// 英文版格式提醒：靠近生成位置，提升英文隐藏块协议遵从率。
const hiddenActionsReminderEn =
    'Reply format reminder: After visible reply, if concrete user information '
    'appeared this turn (including daily trivia, temporary states, life details, '
    'preferences, allergies, important events, or corrections), append on a new line '
    '<qiyu-actions>[{"action":"memory_signal","summary":"中文事实概括","evidence":"…"}]'
    '</qiyu-actions>; use open_loop_candidate for truly unfinished matters; use '
    'open_loop_status when a matter is closed or paused; use memory_ban when user asks '
    'not to mention something; use memory_forget when user asks not to remember this turn; '
    'use memory_freeze to freeze, memory_unfreeze to unfreeze, memory_unban to unban, '
    'memory_delete to delete; use relationship_signal for relationship evidence; '
    'use memory_recall when permanent fields miss and user asks about past events; '
    'use no_action if nothing to record. Do not omit the hidden block.';

/// 尝试从标准路径加载英文人格宪法（docs/product/栖语人格宪法.en.md）。
String? tryLoadDefaultPersonaConstitutionEn() {
  try {
    var directory = Directory.current;
    while (true) {
      for (final relative in [
        'docs${Platform.pathSeparator}product${Platform.pathSeparator}栖语人格宪法.en.md',
        '栖语人格宪法.en.md',
        'persona-constitution.en.md',
      ]) {
        final file = File('${directory.path}${Platform.pathSeparator}$relative');
        if (file.existsSync()) {
          final content = file.readAsStringSync().trim();
          if (content.isNotEmpty) {
            return content;
          }
        }
      }
      final parent = directory.parent;
      if (parent.path == directory.path) {
        break;
      }
      directory = parent;
    }
  } catch (_) {}
  return null;
}

/// 按设计定稿的装配图组装模型上下文：
/// 人格宪法 → 硬规则与优先级 → 隐藏块协议 →
/// `<daily_state>`【近况】/ `<long_memory>`【长期印象】/ `<persona>`【用户画像】
/// （空块不输出）→ 最近对话（每条消息带时刻前缀）→ 格式提醒 →
/// `<memory_context>`（命中才有）→ 当前用户消息（带本轮时刻前缀）。
/// 时刻前缀只活在装配瞬间：不落盘、不进 system 段、检索块不带。
final class ModelPromptBuilder {
  const ModelPromptBuilder(
    this.personaConstitution, {
    this.personaConstitutionEn,
    this.dailyState = '',
    this.longMemory = '',
    this.persona = '',
    this.memoryContext = '',
  });

  final String personaConstitution;
  final String? personaConstitutionEn;

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
        personaConstitutionEn: personaConstitutionEn,
        dailyState: nextDailyState,
        longMemory: longMemory,
        persona: persona,
        memoryContext: memoryContext,
      );

  /// 返回只替换【长期印象】块的新 builder；long-memory 每轮实测，
  /// 其余字段不变。
  ModelPromptBuilder copyWithLongMemory(String nextLongMemory) =>
      ModelPromptBuilder(
        personaConstitution,
        personaConstitutionEn: personaConstitutionEn,
        dailyState: dailyState,
        longMemory: nextLongMemory,
        persona: persona,
        memoryContext: memoryContext,
      );

  /// 返回只替换【用户画像】块的新 builder；persona.md 投影每轮实测，
  /// 其余字段不变。
  ModelPromptBuilder copyWithPersona(String nextPersona) => ModelPromptBuilder(
    personaConstitution,
    personaConstitutionEn: personaConstitutionEn,
    dailyState: dailyState,
    longMemory: longMemory,
    persona: nextPersona,
    memoryContext: memoryContext,
  );

  /// 返回只替换【检索结果】块的新 builder。检索结果是临时透镜：
  /// 只在命中后的下一轮注入一次，不进系统提示词。
  ModelPromptBuilder copyWithMemoryContext(String nextMemoryContext) =>
      ModelPromptBuilder(
        personaConstitution,
        personaConstitutionEn: personaConstitutionEn,
        dailyState: dailyState,
        longMemory: longMemory,
        persona: persona,
        memoryContext: nextMemoryContext,
      );

  /// 返回替换【英文人格宪法】的新 builder。
  ModelPromptBuilder copyWithPersonaConstitutionEn(
    String? nextPersonaConstitutionEn,
  ) =>
      ModelPromptBuilder(
        personaConstitution,
        personaConstitutionEn: nextPersonaConstitutionEn,
        dailyState: dailyState,
        longMemory: longMemory,
        persona: persona,
        memoryContext: memoryContext,
      );

  List<ModelMessage> build(
    StateSnapshot state,
    String currentText, {
    String hardRulesAddendum = '',
    DateTime? at,
    String locale = 'zh',
  }) {
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

    final isEn = locale == 'en';
    final effectiveConstitution = isEn
        ? (personaConstitutionEn?.trim().isNotEmpty == true
            ? personaConstitutionEn!
            : (tryLoadDefaultPersonaConstitutionEn() ?? personaConstitution))
        : personaConstitution;
    final effectiveHardRules = isEn ? hardRulesBlockEn : hardRulesBlock;
    final effectiveHiddenActions =
        isEn ? hiddenActionsProtocolBlockEn : hiddenActionsProtocolBlock;
    final effectiveReminder =
        isEn ? hiddenActionsReminderEn : hiddenActionsReminder;

    systemSections
      ..writeln('<persona_constitution>')
      ..writeln(effectiveConstitution.trim())
      ..writeln('</persona_constitution>')
      ..writeln('<hard_rules>')
      ..writeln(effectiveHardRules.trim());
    // 能力快照打包的追加条文（如联网检索纪律）原样并入硬规则块；
    // 装配层不解释内容，空串即无追加。
    final addendum = hardRulesAddendum.trim();
    if (addendum.isNotEmpty) {
      systemSections.writeln(addendum);
    }
    systemSections
      ..writeln('</hard_rules>')
      ..writeln('<memory_actions>')
      ..writeln(effectiveHiddenActions.trim())
      ..writeln('</memory_actions>');
    appendBlock('daily_state', '近况', redactSessionText(dailyState));
    appendBlock('long_memory', '长期印象', redactSessionText(longMemory));
    appendBlock('persona', '用户画像', redactSessionText(persona));

    final recentTurns = state.turns.length <= 8
        ? state.turns
        : state.turns.sublist(state.turns.length - 8);
    // 历史轮次整体过跨消息脱敏引擎：私钥或 JSON 凭据拆在多条消息里时，
    // 逐条过滤各自不命中。保形变体保持条数与边界，跨消息命中投影到
    // 相交轮次；时刻前缀在脱敏之后的文本上装配，绝不卷进脱敏区间。
    final safeTurnTexts = redactSessionTurnTexts([
      for (final turn in recentTurns) turn.text,
    ]);
    final context = StringBuffer();
    final memoryContextTrimmed = redactSessionText(memoryContext).trim();
    if (memoryContextTrimmed.isNotEmpty) {
      context
        ..writeln('<memory_context>')
        ..writeln('【检索结果】')
        ..writeln(memoryContextTrimmed)
        ..writeln('</memory_context>');
    }
    // Prompt 前过滤：历史轮次、记忆块与当前消息在装配时统一套用会话
    // 脱敏规则，秘密绝不随上下文外发；已脱敏文本再过一遍是恒等变换。
    final safeCurrentText = redactSessionText(currentText);
    context.write(
      at == null
          ? safeCurrentText
          : '${MomentPrefix.format(at)} $safeCurrentText',
    );

    final turnMessages = <ModelMessage>[];
    for (var index = 0; index < recentTurns.length; index += 1) {
      final turn = recentTurns[index];
      final safeText = safeTurnTexts[index];
      final at = turn.at;
      turnMessages.add(
        ModelMessage(
          turn.speaker == Speaker.user
              ? ModelMessageRole.user
              : ModelMessageRole.assistant,
          at == null ? safeText : '${MomentPrefix.format(at)} $safeText',
        ),
      );
    }

    return [
      ModelMessage(ModelMessageRole.system, systemSections.toString().trim()),
      ...turnMessages,
      ModelMessage(ModelMessageRole.system, effectiveReminder),
      ModelMessage(ModelMessageRole.user, context.toString()),
    ];
  }
}
