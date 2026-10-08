import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'qwen_omni_realtime_gateway.dart';

/// Omni 实时会话的原生函数工具集（T03）：聊天轮隐藏动作全集按 wire 名
/// 注册为同名扁平 function 工具，no_action 不映射——原生会话里不调用
/// 任何工具即等价。schema 镜像 T01 §9.7 actions_check 实测形状（扁平
/// `{type,name,description,parameters}`，字段与隐藏块协议同名同义）；
/// 参数合法性（限长、枚举、越权、秘密）不在 schema 侧放行或拒绝，
/// 统一由行为核心 [parseHiddenActionObject] 校验后落地。
final List<OmniRealtimeTool> omniRealtimeMemoryTools = [
  OmniRealtimeTool(
    name: 'memory_signal',
    description: '记录本轮出现的具体用户信息（事实概括+原话摘录）。',
    parameters: {
      'type': 'object',
      'properties': {
        'summary': {
          'type': 'string',
          'description': '不超过60字的事实概括',
        },
        'evidence': {
          'type': 'string',
          'description': '用户原话摘录，不超过80字',
        },
        'keep': {
          'type': 'string',
          'enum': [memorySignalKeepMonth],
          'description': '仅当值得进入月压缩的长期记忆时填 month',
        },
      },
      'required': ['summary'],
    },
  ),
  OmniRealtimeTool(
    name: 'open_loop_candidate',
    description: '用户明确提到、真正未完且以后值得跟进的事项。',
    parameters: {
      'type': 'object',
      'properties': {
        'summary': {'type': 'string', 'description': '事项简称'},
        'due': {
          'type': 'string',
          'description': 'YYYY-MM-DD 时段，可省略',
        },
        'proactive': {
          'type': 'string',
          // 枚举取自行为核心白名单（hidden_actions.dart），不平行维护。
          'enum': [for (final value in LoopProactive.values) value.wireName],
          'description': '跟进方式',
        },
        'note': {'type': 'string', 'description': '跟进背景，可省略'},
        'evidence': {'type': 'string', 'description': '用户原话摘录，可省略'},
        'keep': {
          'type': 'string',
          'enum': [memorySignalKeepMonth],
          'description': '仅当整月未闭环也值得写进月摘要时填 month',
        },
      },
      'required': ['summary'],
    },
  ),
  OmniRealtimeTool(
    name: 'open_loop_status',
    description: '用户回复让某件记录过的事有了结果。',
    parameters: {
      'type': 'object',
      'properties': {
        'summary': {'type': 'string', 'description': '事项简称'},
        'status': {
          'type': 'string',
          'enum': [for (final value in LoopStatus.values) value.wireName],
        },
        'result': {'type': 'string', 'description': '闭环原因，可省略'},
      },
      'required': ['summary', 'status'],
    },
  ),
  OmniRealtimeTool(
    name: 'memory_ban',
    description: '用户明确要求某件事以后不要再提、不要再记住。',
    parameters: {
      'type': 'object',
      'properties': {
        'summary': {'type': 'string', 'description': '事项简称'},
      },
      'required': ['summary'],
    },
  ),
  OmniRealtimeTool(
    name: 'relationship_signal',
    description: '本轮出现关系证据时使用（深谈/温度/边界开合），一轮最多一个。',
    parameters: {
      'type': 'object',
      'properties': {
        'signal': {
          'type': 'string',
          'enum': [
            for (final value in RelationshipSignal.values) value.wireName,
          ],
        },
        'summary': {
          'type': 'string',
          'description': '不超过60字的自然抽象描述',
        },
        'evidence': {'type': 'string', 'description': 'boundary 开合时必填'},
        'keep': {
          'type': 'string',
          'enum': [memorySignalKeepMonth],
          'description': '仅当关系阶段明显变化值得写进月摘要时填 month',
        },
      },
      'required': ['signal', 'summary'],
    },
  ),
  OmniRealtimeTool(
    name: 'memory_forget',
    description: '用户明确要求本轮的某些内容不要记住、不要留下记录。',
    parameters: {
      'type': 'object',
      'properties': {
        'summary': {'type': 'string', 'description': '不记录的内容简称'},
      },
      'required': ['summary'],
    },
  ),
  OmniRealtimeTool(
    name: 'memory_freeze',
    description: '用户明确要求冻结某段记忆（暂停使用，内容保留）。',
    parameters: {
      'type': 'object',
      'properties': {
        'summary': {'type': 'string', 'description': '冻结的内容简称'},
      },
      'required': ['summary'],
    },
  ),
  OmniRealtimeTool(
    name: 'memory_unfreeze',
    description: '用户明确解除之前冻结的某段记忆。',
    parameters: {
      'type': 'object',
      'properties': {
        'summary': {'type': 'string', 'description': '解除冻结的内容简称'},
      },
      'required': ['summary'],
    },
  ),
  OmniRealtimeTool(
    name: 'memory_unban',
    description: '用户明确要求以后可以重新提某件被禁提的事。',
    parameters: {
      'type': 'object',
      'properties': {
        'summary': {'type': 'string', 'description': '解除禁提的内容简称'},
      },
      'required': ['summary'],
    },
  ),
  OmniRealtimeTool(
    name: 'memory_delete',
    description: '用户明确要求删除某段记忆。',
    parameters: {
      'type': 'object',
      'properties': {
        'summary': {'type': 'string', 'description': '删除的内容简称'},
      },
      'required': ['summary'],
    },
  ),
  OmniRealtimeTool(
    name: 'memory_recall',
    description:
        '常驻字段与最近对话都没命中、用户在问旧事时请求后台查找；'
        '本轮先按一时没想起自然回应，绝不等查找结果。',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description':
              '旧事的语义查找目标：说清已知对象、事情与时间线索，'
              '可结合已知语境消解指代，不编造不知道的细节，不带疑问词',
        },
      },
      'required': ['query'],
    },
  ),
];
