import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/settings/web_search_settings_client.dart';
import 'package:qiyu_flutter/features/settings/web_search_settings_section.dart';
import 'package:qiyu_flutter/features/settings/web_search_settings_view_model.dart';

/// 联网搜索领域表单的单元测试：Key 草稿的同步、保存编排（去空白、
/// 空值存 null、成败都清草稿）都在 [WebSearchSettingsForm] 内。
void main() {
  final gateway = _RecordingWebSearchGateway();
  late WebSearchSettingsViewModel viewModel;

  setUp(() {
    gateway.reset();
    viewModel = WebSearchSettingsViewModel(gateway, autoStart: false);
  });

  test('同一份设置重复同步是幂等的，不重置输入中的草稿', () {
    final value = WebSearchSettingsForm();
    final settings = gateway.snapshot;
    value.sync(settings);
    value.apiKeyController.text = 'sk-草稿';

    value.sync(settings);

    expect(value.apiKeyController.text, 'sk-草稿');
  });

  testWidgets('未获焦时同步清掉残留 Key 草稿，获焦时保留', (tester) async {
    final value = WebSearchSettingsForm();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(
            controller: value.apiKeyController,
            focusNode: value.apiKeyFocusNode,
          ),
        ),
      ),
    );

    // 残留草稿 + 新设置到达：未获焦，草稿被清掉，不把旧 Key 带进下一轮。
    value.apiKeyController.text = 'stale-key';
    value.sync(gateway.snapshotWithKey());
    expect(value.apiKeyController.text, isEmpty);

    // 获焦编辑中的草稿不被同步冲掉。
    await tester.showKeyboard(find.byType(TextField));
    value.apiKeyController.text = 'sk-填到一半';
    await tester.pump();
    value.sync(gateway.snapshotWithKey());
    expect(value.apiKeyController.text, 'sk-填到一半');
  });

  test('保存编排：Key 去除首尾空白后上送，空白等价于不换 Key（存 null）', () async {
    final value = WebSearchSettingsForm();
    value.apiKeyController.text = '  sk-anysearch  ';

    final saved = await value.save(viewModel);

    expect(saved, isTrue);
    expect(gateway.savedApiKeys.single, 'sk-anysearch');

    value.apiKeyController.text = '   ';
    await value.save(viewModel);

    expect(gateway.savedApiKeys.last, isNull);
  });

  test('保存编排：成败都清掉 Key 草稿，不让明文留在输入框', () async {
    final value = WebSearchSettingsForm();
    value.apiKeyController.text = 'sk-anysearch';

    await value.save(viewModel);
    expect(value.apiKeyController.text, isEmpty);

    // 保存失败：字段同样被清空（页面只显示人话错误，Key 草稿不回填）。
    gateway.failSave = true;
    value.apiKeyController.text = 'sk-retry';
    final saved = await value.save(viewModel);

    expect(saved, isFalse);
    expect(viewModel.errorMessage, isNotNull);
    expect(value.apiKeyController.text, isEmpty);
  });
}

final class _RecordingWebSearchGateway implements WebSearchSettingsGateway {
  bool failSave = false;
  final savedApiKeys = <String?>[];

  void reset() {
    failSave = false;
    savedApiKeys.clear();
  }

  WebSearchSettings get snapshot =>
      WebSearchSettings(configured: false, keySet: false);

  WebSearchSettings snapshotWithKey() =>
      WebSearchSettings(configured: true, keySet: true);

  @override
  Future<WebSearchSettings> read() async => snapshot;

  @override
  Future<WebSearchSettings> save(WebSearchSettingsDraft draft) async {
    savedApiKeys.add(draft.apiKey);
    if (failSave) {
      throw const WebSearchSettingsGatewayException('联网搜索设置暂时不可用，请稍后重试。');
    }
    return snapshot;
  }

  @override
  Future<WebSearchSettings> forgetApiKey() async => snapshot;
}
