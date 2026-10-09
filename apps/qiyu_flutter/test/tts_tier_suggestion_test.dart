import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/settings/settings_section_shell.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_section.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/voice_tier_suggestion.dart';

/// 档位建议引导卡片与确认制一键换档（ADR 0020）：连接测试命中映射表时
/// 当场出人话结论卡片，「按建议调整」先展示将要改成什么、确认后才写进
/// 表单草稿；3.1 新版端点不代填业务空间 ID（模板原文落草稿待替换）；
/// 跨档回填清 Key 草稿、同档保留。假设置服务钉死零出网之外的建议呈现
/// （出网判定归 Host 测试）；fixture 形状与 Host wire 逐字段一致。
void main() {
  const maasTemplate =
      'https://{业务空间ID}.cn-beijing.maas.aliyuncs.com'
      '/api/v1/services/audio/tts/SpeechSynthesizer';

  group('TtsConnectionTest 解析建议字段', () {
    test('switchTier 建议带缺省端点与原因', () {
      final result = TtsConnectionTest.fromJson({
        'ok': false,
        'status': 'modelInterfaceMismatch',
        'message': '这个型号要走千问朗读档。',
        'suggestion': {
          'kind': 'switchTier',
          'targetFamily': 'synthesis',
          'targetProvider': 'qwen_tts',
          'targetModel': 'qwen-audio-3.1-tts-flash',
          'defaultEndpoint': qwenTtsDefaultEndpoint,
          'reason': '这个型号要走千问朗读档。',
        },
      });
      expect(result.succeeded, isFalse);
      final suggestion = result.tierSuggestion;
      expect(suggestion, isNotNull);
      expect(suggestion!.kind, VoiceSuggestionKind.switchTier);
      expect(suggestion.targetsSynthesis, isTrue);
      expect(suggestion.targetProvider, 'qwen_tts');
      expect(suggestion.defaultEndpoint, qwenTtsDefaultEndpoint);
    });

    test('3.1 模板建议不代填端点，unsupported 建议带替代型号', () {
      final template = TtsConnectionTest.fromJson({
        'ok': false,
        'status': 'modelInterfaceMismatch',
        'message': '这个型号要走千问朗读档的新版语音通道。',
        'suggestion': {
          'kind': 'switchTier',
          'targetFamily': 'synthesis',
          'targetProvider': 'qwen_tts',
          'targetModel': 'qwen-audio-3.1-tts-flash',
          'addressTemplate': maasTemplate,
          'addressGuidance': '把 {业务空间ID} 换成你自己的业务空间 ID。',
          'reason': '这个型号要走千问朗读档的新版语音通道。',
        },
      }).tierSuggestion;
      expect(template!.defaultEndpoint, isNull);
      expect(template.addressTemplate, maasTemplate);
      expect(template.addressGuidance, isNotNull);

      final unsupported = TtsConnectionTest.fromJson({
        'ok': false,
        'status': 'modelInterfaceMismatch',
        'message': '这个型号是统一音频生成型号，官方没有给朗读用的通道，栖语接不了它。',
        'suggestion': {
          'kind': 'unsupported',
          'targetFamily': 'synthesis',
          'targetProvider': 'qwen_tts',
          'targetModel': 'qwen-audio-3.1-tts-flash',
          'reason': '这个型号是统一音频生成型号，官方没有给朗读用的通道，栖语接不了它。',
        },
      }).tierSuggestion;
      expect(unsupported!.kind, VoiceSuggestionKind.unsupported);
      expect(unsupported.targetModel, 'qwen-audio-3.1-tts-flash');
    });

    test('表 miss 与成功结果不带建议', () {
      expect(
        TtsConnectionTest.fromJson({
          'ok': true,
          'status': 'success',
          'message': '连接成功。',
        }).tierSuggestion,
        isNull,
      );
      expect(
        TtsConnectionTest.fromJson({
          'ok': false,
          'status': 'provider',
          'message': '语音合成服务拒绝了测试请求。',
        }).tierSuggestion,
        isNull,
      );
    });

    test('未知 kind 按应换档保守呈现（新 Host 旧界面的兜底）', () {
      final result = TtsConnectionTest.fromJson({
        'ok': false,
        'status': 'modelInterfaceMismatch',
        'message': 'x',
        'suggestion': {
          'kind': 'futureKind',
          'targetFamily': 'synthesis',
          'targetProvider': 'qwen_tts',
          'targetModel': 'm',
          'reason': 'r',
        },
      }).tierSuggestion;
      expect(result!.kind, VoiceSuggestionKind.switchTier);
    });
  });

  group('回填计划：展示与回填同源的推导', () {
    test('新版语音通道条目（推理地址＋备选模板并存）：同档也填推理地址', () {
      // 票 07：3.x 型号在现行地址上调不通，同档建议也要把地址换成
      // 官方推理地址；maas 模板只是卡片备选，不进草稿。
      final form = TtsSettingsForm();
      form.selectProvider('qwen_tts');
      form.baseUrlController.text =
          'https://ws-12345.cn-beijing.maas.aliyuncs.com'
          '/api/v1/services/audio/tts/SpeechSynthesizer';
      final plan = form.planSuggestionApply(
        VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'synthesis',
          targetProvider: 'qwen_tts',
          targetModel: 'qwen-audio-3.1-tts-flash',
          reason: '这个型号要走千问朗读档的新版语音通道。',
          defaultEndpoint: qwenTtsWsInferenceEndpoint,
          addressTemplate: maasTemplate,
        ),
      );
      expect(plan, isNotNull);
      expect(plan!.crossTier, isFalse);
      expect(plan.addressAction, RefillAddressAction.suggestedEndpoint);
      expect(plan.baseUrl, qwenTtsWsInferenceEndpoint);
      expect(plan.model, 'qwen-audio-3.1-tts-flash');
      // 回填按计划执行：地址换成推理地址、型号更新；同档不动 Key 草稿。
      form.applySuggestion(plan);
      expect(form.baseUrlController.text, qwenTtsWsInferenceEndpoint);
      expect(form.modelController.text, 'qwen-audio-3.1-tts-flash');
      form.dispose();
    });

    test('跨档模板建议：地址处置为模板草稿，跨档清 Key', () {
      // 防御形状：只有模板没有可代填端点的建议（旧 Host 形状）仍走
      // 模板草稿分支，`{业务空间ID}` 落草稿待用户替换。
      final form = TtsSettingsForm();
      final plan = form.planSuggestionApply(
        VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'synthesis',
          targetProvider: 'qwen_tts',
          targetModel: 'qwen-audio-3.1-tts-flash',
          reason: 'r',
          addressTemplate: maasTemplate,
        ),
      );
      expect(plan, isNotNull);
      expect(plan!.crossTier, isTrue);
      expect(plan.addressAction, RefillAddressAction.templateDraft);
      expect(plan.baseUrl, maasTemplate);
      expect(plan.model, 'qwen-audio-3.1-tts-flash');
      form.dispose();
    });

    test('同档建议：地址保持现状、不跨档', () {
      final form = TtsSettingsForm();
      form.baseUrlController.text = 'https://my-own.example/v1';
      final plan = form.planSuggestionApply(
        const VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.unsupported,
          targetFamily: 'synthesis',
          targetProvider: 'openai_compatible',
          targetModel: 'tts-1',
          reason: 'r',
        ),
      );
      expect(plan!.crossTier, isFalse);
      expect(plan.addressAction, RefillAddressAction.keepCurrent);
      expect(plan.baseUrl, 'https://my-own.example/v1');
      expect(plan.model, 'tts-1');
      form.dispose();
    });

    test('跨档且建议未给可填地址：计划权威照搬现状，回填等值写回', () {
      final form = TtsSettingsForm();
      form.baseUrlController.text = 'https://my-own.example/v1';
      form.modelController.text = 'old-model';
      form.apiKeyController.text = 'sk-draft';
      final plan = form.planSuggestionApply(
        const VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'synthesis',
          targetProvider: 'qwen_tts',
          targetModel: 'some-model',
          reason: 'r',
        ),
      );
      // 跨档但无端点与模板：地址处置 keepCurrent，计划里的地址就是现状。
      expect(plan!.crossTier, isTrue);
      expect(plan.addressAction, RefillAddressAction.keepCurrent);
      expect(plan.baseUrl, 'https://my-own.example/v1');
      // 回填按计划执行：地址等值写回（不变）、型号更新、Key 草稿清空。
      form.applySuggestion(plan);
      expect(form.baseUrlController.text, 'https://my-own.example/v1');
      expect(form.modelController.text, 'some-model');
      expect(form.apiKeyController.text, isEmpty);
      form.dispose();
    });

    test('目标档不在已知档位集合：计划为 null，回填 no-op', () {
      final form = TtsSettingsForm();
      final plan = form.planSuggestionApply(
        const VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'synthesis',
          targetProvider: 'future_tier',
          targetModel: 'm',
          reason: 'r',
        ),
      );
      expect(plan, isNull);
      // no-op：apply 不炸不改。
      form.applySuggestion(plan);
      expect(form.modelController.text, isEmpty);
      expect(form.baseUrlController.text, isEmpty);
      form.dispose();
    });
  });

  group('引导卡片与确认制回填', () {
    late _SuggestionTtsGateway gateway;
    late TtsSettingsViewModel viewModel;

    setUp(() {
      gateway = _SuggestionTtsGateway();
      viewModel = TtsSettingsViewModel(gateway, autoStart: false);
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
                child: ListView(children: const [TtsSettingsSection()]),
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
        find.byKey(const Key('tts-base-url')),
        'https://tts.example/v1',
      );
      await tester.enterText(
        find.byKey(const Key('tts-model')),
        'some-model',
      );
      await tester.tap(find.byKey(const Key('test-tts-connection')));
      await tester.pumpAndSettle();
    }

    TextField field(WidgetTester tester, String key) =>
        tester.widget<TextField>(find.byKey(Key(key)));

    testWidgets('命中映射表出引导卡片，表 miss 不出', (tester) async {
      gateway.testResult = const TtsConnectionTest(
        succeeded: false,
        message: '这个型号要走千问朗读档。',
        tierSuggestion: VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'synthesis',
          targetProvider: 'qwen_tts',
          targetModel: 'qwen-audio-3.1-tts-flash',
          reason: '这个型号要走千问朗读档。',
          defaultEndpoint: qwenTtsDefaultEndpoint,
        ),
      );
      await pumpSection(tester);
      await runConnectionTest(tester);

      expect(find.text('这个型号要走千问朗读档。'), findsOneWidget);
      expect(find.byKey(const Key('tts-tier-suggestion-apply')), findsOneWidget);
      // 明细多行合并在同一个 Text 里：按子串找。
      expect(find.textContaining('建议型号：qwen-audio-3.1-tts-flash'), findsOneWidget);

      // 表 miss：普通失败行，没有卡片与按钮。
      gateway.testResult = const TtsConnectionTest(
        succeeded: false,
        message: '语音合成服务拒绝了测试请求。',
      );
      await runConnectionTest(tester);
      expect(find.text('语音合成服务拒绝了测试请求。'), findsOneWidget);
      expect(find.byKey(const Key('tts-tier-suggestion-apply')), findsNothing);
    });

    testWidgets('确认制：先弹确认展示改动，再想想不改表单', (tester) async {
      gateway.testResult = const TtsConnectionTest(
        succeeded: false,
        message: '这个型号要走千问朗读档。',
        tierSuggestion: VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'synthesis',
          targetProvider: 'qwen_tts',
          targetModel: 'qwen-audio-3.1-tts-flash',
          reason: '这个型号要走千问朗读档。',
          defaultEndpoint: qwenTtsDefaultEndpoint,
        ),
      );
      await pumpSection(tester);
      await runConnectionTest(tester);

      await tester.tap(find.byKey(const Key('tts-tier-suggestion-apply')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tts-tier-suggestion-dialog')), findsOneWidget);
      expect(find.textContaining('OpenAI 兼容语音合成 → 千问语音合成'), findsOneWidget);
      expect(find.textContaining('API Key：清空重填'), findsOneWidget);

      await tester.tap(find.byKey(const Key('tts-tier-suggestion-cancel')));
      await tester.pumpAndSettle();
      expect(field(tester, 'tts-model').controller!.text, 'some-model');
      expect(field(tester, 'tts-base-url').controller!.text, 'https://tts.example/v1');
    });

    testWidgets('跨档回填：确认后切档、填建议地址与型号、清 Key 草稿', (tester) async {
      gateway.testResult = const TtsConnectionTest(
        succeeded: false,
        message: '这个型号要走千问朗读档。',
        tierSuggestion: VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'synthesis',
          targetProvider: 'qwen_tts',
          targetModel: 'qwen-audio-3.1-tts-flash',
          reason: '这个型号要走千问朗读档。',
          defaultEndpoint: qwenTtsDefaultEndpoint,
        ),
      );
      await pumpSection(tester);
      await tester.enterText(
        find.byKey(const Key('tts-api-key')),
        'sk-openai-draft',
      );
      await runConnectionTest(tester);

      await tester.tap(find.byKey(const Key('tts-tier-suggestion-apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tts-tier-suggestion-confirm')));
      await tester.pumpAndSettle();

      expect(field(tester, 'tts-model').controller!.text, 'qwen-audio-3.1-tts-flash');
      expect(
        field(tester, 'tts-base-url').controller!.text,
        qwenTtsDefaultEndpoint,
      );
      // 跨档清 Key 草稿：切换服务不沿用旧 Key。
      expect(field(tester, 'tts-api-key').controller!.text, isEmpty);
    });

    testWidgets('同档 3.x 建议：填推理地址＋型号，Key 草稿保留但如实说需重填', (tester) async {
      gateway.testResult = TtsConnectionTest(
        succeeded: false,
        message: '这个型号要走千问朗读档的新版语音通道。',
        tierSuggestion: VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'synthesis',
          targetProvider: 'qwen_tts',
          targetModel: 'qwen-audio-3.1-tts-flash',
          reason: '这个型号要走千问朗读档的新版语音通道。',
          // 票 07：推理地址可代填与 maas 备选模板并存下发。
          defaultEndpoint: qwenTtsWsInferenceEndpoint,
          addressTemplate: maasTemplate,
          addressGuidance: '把 {业务空间ID} 换成你自己的阿里云百炼业务空间 ID 后整条填入服务地址。',
        ),
      );
      await pumpSection(tester);
      // 千问档 + 现行 HTTP 地址草稿与 Key 草稿。
      await tester.tap(find.byKey(const Key('tts-provider')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('千问语音合成').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('tts-base-url')),
        'https://ws-12345.cn-beijing.maas.aliyuncs.com'
        '/api/v1/services/audio/tts/SpeechSynthesizer',
      );
      await tester.enterText(
        find.byKey(const Key('tts-api-key')),
        'sk-bailian',
      );
      await tester.enterText(
        find.byKey(const Key('tts-model')),
        'qwen-audio-3.1-tts-next',
      );
      await tester.tap(find.byKey(const Key('test-tts-connection')));
      await tester.pumpAndSettle();

      // 卡片明细：建议地址（推理地址）与地址模板（备选）并存。
      expect(find.textContaining('建议地址：$qwenTtsWsInferenceEndpoint'), findsOneWidget);
      expect(find.textContaining('地址模板：'), findsOneWidget);
      expect(find.textContaining('业务空间 ID'), findsWidgets);

      await tester.tap(find.byKey(const Key('tts-tier-suggestion-apply')));
      await tester.pumpAndSettle();
      // 同档确认框：地址换成官方推理地址；Key 草稿保留，但地址变更
      // 保存后按既有凭据规则需重填（既有机制如实说）。
      expect(find.textContaining('服务地址：填入官方推理地址'), findsOneWidget);
      expect(
        find.textContaining(qwenTtsWsInferenceEndpoint),
        findsWidgets,
      );
      expect(
        find.textContaining('API Key：地址变更保存后 Key 需重填'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('tts-tier-suggestion-confirm')));
      await tester.pumpAndSettle();

      // 型号与地址都按建议落草稿；Key 草稿原样保留（同档不清草稿，
      // 重填发生在保存换作用域之后）。
      expect(
        field(tester, 'tts-model').controller!.text,
        'qwen-audio-3.1-tts-flash',
      );
      expect(
        field(tester, 'tts-base-url').controller!.text,
        qwenTtsWsInferenceEndpoint,
      );
      expect(field(tester, 'tts-api-key').controller!.text, 'sk-bailian');
    });

    testWidgets('不支持型号：卡片给原因与替代型号，确认后按建议落位回填', (tester) async {
      // fixture 与 Host wire 一致：替代型号落位带可代填缺省端点。
      gateway.testResult = const TtsConnectionTest(
        succeeded: false,
        message: '这个型号是统一音频生成型号，官方没有给朗读用的通道，栖语接不了它。',
        tierSuggestion: VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.unsupported,
          targetFamily: 'synthesis',
          targetProvider: 'qwen_tts',
          targetModel: 'qwen-audio-3.1-tts-flash',
          reason: '这个型号是统一音频生成型号，官方没有给朗读用的通道，栖语接不了它。',
          defaultEndpoint: qwenTtsDefaultEndpoint,
        ),
      );
      await pumpSection(tester);
      await runConnectionTest(tester);

      expect(
        find.text('这个型号是统一音频生成型号，官方没有给朗读用的通道，栖语接不了它。'),
        findsOneWidget,
      );
      expect(find.text('可以改用 qwen-audio-3.1-tts-flash。'), findsOneWidget);

      await tester.tap(find.byKey(const Key('tts-tier-suggestion-apply')));
      await tester.pumpAndSettle();
      // 对话框如实显示建议地址行（替代落位的缺省端点可代填）。
      expect(find.textContaining('服务地址：填入建议地址'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tts-tier-suggestion-confirm')));
      await tester.pumpAndSettle();

      expect(field(tester, 'tts-model').controller!.text, 'qwen-audio-3.1-tts-flash');
      expect(
        field(tester, 'tts-base-url').controller!.text,
        qwenTtsDefaultEndpoint,
      );
    });

    testWidgets('跨档 3.x 建议：推理地址与型号落草稿，模板只留在卡片备选', (tester) async {
      gateway.testResult = TtsConnectionTest(
        succeeded: false,
        message: '这个型号要走千问朗读档的新版语音通道。',
        tierSuggestion: VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'synthesis',
          targetProvider: 'qwen_tts',
          targetModel: 'qwen-audio-3.1-tts-flash',
          reason: '这个型号要走千问朗读档的新版语音通道。',
          // 票 07：推理地址可代填为主，maas 模板降为备选信息。
          defaultEndpoint: qwenTtsWsInferenceEndpoint,
          addressTemplate: maasTemplate,
          addressGuidance: '把 {业务空间ID} 换成你自己的阿里云百炼业务空间 ID 后整条填入服务地址。',
        ),
      );
      await pumpSection(tester);
      await tester.enterText(
        find.byKey(const Key('tts-api-key')),
        'sk-openai-draft',
      );
      await runConnectionTest(tester);

      // 卡片明细里建议地址与备选模板并存。
      expect(find.textContaining('建议地址：$qwenTtsWsInferenceEndpoint'), findsOneWidget);
      expect(find.textContaining('地址模板：$maasTemplate'), findsOneWidget);

      await tester.tap(find.byKey(const Key('tts-tier-suggestion-apply')));
      await tester.pumpAndSettle();
      // 对话框如实显示：地址行写的就是将要落进地址栏的推理地址；Key
      // 行按跨档既有机制如实说清空重填。（推理地址对可用 Key 放行，
      // 不再附「需自有百炼 Key」。）
      Finder inDialog(Finder finder) => find.descendant(
        of: find.byKey(const Key('tts-tier-suggestion-dialog')),
        matching: finder,
      );
      expect(inDialog(find.textContaining('服务地址：填入官方推理地址')), findsOneWidget);
      expect(inDialog(find.textContaining(qwenTtsWsInferenceEndpoint)), findsOneWidget);
      expect(inDialog(find.textContaining('API Key：清空重填')), findsOneWidget);
      expect(inDialog(find.textContaining('新版端点需自有百炼 Key')), findsNothing);
      await tester.tap(inDialog(find.byKey(const Key('tts-tier-suggestion-confirm'))));
      await tester.pumpAndSettle();

      expect(
        field(tester, 'tts-model').controller!.text,
        'qwen-audio-3.1-tts-flash',
      );
      // 地址栏落的是可代填的官方推理地址。
      expect(
        field(tester, 'tts-base-url').controller!.text,
        qwenTtsWsInferenceEndpoint,
      );
      expect(field(tester, 'tts-api-key').controller!.text, isEmpty);
    });

    testWidgets('建议落在转写域：不亮回填按钮，卡片指路语音输入设置', (tester) async {
      gateway.testResult = const TtsConnectionTest(
        succeeded: false,
        message: '这个型号要走千问识别档。',
        tierSuggestion: VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'transcription',
          targetProvider: 'qwen_asr',
          targetModel: 'qwen-audio-3.1-asr-flash',
          reason: '这个型号要走千问识别档。',
        ),
      );
      await pumpSection(tester);
      await runConnectionTest(tester);

      expect(find.text('这个型号要走千问识别档。'), findsOneWidget);
      expect(find.textContaining('请到语音输入设置里调整'), findsOneWidget);
      expect(find.byKey(const Key('tts-tier-suggestion-apply')), findsNothing);
    });

    testWidgets('目标档不在已知档位集合：同域也不亮回填按钮（保守兜底）', (tester) async {
      gateway.testResult = const TtsConnectionTest(
        succeeded: false,
        message: 'x',
        tierSuggestion: VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'synthesis',
          targetProvider: 'future_tier',
          targetModel: 'm',
          reason: '这个型号要走某个本界面不认识的档。',
        ),
      );
      await pumpSection(tester);
      await runConnectionTest(tester);

      expect(find.byKey(const Key('tts-tier-suggestion-apply')), findsNothing);
    });

    testWidgets('卡片与按钮带读屏语义标签', (tester) async {
      final semantics = tester.ensureSemantics();
      gateway.testResult = const TtsConnectionTest(
        succeeded: false,
        message: '这个型号要走千问朗读档。',
        tierSuggestion: VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'synthesis',
          targetProvider: 'qwen_tts',
          targetModel: 'qwen-audio-3.1-tts-flash',
          reason: '这个型号要走千问朗读档。',
          defaultEndpoint: qwenTtsDefaultEndpoint,
        ),
      );
      await pumpSection(tester);
      await runConnectionTest(tester);

      // 语义节点会把标签与卡片内可见文字合并播报：按前缀锁定标签存在。
      expect(
        find.bySemanticsLabel(RegExp('^换档建议。这个型号要走千问朗读档。')),
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
      gateway.testResult = const TtsConnectionTest(
        succeeded: false,
        message: '这个型号要走千问朗读档。',
        tierSuggestion: VoiceTierSuggestionData(
          kind: VoiceSuggestionKind.switchTier,
          targetFamily: 'synthesis',
          targetProvider: 'qwen_tts',
          targetModel: 'qwen-audio-3.1-tts-flash',
          reason: '这个型号要走千问朗读档。',
          defaultEndpoint: qwenTtsDefaultEndpoint,
        ),
      );
      await pumpSection(tester, size: const Size(400, 2400));
      await runConnectionTest(tester);

      expect(
        find.byKey(const Key('tts-tier-suggestion-apply')),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const Key('tts-tier-suggestion-apply')),
      );
      await tester.tap(find.byKey(const Key('tts-tier-suggestion-apply')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('tts-tier-suggestion-dialog')),
        findsOneWidget,
      );
    });
  });
}

/// 假设置服务：测试结果由用例预置，其余动作与 [_SuggestionTtsGateway.snapshot]
/// 同口径回显；保存留档供断言。
final class _SuggestionTtsGateway implements TtsSettingsGateway {
  TtsConnectionTest testResult = const TtsConnectionTest(
    succeeded: false,
    message: '语音合成服务拒绝了测试请求。',
  );

  final savedDrafts = <TtsSettingsDraft>[];

  @override
  Future<TtsSettings> read() async => const TtsSettings(
    configured: false,
    keySet: false,
  );

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) async {
    savedDrafts.add(draft);
    return TtsSettings(
      configured: true,
      keySet: draft.apiKey != null,
      provider: draft.provider,
      baseUrl: draft.baseUrl,
      model: draft.model,
    );
  }

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) async =>
      const TtsSettings(configured: false, keySet: false);

  @override
  Future<TtsSettings> forgetApiKey() async =>
      const TtsSettings(configured: false, keySet: false);

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) async =>
      testResult;
}
