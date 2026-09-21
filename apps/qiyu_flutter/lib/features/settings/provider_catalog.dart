import 'provider_settings_client.dart';
import 'tts_settings_client.dart' show TtsServiceKind;

const customModelValue = '__custom_model__';
const customVoiceValue = '__custom_voice__';

final class TtsVoicePreset {
  const TtsVoicePreset({required this.id, required this.label, this.category});

  final String id;
  final String label;
  final String? category;
}

final class ProviderPreset {
  const ProviderPreset({
    required this.id,
    required this.label,
    required this.connections,
  });

  final String id;
  final String label;
  final List<ProviderConnectionPreset> connections;
}

final class ProviderConnectionPreset {
  const ProviderConnectionPreset({
    required this.id,
    required this.label,
    required this.provider,
    required this.baseUrl,
    required this.models,
    this.editableBaseUrl = false,
  });

  final String id;
  final String label;
  final ProviderKind provider;
  final String baseUrl;
  final List<String> models;
  final bool editableBaseUrl;
}

final class ProviderCatalogSelection {
  const ProviderCatalogSelection({
    required this.providerId,
    required this.connectionId,
    required this.customModel,
  });

  final String providerId;
  final String connectionId;
  final bool customModel;
}

/// 常用服务商目录。只保存公开、稳定的连接元数据；API Key 由 Host
/// 写入本机 provider.json，目录本身不会联网，也不持有任何凭据。
const providerCatalog = <ProviderPreset>[
  ProviderPreset(
    id: 'openai',
    label: 'OpenAI',
    connections: [
      ProviderConnectionPreset(
        id: 'official',
        label: '官方 API · OpenAI 兼容',
        provider: ProviderKind.openAiCompatible,
        baseUrl: 'https://api.openai.com/v1',
        models: ['gpt-4.1-mini', 'gpt-5-mini', 'gpt-5.2'],
      ),
    ],
  ),
  ProviderPreset(
    id: 'anthropic',
    label: 'Anthropic',
    connections: [
      ProviderConnectionPreset(
        id: 'official',
        label: '官方 API · Anthropic 兼容',
        provider: ProviderKind.anthropic,
        baseUrl: 'https://api.anthropic.com/v1',
        models: ['claude-sonnet-5', 'claude-opus-5', 'claude-haiku-4-5'],
      ),
    ],
  ),
  ProviderPreset(
    id: 'deepseek',
    label: 'DeepSeek',
    connections: [
      ProviderConnectionPreset(
        id: 'openai',
        label: '按量付费 · OpenAI 兼容',
        provider: ProviderKind.openAiCompatible,
        baseUrl: 'https://api.deepseek.com',
        models: ['deepseek-v4-flash', 'deepseek-v4-pro'],
      ),
      ProviderConnectionPreset(
        id: 'anthropic',
        label: '按量付费 · Anthropic 兼容',
        provider: ProviderKind.anthropic,
        baseUrl: 'https://api.deepseek.com/anthropic',
        models: ['deepseek-v4-flash', 'deepseek-v4-pro'],
      ),
    ],
  ),
  ProviderPreset(
    id: 'bailian',
    label: '阿里云百炼',
    connections: [
      ProviderConnectionPreset(
        id: 'openai',
        label: '按量付费 · OpenAI 兼容',
        provider: ProviderKind.openAiCompatible,
        baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
        models: ['qwen-plus', 'qwen3.7-plus', 'qwen3.8-max'],
      ),
      ProviderConnectionPreset(
        id: 'anthropic',
        label: '按量付费 · Anthropic 兼容',
        provider: ProviderKind.anthropic,
        baseUrl: 'https://dashscope.aliyuncs.com/apps/anthropic',
        models: ['qwen-plus', 'qwen3.7-plus', 'qwen3.8-max'],
      ),
    ],
  ),
  ProviderPreset(
    id: 'ark',
    label: '火山方舟',
    connections: [
      ProviderConnectionPreset(
        id: 'pay_as_you_go',
        label: '按量付费 · OpenAI 兼容',
        provider: ProviderKind.openAiCompatible,
        baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
        models: ['doubao-seed-2-0-lite-260215'],
      ),
      ProviderConnectionPreset(
        id: 'agent_plan_openai',
        label: 'Agent Plan · OpenAI 兼容',
        provider: ProviderKind.openAiCompatible,
        baseUrl: 'https://ark.cn-beijing.volces.com/api/plan/v3',
        models: ['deepseek-v4-flash'],
      ),
      ProviderConnectionPreset(
        id: 'agent_plan_anthropic',
        label: 'Agent Plan · Anthropic 兼容',
        provider: ProviderKind.anthropic,
        baseUrl: 'https://ark.cn-beijing.volces.com/api/plan',
        models: ['deepseek-v4-flash'],
      ),
    ],
  ),
  ProviderPreset(
    id: 'kimi',
    label: 'Kimi / Moonshot',
    connections: [
      ProviderConnectionPreset(
        id: 'openai',
        label: '按量付费 · OpenAI 兼容',
        provider: ProviderKind.openAiCompatible,
        baseUrl: 'https://api.moonshot.cn/v1',
        models: ['kimi-k2.6', 'kimi-k2.5'],
      ),
    ],
  ),
  ProviderPreset(
    id: 'zhipu',
    label: '智谱 AI',
    connections: [
      ProviderConnectionPreset(
        id: 'openai',
        label: '按量付费 · OpenAI 兼容',
        provider: ProviderKind.openAiCompatible,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        models: ['glm-5', 'glm-4.7'],
      ),
    ],
  ),
  ProviderPreset(
    id: 'siliconflow',
    label: '硅基流动',
    connections: [
      ProviderConnectionPreset(
        id: 'openai',
        label: '按量付费 · OpenAI 兼容',
        provider: ProviderKind.openAiCompatible,
        baseUrl: 'https://api.siliconflow.cn/v1',
        models: [
          'deepseek-ai/DeepSeek-V4-Flash',
          'deepseek-ai/DeepSeek-V4-Pro',
          'Qwen/Qwen3.6-35B-A3B',
        ],
      ),
    ],
  ),
  ProviderPreset(
    id: 'minimax',
    label: 'MiniMax',
    connections: [
      ProviderConnectionPreset(
        id: 'openai',
        label: '开放平台 · OpenAI 兼容',
        provider: ProviderKind.openAiCompatible,
        baseUrl: 'https://api.minimaxi.com/v1',
        models: ['MiniMax-M2.7', 'MiniMax-M2.7-highspeed', 'M2-her'],
      ),
      ProviderConnectionPreset(
        id: 'anthropic',
        label: '开放平台 · Anthropic 兼容',
        provider: ProviderKind.anthropic,
        baseUrl: 'https://api.minimaxi.com/anthropic',
        models: ['MiniMax-M2.7', 'MiniMax-M2.7-highspeed'],
      ),
    ],
  ),
  ProviderPreset(
    id: 'gemini',
    label: 'Google Gemini',
    connections: [
      ProviderConnectionPreset(
        id: 'openai',
        label: '官方 API · OpenAI 兼容',
        provider: ProviderKind.openAiCompatible,
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
        models: [
          'gemini-3.7-flash',
          'gemini-3.6-flash',
          'gemini-3.5-flash-lite',
        ],
      ),
    ],
  ),
  ProviderPreset(
    id: 'openrouter',
    label: 'OpenRouter',
    connections: [
      ProviderConnectionPreset(
        id: 'openai',
        label: '聚合 API · OpenAI 兼容',
        provider: ProviderKind.openAiCompatible,
        baseUrl: 'https://openrouter.ai/api/v1',
        models: [
          'openai/gpt-5.2',
          'anthropic/claude-sonnet-5',
          'google/gemini-3.7-flash',
        ],
      ),
    ],
  ),
  ProviderPreset(
    id: 'ollama',
    label: 'Ollama（本机）',
    connections: [
      ProviderConnectionPreset(
        id: 'local',
        label: '本机服务 · Ollama',
        provider: ProviderKind.ollama,
        baseUrl: 'http://127.0.0.1:11434',
        models: ['qwen3', 'deepseek-r1', 'llama3.2'],
        editableBaseUrl: true,
      ),
    ],
  ),
  ProviderPreset(
    id: 'custom_openai',
    label: '自定义 OpenAI 兼容',
    connections: [
      ProviderConnectionPreset(
        id: 'custom',
        label: 'OpenAI Chat Completions',
        provider: ProviderKind.openAiCompatible,
        baseUrl: '',
        models: [],
        editableBaseUrl: true,
      ),
    ],
  ),
  ProviderPreset(
    id: 'custom_anthropic',
    label: '自定义 Anthropic 兼容',
    connections: [
      ProviderConnectionPreset(
        id: 'custom',
        label: 'Anthropic Messages',
        provider: ProviderKind.anthropic,
        baseUrl: '',
        models: [],
        editableBaseUrl: true,
      ),
    ],
  ),
];

ProviderPreset providerPresetById(String id) =>
    providerCatalog.firstWhere((provider) => provider.id == id);

ProviderCatalogSelection matchProviderSettings(ProviderSettings settings) {
  if (settings.configured) {
    for (final preset in providerCatalog) {
      if (preset.id.startsWith('custom_') || preset.id == 'ollama') {
        continue;
      }
      for (final connection in preset.connections) {
        if (connection.provider == settings.provider &&
            _sameBaseUrl(connection.baseUrl, settings.baseUrl!)) {
          return ProviderCatalogSelection(
            providerId: preset.id,
            connectionId: connection.id,
            customModel: !connection.models.contains(settings.model),
          );
        }
      }
    }

    if (settings.provider == ProviderKind.ollama) {
      return ProviderCatalogSelection(
        providerId: 'ollama',
        connectionId: 'local',
        customModel: !providerPresetById(
          'ollama',
        ).connections.single.models.contains(settings.model),
      );
    }

    return ProviderCatalogSelection(
      providerId: settings.provider == ProviderKind.anthropic
          ? 'custom_anthropic'
          : 'custom_openai',
      connectionId: 'custom',
      customModel: true,
    );
  }

  return const ProviderCatalogSelection(
    providerId: 'openai',
    connectionId: 'official',
    customModel: false,
  );
}

bool _sameBaseUrl(String left, String right) =>
    left.trim().replaceFirst(RegExp(r'/+$'), '') ==
    right.trim().replaceFirst(RegExp(r'/+$'), '');

/// 豆包语音合成预设音色库（含标准音色与常用方言）。
const doubaoTtsVoicePresets = <TtsVoicePreset>[
  // 标准音色
  TtsVoicePreset(
    id: 'zh_female_vv_uranus_bigtts',
    label: '标准女声（灿灿）',
    category: '通用',
  ),
  TtsVoicePreset(
    id: 'zh_female_gaolengyujie_uranus_bigtts',
    label: '高冷御姐',
    category: '通用',
  ),
  TtsVoicePreset(
    id: 'zh_male_chunhou_uranus_bigtts',
    label: '醇厚男声',
    category: '通用',
  ),
  TtsVoicePreset(
    id: 'zh_female_shuangkuainvhai_uranus_bigtts',
    label: '爽快女声',
    category: '通用',
  ),
  // 地方方言
  TtsVoicePreset(
    id: 'zh_female_sichuan_uranus_bigtts',
    label: '四川话',
    category: '方言',
  ),
  TtsVoicePreset(
    id: 'zh_female_cantonese_uranus_bigtts',
    label: '粤语',
    category: '方言',
  ),
  TtsVoicePreset(
    id: 'zh_female_dongbei_uranus_bigtts',
    label: '东北话',
    category: '方言',
  ),
  TtsVoicePreset(
    id: 'zh_female_henan_uranus_bigtts',
    label: '河南话',
    category: '方言',
  ),
  TtsVoicePreset(
    id: 'zh_female_shanxi_uranus_bigtts',
    label: '陕西话',
    category: '方言',
  ),
  TtsVoicePreset(
    id: 'zh_female_tianjin_uranus_bigtts',
    label: '天津话',
    category: '方言',
  ),
  TtsVoicePreset(
    id: 'zh_female_shandong_uranus_bigtts',
    label: '山东话',
    category: '方言',
  ),
  TtsVoicePreset(
    id: 'zh_female_minnan_uranus_bigtts',
    label: '闽南话',
    category: '方言',
  ),
  TtsVoicePreset(
    id: 'zh_female_wanwanxiaohe_moon_bigtts',
    label: '台湾普通话',
    category: '方言',
  ),
];

/// OpenAI 兼容语音合成预设音色库。
const openAiTtsVoicePresets = <TtsVoicePreset>[
  TtsVoicePreset(id: 'alloy', label: 'Alloy（中性平衡）'),
  TtsVoicePreset(id: 'echo', label: 'Echo（温和男声）'),
  TtsVoicePreset(id: 'fable', label: 'Fable（英音男声）'),
  TtsVoicePreset(id: 'onyx', label: 'Onyx（深沉男声）'),
  TtsVoicePreset(id: 'nova', label: 'Nova（亲切女声）'),
  TtsVoicePreset(id: 'shimmer', label: 'Shimmer（清亮女声）'),
];

/// 获取对应服务协议的预设音色列表。
List<TtsVoicePreset> ttsVoicePresetsFor(TtsServiceKind provider) =>
    switch (provider) {
      TtsServiceKind.volcTts => doubaoTtsVoicePresets,
      TtsServiceKind.openAiCompatible => openAiTtsVoicePresets,
      // 千问档暂无预设音色目录：音色直给自由输入框（任何音色 ID）。
      TtsServiceKind.qwenTts => const [],
    };
