import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_section_shell.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_client.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_section.dart';
import 'package:qiyu_flutter/features/settings/stt_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/voice_tier_suggestion.dart';

/// 识别侧档位建议引导卡片与确认制一键换档（ADR 0020，票 04）：连接测试
/// 命中映射表时当场出人话结论卡片，「按建议调整」先展示将要改成什么、
/// 确认后才写进表单草稿；跨档回填清 Key 草稿、同档只改型号保 Key。假
/// 设置服务钉死零出网之外的建议呈现（出网判定归 Host 测试）；fixture
/// 形状与 Host wire 逐字段一致，复用与朗读侧同一张卡片与计划类型。
void main() {
  ProviderTestResult resultWithSuggestion(VoiceTierSuggestionData suggestion) =>
      ProviderTestResult(
        succeeded: false,
        status: ProviderTestStatus.modelInterfaceMismatch,
        message: suggestion.reason,
        tierSuggestion: suggestion,
      );

  group('ProviderTestResult 解析建议字段', () {
    test('switchTier 建议带缺省端点与原因', () {
      final result = ProviderTestResult.fromJson({
        'ok': false,
        'status': 'modelInterfaceMismatch',
        'message': '这个型号要走千问识别档。',
        'suggestion': {
          'kind': 'switchTier',
          'targetFamily': 'transcription',
          'targetProvider': 'qwen_asr',
          'targetModel': 'qwen3-asr-flash',
          'defaultEndpoint': qwenAsrDefaultEndpoint,
          'reason': '这个型号要走千问识别档。',
        },
      });
      expect(result.succeeded, isFalse);
      final suggestion = result.tierSuggestion;
      expect(suggestion, isNotNull);
      expect(suggestion!.kind, VoiceSuggestionKind.switchTier);
      expect(suggestion.targetsTranscription, isTrue);
      expect(suggestion.targetProvider, 'qwen_asr');
      expect(suggestion.defaultEndpoint, qwenAsrDefaultEndpoint);
    });

    test('unsupported 建议带替代型号，miss 与成功结果不带建议', () {
      final unsupported = ProviderTestResult.fromJson({
        'ok': false,
        'status': 'modelInterfaceMismatch',
        'message': '这是录音文件转写型号，栖语不支持。',
        'suggestion': {
          'kind': 'unsupported',
          'targetFamily': 'transcription',
          'targetProvider': 'qwen_asr',
          'targetModel': 'qwen3-asr-flash',
          'defaultEndpoint': qwenAsrDefaultEndpoint,
          'reason': '这是录音文件转写型号，栖语不支持。',
        },
      }).tierSuggestion;
      expect(unsupported!.kind, VoiceSuggestionKind.unsupported);
      expect(unsupported.targetModel, 'qwen3-asr-flash');

      expect(
        ProviderTestResult.fromJson({
          'ok': false,
          'status': 'provider',
          'message': '语音服务拒绝了测试请求。',
        }).tierSuggestion,
        isNull,
      );
      expect(
        ProviderTestResult.fromJson({
          'ok': true,
          'status': 'success',
          'message': '连接成功。',
        }).tierSuggestion,
        isNull,
      );
    });
  });

  group('回填计划：展示与回填同源的推导', () {
    test('跨档建议：地址处置为建议端点，跨档清 Key', () {
      final form = SttSettingsForm();
      form.apiKeyController.text = 'sk-openai-draft';
      final plan = form.planSuggestionApply(
        VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'transcription',
          targetProvider: 'qwen_asr',
          targetModel: 'qwen3-asr-flash',
          reason: '这个型号要走千问识别档。',
          defaultEndpoint: qwenAsrDefaultEndpoint,
        ),
      );
      expect(plan, isNotNull);
      expect(plan!.crossTier, isTrue);
      expect(plan.addressAction, RefillAddressAction.suggestedEndpoint);
      expect(plan.baseUrl, qwenAsrDefaultEndpoint);
      expect(plan.model, 'qwen3-asr-flash');
      form.dispose();
    });

    test('同档建议（替代型号就在当前档）：地址保持现状、不跨档', () {
      final form = SttSettingsForm();
      form.selectProvider('qwen_asr');
      final plan = form.planSuggestionApply(
        VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.unsupported,
          targetFamily: 'transcription',
          targetProvider: 'qwen_asr',
          targetModel: 'qwen3-asr-flash',
          reason: '这是录音文件转写型号，栖语不支持。',
          defaultEndpoint: qwenAsrDefaultEndpoint,
        ),
      );
      expect(plan!.crossTier, isFalse);
      expect(plan.addressAction, RefillAddressAction.keepCurrent);
      expect(plan.baseUrl, qwenAsrDefaultEndpoint);
      expect(plan.model, 'qwen3-asr-flash');
      form.dispose();
    });

    test('跨档且建议未给可填地址：计划权威照搬现状，回填等值写回', () {
      final form = SttSettingsForm();
      form.baseUrlController.text = 'https://my-own.example/v1';
      form.modelController.text = 'old-model';
      form.apiKeyController.text = 'sk-draft';
      final plan = form.planSuggestionApply(
        const VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'transcription',
          targetProvider: 'qwen_asr',
          targetModel: 'some-model',
          reason: 'r',
        ),
      );
      expect(plan!.crossTier, isTrue);
      expect(plan.addressAction, RefillAddressAction.keepCurrent);
      expect(plan.baseUrl, 'https://my-own.example/v1');
      form.applySuggestion(plan);
      expect(form.baseUrlController.text, 'https://my-own.example/v1');
      expect(form.modelController.text, 'some-model');
      expect(form.apiKeyController.text, isEmpty);
      form.dispose();
    });

    test('目标档不在已知档位集合：计划为 null，回填 no-op', () {
      final form = SttSettingsForm();
      final plan = form.planSuggestionApply(
        const VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'transcription',
          targetProvider: 'future_tier',
          targetModel: 'm',
          reason: 'r',
        ),
      );
      expect(plan, isNull);
      form.applySuggestion(plan);
      expect(form.modelController.text, isEmpty);
      expect(form.baseUrlController.text, isEmpty);
      form.dispose();
    });
  });

  group('引导卡片与确认制回填', () {
    late _SuggestionSttGateway gateway;
    late SttSettingsViewModel viewModel;

    setUp(() {
      gateway = _SuggestionSttGateway();
      viewModel = SttSettingsViewModel(gateway, autoStart: false);
    });

    Future<void> pumpSection(WidgetTester tester, {Size? size}) async {
      tester.view.physicalSize = size ?? const Size(1200, 4000);
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
                child: ListView(children: const [SttSettingsSection()]),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// 填表单并点「测试连接」：假网关随即返回网关里预置的测试结果。
    Future<void> runConnectionTest(WidgetTester tester) async {
      await tester.enterText(
        find.byKey(const Key('stt-base-url')),
        'https://stt.example/v1',
      );
      await tester.enterText(
        find.byKey(const Key('stt-model')),
        'some-model',
      );
      await tester.tap(find.byKey(const Key('test-stt-connection')));
      await tester.pumpAndSettle();
    }

    TextField field(WidgetTester tester, String key) =>
        tester.widget<TextField>(find.byKey(Key(key)));

    testWidgets('命中映射表出引导卡片，表 miss 不出', (tester) async {
      gateway.testResult = resultWithSuggestion(
        VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'transcription',
          targetProvider: 'qwen_asr',
          targetModel: 'qwen3-asr-flash',
          reason: '这个型号要走千问识别档。',
          defaultEndpoint: qwenAsrDefaultEndpoint,
        ),
      );
      await pumpSection(tester);
      await runConnectionTest(tester);

      expect(find.text('这个型号要走千问识别档。'), findsOneWidget);
      expect(find.byKey(const Key('stt-tier-suggestion-apply')), findsOneWidget);
      // 明细多行合并在同一个 Text 里：按子串找。
      expect(find.textContaining('建议型号：qwen3-asr-flash'), findsOneWidget);

      // 表 miss：普通失败行，没有卡片与按钮。
      gateway.testResult = const ProviderTestResult(
        succeeded: false,
        status: ProviderTestStatus.provider,
        message: '语音服务拒绝了测试请求。',
      );
      await runConnectionTest(tester);
      expect(find.text('语音服务拒绝了测试请求。'), findsOneWidget);
      expect(find.byKey(const Key('stt-tier-suggestion-apply')), findsNothing);
    });

    testWidgets('确认制：先弹确认展示改动，再想想不改表单', (tester) async {
      gateway.testResult = resultWithSuggestion(
        VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'transcription',
          targetProvider: 'qwen_asr',
          targetModel: 'qwen3-asr-flash',
          reason: '这个型号要走千问识别档。',
          defaultEndpoint: qwenAsrDefaultEndpoint,
        ),
      );
      await pumpSection(tester);
      await runConnectionTest(tester);

      await tester.tap(find.byKey(const Key('stt-tier-suggestion-apply')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stt-tier-suggestion-dialog')), findsOneWidget);
      expect(find.textContaining('OpenAI 兼容转写 → 千问语音识别'), findsOneWidget);
      expect(find.textContaining('API Key：清空重填'), findsOneWidget);

      await tester.tap(find.byKey(const Key('stt-tier-suggestion-cancel')));
      await tester.pumpAndSettle();
      expect(field(tester, 'stt-model').controller!.text, 'some-model');
      expect(field(tester, 'stt-base-url').controller!.text, 'https://stt.example/v1');
    });

    testWidgets('跨档回填：确认后切档、填建议地址与型号、清 Key 草稿', (tester) async {
      gateway.testResult = resultWithSuggestion(
        VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'transcription',
          targetProvider: 'qwen_asr',
          targetModel: 'qwen3-asr-flash',
          reason: '这个型号要走千问识别档。',
          defaultEndpoint: qwenAsrDefaultEndpoint,
        ),
      );
      await pumpSection(tester);
      await tester.enterText(
        find.byKey(const Key('stt-api-key')),
        'sk-openai-draft',
      );
      await runConnectionTest(tester);

      await tester.tap(find.byKey(const Key('stt-tier-suggestion-apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('stt-tier-suggestion-confirm')));
      await tester.pumpAndSettle();

      expect(field(tester, 'stt-model').controller!.text, 'qwen3-asr-flash');
      expect(
        field(tester, 'stt-base-url').controller!.text,
        qwenAsrDefaultEndpoint,
      );
      // 跨档清 Key 草稿：切换服务不沿用旧 Key。
      expect(field(tester, 'stt-api-key').controller!.text, isEmpty);
    });

    testWidgets('同档不支持型号：确认后只改型号，地址与 Key 草稿保留', (tester) async {
      gateway.testResult = resultWithSuggestion(
        VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.unsupported,
          targetFamily: 'transcription',
          targetProvider: 'qwen_asr',
          targetModel: 'qwen3-asr-flash',
          reason: '这是录音文件转写型号，栖语不支持。',
          defaultEndpoint: qwenAsrDefaultEndpoint,
        ),
      );
      await pumpSection(tester);
      // 千问识别档 + 已填不支持型号与 Key 草稿。
      await tester.tap(find.byKey(const Key('stt-provider')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('千问语音识别').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('stt-model')),
        'qwen-audio-3.1-asr-flash-filetrans',
      );
      await tester.enterText(
        find.byKey(const Key('stt-api-key')),
        'sk-bailian',
      );
      await tester.tap(find.byKey(const Key('test-stt-connection')));
      await tester.pumpAndSettle();

      // 卡片给原因与替代型号。
      expect(find.text('这是录音文件转写型号，栖语不支持。'), findsOneWidget);
      expect(find.text('可以改用 qwen3-asr-flash。'), findsOneWidget);

      await tester.tap(find.byKey(const Key('stt-tier-suggestion-apply')));
      await tester.pumpAndSettle();
      // 同档确认框如实说明：地址不变、Key 保留，型号行是旧值 → 替代型号。
      expect(find.textContaining('服务地址：不变'), findsOneWidget);
      expect(find.textContaining('API Key：保留'), findsOneWidget);
      expect(
        find.textContaining(
          'qwen-audio-3.1-asr-flash-filetrans → qwen3-asr-flash',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('stt-tier-suggestion-confirm')));
      await tester.pumpAndSettle();

      // 型号改成替代型号；地址与 Key 草稿原样保留。
      expect(field(tester, 'stt-model').controller!.text, 'qwen3-asr-flash');
      expect(
        field(tester, 'stt-base-url').controller!.text,
        qwenAsrDefaultEndpoint,
      );
      expect(field(tester, 'stt-api-key').controller!.text, 'sk-bailian');
    });

    testWidgets('建议落在朗读域：不亮回填按钮，卡片指路语音朗读设置', (tester) async {
      gateway.testResult = resultWithSuggestion(
        const VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'synthesis',
          targetProvider: 'qwen_tts',
          targetModel: 'qwen3-tts-flash',
          reason: '这个型号要走千问朗读档。',
        ),
      );
      await pumpSection(tester);
      await runConnectionTest(tester);

      expect(find.text('这个型号要走千问朗读档。'), findsOneWidget);
      expect(find.textContaining('请到语音朗读设置里调整'), findsOneWidget);
      expect(find.byKey(const Key('stt-tier-suggestion-apply')), findsNothing);
    });

    testWidgets('目标档不在已知档位集合：同域也不亮回填按钮（保守兜底）', (tester) async {
      gateway.testResult = resultWithSuggestion(
        const VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'transcription',
          targetProvider: 'future_tier',
          targetModel: 'm',
          reason: '这个型号要走某个本界面不认识的档。',
        ),
      );
      await pumpSection(tester);
      await runConnectionTest(tester);

      expect(find.byKey(const Key('stt-tier-suggestion-apply')), findsNothing);
    });

    testWidgets('卡片与按钮带读屏语义标签', (tester) async {
      final semantics = tester.ensureSemantics();
      gateway.testResult = resultWithSuggestion(
        VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'transcription',
          targetProvider: 'qwen_asr',
          targetModel: 'qwen3-asr-flash',
          reason: '这个型号要走千问识别档。',
          defaultEndpoint: qwenAsrDefaultEndpoint,
        ),
      );
      await pumpSection(tester);
      await runConnectionTest(tester);

      // 语义节点会把标签与卡片内可见文字合并播报：按前缀锁定标签存在。
      expect(
        find.bySemanticsLabel(RegExp('^换档建议。这个型号要走千问识别档。')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('^按建议调整，自动填好建议的档位、地址与型号')),
        findsOneWidget,
      );
      // 测试框架在测试体结束即校验句柄释放， teardown 来不及。
      semantics.dispose();
    });

    testWidgets('窄屏同款可用：卡片与按钮在 400px 视口内可点', (tester) async {
      gateway.testResult = resultWithSuggestion(
        VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'transcription',
          targetProvider: 'qwen_asr',
          targetModel: 'qwen3-asr-flash',
          reason: '这个型号要走千问识别档。',
          defaultEndpoint: qwenAsrDefaultEndpoint,
        ),
      );
      await pumpSection(tester, size: const Size(400, 2400));
      await runConnectionTest(tester);

      expect(
        find.byKey(const Key('stt-tier-suggestion-apply')),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const Key('stt-tier-suggestion-apply')),
      );
      await tester.tap(find.byKey(const Key('stt-tier-suggestion-apply')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('stt-tier-suggestion-dialog')),
        findsOneWidget,
      );
    });
  });
}

/// 假设置服务：测试结果由用例预置，其余动作与快照同口径回显；保存留档
/// 供断言。
final class _SuggestionSttGateway implements SttSettingsGateway {
  ProviderTestResult testResult = const ProviderTestResult(
    succeeded: false,
    status: ProviderTestStatus.provider,
    message: '语音服务拒绝了测试请求。',
  );

  final savedDrafts = <SttSettingsDraft>[];

  @override
  Future<SttSettings> read() async =>
      const SttSettings(configured: false, keySet: false);

  @override
  Future<SttSettings> save(SttSettingsDraft draft) async {
    savedDrafts.add(draft);
    return SttSettings(
      configured: true,
      keySet: draft.apiKey != null,
      provider: draft.provider,
      baseUrl: draft.baseUrl,
      model: draft.model,
    );
  }

  @override
  Future<SttSettings> forgetApiKey() async =>
      const SttSettings(configured: false, keySet: false);

  @override
  Future<ProviderTestResult> testConnection(SttSettingsDraft draft) async =>
      testResult;
}
