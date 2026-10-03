import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:test/test.dart';

void main() {
  test('text without an action block passes through unchanged', () {
    final parse = parseHiddenActions('在。');

    expect(parse.visibleText, '在。');
    expect(parse.actions, isEmpty);
    expect(parse.diagnostics, isEmpty);
  });

  test(
    'a whitelisted memory signal is parsed and hidden from visible text',
    () {
      final parse = parseHiddenActions('''嗯，面试前紧张很正常。
<qiyu-actions>
[{"action":"memory_signal","summary":"用户明天有面试","evidence":"明天要面试，有点紧张"}]
</qiyu-actions>''');

      expect(parse.visibleText, '嗯，面试前紧张很正常。');
      expect(parse.actions, hasLength(1));
      final signal = parse.actions.single as MemorySignalAction;
      expect(signal.kind, HiddenActionKind.memorySignal);
      expect(signal.summary, '用户明天有面试');
      expect(signal.evidence, '明天要面试，有点紧张');
      expect(parse.diagnostics, isEmpty);
    },
  );

  test('recall and no-action complete the whitelist', () {
    final parse = parseHiddenActions('''在。
<qiyu-actions>[
  {"action":"memory_recall","query":"上次说的那本书"},
  {"action":"no_action"}
]</qiyu-actions>''');

    expect(parse.actions.map((action) => action.kind), [
      HiddenActionKind.memoryRecall,
      HiddenActionKind.noAction,
    ]);
    final recall = parse.actions.first as MemoryRecallAction;
    expect(recall.query, '上次说的那本书');
    // 聊天轮的检索请求不带选择字段。
    expect(recall.months, isNull);
    expect(recall.dates, isNull);
  });

  test('recall selections are format-checked and deduplicated', () {
    final parse = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_recall","query":"火锅店",'
      '"months":["2026-07","2026-07"],"dates":["2026-07-14","2026-7-14",'
      '"2026-07-14"]}]</qiyu-actions>',
    );

    expect(parse.actions, hasLength(1));
    final action = parse.actions.single as MemoryRecallAction;
    expect(action.query, '火锅店');
    expect(action.months, ['2026-07']);
    expect(action.dates, ['2026-07-14']);
    // 非法格式的项被丢弃并记诊断，合法项保留。
    expect(parse.diagnostics, [HiddenActionDiagnostics.invalidFields]);
  });

  test('recall selections are uncapped across months and dates', () {
    // 跨月跨年检索不设月份或日期数量上限（定稿）：全部合法选择保留。
    final dates = List.generate(40, (index) {
      final month = '${(index % 12) + 1}'.padLeft(2, '0');
      final day = '${(index % 28) + 1}'.padLeft(2, '0');
      return '"2026-$month-$day"';
    }).join(',');
    final parse = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_recall","query":"跨月查找",'
      '"dates":[$dates]}]</qiyu-actions>',
    );

    expect(parse.actions, hasLength(1));
    expect((parse.actions.single as MemoryRecallAction).dates, hasLength(40));
    expect(parse.diagnostics, isEmpty);
  });

  test('recall selection fields must be arrays', () {
    final parse = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_recall","query":"火锅店",'
      '"months":"2026-07"}]</qiyu-actions>',
    );

    expect(parse.actions, hasLength(1));
    expect((parse.actions.single as MemoryRecallAction).months, isNull);
    expect(parse.diagnostics, [HiddenActionDiagnostics.invalidFields]);
  });

  test('recall persona paths are format-checked, deduplicated and capped', () {
    final parse = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_recall","query":"跑步的习惯",'
      '"paths":["PR-R001/PR-M002","PR-R001/PR-M002","PR-R001/PR-M003",'
      '"PR-R001/PR-M004","PR-r001/PR-M002","PR-R001/PR-X002","PR-R001",'
      '"PR-R001/PR-M002/PR-L1"]}]</qiyu-actions>',
    );

    expect(parse.actions, hasLength(1));
    final action = parse.actions.single as MemoryRecallAction;
    // 合法路径去重后保留，第三条合法路径超出定稿上限整条丢弃。
    expect(action.paths, ['PR-R001/PR-M002', 'PR-R001/PR-M003']);
    // 四种非法形态各记一条 invalidFields，第三条合法路径记 overLimit。
    expect(
      parse.diagnostics.where(
        (entry) => entry == HiddenActionDiagnostics.invalidFields,
      ),
      hasLength(4),
    );
    expect(parse.diagnostics, contains(HiddenActionDiagnostics.overLimit));
  });

  test('recall persona paths carry at most two leaf pointers each', () {
    final parse = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_recall","query":"画像依据",'
      '"paths":["PR-R001/PR-M002/PR-L001,PR-L004,PR-L007"]}]</qiyu-actions>',
    );

    final action = parse.actions.single as MemoryRecallAction;
    // 叶指针截断到定稿的两条，根与中间理解保留。
    expect(action.paths, ['PR-R001/PR-M002/PR-L001,PR-L004']);
    expect(parse.diagnostics, [HiddenActionDiagnostics.invalidFields]);
  });

  test('recall persona path field must be an array', () {
    final parse = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_recall","query":"跑步",'
      '"paths":"PR-R001/PR-M002"}]</qiyu-actions>',
    );

    expect(parse.actions, hasLength(1));
    expect((parse.actions.single as MemoryRecallAction).paths, isNull);
    expect(parse.diagnostics, [HiddenActionDiagnostics.invalidFields]);
  });

  test('recall entry receipts are format-checked, deduplicated and capped', () {
    final ids = List.generate(
      maxHiddenRecallEntries + 1,
      (index) => '"seed:req:$index"',
    ).join(',');
    final parse = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_recall","query":"爬山",'
      '"entries":[$ids,"seed:req:0","bad id!"]}]</qiyu-actions>',
    );

    final action = parse.actions.single as MemoryRecallAction;
    expect(action.entries, hasLength(maxHiddenRecallEntries));
    expect(action.entries?.first, 'seed:req:0');
    expect(parse.diagnostics, contains(HiddenActionDiagnostics.invalidFields));
    expect(parse.diagnostics, contains(HiddenActionDiagnostics.overLimit));
  });

  test('secrets in recall queries stay on the privilege diagnostic', () {
    // 锁定行为：检索词命中秘密也记 privilegeViolation，而非 sensitiveContent。
    final parse = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_recall",'
      '"query":${_json('密码: hunter2abc')}}]</qiyu-actions>',
    );

    expect(parse.actions, isEmpty);
    expect(parse.diagnostics, [HiddenActionDiagnostics.privilegeViolation]);
  });

  test('unknown actions are dropped with diagnostics, valid ones kept', () {
    final parse = parseHiddenActions('''在。
<qiyu-actions>[
  {"action":"delete_memory","target":"everything"},
  {"action":"memory_signal","summary":"用户喜欢热牛奶"}
]</qiyu-actions>''');

    expect(parse.actions, hasLength(1));
    expect((parse.actions.single as MemorySignalAction).summary, '用户喜欢热牛奶');
    expect(parse.diagnostics, contains(HiddenActionDiagnostics.unknownAction));
  });

  test('malformed JSON is ignored entirely without touching visible text', () {
    final parse = parseHiddenActions('''在。
<qiyu-actions>{not json</qiyu-actions>''');

    expect(parse.visibleText, '在。');
    expect(parse.actions, isEmpty);
    expect(parse.diagnostics, [HiddenActionDiagnostics.invalidFormat]);
  });

  test('non-array payloads are rejected as invalid format', () {
    final parse = parseHiddenActions('''在。
<qiyu-actions>"memory_signal"</qiyu-actions>''');

    expect(parse.actions, isEmpty);
    expect(parse.diagnostics, [HiddenActionDiagnostics.invalidFormat]);
  });

  test('missing or oversized summaries fail field validation', () {
    final missing = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_signal"}]</qiyu-actions>',
    );
    expect(missing.actions, isEmpty);
    expect(missing.diagnostics, [HiddenActionDiagnostics.invalidFields]);

    final oversized = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_signal","summary":"${'长' * 121}"}]'
      '</qiyu-actions>',
    );
    expect(oversized.actions, isEmpty);
    expect(oversized.diagnostics, [HiddenActionDiagnostics.invalidFields]);
  });

  test('secrets never become memory signals', () {
    for (final summary in [
      '密码: hunter2abc',
      'api_key: sk-abcdefghijklmnopqrst',
      '身份证 11010519491231002X',
      '银行卡 6222 0202 0000 1234 567',
      '验证码: 482913',
      // JSON 引号键值：字段名带引号，冒号前多一个引号。
      '{"password":"audit-only-secret"}',
      r'{"client\u005fsecret":"audit-only-client"}',
      r'{"pass\u0077ord":987654321}',
      r'{"client_secret":"audit\q-secret"}',
      '{"client_secret":"audit-only-client"}',
      '{"password":987654321}',
      '{"access_token":123456}',
      '{"passwd":"audit-only-passwd"}',
      '{"api_secret":"audit-only-api"}',
      '{"secret_key":"audit-only-key"}',
      '{"set-cookie":"sid=audit-only-cookie"}',
      // PKCS#8：BEGIN 与 PRIVATE KEY 之间没有类型词。动作字段清洗后
      // 换行折叠为空格，这里按折叠后的形态验证。
      '-----BEGIN PRIVATE KEY----- AUDIT ONLY FAKE KEY -----END PRIVATE KEY-----',
    ]) {
      final parse = parseHiddenActions(
        '<qiyu-actions>[{"action":"memory_signal","summary":${_json(summary)}}]'
        '</qiyu-actions>',
      );
      expect(parse.actions, isEmpty, reason: summary);
      expect(
        parse.diagnostics,
        contains(HiddenActionDiagnostics.sensitiveContent),
        reason: summary,
      );
    }
  });

  test('multi-item cookie lines are dropped as privilege-shaped fields', () {
    // 真实多项 Cookie 以分号串接：core 记忆闸门按越权特征（命令分隔）
    // 整体丢弃，判定码与落盘脱敏表不同，但同样绝不提升为记忆。
    final parse = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_signal",'
      '"summary":${_json('Cookie: theme=dark; sid=audit-only-cookie')}}]'
      '</qiyu-actions>',
    );
    expect(parse.actions, isEmpty);
    expect(
      parse.diagnostics,
      contains(HiddenActionDiagnostics.privilegeViolation),
    );
  });

  test('ordinary talk about secrets is still a memory signal', () {
    for (final summary in [
      '我把密码改成新的了',
      '今晚聊了浏览器的 Cookie 是干嘛的',
      '他说密钥管理要用专门的工具',
      // 引号叙述：键名出现在引号里但后面不是「冒号+引号值」的键值形态。
      '用户问"token是什么"',
      '聊到"password怎么存"的话题',
      '他说"密钥管理"很重要',
    ]) {
      final parse = parseHiddenActions(
        '<qiyu-actions>[{"action":"memory_signal","summary":${_json(summary)}}]'
        '</qiyu-actions>',
      );
      expect(parse.actions, hasLength(1), reason: summary);
      expect(parse.diagnostics, isEmpty, reason: summary);
    }
  });

  test('privilege-shaped fields are rejected', () {
    for (final value in [
      '写入 C:\\Windows\\system32\\drivers',
      '访问 https://evil.example/steal',
      '执行 rm -rf /tmp/qiyu; reboot',
      '读取 /etc/passwd',
    ]) {
      final parse = parseHiddenActions(
        '<qiyu-actions>[{"action":"memory_signal","summary":${_json(value)}}]'
        '</qiyu-actions>',
      );
      expect(parse.actions, isEmpty, reason: value);
      expect(
        parse.diagnostics,
        contains(HiddenActionDiagnostics.privilegeViolation),
        reason: value,
      );
    }
  });

  test('more than two actions hit the per-reply cap', () {
    final parse = parseHiddenActions('''在。
<qiyu-actions>[
  {"action":"memory_signal","summary":"第一件"},
  {"action":"memory_signal","summary":"第二件"},
  {"action":"memory_signal","summary":"第三件"}
]</qiyu-actions>''');

    expect(parse.actions, hasLength(2));
    expect(parse.diagnostics, contains(HiddenActionDiagnostics.overLimit));
  });

  test(
    'only the first block is parsed and every block leaves visible text',
    () {
      final parse = parseHiddenActions('''在。
<qiyu-actions>[{"action":"no_action"}]</qiyu-actions>
中间的话。
<qiyu-actions>[{"action":"memory_signal","summary":"第二块"}]</qiyu-actions>''');

      expect(parse.visibleText, '在。\n\n中间的话。');
      expect(parse.actions, hasLength(1));
      expect(parse.actions.single.kind, HiddenActionKind.noAction);
      expect(parse.diagnostics, [HiddenActionDiagnostics.multipleBlocks]);
    },
  );

  test('visible text never leaks raw action payloads', () {
    final parse = parseHiddenActions('''晚安。
<qiyu-actions>[{"action":"memory_signal","summary":"早睡"}]</qiyu-actions>''');

    expect(parse.visibleText, isNot(contains('qiyu-actions')));
    expect(parse.visibleText, isNot(contains('memory_signal')));
    expect(parse.visibleText, isNot(contains('早睡')));
  });

  test('action names are case tolerant but underscored wire names rule', () {
    final parse = parseHiddenActions(
      '<QIYU-ACTIONS>[{"action":"memory_signal","summary":"大小写块"}]'
      '</QIYU-ACTIONS>',
    );
    expect(parse.visibleText, isEmpty);
    expect(parse.actions, hasLength(1));
  });

  test('an open-loop candidate keeps its four lifecycle fields', () {
    final parse = parseHiddenActions('''那到时候轻轻问一次。
<qiyu-actions>
[{"action":"open_loop_candidate","summary":"人生第一次演讲","due":"2026-07-05 晚上","proactive":"once","note":"用户说这是人生第一次演讲","evidence":"下周三是人生第一次演讲"}]
</qiyu-actions>''');

    expect(parse.visibleText, '那到时候轻轻问一次。');
    expect(parse.actions, hasLength(1));
    final action = parse.actions.single as OpenLoopCandidateAction;
    expect(action.kind, HiddenActionKind.openLoopCandidate);
    expect(action.title, '人生第一次演讲');
    expect(action.due, '2026-07-05 晚上');
    expect(action.proactive, LoopProactive.once);
    expect(action.note, '用户说这是人生第一次演讲');
    expect(action.evidence, '下周三是人生第一次演讲');
    expect(parse.diagnostics, isEmpty);
  });

  test('candidate due and proactive values are validated', () {
    final badDue = parseHiddenActions(
      '<qiyu-actions>[{"action":"open_loop_candidate","summary":"事项",'
      '"due":"下周三"}]</qiyu-actions>',
    );
    expect(badDue.actions, isEmpty);
    expect(badDue.diagnostics, [HiddenActionDiagnostics.invalidFields]);

    final badProactive = parseHiddenActions(
      '<qiyu-actions>[{"action":"open_loop_candidate","summary":"事项",'
      '"proactive":"always"}]</qiyu-actions>',
    );
    expect(badProactive.actions, isEmpty);
    expect(badProactive.diagnostics, [HiddenActionDiagnostics.invalidFields]);

    final bareDate = parseHiddenActions(
      '<qiyu-actions>[{"action":"open_loop_candidate","summary":"事项",'
      '"due":"2026-07-05"}]</qiyu-actions>',
    );
    expect(bareDate.actions, hasLength(1));
    expect(
      (bareDate.actions.single as OpenLoopCandidateAction).due,
      '2026-07-05',
    );
  });

  test('open-loop status changes require a valid target status', () {
    final parse = parseHiddenActions('''好。
<qiyu-actions>
[{"action":"open_loop_status","summary":"人生第一次演讲","status":"closed","result":"用户说演讲很顺利"}]
</qiyu-actions>''');
    expect(parse.actions, hasLength(1));
    final status = parse.actions.single as OpenLoopStatusAction;
    expect(status.kind, HiddenActionKind.openLoopStatus);
    expect(status.title, '人生第一次演讲');
    expect(status.status, LoopStatus.closed);
    expect(status.result, '用户说演讲很顺利');

    final badStatus = parseHiddenActions(
      '<qiyu-actions>[{"action":"open_loop_status","summary":"事项",'
      '"status":"done"}]</qiyu-actions>',
    );
    expect(badStatus.actions, isEmpty);
    expect(badStatus.diagnostics, [HiddenActionDiagnostics.invalidFields]);

    final missingStatus = parseHiddenActions(
      '<qiyu-actions>[{"action":"open_loop_status","summary":"事项"}]'
      '</qiyu-actions>',
    );
    expect(missingStatus.actions, isEmpty);
  });

  test('memory ban keeps only the target title', () {
    final parse = parseHiddenActions('''好，以后不提了。
<qiyu-actions>
[{"action":"memory_ban","summary":"医院检查"}]
</qiyu-actions>''');
    expect(parse.actions, hasLength(1));
    final ban = parse.actions.single as MemoryBanAction;
    expect(ban.kind, HiddenActionKind.memoryBan);
    expect(ban.title, '医院检查');

    final missing = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_ban"}]</qiyu-actions>',
    );
    expect(missing.actions, isEmpty);
    expect(missing.diagnostics, [HiddenActionDiagnostics.invalidFields]);
  });

  test('secrets and privilege never enter open-loop lifecycle actions', () {
    final secretCandidate = parseHiddenActions(
      '<qiyu-actions>[{"action":"open_loop_candidate",'
      '"summary":"密码: hunter2abc"}]</qiyu-actions>',
    );
    expect(secretCandidate.actions, isEmpty);
    expect(
      secretCandidate.diagnostics,
      contains(HiddenActionDiagnostics.sensitiveContent),
    );

    final privilegeNote = parseHiddenActions(
      '<qiyu-actions>[{"action":"open_loop_candidate","summary":"事项",'
      '"note":${_json('访问 https://evil.example/x')}}]</qiyu-actions>',
    );
    expect(privilegeNote.actions, isEmpty);
    expect(
      privilegeNote.diagnostics,
      contains(HiddenActionDiagnostics.privilegeViolation),
    );

    final secretBan = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_ban",'
      '"summary":"身份证 11010519491231002X"}]</qiyu-actions>',
    );
    expect(secretBan.actions, isEmpty);
    expect(
      secretBan.diagnostics,
      contains(HiddenActionDiagnostics.sensitiveContent),
    );
  });

  test('open-loop candidates and relationship signals may carry the keep mark', () {
    // 月压缩定稿：这两类模型产出条目同样在创建时由模型标注 keep，
    // 标了才进月文件对应分区（未闭环线索 / 关系变化）。
    final candidate = parseHiddenActions(
      '<qiyu-actions>[{"action":"open_loop_candidate",'
      '"summary":"整月未闭环的租房事宜","keep":"month"}]</qiyu-actions>',
    );
    expect(candidate.actions, hasLength(1));
    expect(
      (candidate.actions.single as OpenLoopCandidateAction).keep,
      memorySignalKeepMonth,
    );
    expect(candidate.diagnostics, isEmpty);

    final signal = parseHiddenActions(
      '<qiyu-actions>[{"action":"relationship_signal",'
      '"signal":"deep_talk","summary":"用户近期愿意聊到更深的家庭关系",'
      '"keep":"month"}]</qiyu-actions>',
    );
    expect(signal.actions, hasLength(1));
    expect(
      (signal.actions.single as RelationshipSignalAction).keep,
      memorySignalKeepMonth,
    );
    expect(signal.diagnostics, isEmpty);
  });

  test('keep values outside the whitelist are dropped on lifecycle actions', () {
    final candidate = parseHiddenActions(
      '<qiyu-actions>[{"action":"open_loop_candidate",'
      '"summary":"普通待办","keep":"day"}]</qiyu-actions>',
    );
    expect(candidate.actions, hasLength(1));
    expect((candidate.actions.single as OpenLoopCandidateAction).keep, isNull);
    expect(candidate.diagnostics, [HiddenActionDiagnostics.invalidFields]);

    final signal = parseHiddenActions(
      '<qiyu-actions>[{"action":"relationship_signal",'
      '"signal":"temperature","summary":"今晚话少","keep":"week"}]'
      '</qiyu-actions>',
    );
    expect(signal.actions, hasLength(1));
    expect((signal.actions.single as RelationshipSignalAction).keep, isNull);
    expect(signal.diagnostics, [HiddenActionDiagnostics.invalidFields]);

    // 没有 keep 字段时不产生诊断。
    final plain = parseHiddenActions(
      '<qiyu-actions>[{"action":"open_loop_candidate","summary":"普通待办"}]'
      '</qiyu-actions>',
    );
    expect((plain.actions.single as OpenLoopCandidateAction).keep, isNull);
    expect(plain.diagnostics, isEmpty);
  });

  test('a relationship signal keeps its whitelisted signal type', () {
    final parse = parseHiddenActions('''嗯，我在。
<qiyu-actions>
[{"action":"relationship_signal","signal":"deep_talk","summary":"用户近期愿意聊到更深的家庭关系"}]
</qiyu-actions>''');

    expect(parse.visibleText, '嗯，我在。');
    expect(parse.actions, hasLength(1));
    final signal = parse.actions.single as RelationshipSignalAction;
    expect(signal.kind, HiddenActionKind.relationshipSignal);
    expect(signal.signal, RelationshipSignal.deepTalk);
    expect(signal.summary, '用户近期愿意聊到更深的家庭关系');
    expect(parse.diagnostics, isEmpty);
  });

  test('relationship signals validate signal type and summary', () {
    final badSignal = parseHiddenActions(
      '<qiyu-actions>[{"action":"relationship_signal","signal":"mood",'
      '"summary":"用户心情不好"}]</qiyu-actions>',
    );
    expect(badSignal.actions, isEmpty);
    expect(badSignal.diagnostics, [HiddenActionDiagnostics.invalidFields]);

    final missingSignal = parseHiddenActions(
      '<qiyu-actions>[{"action":"relationship_signal",'
      '"summary":"用户心情不好"}]</qiyu-actions>',
    );
    expect(missingSignal.actions, isEmpty);

    final missingSummary = parseHiddenActions(
      '<qiyu-actions>[{"action":"relationship_signal",'
      '"signal":"temperature"}]</qiyu-actions>',
    );
    expect(missingSummary.actions, isEmpty);

    final oversized = parseHiddenActions(
      '<qiyu-actions>[{"action":"relationship_signal",'
      '"signal":"deep_talk","summary":"${'深' * 61}"}]</qiyu-actions>',
    );
    expect(oversized.actions, isEmpty);
    expect(oversized.diagnostics, [HiddenActionDiagnostics.invalidFields]);
  });

  test('boundary signals require evidence and one per reply', () {
    // 边界开合投影进「当前相处方式」，定稿要求每条带依据。
    final missingEvidence = parseHiddenActions(
      '<qiyu-actions>[{"action":"relationship_signal",'
      '"signal":"boundary_close","summary":"用户回避了医院话题"}]</qiyu-actions>',
    );
    expect(missingEvidence.actions, isEmpty);
    expect(missingEvidence.diagnostics, [
      HiddenActionDiagnostics.invalidFields,
    ]);

    final withEvidence = parseHiddenActions(
      '<qiyu-actions>[{"action":"relationship_signal",'
      '"signal":"boundary_open","summary":"用户接受了轻调侃",'
      '"evidence":"被调侃后反逗了一句"}]</qiyu-actions>',
    );
    expect(withEvidence.actions, hasLength(1));

    // 一轮最多一个 relationship_signal：第二条丢弃并记诊断。
    final duplicate = parseHiddenActions(
      '<qiyu-actions>[{"action":"relationship_signal","signal":"deep_talk",'
      '"summary":"愿意聊家庭"},{"action":"relationship_signal",'
      '"signal":"temperature","summary":"今晚话少"}]</qiyu-actions>',
    );
    expect(duplicate.actions, hasLength(1));
    expect(
      (duplicate.actions.single as RelationshipSignalAction).summary,
      '愿意聊家庭',
    );
    expect(duplicate.diagnostics, [
      HiddenActionDiagnostics.duplicateRelationshipSignal,
    ]);
  });

  test('a memory signal may carry a valid persona hint', () {
    final parse = parseHiddenActions('''嗯，记下了。
<qiyu-actions>
[{"action":"memory_signal","summary":"用户养了一只叫米子的猫","branch":"identity","nature":"self_report"}]
</qiyu-actions>''');

    expect(parse.actions, hasLength(1));
    final signal = parse.actions.single as MemorySignalAction;
    expect(signal.kind, HiddenActionKind.memorySignal);
    expect(signal.hint?.branch, PersonaTreeBranch.identity);
    expect(signal.hint?.nature, PersonaNature.selfReport);
    expect(parse.diagnostics, isEmpty);
  });

  test('invalid persona hints are dropped but the memory signal survives', () {
    // 未知分支：丢提示、留记忆。
    final unknownBranch = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_signal","summary":"用户喜欢爬山",'
      '"branch":"hobby","nature":"behavior"}]</qiyu-actions>',
    );
    expect(unknownBranch.actions, hasLength(1));
    expect(
      (unknownBranch.actions.single as MemorySignalAction).summary,
      '用户喜欢爬山',
    );
    expect((unknownBranch.actions.single as MemorySignalAction).hint, isNull);
    expect(unknownBranch.diagnostics, [
      HiddenActionDiagnostics.personaHintDropped,
    ]);

    // 只有 branch 没有 nature：同样丢提示。
    final missingNature = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_signal","summary":"用户喜欢爬山",'
      '"branch":"preferences"}]</qiyu-actions>',
    );
    expect(missingNature.actions, hasLength(1));
    expect((missingNature.actions.single as MemorySignalAction).hint, isNull);
    expect(missingNature.diagnostics, [
      HiddenActionDiagnostics.personaHintDropped,
    ]);

    // 身份事实禁止行为推断：丢提示。
    final identityBehavior = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_signal","summary":"用户像是老师",'
      '"branch":"identity","nature":"behavior"}]</qiyu-actions>',
    );
    expect(identityBehavior.actions, hasLength(1));
    expect(
      (identityBehavior.actions.single as MemorySignalAction).hint,
      isNull,
    );
    expect(identityBehavior.diagnostics, [
      HiddenActionDiagnostics.personaHintDropped,
    ]);

    // 没有画像提示时不产生诊断。
    final noHint = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_signal","summary":"用户喜欢爬山"}]'
      '</qiyu-actions>',
    );
    expect((noHint.actions.single as MemorySignalAction).hint, isNull);
    expect(noHint.diagnostics, isEmpty);
  });

  test('a memory signal may carry the month keep mark', () {
    // 月压缩定稿（Memory.md）：只收当时标了 keep: month 的条目。
    final parse = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_signal",'
      '"summary":"用户认定长期记忆只放极度压缩的人生记忆","keep":"month"}]'
      '</qiyu-actions>',
    );

    expect(parse.actions, hasLength(1));
    final signal = parse.actions.single as MemorySignalAction;
    expect(signal.keep, memorySignalKeepMonth);
    expect(parse.diagnostics, isEmpty);
  });

  test('keep values outside the whitelist are dropped, signal survives', () {
    // 白名单外取值（含笔记里其余 keep 值的字面量）按字段丢弃并记诊断，
    // 记忆信号本身保留：那些流向由 kind、提升流程与 memory_ban 各自
    // 承担，不走 keep 字段。
    for (final value in ['day', 'open-loop', 'relationship', 'week', 'MONTH']) {
      final parse = parseHiddenActions(
        '<qiyu-actions>[{"action":"memory_signal",'
        '"summary":"用户喜欢爬山","keep":${_json(value)}}]</qiyu-actions>',
      );
      expect(parse.actions, hasLength(1));
      expect((parse.actions.single as MemorySignalAction).keep, isNull);
      expect(parse.diagnostics, [HiddenActionDiagnostics.invalidFields]);
    }

    // 非字符串取值与字段缺失同效：按未标记处理，不记诊断（与画像
    // 提示、proactive 等可选枚举字段的口径一致）。
    final numeric = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_signal",'
      '"summary":"用户喜欢爬山","keep":5}]</qiyu-actions>',
    );
    expect(numeric.actions, hasLength(1));
    expect((numeric.actions.single as MemorySignalAction).keep, isNull);
    expect(numeric.diagnostics, isEmpty);

    // 没有 keep 字段时不产生诊断。
    final absent = parseHiddenActions(
      '<qiyu-actions>[{"action":"memory_signal","summary":"用户喜欢爬山"}]'
      '</qiyu-actions>',
    );
    expect((absent.actions.single as MemorySignalAction).keep, isNull);
    expect(absent.diagnostics, isEmpty);
  });

  test('secrets and privilege never enter relationship signals', () {
    final secret = parseHiddenActions(
      '<qiyu-actions>[{"action":"relationship_signal",'
      '"signal":"deep_talk","summary":"密码: hunter2abc"}]</qiyu-actions>',
    );
    expect(secret.actions, isEmpty);
    expect(
      secret.diagnostics,
      contains(HiddenActionDiagnostics.sensitiveContent),
    );

    final privilege = parseHiddenActions(
      '<qiyu-actions>[{"action":"relationship_signal",'
      '"signal":"boundary_open","summary":"用户接受了调侃",'
      '"evidence":${_json('访问 https://evil.example/x')}}]</qiyu-actions>',
    );
    expect(privilege.actions, isEmpty);
    expect(
      privilege.diagnostics,
      contains(HiddenActionDiagnostics.privilegeViolation),
    );
  });

  group('parser emits the sealed typed models', () {
    test('every kind lands on its exact typed shape', () {
      final parse = parseHiddenActions('''都在。
<qiyu-actions>[
  {"action":"memory_signal","summary":"用户养了一只叫米子的猫","evidence":"我家米子","branch":"identity","nature":"self_report"},
  {"action":"memory_recall","query":"火锅店","months":["2026-07"],"dates":["2026-07-14"]}
]</qiyu-actions>''');

      final signal = parse.actions.first;
      expect(signal, isA<MemorySignalAction>());
      signal as MemorySignalAction;
      expect(signal.summary, '用户养了一只叫米子的猫');
      expect(signal.evidence, '我家米子');
      expect(
        signal.hint,
        const PersonaHint(
          branch: PersonaTreeBranch.identity,
          nature: PersonaNature.selfReport,
        ),
      );

      final recall = parse.actions.last;
      expect(recall, isA<MemoryRecallAction>());
      recall as MemoryRecallAction;
      expect(recall.query, '火锅店');
      expect(recall.months, ['2026-07']);
      expect(recall.dates, ['2026-07-14']);

      final rest = parseHiddenActions('''好。
<qiyu-actions>[
  {"action":"no_action"},
  {"action":"open_loop_candidate","summary":"人生第一次演讲","due":"2026-07-05 晚上","proactive":"once","note":"用户说这是人生第一次演讲","evidence":"下周三是人生第一次演讲"}
]</qiyu-actions>''');
      expect(rest.actions.first, const NoAction());
      expect(
        rest.actions.last,
        const OpenLoopCandidateAction(
          title: '人生第一次演讲',
          evidence: '下周三是人生第一次演讲',
          due: '2026-07-05 晚上',
          proactive: LoopProactive.once,
          note: '用户说这是人生第一次演讲',
        ),
      );

      final status = parseHiddenActions(
        '<qiyu-actions>[{"action":"open_loop_status",'
        '"summary":"人生第一次演讲","status":"closed",'
        '"result":"用户说演讲很顺利"}]</qiyu-actions>',
      );
      expect(
        status.actions.single,
        const OpenLoopStatusAction(
          title: '人生第一次演讲',
          status: LoopStatus.closed,
          result: '用户说演讲很顺利',
        ),
      );

      final controls = parseHiddenActions('''好。
<qiyu-actions>[
  {"action":"memory_ban","summary":"医院检查"},
  {"action":"memory_forget","summary":"今晚的争吵"}
]</qiyu-actions>''');
      expect(controls.actions.first, const MemoryBanAction(title: '医院检查'));
      expect(controls.actions.last, const MemoryForgetAction(title: '今晚的争吵'));

      final moreControls = parseHiddenActions('''好。
<qiyu-actions>[
  {"action":"memory_freeze","summary":"换工作话题"},
  {"action":"memory_unfreeze","summary":"换工作话题"}
]</qiyu-actions>''');
      expect(
        moreControls.actions.first,
        const MemoryFreezeAction(title: '换工作话题'),
      );
      expect(
        moreControls.actions.last,
        const MemoryUnfreezeAction(title: '换工作话题'),
      );

      final delete = parseHiddenActions(
        '<qiyu-actions>[{"action":"memory_delete","summary":"医院检查"}]'
        '</qiyu-actions>',
      );
      expect(delete.actions.single, const MemoryDeleteAction(title: '医院检查'));

      final unban = parseHiddenActions(
        '<qiyu-actions>[{"action":"memory_unban","summary":"换工作话题"}]'
        '</qiyu-actions>',
      );
      expect(unban.actions.single, const MemoryUnbanAction(title: '换工作话题'));
      expect(unban.diagnostics, isEmpty);

      final relationship = parseHiddenActions(
        '<qiyu-actions>[{"action":"relationship_signal",'
        '"signal":"boundary_open","summary":"用户接受了轻调侃",'
        '"evidence":"被调侃后反逗了一句"}]</qiyu-actions>',
      );
      expect(
        relationship.actions.single,
        const RelationshipSignalAction(
          summary: '用户接受了轻调侃',
          signal: RelationshipSignal.boundaryOpen,
          evidence: '被调侃后反逗了一句',
        ),
      );
    });

    test('invalid persona hints leave the typed hint absent', () {
      final parse = parseHiddenActions(
        '<qiyu-actions>[{"action":"memory_signal","summary":"用户像是老师",'
        '"branch":"identity","nature":"behavior"}]</qiyu-actions>',
      );
      final signal = parse.actions.single;
      expect(signal, isA<MemorySignalAction>());
      expect((signal as MemorySignalAction).hint, isNull);
      expect(parse.diagnostics, [HiddenActionDiagnostics.personaHintDropped]);
    });

    test('trailing unclosed action block is stripped from visible text with invalidFormat diagnostic', () {
      final parse = parseHiddenActions(
        '明天天气很好。\n<qiyu-actions>[{"action":"memory_recall","query":"天气"',
      );
      expect(parse.visibleText, '明天天气很好。');
      expect(parse.actions, isEmpty);
      expect(parse.diagnostics, [HiddenActionDiagnostics.invalidFormat]);
    });
  });

  group('单动作对象校验入口（Omni 实时原生工具参数，T03）', () {
    test('合法动作按隐藏块同一套规则通过', () {
      final diagnostics = <String>[];
      final action = parseHiddenActionObject('memory_signal', {
        'summary': '用户对芒果过敏',
        'evidence': '我对芒果过敏',
        'keep': 'month',
      }, diagnostics);
      expect(action, const MemorySignalAction(
        summary: '用户对芒果过敏',
        evidence: '我对芒果过敏',
        keep: 'month',
      ));
      expect(diagnostics, isEmpty);
    });

    test('控制动作与回收动作同样成立', () {
      final diagnostics = <String>[];
      final ban = parseHiddenActionObject('memory_ban', {
        'summary': '芒果过敏相关话题',
      }, diagnostics);
      expect(ban, const MemoryBanAction(title: '芒果过敏相关话题'));
      final recall = parseHiddenActionObject('memory_recall', {
        'query': '梧桐里',
      }, diagnostics);
      expect(recall, isA<MemoryRecallAction>());
      expect(diagnostics, isEmpty);
    });

    test('缺必填字段、超限与未知动作整体丢弃并记诊断', () {
      final missing = <String>[];
      expect(
        parseHiddenActionObject('memory_signal', {}, missing),
        isNull,
      );
      expect(missing, [HiddenActionDiagnostics.invalidFields]);

      final overLimit = <String>[];
      parseHiddenActionObject('memory_ban', {
        'summary': '长' * 80,
      }, overLimit);
      expect(overLimit, [HiddenActionDiagnostics.invalidFields]);

      final unknown = <String>[];
      parseHiddenActionObject('not_a_tool', {'summary': 'x'}, unknown);
      expect(unknown, [HiddenActionDiagnostics.unknownAction]);
    });

    test('秘密与越权字段被拒（与隐藏块同闸门）', () {
      final secret = <String>[];
      parseHiddenActionObject('memory_signal', {
        'summary': '我的密钥',
        'evidence': 'api_key: sk-abcdefghijklmnopqrstuvwx',
      }, secret);
      expect(secret, [HiddenActionDiagnostics.sensitiveContent]);

      final privilege = <String>[];
      parseHiddenActionObject('memory_recall', {
        'query': '访问 https://evil.example/x',
      }, privilege);
      expect(privilege, [HiddenActionDiagnostics.privilegeViolation]);
    });

    test('参数混入 action 键以工具名为准，不参与动作分型', () {
      final diagnostics = <String>[];
      final action = parseHiddenActionObject('memory_signal', {
        'action': 'memory_ban',
        'summary': '用户对芒果过敏',
      }, diagnostics);
      // 工具名派生分型：调用的是 memory_signal，参数里的 action 键
      // 是外来噪声，不得把记录动作变成禁提控制。
      expect(action, isA<MemorySignalAction>());
      expect(action, isNot(isA<MemoryBanAction>()));
      expect(diagnostics, isEmpty);
    });

    test('与隐藏块解析同一段内容等价（同一校验器）', () {
      final viaBlock = parseHiddenActions(
        '<qiyu-actions>[{"action":"memory_signal",'
        '"summary":"用户对芒果过敏","evidence":"我对芒果过敏"}]</qiyu-actions>',
      );
      final viaObject = <String>[];
      final action = parseHiddenActionObject('memory_signal', {
        'summary': '用户对芒果过敏',
        'evidence': '我对芒果过敏',
      }, viaObject);
      expect(viaObject, isEmpty);
      expect(action, viaBlock.actions.single);
    });
  });
}

String _json(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
