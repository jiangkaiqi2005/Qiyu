import 'dart:convert';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

/// 档位归口测试（票 08，ADR 0021）：随船数据行的结构完整性、三张分派
/// 表退化后的形状解析对拍、元数据下推载荷，以及「新档位发版＝加数据
/// 行」的演示性用例。
///
/// 行集即测试锁定的表面（与档位映射表同一契约）：新增或修改归口数据行
/// 必须同票补齐这里的遍历断言。
void main() {
  group('随船数据行结构完整性', () {
    test('同族 wire 名唯一，覆盖合成与转写两个族', () {
      final seen = <String>{};
      for (final tier in shipVoiceTiers) {
        final identity = '${tier.family.name}/${tier.wireName}';
        expect(seen.contains(identity), isFalse, reason: identity);
        seen.add(identity);
      }
      expect(
        seen,
        containsAll([
          'synthesis/openai_compatible',
          'synthesis/volc_tts',
          'synthesis/qwen_tts',
          'synthesis/custom',
          'transcription/openai_compatible',
          'transcription/volc_seed_asr',
          'transcription/qwen_asr',
          'transcription/custom',
        ]),
      );
    });

    test('每个档位的文案与缺省配置完整（下推后设置页可直接渲染）', () {
      for (final tier in shipVoiceTiers) {
        expect(tier.label.trim(), isNotEmpty, reason: tier.wireName);
        expect(tier.description.trim(), isNotEmpty, reason: tier.wireName);
        expect(tier.modelLabel.trim(), isNotEmpty, reason: tier.wireName);
        expect(tier.addressSchemes, isNotEmpty, reason: tier.wireName);
        expect(tier.urlHint.trim(), isNotEmpty, reason: tier.wireName);
        expect(tier.modelHint.trim(), isNotEmpty, reason: tier.wireName);
        // 缺省端点允许为空（开放兼容与自定义档等用户直填），非空时必须是
        // 合法 http/ws 地址，缺省模型同理非负。
        if (tier.defaultEndpoint.isNotEmpty) {
          final uri = Uri.tryParse(tier.defaultEndpoint);
          expect(uri, isNotNull, reason: tier.wireName);
          expect(
            uri!.scheme,
            anyOf('http', 'https', 'ws', 'wss'),
            reason: tier.wireName,
          );
        }
      }
    });

    test('每个合成档的形状行以恒真兜底行收尾（解析不落空的构造保证）', () {
      for (final tier in shipVoiceTiers) {
        if (tier.family != VoiceServiceFamily.synthesis) {
          expect(tier.synthesisShapes, isEmpty, reason: tier.wireName);
          continue;
        }
        expect(tier.synthesisShapes, isNotEmpty, reason: tier.wireName);
        final last = tier.synthesisShapes.last;
        expect(
          last.matches(
            TtsConfig(baseUrl: 'https://tts.example.com/v1', model: 'm'),
          ),
          isTrue,
          reason: '${tier.wireName} 的末行必须恒真兜底',
        );
      }
    });

    test('配置层四个合成档与四个转写档在归口里都有行（查表不会落空）', () {
      for (final provider in TtsProviderKind.values) {
        expect(
          synthesisVoiceTier(provider).wireName,
          provider.wireName,
          reason: provider.wireName,
        );
      }
      for (final provider in SttProviderKind.values) {
        expect(
          transcriptionVoiceTier(provider).wireName,
          provider.wireName,
          reason: provider.wireName,
        );
      }
    });

    test('每档 addressSchemes 与配置层 allows 的全接受集一致（防加行漂移）',
        () {
      // 纯数据对拍：归口元数据带的允许 scheme 集合必须逐 scheme 等于
      // 配置校验与出网防护共用的 allows 全接受集（含豆包转写只收 ws/wss、
      // 千问朗读档例外收 ws/wss）。新增档位只改一边时这里的遍历即红。
      const schemes = ['http', 'https', 'ws', 'wss'];
      for (final provider in TtsProviderKind.values) {
        final tier = synthesisVoiceTier(provider);
        for (final scheme in schemes) {
          expect(
            tier.addressSchemes.contains(scheme),
            provider.allows(scheme),
            reason: '${provider.wireName} 档的 $scheme 判定两边不一致',
          );
        }
      }
      for (final provider in SttProviderKind.values) {
        final tier = transcriptionVoiceTier(provider);
        for (final scheme in schemes) {
          expect(
            tier.addressSchemes.contains(scheme),
            provider.allows(scheme),
            reason: '${provider.wireName} 档的 $scheme 判定两边不一致',
          );
        }
      }
    });
  });

  group('三张分派表退化后的形状解析对拍', () {
    // 对拍基准：退化前三张分派表（整段/流式/会话）的逐分支落点。形状 id
    // 与能力矩阵在此逐行锁定，「型号驱动先于地址判定」的优先级由
    // realtime 行排在 ws 推理行之前表达。
    TtsConfig config({
      required TtsProviderKind provider,
      String baseUrl = 'https://tts.example.com/v1',
      String model = 'tts-test',
      TtsTransport transport = TtsTransport.httpChunk,
    }) => TtsConfig(
      provider: provider,
      baseUrl: baseUrl,
      model: model,
      transport: transport,
    );

    test('OpenAI 兼容档：单一 HTTP 形状，有整段与流式、无会话', () {
      final shape = resolveSynthesisShape(
        config(provider: TtsProviderKind.openAiCompatible),
      );
      expect(shape.id, 'openai_http');
      expect(shape.session, isNull);
    });

    test('豆包档：传输驱动——WebSocket 双向先于 HTTP 分块', () {
      final bidirection = resolveSynthesisShape(
        config(
          provider: TtsProviderKind.volcTts,
          transport: TtsTransport.wsBidirection,
        ),
      );
      expect(bidirection.id, 'volc_bidirection_ws');
      expect(bidirection.session, isNotNull);

      final httpChunk = resolveSynthesisShape(
        config(provider: TtsProviderKind.volcTts),
      );
      expect(httpChunk.id, 'volc_http_chunk');
      expect(httpChunk.session, isNull);
    });

    test('千问档：型号驱动先于地址判定（ADR 0020 补篇优先级逐字保持）', () {
      // -realtime 型号配 wss 推理地址：仍落 Realtime（型号驱动在前）。
      expect(
        resolveSynthesisShape(
          config(
            provider: TtsProviderKind.qwenTts,
            baseUrl: qwenTtsWsInferenceEndpoint,
            model: '${qwenTtsDefaultModel}x-realtime',
          ),
        ).id,
        'qwen_realtime_ws',
      );
      // realtime 型号配现行 multimodal 地址：落 Realtime。
      expect(
        resolveSynthesisShape(
          config(
            provider: TtsProviderKind.qwenTts,
            model: 'qwen3-tts-instruct-flash-realtime',
          ),
        ).id,
        'qwen_realtime_ws',
      );
      // wss 地址配普通型号：经典 WS 推理（票 07）。
      expect(
        resolveSynthesisShape(
          config(
            provider: TtsProviderKind.qwenTts,
            baseUrl: qwenTtsWsInferenceEndpoint,
            model: qwenTtsDefaultModel,
          ),
        ).id,
        'qwen_ws_inference',
      );
      // maas 主机与现行 multimodal 地址：都在兜底行（maas 形状在网关内
      // 按主机判定，分派层不区分）。
      expect(
        resolveSynthesisShape(
          config(
            provider: TtsProviderKind.qwenTts,
            baseUrl:
                'https://ws-demo.cn-beijing.maas.aliyuncs.com'
                '/api/v1/services/audio/tts/SpeechSynthesizer',
            model: qwenTtsDefaultModel,
          ),
        ).id,
        'qwen_multimodal_http',
      );
      expect(
        resolveSynthesisShape(
          config(
            provider: TtsProviderKind.qwenTts,
            model: qwenTtsDefaultModel,
          ),
        ).id,
        'qwen_multimodal_http',
      );
    });

    test('realtime 配 wss 推理地址：流式回落行是现行 multimodal 网关', () {
      // 退化前旧表按地址判型，该组合的句级流式落 WS 推理网关；新表按型
      // 号驱动落实时形状、流式回落行取现行 multimodal 网关。该组合产品
      // 链路不可达（realtime 恒先开会话且 D1 下不回落分句），本用例把
      // 现行为锁死，防将来无意识翻转。
      final shape = resolveSynthesisShape(
        TtsConfig(
          provider: TtsProviderKind.qwenTts,
          baseUrl: qwenTtsWsInferenceEndpoint,
          model: '${qwenTtsDefaultModel}x-realtime',
        ),
      );
      expect(shape.id, 'qwen_realtime_ws');
      expect(
        shape.stream(TtsGatewayEnv(_UnusedHttpClient(), null)),
        isA<QwenTtsGateway>(),
      );
    });

    test('会话能力矩阵：三个 WS 形状开会话，其余形状返回 null', () {
      final env = TtsGatewayEnv(_UnusedHttpClient(), null);
      final sessionKinds = <String, Type?>{};
      for (final tier in shipVoiceTiers) {
        if (tier.family != VoiceServiceFamily.synthesis) {
          continue;
        }
        for (final shape in tier.synthesisShapes) {
          sessionKinds[shape.id] = shape.session?.call(env).runtimeType;
        }
      }
      expect(sessionKinds, {
        'openai_http': isNull,
        'volc_bidirection_ws': VolcBidirectionTtsGateway,
        'volc_http_chunk': isNull,
        'qwen_realtime_ws': QwenRealtimeTtsGateway,
        'qwen_ws_inference': QwenWsInferenceTtsGateway,
        'qwen_multimodal_http': isNull,
        'custom_http': isNull,
      });
    });

    test('流式能力矩阵：每个形状都有句级回落（E1 语义由构造保证）', () {
      final env = TtsGatewayEnv(_UnusedHttpClient(), null);
      for (final tier in shipVoiceTiers) {
        for (final shape in tier.synthesisShapes) {
          expect(
            shape.stream(env),
            isA<TtsStreamSynthesisGateway>(),
            reason: shape.id,
          );
        }
      }
    });
  });

  group('档位元数据下推', () {
    test('按族导出：合成四行、转写三行，顺序与随船目录一致', () {
      final synthesis = voiceTierMetadataRows(
        family: VoiceServiceFamily.synthesis,
      );
      expect(
        synthesis.map((row) => row['wireName']),
        ['openai_compatible', 'volc_tts', 'qwen_tts', 'custom'],
      );
      final transcription = voiceTierMetadataRows(
        family: VoiceServiceFamily.transcription,
      );
      expect(
        transcription.map((row) => row['wireName']),
        ['openai_compatible', 'volc_seed_asr', 'qwen_asr', 'custom'],
      );
    });

    test('载荷只含能力/形状/端点缺省/文案的允许清单字段，绝无密钥', () {
      const allowedKeys = {
        'wireName',
        'label',
        'description',
        'modelLabel',
        'modelHelperText',
        'defaultEndpoint',
        'defaultModel',
        'urlHint',
        'modelHint',
        'addressSchemes',
        'transports',
        'transportHelperText',
        'customKnobs',
        'authHeaderHint',
        'authHeaderHelperText',
        'responseShapeOptions',
        'responseShapeHelperText',
        'responseFieldHint',
        'responseFieldHelperText',
        'advancedParams',
        'extraParamsExample',
        'speedSlider',
        'voiceMode',
        'defaultVoice',
        'voiceHint',
        'realtimeModelSuffix',
        'realtimeExtraParamsHint',
      };
      for (final family in VoiceServiceFamily.values) {
        for (final row in voiceTierMetadataRows(family: family)) {
          expect(row.keys.toSet().difference(allowedKeys), isEmpty,
              reason: row['wireName']! as String);
          final encoded = jsonEncode(row);
          expect(encoded.toLowerCase(), isNot(contains('apikey')));
          expect(encoded, isNot(contains('apiKey')));
          expect(encoded, isNot(contains('API_KEY')));
        }
      }
    });

    test('千问朗读档元数据的支持范围说明与宿主常量同源拼装', () {
      final qwen = voiceTierByWireName(
        VoiceServiceFamily.synthesis,
        'qwen_tts',
      )!;
      expect(qwen.modelHelperText, qwenTtsModelHelperText);
      expect(qwen.modelHelperText, contains(qwenTtsWsInferenceEndpoint));
      expect(qwen.modelHelperText, contains(voiceTierMaasAddressTemplate));
      expect(qwen.realtimeModelSuffix, '-realtime');
      expect(qwen.defaultVoice, qwenTtsDefaultVoice);
    });
  });

  group('演示：新增档位只加数据行', () {
    test('测试档位追加为归口数据行后，元数据下推自动带上它', () {
      final rows = voiceTierMetadataRows(
        family: VoiceServiceFamily.synthesis,
        tiers: [...shipVoiceTiers, _demoSynthesisTier],
      );
      expect(rows, hasLength(5));
      final demo = rows.last;
      expect(demo['wireName'], 'acme_voice_demo');
      expect(demo['label'], 'Acme 演示合成档');
      expect(demo['defaultEndpoint'], 'https://tts.acme.example/api/v1');
      expect(demo['defaultModel'], 'acme-voice-1');
      // 演示档的请求形状与元数据同在一份行里：复用的 OpenAI 兼容形状
      // 行按它自己的行解析落表，无需任何归口之外的代码改动。
      final demoShape = _demoSynthesisTier.synthesisShapes.single;
      expect(
        demoShape.matches(
          TtsConfig(baseUrl: 'https://tts.acme.example/api/v1', model: 'm'),
        ),
        isTrue,
      );
      expect(demoShape.id, 'openai_http');
      expect(demoShape.session, isNull);
    });
  });
}

/// 演示用测试档位：只存在于测试，不进随船数据。复用既有 OpenAI 兼容
/// 请求形状——整份「新档位知识」就是下面这一份行。
final _demoSynthesisTier = VoiceTierDescriptor(
  family: VoiceServiceFamily.synthesis,
  wireName: 'acme_voice_demo',
  label: 'Acme 演示合成档',
  description: '演示用数据行：复用 OpenAI 兼容请求形状的新档位。',
  modelLabel: '模型名称',
  defaultEndpoint: 'https://tts.acme.example/api/v1',
  defaultModel: 'acme-voice-1',
  urlHint: 'https://tts.acme.example/api/v1',
  modelHint: 'acme-voice-1',
  addressSchemes: ['http', 'https'],
  extraParamsExample: '配置 Acme 演示合成档的扩展参数。',
  speedSlider: true,
  voiceMode: VoiceTierVoiceMode.freeInput,
  defaultVoice: 'acme-demo-voice',
  voiceHint: 'acme-demo-voice',
  synthesisShapes: [
    TtsTierShape(
      id: 'openai_http',
      matches: (_) => true,
      whole: (env) => OpenAiSpeechGateway(env.httpClient),
      stream: (env) => OpenAiSpeechGateway(env.httpClient),
    ),
  ],
);

/// 形状能力矩阵用的空客户端：工厂只构造网关、不发请求，被调用即失败。
final class _UnusedHttpClient implements ProviderBytesHttpClient {
  @override
  Future<ProviderBytesHttpResponse> postBytes({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) => throw StateError('形状解析不得发起出网请求');

  @override
  Future<ProviderBytesHttpResponse> getBytes({
    required Uri uri,
    required Duration timeout,
  }) => throw StateError('形状解析不得发起出网请求');
}
