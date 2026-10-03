import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:qiyu_flutter/features/chat/voice_recorder_platform.dart';
import 'package:qiyu_flutter/features/settings/omni_startup_settings.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_section.dart';
import 'package:qiyu_flutter/features/settings/proxy_settings_client.dart';
import 'package:qiyu_flutter/features/settings/proxy_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/settings_section_shell.dart';

void main() {
  testWidgets('启动偏好保存不清空未保存的模型或 Key 草稿', (tester) async {
    final gateway = _Gateway();
    final form = ProviderSettingsForm();
    addTearDown(form.dispose);
    form.sync(gateway.value);
    form.modelController.text = 'unsaved-model';
    form.apiKeyController.text = 'unsaved-private-key';
    final updated = await gateway.save(
      ProviderSettingsDraft(
        provider: gateway.value.provider!,
        baseUrl: gateway.value.baseUrl!,
        model: gateway.value.model!,
        temperature: gateway.value.temperature!,
        timeoutSeconds: gateway.value.timeoutSeconds!,
        callStartupMode: CallStartupMode.autoOnChatEntry,
      ),
    );
    form.sync(updated);
    form.sync(updated);
    expect(form.modelController.text, 'unsaved-model');
    expect(form.apiKeyController.text, 'unsaved-private-key');
  });

  testWidgets('现有设置区域只在选中 Omni 时显示启动选项', (tester) async {
    final gateway = _Gateway();
    final viewModel = ProviderSettingsViewModel(gateway, autoStart: false);
    await viewModel.initialize();
    final proxy = ProxySettingsViewModel(_ProxyGateway(), autoStart: false);
    await proxy.initialize();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: viewModel),
          ChangeNotifierProvider.value(value: proxy),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SettingsSectionCollapseScope(
              collapsed: const {},
              onToggle: (_) {},
              child: const SingleChildScrollView(
                child: ProviderSettingsSection(),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('通话启动方式'), findsOneWidget);
    await viewModel.save(
      const ProviderSettingsDraft(
        provider: ProviderKind.anthropic,
        baseUrl: 'https://other.example.com',
        model: 'other',
        temperature: 0.7,
        timeoutSeconds: 30,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('通话启动方式'), findsNothing);
  });

  testWidgets('首次许可后保存自动方式，且仅修改有效配置的偏好', (tester) async {
    final gateway = _Gateway();
    final permission = _Permission()
      ..pending = Completer<VoicePermissionResult>();
    final viewModel = ProviderSettingsViewModel(gateway, autoStart: false);
    await viewModel.initialize();
    await tester.pumpWidget(_page(viewModel, permission));
    await tester.tap(find.byKey(const Key('omni-startup-auto')));
    await tester.pump();
    expect(gateway.saved, isEmpty);
    permission.pending!.complete(VoicePermissionResult.grantedNow);
    await tester.pumpAndSettle();
    expect(
      viewModel.settings!.callStartupMode,
      CallStartupMode.autoOnChatEntry,
    );
    expect(gateway.saved.single.apiKey, isNull);
    expect(gateway.saved.single.model, 'saved-omni-model');
    expect(permission.calls, 1);
  });

  for (final result in VoicePermissionResult.values) {
    testWidgets('权限结果 $result 仅在已获授权时启用自动', (tester) async {
      final gateway = _Gateway();
      final permission = _Permission()..result = result;
      final viewModel = ProviderSettingsViewModel(gateway, autoStart: false);
      await viewModel.initialize();
      await tester.pumpWidget(_page(viewModel, permission));
      await tester.tap(find.byKey(const Key('omni-startup-auto')));
      await tester.pumpAndSettle();
      expect(
        viewModel.settings!.callStartupMode,
        result == VoicePermissionResult.denied
            ? CallStartupMode.manual
            : CallStartupMode.autoOnChatEntry,
      );
      if (result == VoicePermissionResult.denied) {
        expect(gateway.saved, isEmpty);
        expect(find.textContaining('未获得麦克风权限'), findsOneWidget);
      }
    });
  }

  testWidgets('权限取消或永久拒绝保留手动，无重复申请或确认框', (tester) async {
    final gateway = _Gateway();
    final permission = _Permission()..error = true;
    final viewModel = ProviderSettingsViewModel(gateway, autoStart: false);
    await viewModel.initialize();
    await tester.pumpWidget(_page(viewModel, permission));
    await tester.tap(find.byKey(const Key('omni-startup-auto')));
    await tester.pumpAndSettle();
    expect(gateway.saved, isEmpty);
    expect(permission.calls, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(viewModel.settings!.callStartupMode, CallStartupMode.manual);
  });

  testWidgets('保存失败显示现有有效手动选择与真实错误', (tester) async {
    final gateway = _Gateway()..failSave = true;
    final permission = _Permission();
    final viewModel = ProviderSettingsViewModel(gateway, autoStart: false);
    await viewModel.initialize();
    await tester.pumpWidget(_page(viewModel, permission));
    await tester.tap(find.byKey(const Key('omni-startup-auto')));
    await tester.pumpAndSettle();
    expect(viewModel.settings!.callStartupMode, CallStartupMode.manual);
    expect(find.text('保存失败，请重试。'), findsOneWidget);
    final group = tester.widget<RadioGroup<CallStartupMode>>(
      find.byType(RadioGroup<CallStartupMode>),
    );
    expect(group.groupValue, CallStartupMode.manual);
  });

  for (final cancellation in ['改选手动', '切换 Provider', '离开设置']) {
    testWidgets('授权等待期间 $cancellation 使旧许可失效', (tester) async {
      final gateway = _Gateway();
      final permission = _Permission()
        ..pending = Completer<VoicePermissionResult>();
      final viewModel = ProviderSettingsViewModel(gateway, autoStart: false);
      await viewModel.initialize();
      await tester.pumpWidget(_page(viewModel, permission));
      await tester.tap(find.byKey(const Key('omni-startup-auto')));
      await tester.pump();
      switch (cancellation) {
        case '改选手动':
          await tester.tap(find.byKey(const Key('omni-startup-manual')));
          await tester.pump();
        case '切换 Provider':
          await viewModel.save(
            const ProviderSettingsDraft(
              provider: ProviderKind.anthropic,
              baseUrl: 'https://other.example.com',
              model: 'other',
              temperature: 0.7,
              timeoutSeconds: 30,
            ),
          );
          await tester.pump();
          gateway.saved.clear();
        case '离开设置':
          await tester.pumpWidget(const SizedBox.shrink());
      }
      permission.pending!.complete(VoicePermissionResult.grantedNow);
      await tester.pumpAndSettle();
      expect(gateway.saved, isEmpty);
      expect(viewModel.settings!.callStartupMode, CallStartupMode.manual);
    });
  }

  testWidgets('设置保持挂载时路由离开再回来也使旧许可失效', (tester) async {
    final gateway = _Gateway();
    final permission = _Permission()
      ..pending = Completer<VoicePermissionResult>();
    final viewModel = ProviderSettingsViewModel(gateway, autoStart: false);
    await viewModel.initialize();
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        ShellRoute(
          builder: (context, state, child) => Scaffold(
            body: Column(
              children: [
                OmniStartupSettings(permission: permission),
                child,
              ],
            ),
          ),
          routes: [
            GoRoute(path: '/settings', builder: (_, _) => const Text('设置')),
            GoRoute(path: '/other', builder: (_, _) => const Text('其他页')),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: viewModel,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('omni-startup-auto')));
    await tester.pump();
    router.go('/other');
    await tester.pumpAndSettle();
    router.go('/settings');
    await tester.pumpAndSettle();
    permission.pending!.complete(VoicePermissionResult.grantedNow);
    await tester.pumpAndSettle();
    expect(gateway.saved, isEmpty);
  });

  testWidgets('从自动改为手动无需再申请权限', (tester) async {
    final gateway = _Gateway();
    final permission = _Permission();
    final viewModel = ProviderSettingsViewModel(gateway, autoStart: false);
    await viewModel.initialize();
    await tester.pumpWidget(_page(viewModel, permission));
    await tester.tap(find.byKey(const Key('omni-startup-auto')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('omni-startup-manual')));
    await tester.pumpAndSettle();
    expect(viewModel.settings!.callStartupMode, CallStartupMode.manual);
    expect(permission.calls, 1);
  });
}

Widget _page(ProviderSettingsViewModel viewModel, _Permission permission) =>
    ChangeNotifierProvider.value(
      value: viewModel,
      child: MaterialApp(
        home: Scaffold(body: OmniStartupSettings(permission: permission)),
      ),
    );

final class _Permission implements PermissionAwareVoiceRecorderPlatform {
  Completer<VoicePermissionResult>? pending;
  VoicePermissionResult result = VoicePermissionResult.ready;
  int calls = 0;
  bool error = false;
  @override
  Future<VoicePermissionResult> preparePermission() async {
    calls++;
    if (error) throw StateError('权限请求已取消或拒绝');
    return pending?.future ?? Future.value(result);
  }
}

final class _Gateway implements ProviderSettingsGateway {
  ProviderSettings value = const ProviderSettings(
    configured: true,
    keySet: true,
    provider: ProviderKind.qwenOmniRealtime,
    baseUrl: 'wss://saved.example.com/realtime',
    model: 'saved-omni-model',
    temperature: 0.7,
    timeoutSeconds: 30,
  );
  final saved = <ProviderSettingsDraft>[];
  bool failSave = false;
  @override
  Future<ProviderSettings> read() async => value;
  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) async {
    saved.add(draft);
    if (failSave) throw const ProviderSettingsGatewayException('保存失败，请重试。');
    return value = ProviderSettings(
      configured: true,
      keySet: true,
      provider: draft.provider,
      baseUrl: draft.baseUrl,
      model: draft.model,
      temperature: draft.temperature,
      timeoutSeconds: draft.timeoutSeconds,
      callStartupMode: draft.callStartupMode ?? value.callStartupMode,
    );
  }

  @override
  Future<ProviderSettings> forgetApiKey() async => value;
  @override
  Future<ProviderTestResult> testConnection(ProviderSettingsDraft draft) =>
      throw UnimplementedError();
}

final class _ProxyGateway implements ProxySettingsGateway {
  @override
  Future<ProxySettings> read() async => const ProxySettings(
    configured: false,
    enabled: false,
    host: '',
    port: 7890,
  );
  @override
  Future<ProxySettings> save(ProxySettingsDraft draft) => read();
}
