import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'provider_settings_client.dart';
import 'provider_settings_view_model.dart';

class ProviderSettingsView extends StatefulWidget {
  const ProviderSettingsView({super.key});

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
    unawaited(context.read<ProviderSettingsViewModel>().initialize());
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

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<ProviderSettingsViewModel>();
    _sync(viewModel.settings);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
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
                    Text(
                      '模型连接',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ],
                ),
                const SizedBox(height: 30),
                Text(
                  '把模型留在本机这端',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '普通配置保存在本机；API Key 只在保存或测试时交给本机程序，之后页面无法取回明文。',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                onPressed: viewModel.saving
                    ? null
                    : () => unawaited(viewModel.forgetApiKey()),
                child: const Text('忘记已保存的 Key'),
              ),
            ],
          ],
        ),
      ),
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
