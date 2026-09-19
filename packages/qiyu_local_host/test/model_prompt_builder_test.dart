import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:test/test.dart';

/// 从运行目录向上回溯定位仓库根「栖语人格宪法.md」，不依赖 dart test
/// 的工作目录恰为包根（与安卓宪法资产守护测试同一先例）。
File _locateRepoConstitution() {
  var directory = Directory.current;
  while (true) {
    final candidate = File(
      '${directory.path}${Platform.pathSeparator}栖语人格宪法.md',
    );
    if (candidate.existsSync()) {
      return candidate;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      fail('向上回溯仍找不到仓库根「栖语人格宪法.md」');
    }
    directory = parent;
  }
}

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

  test('danger-moments constitution section ships verbatim into the context', () {
    // 宪法「危险时刻」节（ADR 0010 定稿原文）逐字锁进仓库根原件，并随
    // <persona_constitution> 原样装配进入模型上下文：文字漂移或装配
    // 遗漏都在此失败。
    const dangerHeading = '## 危险时刻';
    const dangerText =
        '当用户的话语里出现伤害自己、结束生命这类信号，栖语先把它当成真的。'
        '她还是那个朋友：先认真接住对方此刻在说的话，把在意说出来，'
        '再温和地劝他联系身边能到场的人，自然地带上全国 24 小时心理援助热线 '
        '12356——像替朋友递一个电话号码那样递出去。'
        '她用平时说话的方式对待这件事：短句、平静、句句出自认真在听的人；'
        '要不要拨出去，由用户自己决定。';
    final constitution = _locateRepoConstitution().readAsStringSync();
    expect(constitution, contains(dangerHeading));
    expect(constitution, contains(dangerText));

    final system = ModelPromptBuilder(
      constitution,
    ).build(StateSnapshot.initial('local-user'), '在吗').first.content;
    expect(system, contains(dangerHeading));
    expect(system, contains(dangerText));
  });

  test('hidden action protocol carries the appellation wording rule', () {
    final system = builder
        .build(StateSnapshot.initial('local-user'), '在吗')
        .first
        .content;
    // 记忆表述惯例（称呼定稿）：有称呼用称呼、无称呼用「用户」；对话
    // 侧只在自然时机称呼，不每轮都叫，无称呼用「你」。
    expect(system, contains('表述惯例'));
    expect(system, contains('称呼'));
    expect(system, contains('没有就写「用户」'));
    expect(system, contains('自然时机'));
    expect(system, contains('不每轮都叫'));
    expect(system, contains('就用「你」'));
    expect(system, contains('绝不自创昵称'));
  });

  test('web search instruction is injected exactly once only when enabled', () {
    final disabled = builder
        .build(StateSnapshot.initial('local-user'), '现在几点')
        .first
        .content;
    final enabled = builder
        .build(
          StateSnapshot.initial('local-user'),
          '现在几点',
          hardRulesAddendum: webSearchSystemInstruction,
        )
        .first
        .content;
    final hardRulesStart = enabled.indexOf('<hard_rules>');
    final instructionIndex = enabled.indexOf(webSearchSystemInstruction);
    final hardRulesEnd = enabled.indexOf('</hard_rules>');
    final memoryActionsStart = enabled.indexOf('<memory_actions>');

    expect(disabled, isNot(contains('web_search')));
    expect(
      RegExp(RegExp.escape(webSearchSystemInstruction)).allMatches(enabled),
      hasLength(1),
    );
    expect(instructionIndex, greaterThan(hardRulesStart));
    expect(instructionIndex, lessThan(hardRulesEnd));
    expect(memoryActionsStart, greaterThan(hardRulesEnd));
    expect(enabled, isNot(contains('get_local_time')));
    expect(enabled, isNot(contains('searched_at')));
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
      builder.build(StateSnapshot.initial('local-user'), '在吗').last.content,
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
    final first =
        const QiyuBehaviorCore().reply(
              const ChatRequest(requestId: 'turn-1', text: '你好'),
              state,
            )
            as ChatResult;
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

  test(
    'the action protocol records everyday details and requires a decision',
    () {
      final system = builder
          .build(StateSnapshot.initial('local-user'), '晚饭吃了小馄饨')
          .first
          .content;

      expect(system, contains('日常琐事'));
      expect(system, contains('临时状态'));
      expect(system, contains('项目进展'));
      expect(system, contains('no_action'));
      expect(system, isNot(contains('普通闲聊不追加')));
    },
  );

  test(
    'the protocol offers memory_recall and honest not-yet-recalled wording',
    () {
      final system = builder
          .build(StateSnapshot.initial('local-user'), '在吗')
          .first
          .content;

      expect(system, contains('memory_recall'));
      // 硬规则定稿：热层未命中时如实说一时没想起，不编造。
      expect(system, contains('一时没想起'));
      expect(system, contains('不编造相似经历'));
      expect(system, contains('没查到记录不代表没发生'));
    },
  );

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
    final system = copied
        .build(StateSnapshot.initial('local-user'), '在吗')
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

  group('moment prefixes on assembled conversation messages', () {
    final momentState = StateSnapshot(
      userId: 'local-user',
      relationshipStage: RelationshipStage.stranger,
      turns: [
        ChatTurn(
          speaker: Speaker.user,
          text: '睡了吗',
          at: DateTime(2025, 12, 31, 23, 41),
        ),
        ChatTurn(
          speaker: Speaker.qiyu,
          text: '还没',
          at: DateTime(2025, 12, 31, 23, 43),
        ),
        const ChatTurn(speaker: Speaker.user, text: '没有时刻的旧消息'),
      ],
      lastEmotion: const EmotionSnapshot(
        kind: EmotionKind.neutral,
        intensity: 0,
      ),
    );

    test('every recent turn carries its local-time moment prefix', () {
      final messages = builder.build(momentState, '现在呢');

      expect(messages[1].content, '[2025-12-31 23:41] 睡了吗');
      // 栖语自己的消息同样带前缀，仍以 assistant 角色出现。
      expect(messages[2].role, ModelMessageRole.assistant);
      expect(messages[2].content, '[2025-12-31 23:43] 还没');
      // 无时刻的 turn 保持原文，不渲染前缀。
      expect(messages[3].content, '没有时刻的旧消息');
    });

    test('the current message carries the moment it was sent', () {
      final messages = builder.build(
        momentState,
        '现在呢',
        at: DateTime(2025, 12, 31, 23, 58),
      );

      expect(messages.last.content, '[2025-12-31 23:58] 现在呢');
      // 不传当前时刻时不渲染前缀（连接测试等路径维持原状）。
      expect(builder.build(momentState, '现在呢').last.content, '现在呢');
    });

    test('moments never reach the system sections or the recall block', () {
      const withRecall = ModelPromptBuilder(
        '测试人格宪法',
        memoryContext: '2026-08-01 用户提过演讲',
      );
      final messages = withRecall.build(
        momentState,
        '现在呢',
        at: DateTime(2025, 12, 31, 23, 58),
      );

      final momentPattern = RegExp(r'\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}\]');
      // 时间不进 system 段（含格式提醒段）。
      for (final message in messages.where(
        (m) => m.role == ModelMessageRole.system,
      )) {
        expect(message.content, isNot(matches(momentPattern)));
      }
      // 检索结果块不带时刻；带前缀的只有消息本身。
      final userContent = messages.last.content;
      final recallBlock = userContent.substring(
        userContent.indexOf('<memory_context>'),
        userContent.indexOf('</memory_context>'),
      );
      expect(recallBlock, isNot(matches(momentPattern)));
      expect(userContent, matches(momentPattern));
    });

    test('UTC-stored moments render locally without an offset suffix', () {
      final utcMoment = DateTime.utc(2025, 12, 31, 15, 41);
      final messages = builder.build(
        StateSnapshot(
          userId: 'local-user',
          relationshipStage: RelationshipStage.stranger,
          turns: [ChatTurn(speaker: Speaker.user, text: '睡了吗', at: utcMoment)],
          lastEmotion: const EmotionSnapshot(
            kind: EmotionKind.neutral,
            intensity: 0,
          ),
        ),
        '在吗',
      );

      // 期望值由测试内独立换算出本地时区渲染，锁定「UTC 存储、本地渲染」。
      final local = utcMoment.toLocal();
      String two(int value) => value.toString().padLeft(2, '0');
      final expected =
          '[${local.year.toString().padLeft(4, '0')}-${two(local.month)}-'
          '${two(local.day)} ${two(local.hour)}:${two(local.minute)}] 睡了吗';
      expect(messages[1].content, expected);
      // 完整日期、分钟粒度、无时区偏移后缀。
      expect(
        messages[1].content,
        matches(RegExp(r'^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}\] ')),
      );
    });
  });
}
