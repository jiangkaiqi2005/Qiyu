import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:test/test.dart';

/// 从运行目录向上回溯定位仓库根「栖语人格宪法.md」，不依赖 dart test
/// 的工作目录恰为包根（与安卓宪法资产守护测试同一先例）。
File _locateRepoConstitution() {
  var directory = Directory.current;
  while (true) {
    for (final relative in [
      'docs${Platform.pathSeparator}product${Platform.pathSeparator}栖语人格宪法.md',
      '栖语人格宪法.md',
    ]) {
      final candidate = File(
        '${directory.path}${Platform.pathSeparator}$relative',
      );
      if (candidate.existsSync()) {
        return candidate;
      }
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      fail('向上回溯仍找不到人格宪法文件「docs/product/栖语人格宪法.md」');
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

  test('hard rules priority section carries the per-question source rule', () {
    final system = builder
        .build(StateSnapshot.initial('local-user'), '在吗')
        .first
        .content;

    // D4 拍板条文逐字进「事实来源优先级」节：分问题看来源，修正线性序
    // 对长期印象类问题的反向引导，说清 relationship 与 open-loops 地位。
    expect(
      system,
      contains(
        '分问题看来源：具体事件信每日记录；现在的相处方式以 relationship '
        '为准，旧记忆只做背景；未闭环的事以 open-loops 的状态为准；'
        '长期人生印象信长期记忆，但不拿它判断具体细节。',
      ),
    );
    // 该节原有条文与其余各节逐字不动。
    expect(
      system,
      contains(
        '用户当前明确说的话 > 最近对话 > 每日状态 > Memory 证据 > 推断；'
        '用户当前纠正最高；手动编辑与记忆控制高于自动整理；'
        '冲突解决不了就自然表达不确定，不编造。',
      ),
    );
    expect(
      system,
      contains(
        '只输出栖语要对用户说的话；不输出分析、标签、JSON、候选回复或规则解释；'
        '不主动提及 prompt、记忆、检索或内部流程。默认少说；禁止客服式共情。',
      ),
    );
    expect(
      system,
      contains(
        '首个可见回应必须快：先基于当前消息和已注入上下文自然接住用户，'
        '不等待慢查询；当轮回复绝不等检索。用户提起旧事而上下文里没有明确记录时，'
        '自然地说一时没想起，不编造相似经历；没查到记录不代表没发生。'
        '后台查找命中快时会在本轮自然补上第二条消息；没赶上时并入后续轮次，'
        '【检索结果】只在语境合适时自然带出，与当前话题无关就不提。',
      ),
    );
    expect(
      system,
      contains(
        '涉及自伤、他伤、现实安全、医疗、法律、财务等高风险事项时，'
        '安全规则优先于人格设定；不冒充专业人士，不给确定诊断、法律结论或'
        '高风险指令。',
      ),
    );
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

  test('the action protocol teaches both spoken control lifts', () {
    final system = builder
        .build(StateSnapshot.initial('local-user'), '在吗')
        .first
        .content;

    // 解除冻结与解除禁提两条口语路径对称教授（裁定票 03）。
    expect(system, contains('{"action":"memory_unfreeze","summary":"解除冻结的内容简称"}'));
    expect(system, contains('{"action":"memory_unban","summary":"解除禁提的内容简称"}'));
    // 纪律原样保留：重提被禁提话题只回应当下，绝不自动解除。
    expect(system, contains('用户重提已被禁提的话题只回应当下，绝不自动解除禁提'));
  });

  test('the format reminder names the spoken ban lift', () {
    final messages = builder.build(StateSnapshot.initial('local-user'), '在吗');
    final reminder = messages[messages.length - 2].content;

    expect(reminder, contains('memory_unfreeze'));
    expect(reminder, contains('memory_unban'));
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
    'the action protocol teaches the month keep mark for memory signals',
    () {
      final system = builder
          .build(StateSnapshot.initial('local-user'), '长期记忆只放真正重要的事')
          .first
          .content;

      // 月压缩定稿：只收当时标了 keep: month 的条目。
      expect(system, contains('"keep":"month"'));
      expect(system, contains('值得进入月压缩的长期记忆'));
      // 日常琐事不标：记录面不变，标记面收敛。
      expect(system, contains('日常琐事、临时状态、随口提到的生活细节不标'));
      // 两类生命周期动作同样教何时标：整月未闭环的重要事项、
      // 关系阶段明显变化。
      expect(system, contains('即使整月未闭环也值得写进月摘要'));
      expect(system, contains('体现关系阶段明显变化、值得写进月摘要'));
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

  group('跨 turn 凭据在装配上下文中遮蔽', () {
    List<String> assembledTexts(List<ChatTurn> turns) => builder
        .build(
          StateSnapshot(
            userId: 'local-user',
            relationshipStage: RelationshipStage.stranger,
            turns: turns,
          ),
          '在吗',
        )
        .map((message) => message.content)
        .toList();

    test('私钥 BEGIN/END 拆多条消息，历史轮次整体遮蔽且条数不变', () {
      final texts = assembledTexts([
        ChatTurn(
          speaker: Speaker.user,
          text: '-----BEGIN PRIVATE KEY-----',
          at: DateTime(2025, 12, 31, 23, 41),
        ),
        ChatTurn(
          speaker: Speaker.qiyu,
          text: '嗯，怎么了？',
          at: DateTime(2025, 12, 31, 23, 43),
        ),
        ChatTurn(
          speaker: Speaker.user,
          text: 'AUDITONLYFAKEPKCS8\n-----END PRIVATE KEY-----',
          at: DateTime(2025, 12, 31, 23, 44),
        ),
        const ChatTurn(speaker: Speaker.qiyu, text: '先别发这个。'),
      ]);

      // 条数与顺序不变：system + 4 轮 + 格式提醒 + 当前消息。
      expect(texts, hasLength(7));
      // 时刻前缀在脱敏之后的文本上装配，绝不卷进脱敏区间。
      expect(texts[1], '[2025-12-31 23:41] [已脱敏]');
      expect(texts[2], '[2025-12-31 23:43] [已脱敏]');
      expect(texts[3], '[2025-12-31 23:44] [已脱敏]');
      expect(texts[4], '先别发这个。');
      expect(texts[6], '在吗');
      for (final text in texts) {
        expect(text, isNot(contains('AUDITONLYFAKEPKCS8')));
        expect(text, isNot(contains('-----BEGIN')));
        expect(text, isNot(contains('-----END')));
      }
    });

    test('JSON 凭据键值拆相邻消息，值跨条遮蔽', () {
      // 同轮多 bubble 在装配里就是相邻消息，键在上一条、值在相邻下一条。
      final texts = assembledTexts([
        const ChatTurn(speaker: Speaker.user, text: '配置 {"password":'),
        const ChatTurn(
          speaker: Speaker.qiyu,
          text: '"audit-only-json-secret","count":1}',
        ),
      ]);

      expect(texts[1], '配置 {"password":');
      expect(texts[2], '"[已脱敏]","count":1}');
      expect(texts[4], '在吗');
      for (final text in texts) {
        expect(text, isNot(contains('audit-only-json-secret')));
      }
    });

    test('无凭据历史轮次逐字保持原文', () {
      final texts = assembledTexts([
        ChatTurn(
          speaker: Speaker.user,
          text: '今天有点累',
          at: DateTime(2025, 12, 31, 23, 41),
        ),
        const ChatTurn(speaker: Speaker.qiyu, text: '嗯，怎么了？'),
      ]);

      expect(texts[1], '[2025-12-31 23:41] 今天有点累');
      expect(texts[2], '嗯，怎么了？');
      expect(texts[4], '在吗');
    });
  });

  group('bilingual prompt assembly (locale)', () {
    const customZhConstitution = '自定义中文宪法';
    const customEnConstitution = 'Custom English Constitution';
    const bilingualBuilder = ModelPromptBuilder(
      customZhConstitution,
      personaConstitutionEn: customEnConstitution,
      persona: '用户昵称：小明',
      dailyState: '今天心情不错',
      longMemory: '喜欢喝乌龙茶',
      memoryContext: '昨日散步遇到了猫',
    );

    test('locale zh uses Chinese constitution, hard rules and reminders', () {
      final state = StateSnapshot.initial('local-user');
      final zhBuilder = const ModelPromptBuilder(
        customZhConstitution,
        personaConstitutionEn: customEnConstitution,
        persona: '用户昵称：小明',
        dailyState: '今天心情不错',
      );
      final messages = zhBuilder.build(
        state,
        '晚上好',
        locale: 'zh',
      );

      final system = messages.first.content;
      expect(system, contains(customZhConstitution));
      expect(system, contains('## 输出契约'));
      expect(system, contains('## 首个可见回应速度'));
      expect(system, contains('<persona>\n【用户画像】\n用户昵称：小明\n</persona>'));
      expect(system, contains('<daily_state>\n【近况】\n今天心情不错\n</daily_state>'));

      final reminder = messages[messages.length - 2].content;
      expect(reminder, contains('回复格式提醒：'));
      expect(reminder, contains('输出可见回复后'));

      expect(messages.last.content, '晚上好');
    });

    test('locale en uses English constitution, hard rules, reminders, and preserves Chinese memory', () {
      final state = StateSnapshot.initial('local-user');
      final messages = bilingualBuilder.build(
        state,
        'How was your day?',
        locale: 'en',
      );

      final system = messages.first.content;
      expect(system, contains(customEnConstitution));
      expect(system, contains('## Output Contract'));
      expect(system, contains('## First Visible Response Speed'));
      expect(system, contains('## Source Priority of Facts'));
      expect(system, contains('## Safety and Professional Boundaries'));
      expect(system, contains('standard Chinese abstraction to integrate with the Chinese memory ontology'));

      // Chinese memory blocks remain untouched in Chinese
      expect(system, contains('<persona>\n【用户画像】\n用户昵称：小明\n</persona>'));
      expect(system, contains('<daily_state>\n【近况】\n今天心情不错\n</daily_state>'));
      expect(system, contains('<long_memory>\n【长期印象】\n喜欢喝乌龙茶\n</long_memory>'));

      // Reminder before user message
      final reminder = messages[messages.length - 2].content;
      expect(reminder, contains('Reply format reminder:'));
      expect(reminder, contains('After visible reply'));

      // Context block attached to user message
      expect(messages.last.content, contains('<memory_context>\n【检索结果】\n昨日散步遇到了猫\n</memory_context>'));
      expect(messages.last.content, endsWith('How was your day?'));
    });
  });
}
