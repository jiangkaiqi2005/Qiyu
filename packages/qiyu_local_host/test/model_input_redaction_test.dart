import 'dart:io';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/scripted_chat_client.dart';

/// 模型输入脱敏的收口回归锁（ticket 01 第二轮审查）：Dream 与日终
/// 理解的模型调用都把旧规则时代可能残留秘密的记忆材料拼进提示，
/// 这里在服务级接缝钉住「发给模型的输入不含样例秘密」。全部为固定
/// 合成文本，不含任何真实秘密。
void main() {
  group('Dream 模型输入', () {
    test('日摘要与关系档案里的秘密不外发', () async {
      final directory = await Directory.systemTemp.createTemp(
        'qiyu-dream-redaction-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final now = DateTime(2026, 8, 15, 23, 10);
      final pipeline = EpisodeMemoryPipeline(
        memoryDirectory: directory.path,
        clock: () => now,
      );
      // 手写「旧规则时代」的已归档日文件：元数据摘要带键值秘密。
      final at = DateTime.parse('2026-08-05T20:00:00Z').toUtc();
      final meta = encodeMarkerPayload({
        'schemaVersion': 1,
        'date': '2026-08-05',
        'updatedAt': at.toIso8601String(),
        'summary': '服务器密码：{"password":"audit-only-dream"}',
        'finalized': true,
        'finalizedAt': DateTime.parse(
          '2026-08-05T23:00:00Z',
        ).toUtc().toIso8601String(),
      });
      File(
        '${directory.path}/episodes/2026/08/2026-08-05.md',
      )
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '# 栖语每日记录\n\n<!-- qiyu-episode:$meta -->\n\n'
          '## summary\n服务器密码：{"password":"audit-only-dream"}\n\n',
          flush: true,
        );
      // 关系档案：整行 Cookie 形态的秘密。
      File('${directory.path}/relationship.md').writeAsStringSync(
        '# 关系\n\n- 用户提到 Cookie: sid=audit-only-dream-cookie\n',
        flush: true,
      );
      // 称呼含秘密样式文本：限长内、无控制字符，格式校验放行。
      File(
        '${directory.path}/persona.md',
      ).writeAsStringSync('# 用户画像\n\n称呼：sk-abcdef1234567890\n');
      final client = ScriptedChatClient([
        ModelCompletion.reply(
          '{"items":[{"section":"重要事件","text":"用户状态平稳",'
          '"evidence":["2026-08-05"]}]}',
        ),
      ]);
      final dream = DreamService(
        memoryDirectory: directory.path,
        episodePipeline: pipeline,
        personaTree: PersonaTreeStore(
          memoryDirectory: directory.path,
          episodePipeline: pipeline,
          diagnosticsSink: (_) {},
        ),
        modelClient: client,
        clock: () => now,
        diagnosticsSink: (_) {},
      );

      final outcome = await dream.run(bedtime: true);

      expect(outcome.status, DreamStatus.accepted);
      expect(client.calls, hasLength(1));
      // 系统提示里的称呼与整块输入一样先过脱敏。
      final systemMessage = client.calls.single.first.content;
      expect(systemMessage, contains('称呼'));
      expect(systemMessage, isNot(contains('sk-abcdef1234567890')));
      for (final message in client.calls.single) {
        expect(
          message.content,
          isNot(contains('audit-only-dream')),
          reason: message.content,
        );
      }
    });
  });

  group('日终理解模型输入', () {
    test('待补轮文本发给模型前脱敏，待补标识保持原样', () async {
      final client = ScriptedChatClient([ModelCompletion.reply('{}')]);
      final at = DateTime.parse('2026-08-10T14:00:00Z').toUtc();
      final session = RawSession(
        id: 'legacy-understanding-session',
        date: '2026-08-10',
        segment: 1,
        createdAt: at,
        updatedAt: at,
        turns: [
          RawSessionTurn.user(
            requestId: 'legacy-u1',
            text: '{"client_secret":"audit-only-understanding",'
                '"cookie":"sid=audit-only-cookie; refresh=audit-only-refresh",'
                '"password":987654321,"count":42}',
            at: at,
          ),
        ],
      );

      await fetchDayUnderstanding(
        client: client,
        date: '2026-08-10',
        entries: const [],
        openLoops: null,
        relationship: null,
        dailyState: null,
        sessions: [session],
        pendingRequestIds: {'legacy-u1'},
        bannedTitles: const {},
        diagnosticsSink: (_) {},
      );

      expect(client.calls, hasLength(1));
      final userMessage = client.calls.single.last.content;
      // 待补标识必须原样保留（补建覆盖校验依赖模型原样回抄）。
      expect(userMessage, contains('legacy-u1'));
      expect(userMessage, isNot(contains('audit-only-understanding')));
      expect(userMessage, isNot(contains('audit-only-cookie')));
      expect(userMessage, isNot(contains('audit-only-refresh')));
      expect(userMessage, isNot(contains('987654321')));
      expect(userMessage, contains('[已脱敏]'));
    });

    test('系统提示里的称呼不外发', () async {
      final client = ScriptedChatClient([ModelCompletion.reply('{}')]);

      await fetchDayUnderstanding(
        client: client,
        date: '2026-08-10',
        entries: const [],
        openLoops: null,
        relationship: null,
        dailyState: null,
        sessions: const [],
        pendingRequestIds: const <String>{},
        bannedTitles: const {},
        appellation: 'sk-abcdef1234567890',
        diagnosticsSink: (_) {},
      );

      expect(client.calls, hasLength(1));
      final systemMessage = client.calls.single.first.content;
      expect(systemMessage, contains('用称呼「[已脱敏]」'));
      expect(systemMessage, isNot(contains('sk-abcdef1234567890')));
    });
  });
}
