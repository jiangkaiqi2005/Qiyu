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
}

String _json(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
