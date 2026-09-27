import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_section.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/proxy_settings_client.dart';
import 'package:qiyu_flutter/features/settings/proxy_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/settings_section_shell.dart';

import 'support/shared_fakes.dart';

/// 出站代理块（ticket 08）的表单单元测试与区块 widget 测试：同步、
/// 草稿校验与保存编排都在 [ProxySettingsForm] 内；widget 层锁保存/
/// 回显与开关呈现。
void main() {
  final gateway = _RecordingProxyGateway();
  late ProxySettingsViewModel viewModel;

  setUp(() {
    gateway.reset();
    viewModel = ProxySettingsViewModel(gateway, autoStart: false);
  });

  test('已保存设置回显：开关、地址与端口', () {
    final value = ProxySettingsForm();
    value.sync(
      const ProxySettings(
        configured: true,
        enabled: true,
        host: '192.168.1.2',
        port: 7890,
      ),
    );

    expect(value.enabled, isTrue);
    expect(value.hostController.text, '192.168.1.2');
    expect(value.portController.text, '7890');
  });

  test('端口 0（未填）同步为空串；未配置快照回显关闭态', () {
    final value = ProxySettingsForm();
    value.sync(
      const ProxySettings(configured: false, enabled: false, host: '', port: 0),
    );
    expect(value.enabled, isFalse);
    expect(value.portController.text, isEmpty);
  });

  test('同一份设置重复同步是幂等的，不重置输入中的草稿', () {
    final value = ProxySettingsForm();
    final settings = const ProxySettings(
      configured: false,
      enabled: false,
      host: '',
      port: 0,
    );
    value.sync(settings);
    value.hostController.text = 'proxy.lan';

    value.sync(settings);

    expect(value.hostController.text, 'proxy.lan');
  });

  test('启用时地址与端口必填，缺一项给出人话且不上送', () async {
    final value = ProxySettingsForm();
    value.enabled = true;

    final reports = <String>[];
    expect(value.readDraftOrReport(reports.add), isNull);
    expect(reports.single, contains('代理地址'));

    value.hostController.text = 'proxy.lan';
    value.portController.text = '';
    expect(value.readDraftOrReport(reports.add), isNull);
    expect(reports.last, contains('端口'));

    value.portController.text = '70000';
    expect(value.readDraftOrReport(reports.add), isNull);
    expect(reports.last, contains('1 到 65535'));
  });

  test('地址带 http:// 前缀被拒，关闭态可只留地址端口备改', () async {
    final value = ProxySettingsForm();
    value.hostController.text = 'http://proxy.lan';
    value.portController.text = '7890';

    final reports = <String>[];
    expect(value.readDraftOrReport(reports.add), isNull);
    expect(reports.single, contains('前缀'));

    // 关闭态保留已填值合法（用户想暂时关掉、保留配置）。
    value.hostController.text = 'proxy.lan';
    final draft = value.readDraftOrReport((_) {});
    expect(draft, isNotNull);
    expect(draft!.enabled, isFalse);
    expect(draft.host, 'proxy.lan');
    expect(draft.port, 7890);
  });

  test('保存编排：启用中的草稿原样上送，校验失败不上送', () async {
    final value = ProxySettingsForm();
    value.enabled = true;
    value.hostController.text = ' proxy.lan ';
    value.portController.text = '7890';

    final saved = await value.save(viewModel);
    expect(saved, isTrue);
    expect(gateway.savedDrafts.single.enabled, isTrue);
    expect(gateway.savedDrafts.single.host, 'proxy.lan');
    expect(gateway.savedDrafts.single.port, 7890);

    gateway.failSave = true;
    final savedAgain = await value.save(viewModel, report: (_) {});
    // 网关失败不是校验拒绝：草稿已上送，页面只显示人话错误。
    expect(savedAgain, isFalse);
    expect(gateway.savedDrafts, hasLength(2));
    expect(viewModel.errorMessage, isNotNull);
  });

  testWidgets('局域网地址提示：可编辑地址的套餐（Ollama）下出现在地址框旁', (tester) async {
    final providerViewModel = ProviderSettingsViewModel(
      const FixedProviderSettingsGateway(),
      autoStart: false,
    );
    await providerViewModel.initialize();
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: providerViewModel),
          ChangeNotifierProvider.value(value: viewModel),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SettingsSectionCollapseScope(
              collapsed: const {},
              onToggle: (_) {},
              child: ListView(children: const [ProviderSettingsSection()]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 未配置初值是 OpenAI 官方套餐（地址不可编辑），提示不在树上。
    expect(find.text('局域网地址请填 IP（明文 HTTP 不接受主机名）'), findsNothing);

    // 切到 Ollama（地址可编辑）：提示出现在服务地址框旁。
    await tester.tap(find.byKey(const Key('provider-preset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ollama（本机）').last);
    await tester.pumpAndSettle();
    expect(find.text('局域网地址请填 IP（明文 HTTP 不接受主机名）'), findsOneWidget);
  });

  testWidgets('区块呈现：开关、字段与保存按钮，保存后回显', (tester) async {
    gateway.snapshot = const ProxySettings(
      configured: true,
      enabled: true,
      host: '192.168.1.2',
      port: 7890,
    );
    await viewModel.initialize();
    // 区块嵌在「模型连接」节内，宿主必须同时提供两个领域的视图模型。
    final providerViewModel = ProviderSettingsViewModel(
      const FixedProviderSettingsGateway(),
      autoStart: false,
    );
    await providerViewModel.initialize();
    // 代理块在分节末尾：拉高视口保证开关与保存钮都在命中范围。
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: providerViewModel),
          ChangeNotifierProvider.value(value: viewModel),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SettingsSectionCollapseScope(
              collapsed: const {},
              onToggle: (_) {},
              child: ListView(children: const [ProviderSettingsSection()]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(
      find.byKey(const Key('provider-proxy-enabled')),
    ).value, isTrue);
    expect(
      tester.widget<TextField>(
        find.byKey(const Key('provider-proxy-host')),
      ).controller!.text,
      '192.168.1.2',
    );
    expect(
      tester.widget<TextField>(
        find.byKey(const Key('provider-proxy-port')),
      ).controller!.text,
      '7890',
    );

    // 关掉开关再保存：新快照回显关闭态。
    await tester.ensureVisible(find.byKey(const Key('provider-proxy-enabled')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('provider-proxy-enabled')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('save-proxy-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-proxy-settings')));
    await tester.pumpAndSettle();

    expect(gateway.savedDrafts.last.enabled, isFalse);
    expect(tester.widget<Switch>(
      find.byKey(const Key('provider-proxy-enabled')),
    ).value, isFalse);
  });
}

final class _RecordingProxyGateway implements ProxySettingsGateway {
  ProxySettings snapshot = const ProxySettings(
    configured: false,
    enabled: false,
    host: '',
    port: 0,
  );
  bool failSave = false;
  final savedDrafts = <ProxySettingsDraft>[];

  void reset() {
    snapshot = const ProxySettings(
      configured: false,
      enabled: false,
      host: '',
      port: 0,
    );
    failSave = false;
    savedDrafts.clear();
  }

  @override
  Future<ProxySettings> read() async => snapshot;

  @override
  Future<ProxySettings> save(ProxySettingsDraft draft) async {
    savedDrafts.add(draft);
    if (failSave) {
      throw const ProxySettingsGatewayException('代理设置暂时不可用，请稍后重试。');
    }
    snapshot = ProxySettings(
      configured: draft.enabled,
      enabled: draft.enabled,
      host: draft.host,
      port: draft.port,
    );
    return snapshot;
  }
}
