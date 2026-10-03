import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  group('实时版提示词装配（T03，T01 §9.7 变体 B 实测形态）', () {
    const constitution = '你是栖语。温暖但不讨好，聪明但不炫耀，安静但不冷淡。';
    const builder = ModelPromptBuilder(constitution);

    test('主协议块替换为实时工具指令，<qiyu-actions> 文本协议不再出现', () {
      final instructions = builder.buildRealtimeInstructions();
      expect(instructions, contains(constitution));
      expect(instructions, contains('<memory_actions>'));
      expect(instructions, contains(omniRealtimeActionsDirective));
      // 文本协议主块与格式提醒都不再进入实时 instructions：实时会话
      // 的动作经原生工具承载（T01 §9.7：并存时动作漏发/晚发）。
      expect(instructions, isNot(contains(hiddenActionsProtocolBlock.trim())));
      expect(instructions, isNot(contains(hiddenActionsReminder.trim())));
      expect(instructions, contains(omniRealtimeToolReminder));
    });

    test('动态记忆块与脱敏、空块不输出规则与聊天装配同源', () {
      final withBlocks = ModelPromptBuilder(
        constitution,
        dailyState: '【近日状态】\n明天要出门办事',
        longMemory: '用户叫林晚秋',
        persona: '称呼：晚秋',
      );
      final instructions = withBlocks.buildRealtimeInstructions();
      expect(instructions, contains('<daily_state>'));
      expect(instructions, contains('【近况】'));
      expect(instructions, contains('<long_memory>'));
      expect(instructions, contains('<persona>'));
      final empty = ModelPromptBuilder(constitution).buildRealtimeInstructions();
      expect(empty, isNot(contains('<daily_state>')));
      expect(empty, isNot(contains('<long_memory>')));
      expect(empty, isNot(contains('<persona>')));
      // 秘密脱敏先于外发：块内凭据不进 instructions。
      final secreted = ModelPromptBuilder(
        constitution,
        persona: 'api_key: sk-abcdefghijklmnopqrstuvwxyz123456',
      ).buildRealtimeInstructions();
      expect(secreted, isNot(contains('sk-abcdefghijklmnopqrstuvwxyz123456')));
    });

    test('聊天 build() 的文本协议不受实时变体影响（两条装配并存）', () {
      final chat = builder.build(
        StateSnapshot.initial('test'),
        '在吗',
      );
      expect(chat.first.content, contains(hiddenActionsProtocolBlock.trim()));
      expect(chat.first.content, isNot(contains(omniRealtimeActionsDirective)));
    });
  });

  group('实时动作工具集（T01 §9.7 actions_check 实测形状）', () {
    test('11 个同名扁平工具，no_action 不映射', () {
      final names = omniRealtimeMemoryTools.map((tool) => tool.name).toSet();
      expect(names, {
        'memory_signal',
        'open_loop_candidate',
        'open_loop_status',
        'memory_ban',
        'relationship_signal',
        'memory_forget',
        'memory_freeze',
        'memory_unfreeze',
        'memory_unban',
        'memory_delete',
        'memory_recall',
      });
      expect(omniRealtimeMemoryTools, hasLength(11));
      for (final tool in omniRealtimeMemoryTools) {
        final json = tool.toJson();
        expect(json['type'], 'function');
        expect(json['name'], tool.name);
        expect((json['parameters'] as Map<String, Object?>)['type'], 'object');
        // 扁平形状是唯一被服务端真实注册的形状（T01 §4）。
        expect(json.containsKey('function'), isFalse);
      }
    });

    test('session 配置携带全部工具进 payload（扁平 function 形状）', () {
      final config = OmniRealtimeSessionConfig(
        instructions: '你是栖语。',
        tools: omniRealtimeMemoryTools,
      );
      final payload = config.toSessionPayload();
      final tools = payload['tools']! as List<Map<String, Object?>>;
      expect(tools, hasLength(11));
      expect(tools.map((tool) => tool['name']), omniRealtimeMemoryTools.map((tool) => tool.name));
      for (final tool in tools) {
        expect(tool['type'], 'function');
      }
    });

    test('未注册工具时 session 配置不携带 tools 键', () {
      const config = OmniRealtimeSessionConfig(
        instructions: '你是栖语。',
        tools: [],
      );
      expect(config.toSessionPayload().containsKey('tools'), isFalse);
    });
  });
}
