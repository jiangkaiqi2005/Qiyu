import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/scripted_chat_client.dart';

void main() {
  group('memory alias expansion', () {
    test('configured model aliases join the control scope', () async {
      final client = ScriptedChatClient([
        const ModelCompletion.reply('["跳槽","离职","换东家"]'),
      ]);

      final aliases = await expandMemoryAliases(client, '换工作');

      expect(aliases, ['跳槽', '离职', '换东家']);
      // 一次有界调用：系统提示交代任务，用户消息只带目标摘要。
      expect(client.calls, hasLength(1));
      expect(client.calls.single.first.role, ModelMessageRole.system);
      expect(client.calls.single.last.content, contains('换工作'));
      expect(client.maxTokens.single, 200);
    });

    test('no configured client degrades to no aliases', () async {
      expect(await expandMemoryAliases(null, '换工作'), isEmpty);
    });

    test('provider failure degrades to no aliases', () async {
      // 调用失败（text 为 null）：控制本身不受影响。
      final client = ScriptedChatClient([
        const ModelCompletion.failure(ModelFailureKind.provider),
      ]);
      expect(await expandMemoryAliases(client, '换工作'), isEmpty);

      // 客户端抛异常同样静默退回。
      final throwing = _ThrowingClient();
      expect(await expandMemoryAliases(throwing, '换工作'), isEmpty);
    });

    test('empty and out-of-shape outputs degrade to no aliases', () async {
      for (final raw in const [
        '',
        '[]',
        '{"aliases":["跳槽"]}',
        '不是 JSON',
        '["跳槽", 42, null]',
      ]) {
        final client = ScriptedChatClient([ModelCompletion.reply(raw)]);
        expect(
          await expandMemoryAliases(client, '换工作'),
          raw == '["跳槽", 42, null]' ? ['跳槽'] : isEmpty,
          reason: raw,
        );
      }
    });

    test('aliases are capped, trimmed, deduped and shape-cleaned', () async {
      final client = ScriptedChatClient([
        const ModelCompletion.reply(
          '["  跳槽  ","跳槽","换工作","离职","换东家","挪窝","下岗","太长'
          '的别名直接超过三十个字符上限应当被丢弃abcdefghijklmnopqrstuvwxyz"]',
        ),
      ]);

      final aliases = await expandMemoryAliases(client, '换工作');

      // 上限 5 条；与主摘要等价的项去掉；重复项折叠；超长项丢弃。
      expect(aliases, ['跳槽', '离职', '换东家', '挪窝', '下岗']);
    });

    test('newlines and pipes never reach the stored line format', () async {
      final client = ScriptedChatClient([
        const ModelCompletion.reply('["跳槽\\n下周","离|职"]'),
      ]);

      final aliases = await expandMemoryAliases(client, '换工作');

      expect(aliases, ['跳槽 下周', '离 职']);
    });

    test('empty summaries skip the call entirely', () async {
      final client = ScriptedChatClient([const ModelCompletion.reply('["x"]')]);
      expect(await expandMemoryAliases(client, '   '), isEmpty);
      expect(client.calls, isEmpty);
    });
  });
}

final class _ThrowingClient implements ProviderChatClient {
  @override
  Future<ModelCompletion?> complete(
    List<ModelMessage> messages, {
    int? maxTokens,
  }) async => throw const ModelGatewayException(
    kind: ModelFailureKind.network,
    message: '脚本故障',
  );
}
