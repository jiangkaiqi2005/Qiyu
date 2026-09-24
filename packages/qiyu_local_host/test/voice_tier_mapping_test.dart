import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

/// 档位映射表查询纯函数的逐条锁定（spec 决策 1、8）：
/// 三态（未知不干预／应换档＋目标档＋缺省端点与型号／不支持＋原因话术）、
/// 型号名归一（去空白、小写、精确匹配）与未知回退。表条目的话术与缺省值
/// 逐字锁死：改表必须同票改测试（用户故事 26）。
void main() {
  group('朗读族：现行形状型号引导换档', () {
    // 三个非千问朗读档都会命中同一条建议；千问朗读档本身不干预（下方
    // 单独锁定）。
    for (final tier in ['openai_compatible', 'volc_tts', 'custom']) {
      test('openai_compatible 之外的 $tier 填 qwen3-tts-flash 被引导去千问朗读档', () {
        final suggestion = lookupVoiceTierSuggestion(
          family: VoiceServiceFamily.synthesis,
          currentProviderWireName: tier,
          model: 'qwen3-tts-flash',
        );
        expect(suggestion, isA<VoiceTierSwitchSuggestion>());
        final switchSuggestion = suggestion! as VoiceTierSwitchSuggestion;
        expect(switchSuggestion.targetFamily, VoiceServiceFamily.synthesis);
        expect(switchSuggestion.targetProviderWireName, 'qwen_tts');
        expect(switchSuggestion.targetModel, 'qwen3-tts-flash');
        expect(switchSuggestion.defaultEndpoint, qwenTtsDefaultEndpoint);
        expect(switchSuggestion.addressTemplate, isNull);
        expect(switchSuggestion.addressGuidance, isNull);
        expect(switchSuggestion.reason, '这个型号要走千问朗读档。');
      });
    }

    test('realtime 系两个型号同样引导去千问朗读档（型号驱动在档内生效）', () {
      for (final model in [
        'qwen3-tts-flash-realtime',
        'qwen3-tts-instruct-flash-realtime',
      ]) {
        final suggestion = lookupVoiceTierSuggestion(
          family: VoiceServiceFamily.synthesis,
          currentProviderWireName: 'openai_compatible',
          model: model,
        );
        expect(suggestion, isA<VoiceTierSwitchSuggestion>(), reason: model);
        final switchSuggestion = suggestion! as VoiceTierSwitchSuggestion;
        expect(switchSuggestion.targetProviderWireName, 'qwen_tts');
        expect(switchSuggestion.targetModel, model);
        expect(switchSuggestion.defaultEndpoint, qwenTtsDefaultEndpoint);
        expect(switchSuggestion.reason, '这个型号要走千问朗读档。');
      }
    });

    test('千问朗读档填现行型号：正确落位，不干预', () {
      expect(
        lookupVoiceTierSuggestion(
          family: VoiceServiceFamily.synthesis,
          currentProviderWireName: 'qwen_tts',
          model: 'qwen3-tts-flash',
        ),
        isNull,
      );
      expect(
        lookupVoiceTierSuggestion(
          family: VoiceServiceFamily.synthesis,
          currentProviderWireName: 'qwen_tts',
          model: 'qwen3-tts-flash-realtime',
        ),
        isNull,
      );
    });
  });

  group('朗读族：3.1／3.0 新形状型号只给模板不代填', () {
    for (final model in [
      'qwen-audio-3.1-tts-flash',
      'qwen-audio-3.0-tts-flash',
      'qwen-audio-3.0-tts-plus',
    ]) {
      test('$model 在千问朗读档填现行地址：引导去新版端点（同档）', () {
        final suggestion = lookupVoiceTierSuggestion(
          family: VoiceServiceFamily.synthesis,
          currentProviderWireName: 'qwen_tts',
          model: model,
        );
        expect(suggestion, isA<VoiceTierSwitchSuggestion>(), reason: model);
        final switchSuggestion = suggestion! as VoiceTierSwitchSuggestion;
        expect(switchSuggestion.targetFamily, VoiceServiceFamily.synthesis);
        expect(switchSuggestion.targetProviderWireName, 'qwen_tts');
        expect(switchSuggestion.targetModel, model);
        // 业务空间 ID 只有用户知道：不代填端点，只给模板与拼接指引。
        expect(switchSuggestion.defaultEndpoint, isNull);
        expect(
          switchSuggestion.addressTemplate,
          'https://{业务空间ID}.cn-beijing.maas.aliyuncs.com'
          '/api/v1/services/audio/tts/SpeechSynthesizer',
        );
        expect(switchSuggestion.addressGuidance, contains('业务空间 ID'));
        expect(
          switchSuggestion.reason,
          '这个型号要走千问朗读档的新版千问端点。',
        );
      });

      test('$model 在其他档同样给模板引导', () {
        final suggestion = lookupVoiceTierSuggestion(
          family: VoiceServiceFamily.synthesis,
          currentProviderWireName: 'openai_compatible',
          model: model,
        );
        expect(suggestion, isA<VoiceTierSwitchSuggestion>(), reason: model);
        final switchSuggestion = suggestion! as VoiceTierSwitchSuggestion;
        expect(switchSuggestion.targetProviderWireName, 'qwen_tts');
        expect(switchSuggestion.defaultEndpoint, isNull);
        expect(switchSuggestion.addressTemplate, isNotNull);
      });

      test('$model 在千问朗读档配新版地址：正确落位，不干预', () {
        expect(
          lookupVoiceTierSuggestion(
            family: VoiceServiceFamily.synthesis,
            currentProviderWireName: 'qwen_tts',
            model: model,
            currentAddressUsesMaasShape: true,
          ),
          isNull,
        );
      });
    }
  });

  group('不支持裁定逐字锁定（spec 决策 8，遍历全表防加行漏测）', () {
    // 遍历表行集逐字锁定：每条不支持条目的原因话术、替代型号与替代
    // 落位（含可代填缺省端点）。新增行不补这里的断言即红（用户故事 26）。
    test('全表逐字锁定：原因话术、替代型号与替代落位（无论当前档是什么）', () {
      expect(unsupportedVoiceModelRows, isNotEmpty);
      for (final row in unsupportedVoiceModelRows) {
        for (final tier in ['qwen_tts', 'openai_compatible']) {
          final suggestion = lookupVoiceTierSuggestion(
            family: VoiceServiceFamily.synthesis,
            currentProviderWireName: tier,
            model: row.model,
          );
          expect(
            suggestion,
            isA<VoiceTierUnsupportedSuggestion>(),
            reason: row.model,
          );
          final unsupported = suggestion! as VoiceTierUnsupportedSuggestion;
          expect(unsupported.reason, row.reason, reason: row.model);
          expect(unsupported.targetModel, row.replacement, reason: row.model);
          // 替代型号的落位从支持表派生：目标族、目标档与可代填缺省
          // 端点随替代型号自己的支持条目走。
          expect(
            unsupported.targetProviderWireName,
            row.replacement == 'qwen3-tts-flash' ? 'qwen_tts' : 'qwen_asr',
            reason: row.model,
          );
          expect(
            unsupported.defaultEndpoint,
            row.replacement == 'qwen3-tts-flash'
                ? qwenTtsDefaultEndpoint
                : qwenAsrDefaultEndpoint,
            reason: row.model,
          );
        }
      }
    });

    test('结构完整性：每条替代型号按其落位查表必须落位正确（不干预）', () {
      for (final row in unsupportedVoiceModelRows) {
        final suggestion = lookupVoiceTierSuggestion(
          family: VoiceServiceFamily.synthesis,
          currentProviderWireName: 'qwen_tts',
          model: row.model,
        )! as VoiceTierUnsupportedSuggestion;
        // 替代型号在自己的落位（族＋档＋现行形状）上是正确放置：查表
        // 不干预。缺了这一条的替代建议会把用户引到另一个错误里。
        expect(
          lookupVoiceTierSuggestion(
            family: suggestion.targetFamily,
            currentProviderWireName: suggestion.targetProviderWireName,
            model: suggestion.targetModel,
          ),
          isNull,
          reason: '${suggestion.targetModel} 的落位',
        );
      }
    });

    test('转写档查不支持条目：同样给裁定', () {
      final suggestion = lookupVoiceTierSuggestion(
        family: VoiceServiceFamily.transcription,
        currentProviderWireName: 'qwen_asr',
        model: 'qwen-audio-3.1-asr-flash-filetrans',
      );
      expect(suggestion, isA<VoiceTierUnsupportedSuggestion>());
      final unsupported = suggestion! as VoiceTierUnsupportedSuggestion;
      expect(unsupported.reason, '这是录音文件转写型号，栖语不支持。');
      expect(unsupported.targetModel, 'qwen3-asr-flash');
    });
  });

  group('转写族（票 04 接线，本票只保证查询可用）', () {
    test('其他转写档填 qwen3-asr-flash 被引导去千问识别档', () {
      final suggestion = lookupVoiceTierSuggestion(
        family: VoiceServiceFamily.transcription,
        currentProviderWireName: 'openai_compatible',
        model: 'qwen3-asr-flash',
      );
      expect(suggestion, isA<VoiceTierSwitchSuggestion>());
      final switchSuggestion = suggestion! as VoiceTierSwitchSuggestion;
      expect(switchSuggestion.targetFamily, VoiceServiceFamily.transcription);
      expect(switchSuggestion.targetProviderWireName, 'qwen_asr');
      expect(switchSuggestion.targetModel, 'qwen3-asr-flash');
      expect(switchSuggestion.defaultEndpoint, qwenAsrDefaultEndpoint);
      expect(switchSuggestion.reason, '这个型号要走千问识别档。');
    });

    test('千问识别档填 qwen3-asr-flash：正确落位，不干预', () {
      expect(
        lookupVoiceTierSuggestion(
          family: VoiceServiceFamily.transcription,
          currentProviderWireName: 'qwen_asr',
          model: 'qwen3-asr-flash',
        ),
        isNull,
      );
    });

    test('转写档填朗读型号被引导回千问朗读档（跨族指引）', () {
      final suggestion = lookupVoiceTierSuggestion(
        family: VoiceServiceFamily.transcription,
        currentProviderWireName: 'qwen_asr',
        model: 'qwen3-tts-flash',
      );
      expect(suggestion, isA<VoiceTierSwitchSuggestion>());
      final switchSuggestion = suggestion! as VoiceTierSwitchSuggestion;
      expect(switchSuggestion.targetFamily, VoiceServiceFamily.synthesis);
      expect(switchSuggestion.targetProviderWireName, 'qwen_tts');
      expect(switchSuggestion.defaultEndpoint, qwenTtsDefaultEndpoint);
    });
  });

  group('型号名归一与精确匹配', () {
    test('去空白、小写归一后命中', () {
      final suggestion = lookupVoiceTierSuggestion(
        family: VoiceServiceFamily.synthesis,
        currentProviderWireName: 'volc_tts',
        model: '  QWEN3-TTS-Flash  ',
      );
      expect(suggestion, isA<VoiceTierSwitchSuggestion>());
      expect((suggestion! as VoiceTierSwitchSuggestion).targetModel,
          'qwen3-tts-flash');
    });

    test('精确匹配：前后多一字、少一字都不命中', () {
      for (final model in [
        'xqwen3-tts-flash',
        'qwen3-tts-flashx',
        'qwen3-tts-flash-realtime-plus',
        'qwen-audio-3.1-tts',
      ]) {
        expect(
          lookupVoiceTierSuggestion(
            family: VoiceServiceFamily.synthesis,
            currentProviderWireName: 'openai_compatible',
            model: model,
          ),
          isNull,
          reason: model,
        );
      }
    });
  });

  test('未知回退：任何字段组合 miss 都不干预', () {
    for (final model in [
      '',
      '   ',
      'tts-1',
      'gpt-4o-audio-preview',
      'cosyvoice-v2',
      'seed-tts-2.0',
      'qwen-max',
      'qwen3-tts-flash-2025-09',
    ]) {
      for (final family in VoiceServiceFamily.values) {
        for (final tier in [
          'openai_compatible',
          'volc_tts',
          'qwen_tts',
          'custom',
          'qwen_asr',
          'volc_seed_asr',
        ]) {
          expect(
            lookupVoiceTierSuggestion(
              family: family,
              currentProviderWireName: tier,
              model: model,
            ),
            isNull,
            reason: '$family/$tier/$model',
          );
        }
      }
    }
  });

  test('JSON 下发形状：建议字段带 kind 与目标信息', () {
    final switchSuggestion = lookupVoiceTierSuggestion(
      family: VoiceServiceFamily.synthesis,
      currentProviderWireName: 'openai_compatible',
      model: 'qwen3-tts-flash',
    )! as VoiceTierSwitchSuggestion;
    expect(switchSuggestion.toJson(), {
      'kind': 'switchTier',
      'targetFamily': 'synthesis',
      'targetProvider': 'qwen_tts',
      'targetModel': 'qwen3-tts-flash',
      'defaultEndpoint': qwenTtsDefaultEndpoint,
      'reason': '这个型号要走千问朗读档。',
    });

    final maasSuggestion = lookupVoiceTierSuggestion(
      family: VoiceServiceFamily.synthesis,
      currentProviderWireName: 'qwen_tts',
      model: 'qwen-audio-3.1-tts-flash',
    )! as VoiceTierSwitchSuggestion;
    expect(maasSuggestion.toJson()['kind'], 'switchTier');
    expect(maasSuggestion.toJson()['addressTemplate'], isNotNull);
    expect(maasSuggestion.toJson().containsKey('defaultEndpoint'), isFalse);

    final unsupported = lookupVoiceTierSuggestion(
      family: VoiceServiceFamily.synthesis,
      currentProviderWireName: 'qwen_tts',
      model: 'qwen-audio-3.1-tts-next',
    )! as VoiceTierUnsupportedSuggestion;
    expect(unsupported.toJson(), {
      'kind': 'unsupported',
      'targetFamily': 'synthesis',
      'targetProvider': 'qwen_tts',
      'targetModel': 'qwen3-tts-flash',
      'reason': '这个型号是统一音频生成型号，官方没有给朗读用的通道，栖语接不了它。',
      'defaultEndpoint': qwenTtsDefaultEndpoint,
    });
  });
}
