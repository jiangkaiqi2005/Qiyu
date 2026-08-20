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
  });

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
