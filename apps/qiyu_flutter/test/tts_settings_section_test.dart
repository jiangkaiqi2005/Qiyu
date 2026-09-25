import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/settings/provider_catalog.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_section_shell.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_section.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_view_model.dart';

/// 语音朗读领域表单的单元测试：协议缺省值、同步（含 extraParams 的
/// JSON 编排）、音色与语速选择态、校验与保存编排都在 [TtsSettingsForm]
/// 内。
void main() {
  final gateway = _RecordingTtsGateway();
  late TtsSettingsViewModel viewModel;

  setUp(() {
    gateway.reset();
    viewModel = TtsSettingsViewModel(gateway, autoStart: false);
  });

  TtsSettingsForm form() {
    final value = TtsSettingsForm();
    value.sync(gateway.snapshot);
    return value;
  }

  test('未配置时按当前协议回填缺省地址、模型、首个音色预设与默认语速', () {
    final value = form();

    expect(value.provider, TtsServiceKind.openAiCompatible);
    expect(value.baseUrlController.text, isEmpty);
    expect(value.modelController.text, isEmpty);
    expect(value.voiceController.text, 'alloy');
    expect(value.speed, isNull);
    expect(value.extraParamsController.text, isEmpty);
    expect(value.voiceDropdownValue, 'alloy');
    expect(value.showCustomVoiceField, isFalse);
    expect(value.apiKeyController.text, isEmpty);
  });

  test('未配置的豆包协议回填火山端点、Resource-Id 与豆包首档音色', () {
    final value = form();
    value.selectProvider('volc_tts');

    expect(
      value.baseUrlController.text,
      'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
    );
    expect(value.modelController.text, 'seed-tts-2.0');
    expect(value.voiceController.text, 'zh_female_vv_uranus_bigtts');
  });

  test('未配置的千问协议回填 DashScope 端点、模型与缺省音色', () {
    final value = form();
    value.selectProvider('qwen_tts');

    expect(value.provider, TtsServiceKind.qwenTts);
    expect(value.baseUrlController.text, qwenTtsDefaultEndpoint);
    expect(value.modelController.text, qwenTtsDefaultModel);
    expect(value.voiceController.text, qwenTtsDefaultVoice);
    // 千问档没有预设音色目录：音色恒为自由输入态。
    expect(value.showCustomVoiceField, isTrue);
  });

  test('切到千问档丢掉语速草稿：千问档没有语速参数', () {
    final value = form();
    value.selectSpeed(1.5);

    value.selectProvider('qwen_tts');

    expect(value.speed, isNull);
  });

  test('千问档保存编排：自由音色 ID 与 extraParams 随草稿保存，无语速', () async {
    final value = form();
    value.selectProvider('qwen_tts');
    value.voiceController.text = 'Nofish';
    value.extraParamsController.text = '{"instructions": "用温柔的语气"}';
    value.apiKeyController.text = 'sk-dashscope';

    final saved = await value.save(viewModel, report: (_) {});

    expect(saved, isTrue);
    final draft = gateway.savedDrafts.single;
    expect(draft.provider, TtsServiceKind.qwenTts);
    expect(draft.baseUrl, qwenTtsDefaultEndpoint);
    expect(draft.model, qwenTtsDefaultModel);
    expect(draft.voice, 'Nofish');
    expect(draft.speed, isNull);
    expect(draft.extraParams, {'instructions': '用温柔的语气'});
    expect(draft.apiKey, 'sk-dashscope');
  });

  test('已配置时回填保存值：协议、地址、模型、自定义音色、语速与 extraParams', () {
    gateway.configured = true;
    final value = form();

    expect(value.provider, TtsServiceKind.volcTts);
    expect(value.baseUrlController.text, 'https://tts.example/v3');
    expect(value.modelController.text, 'tts-model');
    // 保存值不在当前协议预设目录里：按自定义音色态呈现并亮出输入框。
    expect(value.voiceController.text, 'my-voice-id');
    expect(value.voiceDropdownValue, customVoiceValue);
    expect(value.showCustomVoiceField, isTrue);
    expect(value.speed, 1.25);
    // 传输方式随快照回显（票三）。
    expect(value.transport, TtsTransport.wsBidirection);
    expect(
      value.extraParamsController.text,
      const JsonEncoder.withIndent('  ').convert({
        'audio_params': {'sample_rate': 16000},
      }),
    );
  });

  test('传输方式（票三）：豆包档随草稿上送，切档回落缺省', () {
    final value = form();
    expect(value.transport, TtsTransport.httpChunk);

    value.selectProvider('volc_tts');
    value.selectTransport('ws_bidirection');
    expect(value.transport, TtsTransport.wsBidirection);

    // 切到别的档：传输方式回落缺省（Host 侧也不为别的档落盘）。
    value.selectProvider('qwen_tts');
    expect(value.transport, TtsTransport.httpChunk);

    value.selectProvider('volc_tts');
    expect(value.transport, TtsTransport.httpChunk);
  });

  test('豆包档保存编排：传输方式随草稿上送，非豆包档不上送', () async {
    final value = form();
    value.selectProvider('volc_tts');
    value.selectTransport('ws_bidirection');

    final saved = await value.save(viewModel, report: (_) {});

    expect(saved, isTrue);
    final draft = gateway.savedDrafts.last;
    expect(draft.provider, TtsServiceKind.volcTts);
    expect(draft.transport, TtsTransport.wsBidirection);

    final other = form();
    other.selectProvider('qwen_tts');
    await other.save(viewModel, report: (_) {});
    expect(gateway.savedDrafts.last.transport, isNull);
  });

  testWidgets('传输方式下拉只在豆包档出现，其余档不出现', (tester) async {
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

    // 初值 OpenAI 兼容档：没有传输方式下拉。
    expect(find.byKey(const Key('tts-transport')), findsNothing);

    // 切到豆包档：下拉出现并默认 HTTP 分块。
    await tester.tap(find.byKey(const Key('tts-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('豆包语音合成').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tts-transport')), findsOneWidget);
    expect(find.text('HTTP 分块'), findsOneWidget);

    // 切到千问档：下拉不再出现（型号驱动，不做传输选择器）。
    await tester.tap(find.byKey(const Key('tts-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('千问语音合成').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tts-transport')), findsNothing);
  });

  testWidgets('获焦字段在同步时保留草稿，未获焦字段照常覆盖', (tester) async {
    final value = TtsSettingsForm();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(
            controller: value.baseUrlController,
            focusNode: value.baseUrlFocusNode,
          ),
        ),
      ),
    );
    await tester.showKeyboard(find.byType(TextField));
    value.baseUrlController.text = 'https://my-draft.example/v1';
    await tester.pump();
    expect(value.baseUrlFocusNode.hasFocus, isTrue, reason: '前置：字段已获焦');

    value.sync(gateway.snapshotWithConfigured());

    expect(
      value.baseUrlController.text,
      'https://my-draft.example/v1',
      reason: '获焦编辑中的草稿被同步冲掉了',
    );
    expect(value.modelController.text, 'tts-model');
  });

  testWidgets('模型框支持范围说明只在千问档出现，其余档不出现', (tester) async {
    // 区块嵌在设置页分节壳里：拉高视口保证模型框在命中范围内。
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

    const qwenModelHelp =
        '流式合成型号：$qwenTtsDefaultModel（HTTP SSE，边出文字边出声）'
        '；$qwenTtsDefaultModel-realtime（WebSocket，前几个字就出声）\n'
        '3.x 新型号（qwen-audio-3.1-tts-flash 等）走官方新版语音通道：'
        '服务地址直接填 $qwenTtsWsInferenceEndpoint（推理通道按句流式）；'
        '也可填官方 maas HTTP 端点 $qwenTtsMaasAddressTemplate，'
        '把 {业务空间ID} 换成你自己的阿里云百炼业务空间 ID'
        '（栖语不代填，按句等整段返回）；型号支持范围见'
        '官方模型页：https://help.aliyun.com/zh/model-studio/qwen-tts';

    // 说明归属锁死在模型名称框：helperText 渲染在 TextField 子树内，同一句
    // 误挂到服务地址等别的框上时断言会红。
    Finder modelFieldHelp() => find.descendant(
      of: find.byKey(const Key('tts-model')),
      matching: find.text(qwenModelHelp),
    );

    // 初值 OpenAI 兼容档：模型框旁没有支持范围说明。
    expect(modelFieldHelp(), findsNothing);

    // 切到千问档：说明出现在模型名称框旁，且只渲染一处。
    await tester.tap(find.byKey(const Key('tts-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('千问语音合成').last);
    await tester.pumpAndSettle();
    expect(modelFieldHelp(), findsOneWidget);
    // 全页也只此一处：同一句不得重复挂到别的字段上。
    expect(find.text(qwenModelHelp), findsOneWidget);

    // 切到豆包档：说明不再出现。
    await tester.tap(find.byKey(const Key('tts-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('豆包语音合成').last);
    await tester.pumpAndSettle();
    expect(modelFieldHelp(), findsNothing);

    // 切到自定义档：同样不出现。
    await tester.tap(find.byKey(const Key('tts-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义合成服务').last);
    await tester.pumpAndSettle();
    expect(modelFieldHelp(), findsNothing);
  });

  test('同一份设置重复同步是幂等的，不重置输入中的草稿', () {
    final settings = gateway.snapshot;
    final value = TtsSettingsForm();
    value.sync(settings);
    value.baseUrlController.text = 'https://my-draft.example/v1';

    value.sync(settings);

    expect(value.baseUrlController.text, 'https://my-draft.example/v1');
  });

  test('选择预设音色落名，「输入其他音色 ID」切自定义态并清空等待输入', () {
    final value = form();

    value.selectVoice('echo');
    expect(value.voiceController.text, 'echo');
    expect(value.showCustomVoiceField, isFalse);

    value.selectVoice(customVoiceValue);
    expect(value.voiceController.text, isEmpty);
    expect(value.voiceDropdownValue, customVoiceValue);
    expect(value.showCustomVoiceField, isTrue);
  });

  test('校验驳回空白服务地址或模型名称，并给出人话且不触达网关', () async {
    final value = form();
    value.baseUrlController.text = '   ';

    final reported = <String>[];
    final draft = value.readDraftOrReport(reported.add);

    expect(draft, isNull);
    expect(reported, ['请填写语音合成服务地址和模型名称。']);
    expect(gateway.saveCalls, 0);
  });

  test('校验驳回非法 JSON 与非对象 JSON 的自定义高级参数', () async {
    final value = form();
    value.baseUrlController.text = 'https://api.example.com/v1';
    value.modelController.text = 'tts-1';

    final reported = <String>[];
    value.extraParamsController.text = '{oops';
    expect(value.readDraftOrReport(reported.add), isNull, reason: '语法错误要驳回');
    expect(reported.single, '自定义高级参数 JSON 格式不正确，请检查语法。');

    reported.clear();
    value.extraParamsController.text = '[1, 2, 3]';
    expect(
      value.readDraftOrReport(reported.add),
      isNull,
      reason: '非 JSON 对象要驳回',
    );
    expect(reported.single, '自定义高级参数必须是 JSON 对象。');
    expect(gateway.saveCalls, 0);
  });

  testWidgets('自定义档响应形态下拉带流式/整段分工说明（F3 第一期）', (tester) async {
    // 区块嵌在设置页分节壳里：拉高视口保证下拉在命中范围内。
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

    const shapeHelp = '裸音频字节（且未覆盖成压缩格式）走流式分块合成；逐行 JSON 与 JSON 字段按句子级整段朗读';

    // 非自定义档没有这个旋钮，说明也不出现。
    expect(find.text(shapeHelp), findsNothing);

    // 切到自定义档：说明出现在响应形态旁，且只渲染一处。
    await tester.tap(find.byKey(const Key('tts-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义合成服务').last);
    await tester.pumpAndSettle();
    expect(find.text(shapeHelp), findsOneWidget);
    expect(find.byKey(const Key('tts-response-shape')), findsOneWidget);
  });

  testWidgets('OpenAI 兼容档高级参数示例标注压缩格式按句子级整段朗读', (tester) async {
    // 区块嵌在设置页分节壳里：拉高视口保证高级参数区在命中范围内。
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

    // 高级参数区默认收起：先展开再断言示例文案。
    await tester.tap(find.byKey(const Key('tts-advanced-params-tile')));
    await tester.pumpAndSettle();

    // 示例带降级标注：把 response_format 覆盖成压缩格式不再是静默的
    // 句子级整段播放。
    expect(
      find.text(
        '配置 OpenAI 兼容语音合成的顶层扩展参数，例如：\n'
        '{\n'
        '  "response_format": "mp3"\n'
        '}\n'
        '覆盖成压缩格式将按句子级整段朗读。',
      ),
      findsOneWidget,
    );
  });

  test('保存编排：合法草稿带着音色、语速与 extraParams 交给视图模型', () async {
    final value = form();
    value.baseUrlController.text = '  https://api.example.com/v1  ';
    value.modelController.text = 'tts-1';
    value.voiceController.text = 'alloy';
    value.selectSpeed(1.5);
    value.extraParamsController.text = '{"response_format": "mp3"}';
    value.apiKeyController.text = '  sk-tts  ';

    final saved = await value.save(viewModel, report: (_) {});

    expect(saved, isTrue);
    final draft = gateway.savedDrafts.single;
    expect(draft.baseUrl, 'https://api.example.com/v1');
    expect(draft.model, 'tts-1');
    expect(draft.voice, 'alloy');
    expect(draft.speed, 1.5);
    expect(draft.extraParams, {'response_format': 'mp3'});
    expect(draft.apiKey, 'sk-tts');
    // 保存成功后 Key 草稿即刻清空，不留明文在输入框。
    expect(value.apiKeyController.text, isEmpty);
  });

  test('保存编排：空白 Key 等价于不换 Key（存 null）', () async {
    final value = form();
    value.baseUrlController.text = 'https://api.example.com/v1';
    value.modelController.text = 'tts-1';
    value.apiKeyController.text = '   ';

    await value.save(viewModel, report: (_) {});

    expect(gateway.savedDrafts.single.apiKey, isNull);
  });

  test('保存编排：草稿不合法时不触达网关、不误报保存成功', () async {
    final value = form();
    value.baseUrlController.text = 'https://api.example.com/v1';
    value.modelController.text = 'tts-1';
    value.extraParamsController.text = '{oops';

    final reported = <String>[];
    final saved = await value.save(viewModel, report: reported.add);

    expect(saved, isFalse);
    expect(reported, ['自定义高级参数 JSON 格式不正确，请检查语法。']);
    expect(gateway.saveCalls, 0);
  });

  test('保存编排：网关失败时返回失败，Key 草稿保留待重试', () async {
    gateway.failSave = true;
    final value = form();
    value.baseUrlController.text = 'https://api.example.com/v1';
    value.modelController.text = 'tts-1';
    value.apiKeyController.text = 'sk-tts';

    final saved = await value.save(viewModel, report: (_) {});

    expect(saved, isFalse);
    expect(viewModel.errorMessage, isNotNull);
    expect(value.apiKeyController.text, 'sk-tts');
  });

  test('火山豆包保存与同步回显：方言音色（四川话）与滑动语速保存后正确回显且无状态丢失', () async {
    final value = form();
    value.selectProvider('volc_tts');
    value.selectVoice('zh_female_sichuan_uranus_bigtts');
    value.selectSpeed(0.8);
    value.apiKeyController.text = 'ark-test-key';

    final saved = await value.save(viewModel, report: (_) {});

    expect(saved, isTrue);
    final draft = gateway.savedDrafts.single;
    expect(draft.provider, TtsServiceKind.volcTts);
    expect(
      draft.baseUrl,
      'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
    );
    expect(draft.model, 'seed-tts-2.0');
    expect(draft.voice, 'zh_female_sichuan_uranus_bigtts');
    expect(draft.speed, 0.8);
    expect(draft.apiKey, 'ark-test-key');

    // 视图模型更新并同步回表单
    value.sync(viewModel.settings);
    expect(value.provider, TtsServiceKind.volcTts);
    expect(value.voiceController.text, 'zh_female_sichuan_uranus_bigtts');
    expect(value.voiceDropdownValue, 'zh_female_sichuan_uranus_bigtts');
    expect(value.showCustomVoiceField, isFalse);
    expect(value.speed, 0.8);
  });

  test('未配置的自定义协议回填空档：完整地址与模型都等用户填', () {
    final value = form();
    value.selectProvider('custom');

    expect(value.provider, TtsServiceKind.custom);
    expect(value.baseUrlController.text, isEmpty);
    expect(value.modelController.text, isEmpty);
    expect(
      value.protocolDefaults.urlHint,
      'https://api.example.com/v1/audio/speech',
    );
    // 旋钮缺省态：默认 Bearer（输入框留空）、裸音频字节、字段名缺省 data
    // （输入框留空）。
    expect(value.authHeaderController.text, isEmpty);
    expect(value.responseShape, TtsResponseShape.rawBytes);
    expect(value.responseFieldController.text, isEmpty);
    expect(value.extraParamsController.text, isEmpty);
    // 自定义档没有音色位：Spec 只给鉴权头/响应形态/字段名/高级参数四件套。
    expect(value.showCustomVoiceField, isFalse);
  });

  test('已配置自定义档回填旋钮：鉴权头、响应形态、字段名与高级参数 JSON', () {
    final value = TtsSettingsForm();
    value.sync(
      const TtsSettings(
        configured: true,
        keySet: true,
        provider: TtsServiceKind.custom,
        baseUrl: 'https://tts.example.com/v1/audio/speech',
        model: 'tts-test',
        authHeader: 'X-Api-Key',
        responseShape: TtsResponseShape.jsonField,
        responseField: 'result.audio',
        extraParams: {'voice': 'custom-voice'},
      ),
    );

    expect(value.provider, TtsServiceKind.custom);
    expect(
      value.baseUrlController.text,
      'https://tts.example.com/v1/audio/speech',
    );
    expect(value.authHeaderController.text, 'X-Api-Key');
    expect(value.responseShape, TtsResponseShape.jsonField);
    expect(value.responseFieldController.text, 'result.audio');
    expect(value.extraParamsController.text, '{\n  "voice": "custom-voice"\n}');
  });

  test('切到自定义档丢掉语速草稿：自定义档没有语速参数', () {
    final value = form();
    value.selectSpeed(1.5);

    value.selectProvider('custom');

    expect(value.speed, isNull);
  });

  test('协议切换：切走自定义档时清掉旋钮草稿，不残留到别的档', () {
    final value = form();
    value.selectProvider('custom');
    value.authHeaderController.text = 'X-Api-Key';
    value.selectResponseShape('json_lines');
    value.responseFieldController.text = 'result.audio';
    value.extraParamsController.text = '{"voice":"custom-voice"}';

    value.selectProvider('qwen_tts');

    expect(value.provider, TtsServiceKind.qwenTts);
    expect(value.authHeaderController.text, isEmpty);
    expect(value.responseShape, TtsResponseShape.rawBytes);
    expect(value.responseFieldController.text, isEmpty);
    expect(value.extraParamsController.text, isEmpty);
    // 千问档的音色 ID 输入框不受影响（既有露出条件保持）。
    expect(value.showCustomVoiceField, isTrue);
  });

  test('校验要求自定义高级参数是合法 JSON 对象', () {
    final scenarios = [
      (extraText: '[1,2]', message: '自定义高级参数必须是 JSON 对象。'),
      (extraText: '"text"', message: '自定义高级参数必须是 JSON 对象。'),
      (extraText: '{', message: '自定义高级参数 JSON 格式不正确，请检查语法。'),
    ];
    for (final scenario in scenarios) {
      final value = form();
      value.selectProvider('custom');
      value.baseUrlController.text = 'https://tts.example.com/v1/audio/speech';
      value.modelController.text = 'tts-test';
      value.extraParamsController.text = scenario.extraText;

      final reported = <String>[];
      final draft = value.readDraftOrReport(reported.add);

      expect(draft, isNull, reason: scenario.extraText);
      expect(reported, [scenario.message], reason: scenario.extraText);
      expect(gateway.saveCalls, 0);
    }
  });

  test('保存编排：自定义草稿带着旋钮与高级参数上送，鉴权头去空白', () async {
    final value = form();
    value.selectProvider('custom');
    value.baseUrlController.text = 'https://tts.example.com/v1/audio/speech';
    value.modelController.text = 'tts-test';
    value.apiKeyController.text = '  sk-custom  ';
    value.authHeaderController.text = '  X-Api-Key  ';
    value.selectResponseShape('json_lines');
    value.responseFieldController.text = 'result.audio';
    value.extraParamsController.text = '{"voice":"custom-voice"}';

    final saved = await value.save(viewModel, report: (_) {});

    expect(saved, isTrue);
    final draft = gateway.savedDrafts.single;
    expect(draft.provider, TtsServiceKind.custom);
    expect(draft.baseUrl, 'https://tts.example.com/v1/audio/speech');
    expect(draft.model, 'tts-test');
    expect(draft.apiKey, 'sk-custom');
    expect(draft.authHeader, 'X-Api-Key');
    expect(draft.responseShape, TtsResponseShape.jsonLines);
    expect(draft.responseField, 'result.audio');
    expect(draft.extraParams, {'voice': 'custom-voice'});
    // 保存成功后 Key 草稿即刻清空，不留明文在输入框。
    expect(value.apiKeyController.text, isEmpty);
  });

  test('保存编排：非自定义档草稿不带自定义旋钮', () async {
    final value = form();
    value.selectProvider('custom');
    value.authHeaderController.text = 'X-Api-Key';
    value.extraParamsController.text = '{"voice":"custom-voice"}';
    value.selectProvider('openai_compatible');
    value.baseUrlController.text = 'https://api.example.com/v1';
    value.modelController.text = 'tts-1';

    await value.save(viewModel, report: (_) {});

    final draft = gateway.savedDrafts.single;
    expect(draft.provider, TtsServiceKind.openAiCompatible);
    expect(draft.authHeader, isNull);
    expect(draft.responseShape, isNull);
    expect(draft.responseField, isNull);
  });
}

final class _RecordingTtsGateway implements TtsSettingsGateway {
  bool configured = false;
  bool failSave = false;
  final savedDrafts = <TtsSettingsDraft>[];
  int saveCalls = 0;

  void reset() {
    configured = false;
    failSave = false;
    savedDrafts.clear();
    saveCalls = 0;
  }

  TtsSettings get snapshot => TtsSettings(
    configured: configured,
    keySet: configured,
    provider: configured
        ? TtsServiceKind.volcTts
        : TtsServiceKind.openAiCompatible,
    baseUrl: configured ? 'https://tts.example/v3' : null,
    model: configured ? 'tts-model' : null,
    voice: configured ? 'my-voice-id' : null,
    speed: configured ? 1.25 : null,
    transport: configured
        ? TtsTransport.wsBidirection
        : TtsTransport.httpChunk,
    extraParams: configured
        ? {
            'audio_params': {'sample_rate': 16000},
          }
        : null,
  );

  TtsSettings snapshotWithConfigured() {
    configured = true;
    return snapshot;
  }

  @override
  Future<TtsSettings> read() async => snapshot;

  @override
  Future<TtsSettings> save(TtsSettingsDraft draft) async {
    saveCalls += 1;
    if (failSave) {
      throw const ProviderSettingsGatewayException('语音朗读设置暂时不可用，请稍后重试。');
    }
    savedDrafts.add(draft);
    return TtsSettings(
      configured: true,
      keySet: draft.apiKey != null,
      provider: draft.provider,
      baseUrl: draft.baseUrl,
      model: draft.model,
      voice: draft.voice,
      speed: draft.speed,
      extraParams: draft.extraParams,
    );
  }

  @override
  Future<TtsSettings> setAutoSpeak(bool enabled) async => snapshot;

  @override
  Future<TtsSettings> forgetApiKey() async {
    configured = true;
    return TtsSettings(
      configured: true,
      keySet: false,
      provider: TtsServiceKind.openAiCompatible,
      baseUrl: 'https://api.example.com/v1',
      model: 'tts-1',
    );
  }

  @override
  Future<TtsConnectionTest> testConnection(TtsSettingsDraft draft) async =>
      const TtsConnectionTest(succeeded: true, message: '连接成功。');
}
