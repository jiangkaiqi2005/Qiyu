import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:test/test.dart';

void main() {
  const builder = ModelPromptBuilder('测试人格宪法');

  test('system message follows the finalized assembly order', () {
    final messages = builder.build(StateSnapshot.initial('local-user'), '在吗');

    final system = messages.first.content;
    expect(messages.first.role, ModelMessageRole.system);
    final constitutionIndex = system.indexOf('<persona_constitution>');
    final hardRulesIndex = system.indexOf('<hard_rules>');
    final memoryActionsIndex = system.indexOf('<memory_actions>');
    expect(constitutionIndex, greaterThanOrEqualTo(0));
    expect(hardRulesIndex, greaterThan(constitutionIndex));
    expect(memoryActionsIndex, greaterThan(hardRulesIndex));
    expect(system, contains('测试人格宪法'));
    expect(system, contains('## 输出契约'));
    expect(system, contains('## 首个可见回应速度'));
    expect(system, contains('## 事实来源优先级'));
    expect(system, contains('## 安全与专业边界'));
    expect(system, isNot(contains('用户说晚安只收束')));

    expect(messages.last.role, ModelMessageRole.user);
    expect(messages.last.content, '在吗');
  });

  test('empty dynamic blocks are omitted entirely', () {
    final system = builder
        .build(StateSnapshot.initial('local-user'), '在吗')
        .first
        .content;

    for (final tag in ['daily_state', 'long_memory', 'persona']) {
      expect(system, isNot(contains('<$tag>')), reason: tag);
    }
    // 检索结果只附在本轮上下文，未命中时不出现。
    expect(
      builder
          .build(StateSnapshot.initial('local-user'), '在吗')
          .last
          .content,
      isNot(contains('<memory_context>')),
    );
  });

  test('filled hot-layer blocks appear with their human labels', () {
    const full = ModelPromptBuilder(
      '测试人格宪法',
      dailyState: '## 近日气氛\n有点累',
      longMemory: '- 用户喜欢热牛奶',
      persona: '### 偏好\n熬夜型',
      memoryContext: '2026-08-01 用户提过演讲',
    );
    final messages = full.build(StateSnapshot.initial('local-user'), '在吗');
    final system = messages.first.content;

    expect(system, contains('<daily_state>'));
    expect(system, contains('【近况】'));
    expect(system, contains('有点累'));
    expect(system, contains('<long_memory>'));
    expect(system, contains('【长期印象】'));
    expect(system, contains('<persona>'));
    expect(system, contains('【用户画像】'));

    // 检索结果是临时透镜：只拼在本轮用户消息前，不进系统提示词。
    expect(system, isNot(contains('memory_context')));
    expect(messages.last.content, contains('<memory_context>'));
    expect(messages.last.content, contains('【检索结果】'));
    expect(messages.last.content.trim(), endsWith('在吗'));
  });

  test('format reminder sits right before the current user message', () {
    var state = StateSnapshot.initial('local-user');
    final first = const QiyuBehaviorCore().reply(
      const ChatRequest(requestId: 'turn-1', text: '你好'),
      state,
    ) as ChatResult;
    state = first.nextState;

    final messages = builder.build(state, '再说一句');

    expect(messages.last.role, ModelMessageRole.user);
    expect(messages.last.content, '再说一句');
    expect(messages[messages.length - 2].role, ModelMessageRole.system);
    expect(messages[messages.length - 2].content, contains('回复格式提醒'));
    expect(messages[1].role, ModelMessageRole.user);
    expect(messages[1].content, '你好');
    expect(messages[2].role, ModelMessageRole.assistant);
  });

  test('the action protocol covers the whole open-loop lifecycle', () {
    final system = builder
        .build(StateSnapshot.initial('local-user'), '在吗')
        .first
        .content;

    expect(system, contains('memory_signal'));
    expect(system, contains('open_loop_candidate'));
    expect(system, contains('open_loop_status'));
    expect(system, contains('memory_ban'));
    // 候选门槛写进协议：普通闲聊不得变成任务。
    expect(system, contains('普通闲聊'));
  });

  test('the protocol offers memory_recall and honest not-yet-recalled wording', () {
    final system = builder
        .build(StateSnapshot.initial('local-user'), '在吗')
        .first
        .content;

    expect(system, contains('memory_recall'));
    // 硬规则定稿：热层未命中时如实说一时没想起，不编造。
    expect(system, contains('一时没想起'));
    expect(system, contains('不编造相似经历'));
    expect(system, contains('没查到记录不代表没发生'));
  });

  test('the recall discipline states index paths and selection rules', () {
    final system = builder
        .build(StateSnapshot.initial('local-user'), '在吗')
        .first
        .content;

    // 触发纪律：常驻字段没命中且用户问旧事才发。
    expect(system, contains('常驻字段'));
    // 两级索引路径与格式静态写明，不常驻挂载索引内容本身。
    expect(system, contains('episodes/index.md'));
    expect(system, contains('episodes/YYYY/MM/index.md'));
    expect(system, contains('- YYYY-MM | 关键词'));
    expect(system, contains('- YYYY-MM-DD | 关键词'));
    expect(system, isNot(contains('# episodes index')));
    // 选择纪律：只取递来的目录、可空、禁编造日期。
    expect(system, contains('选择只能取自递来的目录'));
    expect(system, contains('绝不编造日期'));
    // 节奏：命中快本轮补，绝不等查找。
    expect(system, contains('绝不等查找结果'));
    expect(system, contains('第二条消息'));
  });

  test('copyWithDailyState replaces only the recent-state block', () {
    const full = ModelPromptBuilder(
      '测试人格宪法',
      dailyState: '旧状态',
      longMemory: '- 用户喜欢热牛奶',
      persona: '### 偏好\n熬夜型',
    );

    final copied = full.copyWithDailyState('新状态');
    final system = copied.build(StateSnapshot.initial('local-user'), '在吗')
        .first
        .content;

    expect(system, contains('新状态'));
    expect(system, isNot(contains('旧状态')));
    expect(system, contains('- 用户喜欢热牛奶'));
    expect(system, contains('熬夜型'));
  });

  test('copyWithMemoryContext replaces only the one-shot recall lens', () {
    const full = ModelPromptBuilder(
      '测试人格宪法',
      dailyState: '旧状态',
      memoryContext: '旧检索结果',
    );

    final copied = full.copyWithMemoryContext('新检索结果');
    final userMessage = copied
        .build(StateSnapshot.initial('local-user'), '在吗')
        .last
        .content;

    expect(userMessage, contains('新检索结果'));
    expect(userMessage, isNot(contains('旧检索结果')));
    expect(userMessage, contains('<memory_context>'));
  });
}
