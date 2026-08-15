import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:test/test.dart';

void main() {
  test('text without an action block passes through unchanged', () {
    final parse = parseHiddenActions('在。');

    expect(parse.visibleText, '在。');
    expect(parse.actions, isEmpty);
    expect(parse.diagnostics, isEmpty);
  });

  test('a whitelisted memory signal is parsed and hidden from visible text', () {
    final parse = parseHiddenActions('''嗯，面试前紧张很正常。
<qiyu-actions>
[{"action":"memory_signal","summary":"用户明天有面试","evidence":"明天要面试，有点紧张"}]
</qiyu-actions>''');

    expect(parse.visibleText, '嗯，面试前紧张很正常。');
    expect(parse.actions, hasLength(1));
    expect(parse.actions.single.kind, HiddenActionKind.memorySignal);
    expect(parse.actions.single.summary, '用户明天有面试');
    expect(parse.actions.single.evidence, '明天要面试，有点紧张');
    expect(parse.diagnostics, isEmpty);
  });

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
    expect(parse.actions.first.query, '上次说的那本书');
  });

  test('unknown actions are dropped with diagnostics, valid ones kept', () {
    final parse = parseHiddenActions('''在。
<qiyu-actions>[
  {"action":"delete_memory","target":"everything"},
  {"action":"memory_signal","summary":"用户喜欢热牛奶"}
]</qiyu-actions>''');

    expect(parse.actions, hasLength(1));
    expect(parse.actions.single.summary, '用户喜欢热牛奶');
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

  test('only the first block is parsed and every block leaves visible text', () {
    final parse = parseHiddenActions('''在。
<qiyu-actions>[{"action":"no_action"}]</qiyu-actions>
中间的话。
<qiyu-actions>[{"action":"memory_signal","summary":"第二块"}]</qiyu-actions>''');

    expect(parse.visibleText, '在。\n\n中间的话。');
    expect(parse.actions, hasLength(1));
    expect(parse.actions.single.kind, HiddenActionKind.noAction);
    expect(parse.diagnostics, [HiddenActionDiagnostics.multipleBlocks]);
  });

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
    final action = parse.actions.single;
    expect(action.kind, HiddenActionKind.openLoopCandidate);
    expect(action.summary, '人生第一次演讲');
    expect(action.due, '2026-07-05 晚上');
    expect(action.proactive, 'once');
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
    expect(bareDate.actions.single.due, '2026-07-05');
  });

  test('open-loop status changes require a valid target status', () {
    final parse = parseHiddenActions('''好。
<qiyu-actions>
[{"action":"open_loop_status","summary":"人生第一次演讲","status":"closed","result":"用户说演讲很顺利"}]
</qiyu-actions>''');
    expect(parse.actions, hasLength(1));
    final action = parse.actions.single;
    expect(action.kind, HiddenActionKind.openLoopStatus);
    expect(action.summary, '人生第一次演讲');
    expect(action.status, 'closed');
    expect(action.result, '用户说演讲很顺利');

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
    expect(parse.actions.single.kind, HiddenActionKind.memoryBan);
    expect(parse.actions.single.summary, '医院检查');

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

  test('a relationship signal keeps its whitelisted signal type', () {
    final parse = parseHiddenActions('''嗯，我在。
<qiyu-actions>
[{"action":"relationship_signal","signal":"deep_talk","summary":"用户近期愿意聊到更深的家庭关系"}]
</qiyu-actions>''');

    expect(parse.visibleText, '嗯，我在。');
    expect(parse.actions, hasLength(1));
    final action = parse.actions.single;
    expect(action.kind, HiddenActionKind.relationshipSignal);
    expect(action.signal, 'deep_talk');
    expect(action.summary, '用户近期愿意聊到更深的家庭关系');
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
    expect(missingEvidence.diagnostics, [HiddenActionDiagnostics.invalidFields]);

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
    expect(duplicate.actions.single.summary, '愿意聊家庭');
    expect(
      duplicate.diagnostics,
      [HiddenActionDiagnostics.duplicateRelationshipSignal],
    );
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
}

String _json(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
