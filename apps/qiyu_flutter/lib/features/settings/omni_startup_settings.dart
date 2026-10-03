import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../chat/microphone_permission_platform.dart';
import '../chat/voice_recorder_platform.dart';
import 'provider_settings_client.dart';
import 'provider_settings_view_model.dart';
import 'settings_strings.dart';

/// 启动偏好只修改有效的本机配置，不提交模型表单里尚未保存的草稿。
class OmniStartupSettings extends StatefulWidget {
  const OmniStartupSettings({super.key, this.permission});

  final PermissionAwareVoiceRecorderPlatform? permission;

  @override
  State<OmniStartupSettings> createState() => _OmniStartupSettingsState();
}

class _OmniStartupSettingsState extends State<OmniStartupSettings> {
  late final _permission =
      widget.permission ?? createMicrophonePermissionPlatform();
  GoRouter? _router;
  String? _location;
  int _attempt = 0;
  bool _requesting = false;
  String? _permissionError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final router = GoRouter.maybeOf(context);
    if (router != _router) {
      _router?.routerDelegate.removeListener(_onRouteChanged);
      _router = router;
      _location = router?.routerDelegate.currentConfiguration.uri.path;
      router?.routerDelegate.addListener(_onRouteChanged);
    }
  }

  void _onRouteChanged() {
    if (_router?.routerDelegate.currentConfiguration.uri.path != _location) {
      _attempt++;
      if (mounted) setState(() => _requesting = false);
    }
  }

  @override
  void dispose() {
    _attempt++;
    _router?.routerDelegate.removeListener(_onRouteChanged);
    super.dispose();
  }

  Future<void> _select(
    CallStartupMode mode,
    ProviderSettingsViewModel viewModel,
  ) async {
    if (viewModel.saving ||
        (_requesting && mode == CallStartupMode.autoOnChatEntry)) {
      return;
    }
    final settings = viewModel.settings;
    if (settings == null ||
        !settings.configured ||
        settings.provider != ProviderKind.qwenOmniRealtime) {
      return;
    }
    final attempt = ++_attempt;
    setState(() {
      _requesting = false;
      _permissionError = null;
    });
    if (mode == settings.callStartupMode) return;
    if (mode == CallStartupMode.autoOnChatEntry) {
      setState(() => _requesting = true);
      VoicePermissionResult result;
      try {
        result = await _permission.preparePermission();
      } on Object {
        result = VoicePermissionResult.denied;
      }
      if (!mounted || attempt != _attempt) return;
      setState(() => _requesting = false);
      if (!identical(settings, viewModel.settings)) return;
      if (result == VoicePermissionResult.denied) {
        setState(
          () => _permissionError = settingsTextNow(
            context,
            '未获得麦克风权限，保持手动开始。可检查系统或浏览器的麦克风设置。',
            'Microphone permission was not granted. Manual start remains selected. Check your system or browser settings.',
          ),
        );
        return;
      }
    }
    await viewModel.save(
      ProviderSettingsDraft(
        provider: settings.provider!,
        baseUrl: settings.baseUrl!,
        model: settings.model!,
        temperature: settings.temperature!,
        timeoutSeconds: settings.timeoutSeconds!,
        callStartupMode: mode,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Consumer<ProviderSettingsViewModel>(
    builder: (context, viewModel, _) {
      final settings = viewModel.settings;
      final enabled =
          settings?.configured == true &&
          settings?.provider == ProviderKind.qwenOmniRealtime;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            settingsText(context, '通话启动方式', 'Call startup'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          RadioGroup<CallStartupMode>(
            groupValue: settings?.callStartupMode ?? CallStartupMode.manual,
            onChanged: (mode) =>
                unawaited(_select(mode ?? CallStartupMode.manual, viewModel)),
            child: Column(
              children: [
                RadioListTile<CallStartupMode>(
                  key: const Key('omni-startup-manual'),
                  value: CallStartupMode.manual,
                  title: Text(settingsText(context, '手动开始', 'Start manually')),
                  toggleable: _requesting,
                  enabled: enabled && !viewModel.saving,
                  activeColor: Theme.of(context).colorScheme.onSurface,
                  contentPadding: EdgeInsets.zero,
                ),
                RadioListTile<CallStartupMode>(
                  key: const Key('omni-startup-auto'),
                  value: CallStartupMode.autoOnChatEntry,
                  title: Text(
                    settingsText(
                      context,
                      '进入聊天页自动开始',
                      'Start when entering chat',
                    ),
                  ),
                  enabled: enabled && !viewModel.saving,
                  contentPadding: EdgeInsets.zero,
                  activeColor: Theme.of(context).colorScheme.onSurface,
                ),
              ],
            ),
          ),
          if (!enabled)
            Text(
              settingsText(
                context,
                '先保存 Omni 模型配置，再选择启动方式。',
                'Save the Omni model settings before choosing a startup mode.',
              ),
            ),
          if (_requesting)
            Text(
              settingsText(
                context,
                '正在申请麦克风权限…',
                'Requesting microphone permission…',
              ),
            ),
          if (_permissionError != null)
            Text(
              _permissionError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      );
    },
  );
}
