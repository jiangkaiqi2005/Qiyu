import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/settings/settings_section_shell.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_section.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/voice_tier_metadata.dart';
import 'package:qiyu_flutter/features/settings/voice_tier_suggestion.dart';

/// 档位元数据下推的界面侧测试（票 08，ADR 0021）：设置页按宿主下发的
/// `tiers` 行集渲染，旧版宿主回落内置降级目录，未知档位走确认式兜底。
///
/// 「新增档位＝加数据行」的演示在这里走通最后一段：宿主数据行的 JSON
/// 出现在快照 `tiers` 里，区块就自动渲染出该档位（下拉出现、切档按元
/// 数据回填缺省地址与模型），界面代码零改动。
void main() {
  /// 宿主档位归口下发的演示行（与宿主侧 voice_tier_registry_test 的
  /// 演示数据行同形状）：只存在于测试，不进随船数据。
  Map<String, Object?> demoTierJson() => {
    'wireName': 'acme_voice_demo',
    'label': 'Acme 演示合成档',
    'description': '演示用数据行：复用 OpenAI 兼容请求形状的新档位。',
    'modelLabel': '模型名称',
    'defaultEndpoint': 'https://tts.acme.example/api/v1',
    'defaultModel': 'acme-voice-1',
    'urlHint': 'https://tts.acme.example/api/v1',
    'modelHint': 'acme-voice-1',
    'addressSchemes': ['http', 'https'],
    'extraParamsExample': '配置 Acme 演示合成档的扩展参数。',
    'advancedParams': true,
    'speedSlider': true,
    'voiceMode': 'free_input',
    'defaultVoice': 'acme-demo-voice',
    'voiceHint': 'acme-demo-voice',
  };

  group('快照解析：tiers 行集与原始 wire 名', () {
    test('下发 tiers 时按行集建目录，未知 wire 名原始身份保留', () {
      final settings = TtsSettings.fromJson({
        'configured': false,
        'keySet': false,
        'provider': 'acme_voice_demo',
        'tiers': [demoTierJson()],
      });

      expect(settings.tiers, hasLength(1));
      expect(settings.tiers!.single.wireName, 'acme_voice_demo');
      expect(settings.tiers!.single.label, 'Acme 演示合成档');
      // 类型化视图按缺省档呈现（防御口径不变），原始 wire 名不丢失。
      expect(settings.provider, TtsServiceKind.openAiCompatible);
      expect(settings.providerWireName, 'acme_voice_demo');
      expect(settings.tierCatalog.knownTier('acme_voice_demo'), isNotNull);
    });

    test('不带 tiers 的快照＝旧版宿主：回落内置降级目录', () {
      final settings = TtsSettings.fromJson({
        'configured': false,
        'keySet': false,
      });

      expect(settings.tiers, isNull);
      // 降级目录冻结在今天已知的四个档位，可用。
      expect(
        settings.tierCatalog.rows.map((tier) => tier.wireName),
        ['openai_compatible', 'volc_tts', 'qwen_tts', 'custom'],
      );
      // 降级渲染与升级前一字不差：合成四档恒有高级参数面板（元数据
      // 门控的口径与随船归口一致）。
      expect(
        settings.tierCatalog.rows.every((tier) => tier.advancedParams),
        isTrue,
      );
      expect(settings.tierCatalog.knownTier('qwen_tts'), isNotNull);
      expect(settings.tierCatalog.knownTier('acme_voice_demo'), isNull);
    });

    test('未知档位不在行集时下拉取值回退类型化视图，不失配不崩溃', () {
      final form = TtsSettingsForm()
        ..sync(
          // 防御形状：快照 provider 是未知 wire 名且无元数据下推——旧版
          // 宿主不可能发出这种组合，界面照旧不崩。
          TtsSettings.fromJson({
            'configured': true,
            'keySet': true,
            'provider': 'never_heard_tier',
            'baseUrl': 'https://tts.example.com/v1',
            'model': 'm',
          }),
        );

      expect(form.provider, TtsServiceKind.openAiCompatible);
      expect(form.dropdownValue, 'openai_compatible');
      expect(form.tierChoices.any((tier) => tier.wireName == 'never_heard_tier'),
          isFalse);
    });

    test('下发行集查不到的档位回落降级行，再查不到给最小可用行', () {
      final catalog = TtsSettings.fromJson({
        'configured': false,
        'keySet': false,
        'tiers': [demoTierJson()],
      }).tierCatalog;

      // 查询不会落空：未知档给最小可用行（标签即 wire 名，HTTP 家族
      // 语义），不崩溃、不静默丢档。
      final unknown = catalog.tierFor('never_heard_tier');
      expect(unknown.label, 'never_heard_tier');
      expect(unknown.customKnobs, isFalse);
      expect(unknown.allowsScheme('https'), isTrue);
      expect(unknown.allowsScheme('wss'), isFalse);
    });

    test('元数据能力字段逐项解析：传输、旋钮、语速与实时形态', () {
      final settings = TtsSettings.fromJson({
        'configured': false,
        'keySet': false,
        'tiers': [
          {
            'wireName': 'demo_knobs',
            'label': '旋钮演示档',
            'description': 'd',
            'modelLabel': 'Resource-Id',
            'defaultEndpoint': 'https://demo.example/v1',
            'defaultModel': 'demo-1',
            'urlHint': 'https://demo.example/v1',
            'modelHint': 'demo-1',
            'addressSchemes': ['ws', 'wss'],
            'transports': [
              {'wireName': 'http_chunk', 'label': 'HTTP 分块'},
            ],
            'transportHelperText': '传输说明',
            'customKnobs': true,
            'authHeaderHint': 'X-Api-Key',
            'authHeaderHelperText': '鉴权头说明',
            'responseShapeOptions': [
              {'wireName': 'json_field', 'label': 'JSON 字段'},
            ],
            'responseShapeHelperText': '形态说明',
            'responseFieldHint': 'audio',
            'responseFieldHelperText': '字段说明',
            'advancedParams': true,
            'extraParamsExample': '示例',
            'speedSlider': true,
            'voiceMode': 'presets',
            'realtimeModelSuffix': '-rt',
            'realtimeExtraParamsHint': '实时形态提示',
          },
        ],
      });
      final tier = settings.tiers!.single;

      expect(
        tier.transports.single,
        (wireName: 'http_chunk', label: 'HTTP 分块'),
      );
      expect(tier.transportHelperText, '传输说明');
      expect(tier.customKnobs, isTrue);
      expect(tier.authHeaderHint, 'X-Api-Key');
      expect(tier.responseShapeOptions.single.label, 'JSON 字段');
      expect(tier.responseFieldHint, 'audio');
      expect(tier.speedSlider, isTrue);
      expect(tier.voiceMode, VoiceTierVoiceMode.presets);
      expect(tier.realtimeModelSuffix, '-rt');
      expect(tier.realtimeExtraParamsHint, '实时形态提示');
      expect(tier.allowsScheme('WSS'), isTrue);
      expect(tier.allowsScheme('http'), isFalse);
    });

    test('未知档位草稿上送原始 wire 名，档位身份不因枚举封闭而丢失', () {
      const draft = TtsSettingsDraft(
        baseUrl: 'https://tts.acme.example/api/v1',
        model: 'acme-voice-1',
        providerWireName: 'acme_voice_demo',
      );
      expect(draft.toJson()['provider'], 'acme_voice_demo');

      // 已知档不携带原始 wire 名，请求形状与既有口径一字不变。
      const known = TtsSettingsDraft(
        baseUrl: 'https://tts.example.com/v1',
        model: 'tts-1',
      );
      expect(known.toJson()['provider'], 'openai_compatible');
    });
  });

  group('设置页按数据渲染（下推演示）', () {
    late _FixedSnapshotGateway gateway;
    late TtsSettingsViewModel viewModel;

    setUp(() {
      gateway = _FixedSnapshotGateway();
      viewModel = TtsSettingsViewModel(gateway, autoStart: false);
    });

    Future<void> pumpSection(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: viewModel,
          child: MaterialApp(
            home: Scaffold(
              body: SettingsSectionCollapseScope(
                collapsed: const {},
                onToggle: (_) {},
                child: ListView(children: const [TtsSettingsSection()]),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('宿主快照带演示档：设置页自动出现，切档按元数据回填缺省',
        (tester) async {
      gateway.snapshotJson = {
        'configured': false,
        'keySet': false,
        'tiers': [
          // 随船四档：由界面内置降级目录兜底也可以渲染，但真实宿主会把
          // 它们一并发下——这里照实构造，证明下发渲染与降级渲染同形。
          ...builtinTtsTierCatalog.map(
            (tier) => {
              'wireName': tier.wireName,
              'label': tier.label,
              'description': tier.description,
              'modelLabel': tier.modelLabel,
              'defaultEndpoint': tier.defaultEndpoint,
              'defaultModel': tier.defaultModel,
              'urlHint': tier.urlHint,
              'modelHint': tier.modelHint,
              'addressSchemes': tier.addressSchemes,
              'advancedParams': tier.advancedParams,
              'speedSlider': tier.speedSlider,
              'voiceMode': tier.voiceMode.wireName,
            },
          ),
          demoTierJson(),
        ],
      };
      // 先加载快照再挂载区块：表单的档位目录随第一次 sync 换上下发行集。
      await viewModel.initialize();
      await pumpSection(tester);

      // 展开服务类型下拉：演示档出现在选项里——「新档位发版靠加数据
      // 行」的落点（选项按宿主下发行集渲染，界面零改动）。
      await tester.tap(find.byKey(const Key('tts-provider')));
      await tester.pumpAndSettle();
      expect(find.text('Acme 演示合成档'), findsOneWidget);

      // 切到演示档：简介、缺省地址与模型全部来自下发元数据。
      await tester.tap(find.text('Acme 演示合成档').last);
      await tester.pumpAndSettle();

      expect(
        find.text('演示用数据行：复用 OpenAI 兼容请求形状的新档位。'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('tts-base-url')))
            .controller!
            .text,
        'https://tts.acme.example/api/v1',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('tts-model')))
            .controller!
            .text,
        'acme-voice-1',
      );
      // 音色按元数据回填官方示例音色；演示档无传输选项，下拉不出现。
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('tts-voice')))
            .controller!
            .text,
        'acme-demo-voice',
      );
      expect(find.byKey(const Key('tts-transport')), findsNothing);
      expect(find.byKey(const Key('tts-advanced-params-tile')), findsOneWidget);
    });

    test('未知档确认式兜底：下发档位可回填，行集之外的档保守不回填', () {
      final form = TtsSettingsForm()
        ..sync(
          TtsSettings.fromJson({
            'configured': false,
            'keySet': false,
            'tiers': [demoTierJson()],
          }),
        );

      // 目标档在下发行集里：回填计划照算（确认制对话框之后落草稿）。
      // 建议带可代填缺省端点（与正式链路的建议形状一致），地址处置落到
      // 演示档元数据带的端点上。
      final plan = form.planSuggestionApply(
        const VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'synthesis',
          targetProvider: 'acme_voice_demo',
          targetModel: 'acme-voice-1',
          reason: 'r',
          defaultEndpoint: 'https://tts.acme.example/api/v1',
        ),
      );
      expect(plan, isNotNull);
      expect(plan!.crossTier, isTrue);
      form.applySuggestion(plan);
      expect(form.baseUrlController.text, 'https://tts.acme.example/api/v1');
      expect(form.modelController.text, 'acme-voice-1');

      // 目标档不在下发与降级行集里：保守兜底，计划为 null，no-op。
      final blocked = form.planSuggestionApply(
        const VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'synthesis',
          targetProvider: 'never_heard_tier',
          targetModel: 'm',
          reason: 'r',
        ),
      );
      expect(blocked, isNull);
    });

    test('旧版宿主降级形态：快照无 tiers 时表单照常按降级目录工作', () {
      final form = TtsSettingsForm()
        ..sync(
          TtsSettings.fromJson({'configured': false, 'keySet': false}),
        );

      form.selectProvider('qwen_tts');
      // 降级目录回填缺省端点与型号（可用），与升级前行为一字不差。
      expect(form.provider, TtsServiceKind.qwenTts);
      expect(form.baseUrlController.text, qwenTtsDefaultEndpoint);
      expect(form.modelController.text, qwenTtsDefaultModel);
      // 降级目录冻结在已知四档：不会从降级形态里长出新档位知识。
      expect(form.tierChoices, hasLength(4));
      expect(form.tierChoices.any((tier) => tier.wireName == 'acme'), isFalse);
    });
  });
}

/// 固定快照的假网关：read 永远返回 [snapshotJson] 解析出的设置对象。
final class _FixedSnapshotGateway implements TtsSettingsGateway {
  Map<String, Object?> snapshotJson = {'configured': false, 'keySet': false};

  @override
  Future<TtsSettings> read() async => TtsSettings.fromJson(snapshotJson);

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) async =>
      TtsSettings.fromJson(snapshotJson);

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) async =>
      TtsSettings.fromJson(snapshotJson);

  @override
  Future<TtsSettings> forgetApiKey() async =>
      TtsSettings.fromJson(snapshotJson);

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) async =>
      const TtsConnectionTest(succeeded: true, message: '连接成功。');
}
