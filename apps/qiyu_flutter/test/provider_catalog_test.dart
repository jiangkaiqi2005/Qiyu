import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/settings/provider_catalog.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';

void main() {
  test('catalog covers popular providers and both custom protocols', () {
    final ids = providerCatalog.map((provider) => provider.id).toSet();

    expect(
      ids,
      containsAll(<String>{
        'openai',
        'anthropic',
        'deepseek',
        'bailian',
        'ark',
        'kimi',
        'zhipu',
        'siliconflow',
        'minimax',
        'gemini',
        'openrouter',
        'ollama',
        'custom_openai',
        'custom_anthropic',
        'custom_omni',
      }),
    );
    expect(ids.length, providerCatalog.length);
    expect(
      providerPresetById('custom_openai').connections.single.provider,
      ProviderKind.openAiCompatible,
    );
    expect(
      providerPresetById('custom_anthropic').connections.single.provider,
      ProviderKind.anthropic,
    );
    expect(
      providerPresetById('custom_omni').connections.single.provider,
      ProviderKind.qwenOmniRealtime,
    );
  });

  test('bailian catalog exposes the verified Omni realtime connection', () {
    final connection = providerPresetById(
      'bailian',
    ).connections.firstWhere((connection) => connection.id == 'omni_realtime');

    expect(connection.provider, ProviderKind.qwenOmniRealtime);
    expect(
      connection.baseUrl,
      'wss://dashscope.aliyuncs.com/api-ws/v1/realtime',
    );
    expect(connection.models, ['qwen3.8-omni-flash-realtime']);
  });

  test('host snapshot with the Omni realtime wire name parses and restores', () {
    final settings = ProviderSettings.fromJson(const {
      'configured': true,
      'keySet': true,
      'provider': 'qwen_omni_realtime',
      'baseUrl': 'wss://dashscope.aliyuncs.com/api-ws/v1/realtime',
      'model': 'qwen3.8-omni-flash-realtime',
      'temperature': 0.7,
      'timeoutSeconds': 30,
    });

    expect(settings.provider, ProviderKind.qwenOmniRealtime);
    final selection = matchProviderSettings(settings);
    expect(selection.providerId, 'bailian');
    expect(selection.connectionId, 'omni_realtime');
  });

  test(
    'unknown Omni endpoint falls back to the Omni custom preset, not chat',
    () {
      final selection = matchProviderSettings(
        const ProviderSettings(
          configured: true,
          keySet: true,
          provider: ProviderKind.qwenOmniRealtime,
          baseUrl: 'wss://gateway.example.com/realtime',
          model: 'private-realtime-model',
          temperature: 0.7,
          timeoutSeconds: 60,
        ),
      );

      expect(selection.providerId, 'custom_omni');
      expect(selection.connectionId, 'custom');
      expect(selection.customModel, isTrue);
    },
  );

  test('saved preset is restored while an unlisted model remains editable', () {
    final selection = matchProviderSettings(
      const ProviderSettings(
        configured: true,
        keySet: true,
        provider: ProviderKind.anthropic,
        baseUrl: 'https://ark.cn-beijing.volces.com/api/plan/',
        model: 'new-agent-plan-model',
        temperature: 0.7,
        timeoutSeconds: 60,
      ),
    );

    expect(selection.providerId, 'ark');
    expect(selection.connectionId, 'agent_plan_anthropic');
    expect(selection.customModel, isTrue);
  });

  test(
    'unknown Anthropic endpoint falls back without losing compatibility',
    () {
      final selection = matchProviderSettings(
        const ProviderSettings(
          configured: true,
          keySet: true,
          provider: ProviderKind.anthropic,
          baseUrl: 'https://gateway.example.com/anthropic',
          model: 'private-model',
          temperature: 0.7,
          timeoutSeconds: 60,
        ),
      );

      expect(selection.providerId, 'custom_anthropic');
      expect(selection.connectionId, 'custom');
      expect(selection.customModel, isTrue);
    },
  );
}
