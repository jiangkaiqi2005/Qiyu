import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../memory/backup_client.dart';
import '../memory/backup_platform.dart';
import '../memory/backup_view.dart';
import '../onboarding/onboarding_view_model.dart';
import 'provider_settings_client.dart';
import 'provider_settings_view_model.dart';
import 'settings_view_model.dart';

/// 设置中心（ticket 23）：模型连接、本地数据管理（备份 / 记忆控制
/// 总览 / 清除产品数据）、隐私说明与开发者选项。危险操作（忘记
/// Key、清除产品数据）都有明确影响说明与确认。
class ProviderSettingsView extends StatefulWidget {
  const ProviderSettingsView({super.key, this.backupGateway, this.backupPlatform});

  /// 备份网关与浏览器能力接缝：缺省走真实 HTTP 与 Web 实现；
  /// widget 测试注入桩。
  final BackupGateway? backupGateway;
  final BackupPlatform? backupPlatform;

  @override
  State<ProviderSettingsView> createState() => _ProviderSettingsViewState();
}

class _ProviderSettingsViewState extends State<ProviderSettingsView> {
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();
  final _temperatureController = TextEditingController(text: '0.7');
  final _timeoutController = TextEditingController(text: '60');
  final _apiKeyController = TextEditingController();
  ProviderKind _provider = ProviderKind.openAiCompatible;
  ProviderSettings? _syncedSettings;
  bool _requestedInitialization = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_requestedInitialization) {
      return;
    }
    _requestedInitialization = true;
    final settingsViewModel = context.read<SettingsViewModel>();
    unawaited(context.read<ProviderSettingsViewModel>().initialize());
    unawaited(settingsViewModel.loadPreferences());
    unawaited(settingsViewModel.loadClearPreview());
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _modelController.dispose();
    _temperatureController.dispose();
    _timeoutController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  void _sync(ProviderSettings? settings) {
    if (settings == null || identical(settings, _syncedSettings)) {
      return;
    }
    _syncedSettings = settings;
    if (settings.configured) {
      _provider = settings.provider!;
      _baseUrlController.text = settings.baseUrl!;
      _modelController.text = settings.model!;
      _temperatureController.text = '${settings.temperature!}';
      _timeoutController.text = '${settings.timeoutSeconds!}';
    } else if (_baseUrlController.text.isEmpty) {
      _baseUrlController.text = 'https://api.openai.com/v1';
    }
    _apiKeyController.clear();
  }

  ProviderSettingsDraft? _readDraft() {
    final temperature = double.tryParse(_temperatureController.text.trim());
    final timeout = int.tryParse(_timeoutController.text.trim());
    if (temperature == null || timeout == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请检查 temperature 和超时时间。')));
      return null;
    }
    final key = _apiKeyController.text.trim();
    return ProviderSettingsDraft(
      provider: _provider,
      baseUrl: _baseUrlController.text.trim(),
      model: _modelController.text.trim(),
      temperature: temperature,
      timeoutSeconds: timeout,
      apiKey: key.isEmpty ? null : key,
    );
  }

  Future<void> _save(ProviderSettingsViewModel viewModel) async {
    final draft = _readDraft();
    if (draft == null) {
      return;
    }
    final saved = await viewModel.save(draft);
    if (saved && mounted) {
      _apiKeyController.clear();
    }
  }

  Future<void> _confirmForgetKey(ProviderSettingsViewModel viewModel) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('forget-key-dialog'),
        title: const Text('忘记已保存的 API Key？'),
        content: const Text(
          '忘记后本机不再保存这个 Key，栖语将无法调用模型服务，'
          '直到你重新输入。模型连接的其他设置不受影响。',
        ),
        actions: [
          TextButton(
            key: const Key('forget-key-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('再想想'),
          ),
          FilledButton(
            key: const Key('forget-key-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('忘记 Key'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await viewModel.forgetApiKey();
    }
  }

  Future<void> _showMemoryControls(SettingsViewModel viewModel) async {
    unawaited(viewModel.loadMemoryControls());
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => const _MemoryControlsDialog(),
    );
  }

  Future<void> _confirmClearData(SettingsViewModel viewModel) async {
    final loaded = await viewModel.loadClearPreview();
    if (!loaded || !mounted) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => const _ClearDataDialog(),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final cleared = await viewModel.clearData();
    if (cleared && mounted) {
      // 清除后一切从头开始：初见记录已随产品数据清除，重读初见状态
      // 后回到首页，当次会话即重走初见引导。
      unawaited(context.read<OnboardingViewModel>().reload());
      context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<ProviderSettingsViewModel>();
    final settingsViewModel = context.watch<SettingsViewModel>();
    _sync(viewModel.settings);
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              key: const Key('settings-scroll'),
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 48),
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: () => context.pop(),
                      tooltip: '返回聊天',
                      icon: const Icon(Icons.arrow_back),
                    ),
                    const SizedBox(width: 8),
                    Text('设置', style: theme.textTheme.headlineSmall),
                  ],
                ),
                const SizedBox(height: 30),
                Text(
                  '模型连接',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '把模型留在本机这端。普通配置保存在本机；API Key 只在保存或测试时'
                  '交给本机程序，之后页面无法取回明文。',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.55,
                  ),
                ),
                const SizedBox(height: 28),
                if (viewModel.loading)
                  const Center(child: CircularProgressIndicator())
                else ...[
                  SegmentedButton<ProviderKind>(
                    segments: ProviderKind.values
                        .map(
                          (provider) => ButtonSegment(
                            value: provider,
                            label: Text(provider.label),
                          ),
                        )
                        .toList(),
                    selected: {_provider},
                    onSelectionChanged: (selection) {
                      setState(() => _provider = selection.single);
                    },
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    key: const Key('provider-base-url'),
                    controller: _baseUrlController,
                    decoration: const InputDecoration(
                      labelText: '服务地址',
                      hintText: 'https://api.openai.com/v1',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('provider-model'),
                    controller: _modelController,
                    decoration: const InputDecoration(
                      labelText: '模型名称',
                      hintText: 'gpt-4.1-mini',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('provider-temperature'),
                          controller: _temperatureController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'temperature',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextField(
                          key: const Key('provider-timeout'),
                          controller: _timeoutController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '超时（秒）',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  _credentialSection(context, viewModel),
                  const SizedBox(height: 24),
                  if (viewModel.errorMessage case final message?)
                    _StatusMessage(message: message, succeeded: false),
                  if (viewModel.testResult case final result?)
                    _StatusMessage(
                      message: result.message,
                      succeeded: result.succeeded,
                    ),
                  if (viewModel.errorMessage != null ||
                      viewModel.testResult != null)
                    const SizedBox(height: 18),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        key: const Key('save-provider-settings'),
                        onPressed: viewModel.saving
                            ? null
                            : () => unawaited(_save(viewModel)),
                        icon: viewModel.saving
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.lock_outline),
                        label: const Text('保存到本机'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('test-provider-connection'),
                        onPressed: viewModel.testing
                            ? null
                            : () {
                                final draft = _readDraft();
                                if (draft != null) {
                                  unawaited(viewModel.testConnection(draft));
                                }
                              },
                        icon: viewModel.testing
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.bolt_outlined),
                        label: const Text('测试连接'),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 40),
                _localDataSection(context, settingsViewModel),
                const SizedBox(height: 24),
                _privacySection(context),
                const SizedBox(height: 24),
                _developerSection(context, settingsViewModel),
                if (settingsViewModel.errorMessage case final message?) ...[
                  const SizedBox(height: 16),
                  _StatusMessage(message: message, succeeded: false),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _credentialSection(
    BuildContext context,
    ProviderSettingsViewModel viewModel,
  ) {
    final keySet = viewModel.settings?.keySet ?? false;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              keySet ? 'API Key 已安全保存在 Windows 凭据管理器' : '尚未保存 API Key',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              keySet ? '留空即可继续使用；输入新值会覆盖旧值。' : 'Ollama 本地服务通常可以留空。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('provider-api-key'),
              controller: _apiKeyController,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: '只在本次保存时使用',
                border: OutlineInputBorder(),
              ),
            ),
            if (keySet) ...[
              const SizedBox(height: 8),
              TextButton(
                key: const Key('forget-api-key'),
                onPressed: viewModel.saving
                    ? null
                    : () => unawaited(_confirmForgetKey(viewModel)),
                child: const Text('忘记已保存的 Key'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _localDataSection(BuildContext context, SettingsViewModel viewModel) {
    final theme = Theme.of(context);
    final preview = viewModel.clearPreview;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('本地数据', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '全部会话与记忆都是这台电脑上的 Markdown 文件，不会上传到任何服务器。',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (preview != null) ...[
              const SizedBox(height: 10),
              Text(
                '数据位置：${preview.memoryDirectory}',
                key: const Key('local-data-location'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  key: const Key('settings-backup'),
                  onPressed: () => unawaited(
                    showBackupDialog(
                      context,
                      gateway: widget.backupGateway,
                      platform: widget.backupPlatform,
                    ),
                  ),
                  icon: const Icon(Icons.archive_outlined),
                  label: const Text('备份与恢复'),
                ),
                OutlinedButton.icon(
                  key: const Key('settings-memory-center'),
                  onPressed: () => context.push('/memory'),
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('记忆中心'),
                ),
                OutlinedButton.icon(
                  key: const Key('settings-memory-controls'),
                  onPressed: () => unawaited(_showMemoryControls(viewModel)),
                  icon: const Icon(Icons.shield_outlined),
                  label: const Text('记忆控制总览'),
                ),
                TextButton.icon(
                  key: const Key('settings-clear-data'),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  onPressed: viewModel.clearing
                      ? null
                      : () => unawaited(_confirmClearData(viewModel)),
                  icon: viewModel.clearing
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline),
                  label: const Text('清除产品数据'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _privacySection(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('隐私与边界', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '数据只在本机；只有你配置了模型服务才会联网；敏感信息永不被记住。',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              key: const Key('settings-privacy'),
              onPressed: () => context.push('/privacy'),
              icon: const Icon(Icons.privacy_tip_outlined),
              label: const Text('查看隐私说明'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _developerSection(
    BuildContext context,
    SettingsViewModel viewModel,
  ) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('体验与开发者选项', style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('开发者模式', style: theme.textTheme.titleSmall),
                      Text(
                        '开启后出现开发者诊断入口。诊断只读，不修改任何数据。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  key: const Key('developer-mode-switch'),
                  value: viewModel.developerMode,
                  onChanged: viewModel.busy
                      ? null
                      : (value) => unawaited(viewModel.setDeveloperMode(value)),
                ),
              ],
            ),
            if (viewModel.developerMode)
              OutlinedButton.icon(
                key: const Key('settings-diagnostics'),
                onPressed: () => context.push('/settings/diagnostics'),
                icon: const Icon(Icons.monitor_heart_outlined),
                label: const Text('开发者诊断'),
              ),
          ],
        ),
      ),
    );
  }
}

/// 记忆控制总览对话框：冻结与禁提逐条列出，删除只给数量；具体
/// 管理去记忆中心。
class _MemoryControlsDialog extends StatefulWidget {
  const _MemoryControlsDialog();

  @override
  State<_MemoryControlsDialog> createState() => _MemoryControlsDialogState();
}

class _MemoryControlsDialogState extends State<_MemoryControlsDialog> {
  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<SettingsViewModel>();
    final controls = viewModel.controls;
    final theme = Theme.of(context);
    return AlertDialog(
      key: const Key('memory-controls-dialog'),
      title: const Text('记忆控制总览'),
      content: SizedBox(
        width: 460,
        child: controls == null
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '冻结的内容仍在但不会被注入；禁提的内容栖语不再主动提起。'
                      '解除或调整请去记忆中心。',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('已冻结（${controls.frozen.length}）',
                        style: theme.textTheme.titleSmall),
                    if (controls.frozen.isEmpty)
                      Text('没有冻结的记忆。',
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                          ))
                    else
                      for (final entry in controls.frozen)
                        Text('· ${entry.summary}',
                            style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 12),
                    Text('已禁提（${controls.banned.length}）',
                        style: theme.textTheme.titleSmall),
                    if (controls.banned.isEmpty)
                      Text('没有禁提的内容。',
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                          ))
                    else
                      for (final entry in controls.banned)
                        Text('· ${entry.summary}',
                            style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 12),
                    Text(
                      '已删除范围：${controls.deletedCount} 条（只保留抽象范围，防止复活）',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          key: const Key('memory-controls-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton(
          key: const Key('memory-controls-open-center'),
          onPressed: () {
            Navigator.of(context).pop();
            context.push('/memory');
          },
          child: const Text('去记忆中心'),
        ),
      ],
    );
  }
}

/// 清除产品数据确认对话框：影响逐条列清，确认后由 Host 先落快照
/// 再删除。
class _ClearDataDialog extends StatelessWidget {
  const _ClearDataDialog();

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<SettingsViewModel>();
    final preview = viewModel.clearPreview;
    final theme = Theme.of(context);
    return AlertDialog(
      key: const Key('clear-data-dialog'),
      title: const Text('清除产品数据？'),
      content: preview == null
          ? const SizedBox(
              width: 460,
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          : SizedBox(
              width: 460,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '将清除 ${preview.sessionCount} 段会话、'
                    '${preview.episodeDayCount} 天的整理记录，'
                    '以及长期印象、画像、关系、近日状态与全部记忆控制'
                    '（冻结 ${preview.frozenCount}、禁提 ${preview.bannedCount}、'
                    '删除范围 ${preview.deletedCount}）。',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '清除前会先创建一份备份快照，之后随时可以在「备份与恢复」里找回；'
                    '模型连接设置与 API Key 不受影响。清除后栖语会像第一次见面一样重新开始。',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
      actions: [
        TextButton(
          key: const Key('clear-data-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('先不清除'),
        ),
        FilledButton(
          key: const Key('clear-data-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: viewModel.clearing
              ? null
              : () => Navigator.of(context).pop(true),
          child: viewModel.clearing
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('确认清除'),
        ),
      ],
    );
  }
}

class _StatusMessage extends StatelessWidget {
  const _StatusMessage({required this.message, required this.succeeded});

  final String message;
  final bool succeeded;

  @override
  Widget build(BuildContext context) {
    final color = succeeded
        ? const Color(0xFF91C7A7)
        : Theme.of(context).colorScheme.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          succeeded ? Icons.check_circle_outline : Icons.info_outline,
          color: color,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(message, style: TextStyle(color: color)),
        ),
      ],
    );
  }
}
