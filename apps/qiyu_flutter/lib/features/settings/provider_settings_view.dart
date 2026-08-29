import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../memory/backup_client.dart';
import '../memory/backup_platform.dart';
import '../memory/backup_view.dart';
import '../navigation.dart';
import '../onboarding/onboarding_view_model.dart';
import '../shell/qiyu_shell.dart';
import 'provider_catalog.dart';
import 'provider_settings_client.dart';
import 'provider_settings_view_model.dart';
import 'settings_client.dart';
import 'settings_view_model.dart';
import 'stt_settings_client.dart';
import 'stt_settings_view_model.dart';
import 'tts_settings_client.dart';
import 'tts_settings_view_model.dart';
import 'web_search_settings_client.dart';
import 'web_search_settings_view_model.dart';

/// 设置中心（ticket 23）：模型连接、本地数据管理（备份 / 记忆控制
/// 总览 / 清除产品数据）、隐私说明与开发者选项。危险操作（忘记
/// Key、清除产品数据）都有明确影响说明与确认。
class ProviderSettingsView extends StatefulWidget {
  const ProviderSettingsView({
    super.key,
    this.backupGateway,
    this.backupPlatform,
  });

  /// 备份网关与浏览器能力接缝：缺省走真实 HTTP 与 Web 实现；
  /// widget 测试注入桩。
  final BackupGateway? backupGateway;
  final BackupPlatform? backupPlatform;

  @override
  State<ProviderSettingsView> createState() => _ProviderSettingsViewState();
}

class _ProviderSettingsViewState extends State<ProviderSettingsView> {
  bool _requestedInitialization = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_requestedInitialization) {
      return;
    }
    _requestedInitialization = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final settingsViewModel = context.read<SettingsViewModel>();
      unawaited(context.read<ProviderSettingsViewModel>().initialize());
      unawaited(context.read<SttSettingsViewModel>().initialize());
      unawaited(context.read<TtsSettingsViewModel>().initialize());
      unawaited(context.read<WebSearchSettingsViewModel>().initialize());
      unawaited(settingsViewModel.loadPreferences());
      unawaited(settingsViewModel.loadClearPreview());
    });
  }

  @override
  Widget build(BuildContext context) {
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
                    // 窄屏且被壳包住时不再摆自己的返回箭头：那里三条杠浮在同一个
                    // 左上角，导航交给抽屉。桌面的箭头保留——侧边栏在另一栏，不与
                    // 它相交，而「回到打开这一页的那一层」只有它给得出（品牌槽回
                    // 的是首页）。
                    if (!QiyuShellScope.coversFrontNavigation(context)) ...[
                      IconButton(
                        key: const Key('settings-back'),
                        onPressed: () => backToPrevious(context),
                        tooltip: '返回上一页',
                        icon: const Icon(Icons.arrow_back),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text('设置', style: theme.textTheme.headlineSmall),
                  ],
                ),
                const SizedBox(height: 30),
                const _ProviderSection(),
                const SizedBox(height: 40),
                const _WebSearchSection(),
                const SizedBox(height: 24),
                const _SttSection(),
                const SizedBox(height: 24),
                const _TtsSection(),
                const SizedBox(height: 24),
                _LocalDataSection(
                  backupGateway: widget.backupGateway,
                  backupPlatform: widget.backupPlatform,
                ),
                const SizedBox(height: 24),
                const _PrivacySection(),
                const SizedBox(height: 24),
                const _DeveloperSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 获焦安全保护字段同步：在输入框获焦时不覆盖用户正在输入的草稿。
void _syncField(
  TextEditingController controller,
  FocusNode focusNode,
  String newValue,
) {
  if (!focusNode.hasFocus && controller.text != newValue) {
    controller.text = newValue;
  }
}

/// 模型连接（Provider）配置区块：模型连接、参数设置与 API Key 凭据管理。
class _ProviderSection extends StatefulWidget {
  const _ProviderSection();

  @override
  State<_ProviderSection> createState() => _ProviderSectionState();
}

class _ProviderSectionState extends State<_ProviderSection> {
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();
  final _temperatureController = TextEditingController(text: '0.7');
  final _timeoutController = TextEditingController(text: '60');
  final _apiKeyController = TextEditingController();

  final _baseUrlFocusNode = FocusNode();
  final _modelFocusNode = FocusNode();
  final _temperatureFocusNode = FocusNode();
  final _timeoutFocusNode = FocusNode();
  final _apiKeyFocusNode = FocusNode();

  String _selectedProviderId = 'openai';
  String _selectedConnectionId = 'official';
  bool _customModel = false;
  ProviderSettings? _syncedSettings;

  ProviderPreset get _selectedProvider =>
      providerPresetById(_selectedProviderId);

  ProviderConnectionPreset get _selectedConnection => _selectedProvider
      .connections
      .firstWhere((connection) => connection.id == _selectedConnectionId);

  @override
  void dispose() {
    _baseUrlController.dispose();
    _modelController.dispose();
    _temperatureController.dispose();
    _timeoutController.dispose();
    _apiKeyController.dispose();
    _baseUrlFocusNode.dispose();
    _modelFocusNode.dispose();
    _temperatureFocusNode.dispose();
    _timeoutFocusNode.dispose();
    _apiKeyFocusNode.dispose();
    super.dispose();
  }

  void _sync(ProviderSettings? settings) {
    if (settings == null || identical(settings, _syncedSettings)) {
      return;
    }
    _syncedSettings = settings;
    final selection = matchProviderSettings(settings);
    _selectedProviderId = selection.providerId;
    _selectedConnectionId = selection.connectionId;
    _customModel = selection.customModel;
    if (settings.configured) {
      _syncField(_baseUrlController, _baseUrlFocusNode, settings.baseUrl ?? '');
      _syncField(_modelController, _modelFocusNode, settings.model ?? '');
      _syncField(
        _temperatureController,
        _temperatureFocusNode,
        settings.temperature != null ? '${settings.temperature}' : '',
      );
      _syncField(
        _timeoutController,
        _timeoutFocusNode,
        settings.timeoutSeconds != null ? '${settings.timeoutSeconds}' : '',
      );
    } else {
      _syncField(
        _baseUrlController,
        _baseUrlFocusNode,
        _selectedConnection.baseUrl,
      );
      _syncField(
        _modelController,
        _modelFocusNode,
        _selectedConnection.models.isNotEmpty
            ? _selectedConnection.models.first
            : '',
      );
    }
    if (!_apiKeyFocusNode.hasFocus && _apiKeyController.text.isNotEmpty) {
      _apiKeyController.clear();
    }
  }

  void _selectProvider(String providerId) {
    final provider = providerPresetById(providerId);
    setState(() {
      _selectedProviderId = provider.id;
      _selectedConnectionId = provider.connections.first.id;
      _applyConnection(provider.connections.first);
    });
  }

  void _selectConnection(String connectionId) {
    final connection = _selectedProvider.connections.firstWhere(
      (candidate) => candidate.id == connectionId,
    );
    setState(() {
      _selectedConnectionId = connection.id;
      _applyConnection(connection);
    });
  }

  void _applyConnection(ProviderConnectionPreset connection) {
    _baseUrlController.text = connection.baseUrl;
    _customModel = connection.models.isEmpty;
    _modelController.text = connection.models.isEmpty
        ? ''
        : connection.models.first;
  }

  void _selectModel(String model) {
    setState(() {
      _customModel = model == customModelValue;
      _modelController.text = _customModel ? '' : model;
    });
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
    if (_baseUrlController.text.trim().isEmpty ||
        _modelController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请填写服务地址和模型名称。')));
      return null;
    }
    final key = _apiKeyController.text.trim();
    return ProviderSettingsDraft(
      provider: _selectedConnection.provider,
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

  Widget _credentialSection(
    BuildContext context,
    ProviderSettingsViewModel viewModel,
  ) {
    final keySet = viewModel.settings?.keySet ?? false;
    return _SettingsPanel(
      children: [
        Text(
          keySet ? 'API Key 已保存在本机 provider.json' : '尚未保存 API Key',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          keySet
              ? '留空即可继续使用；输入新值会覆盖旧值，也可以直接编辑 provider.json 更换。'
              : 'Ollama 本地服务通常可以留空。',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('provider-api-key'),
          controller: _apiKeyController,
          focusNode: _apiKeyFocusNode,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'API Key',
            hintText: '保存后写入本机 provider.json',
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ProviderSettingsViewModel>(
      builder: (context, viewModel, child) {
        _sync(viewModel.settings);
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '模型连接',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w500,
                letterSpacing: -0.8,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '把模型留在本机这端。普通配置和 API Key 都保存在本机 '
              'provider.json 文件里，可以直接编辑该文件更换 Key；'
              '页面只显示是否已保存，无法取回明文。',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 28),
            if (viewModel.loading)
              const Center(child: CircularProgressIndicator())
            else ...[
              _ControlledDropdown(
                dropdownKey: const Key('provider-preset'),
                label: '提供商',
                value: _selectedProviderId,
                items: [
                  for (final provider in providerCatalog)
                    DropdownMenuItem(
                      value: provider.id,
                      child: Text(provider.label),
                    ),
                ],
                onChanged: _selectProvider,
              ),
              const SizedBox(height: 16),
              _ControlledDropdown(
                dropdownKey: const Key('provider-connection'),
                label: '套餐 / 接口类型',
                value: _selectedConnectionId,
                items: [
                  for (final connection in _selectedProvider.connections)
                    DropdownMenuItem(
                      value: connection.id,
                      child: Text(connection.label),
                    ),
                ],
                onChanged: _selectConnection,
              ),
              const SizedBox(height: 16),
              _ControlledDropdown(
                dropdownKey: const Key('provider-model-preset'),
                label: '模型',
                value: _customModel ||
                        !_selectedConnection.models
                            .contains(_modelController.text)
                    ? customModelValue
                    : _modelController.text,
                items: [
                  for (final model in _selectedConnection.models)
                    DropdownMenuItem(value: model, child: Text(model)),
                  const DropdownMenuItem(
                    value: customModelValue,
                    child: Row(
                      children: [
                        Icon(Icons.edit_outlined, size: 18),
                        SizedBox(width: 8),
                        Text('输入其他模型名称'),
                      ],
                    ),
                  ),
                ],
                onChanged: _selectModel,
              ),
              if (_customModel) ...[
                const SizedBox(height: 16),
                TextField(
                  key: const Key('provider-model'),
                  controller: _modelController,
                  focusNode: _modelFocusNode,
                  decoration: const InputDecoration(
                    labelText: '模型名称',
                    hintText: '输入服务商提供的 Model ID',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (_selectedConnection.editableBaseUrl)
                TextField(
                  key: const Key('provider-base-url'),
                  controller: _baseUrlController,
                  focusNode: _baseUrlFocusNode,
                  decoration: const InputDecoration(
                    labelText: '服务地址',
                    hintText: 'https://example.com/v1',
                    border: OutlineInputBorder(),
                  ),
                )
              else
                _ResolvedConnection(
                  provider: _selectedConnection.provider,
                  baseUrl: _selectedConnection.baseUrl,
                ),
              const SizedBox(height: 8),
              ExpansionTile(
                key: const Key('provider-advanced-settings'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                title: const Text('高级参数'),
                subtitle: const Text('temperature 与请求超时'),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('provider-temperature'),
                          controller: _temperatureController,
                          focusNode: _temperatureFocusNode,
                          keyboardType:
                              const TextInputType.numberWithOptions(
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
                          focusNode: _timeoutFocusNode,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '超时（秒）',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
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
                    icon: _busyOr(viewModel.saving, Icons.lock_outline),
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
                    icon: _busyOr(viewModel.testing, Icons.bolt_outlined),
                    label: const Text('测试连接'),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 联网搜索设置区块：AnySearch API Key 配置与保存。
class _WebSearchSection extends StatefulWidget {
  const _WebSearchSection();

  @override
  State<_WebSearchSection> createState() => _WebSearchSectionState();
}

class _WebSearchSectionState extends State<_WebSearchSection> {
  final _webSearchApiKeyController = TextEditingController();
  final _webSearchApiKeyFocusNode = FocusNode();
  WebSearchSettings? _syncedWebSearchSettings;

  @override
  void dispose() {
    _webSearchApiKeyController.dispose();
    _webSearchApiKeyFocusNode.dispose();
    super.dispose();
  }

  void _syncWebSearch(WebSearchSettings? settings) {
    if (settings == null || identical(settings, _syncedWebSearchSettings)) {
      return;
    }
    _syncedWebSearchSettings = settings;
    if (!_webSearchApiKeyFocusNode.hasFocus &&
        _webSearchApiKeyController.text.isNotEmpty) {
      _webSearchApiKeyController.clear();
    }
  }

  Future<void> _saveWebSearch(WebSearchSettingsViewModel viewModel) async {
    final key = _webSearchApiKeyController.text.trim();
    try {
      await viewModel.save(
        WebSearchSettingsDraft(apiKey: key.isEmpty ? null : key),
      );
    } finally {
      if (mounted) {
        _webSearchApiKeyController.clear();
      }
    }
  }

  Future<void> _confirmForgetWebSearchKey(
    WebSearchSettingsViewModel viewModel,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('web-search-forget-key-dialog'),
        title: const Text('忘记 AnySearch API Key？'),
        content: const Text(
          '忘记后本机不再保存这个 Key，联网搜索会立即停用，'
          '普通聊天仍可照常使用。',
        ),
        actions: [
          TextButton(
            key: const Key('web-search-forget-key-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('再想想'),
          ),
          FilledButton(
            key: const Key('web-search-forget-key-confirm'),
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

  @override
  Widget build(BuildContext context) {
    return Consumer<WebSearchSettingsViewModel>(
      builder: (context, viewModel, child) {
        _syncWebSearch(viewModel.settings);
        final theme = Theme.of(context);
        final keySet = viewModel.settings?.keySet ?? false;
        return _SettingsPanel(
          children: [
            Text(
              '联网搜索',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w500,
                letterSpacing: -0.8,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '需要当前时间、天气、新闻等变化中的事实时，栖语可以按需搜索。'
              'Key 只保存在本机 provider.json，页面不会取回明文。',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 16),
            if (viewModel.loading)
              const Center(child: CircularProgressIndicator())
            else ...[
              Text(
                keySet ? 'AnySearch Key 已保存在本机' : '尚未保存 AnySearch Key',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('web-search-api-key'),
                controller: _webSearchApiKeyController,
                focusNode: _webSearchApiKeyFocusNode,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'ANYSEARCH_API_KEY',
                  hintText: keySet
                      ? '留空即可继续使用已保存的 Key'
                      : '保存后写入本机 provider.json',
                  border: const OutlineInputBorder(),
                ),
              ),
              if (keySet) ...[
                const SizedBox(height: 8),
                TextButton(
                  key: const Key('forget-web-search-key'),
                  onPressed: viewModel.saving
                      ? null
                      : () => unawaited(_confirmForgetWebSearchKey(viewModel)),
                  child: const Text('忘记 AnySearch Key'),
                ),
              ],
              const SizedBox(height: 20),
              if (viewModel.errorMessage case final message?) ...[
                _StatusMessage(message: message, succeeded: false),
                const SizedBox(height: 14),
              ],
              FilledButton.icon(
                key: const Key('save-web-search-settings'),
                onPressed: viewModel.saving
                    ? null
                    : () => unawaited(_saveWebSearch(viewModel)),
                icon: _busyOr(viewModel.saving, Icons.lock_outline),
                label: const Text('保存到本机'),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 语音输入（STT）服务配置区块：与聊天 Provider 同构的表单与 Key 规则。
class _SttSection extends StatefulWidget {
  const _SttSection();

  @override
  State<_SttSection> createState() => _SttSectionState();
}

class _SttSectionState extends State<_SttSection> {
  final _sttBaseUrlController = TextEditingController();
  final _sttModelController = TextEditingController();
  final _sttApiKeyController = TextEditingController();

  final _sttBaseUrlFocusNode = FocusNode();
  final _sttModelFocusNode = FocusNode();
  final _sttApiKeyFocusNode = FocusNode();

  SttServiceKind _sttProvider = SttServiceKind.openaiCompatible;
  SttSettings? _syncedSttSettings;

  @override
  void dispose() {
    _sttBaseUrlController.dispose();
    _sttModelController.dispose();
    _sttApiKeyController.dispose();
    _sttBaseUrlFocusNode.dispose();
    _sttModelFocusNode.dispose();
    _sttApiKeyFocusNode.dispose();
    super.dispose();
  }

  void _syncStt(SttSettings? settings) {
    if (settings == null || identical(settings, _syncedSttSettings)) {
      return;
    }
    _syncedSttSettings = settings;
    _sttProvider = settings.provider;
    if (settings.configured) {
      _syncField(
        _sttBaseUrlController,
        _sttBaseUrlFocusNode,
        settings.baseUrl ?? '',
      );
      _syncField(
        _sttModelController,
        _sttModelFocusNode,
        settings.model ?? '',
      );
    } else {
      final defaults = _sttProtocolDefaults(_sttProvider);
      _syncField(_sttBaseUrlController, _sttBaseUrlFocusNode, defaults.url);
      _syncField(_sttModelController, _sttModelFocusNode, defaults.model);
    }
    if (!_sttApiKeyFocusNode.hasFocus && _sttApiKeyController.text.isNotEmpty) {
      _sttApiKeyController.clear();
    }
  }

  void _selectSttProvider(String wireName) {
    final next = wireName == 'volc_seed_asr'
        ? SttServiceKind.volcSeedAsr
        : SttServiceKind.openaiCompatible;
    if (next == _sttProvider) {
      return;
    }
    setState(() {
      final previous = _sttProvider;
      _sttProvider = next;
      _applySttProtocolDefaults(from: previous, to: next);
    });
  }

  /// 切换协议时，若地址空白或 scheme 与新协议不兼容（https 不能给豆包，
  /// wss 不能给 OpenAI 兼容），换成新协议的缺省地址和模型。
  void _applySttProtocolDefaults({
    required SttServiceKind from,
    required SttServiceKind to,
  }) {
    final url = _sttBaseUrlController.text.trim();
    final model = _sttModelController.text.trim();
    final fromDefaults = _sttProtocolDefaults(from);
    final toDefaults = _sttProtocolDefaults(to);
    final uri = Uri.tryParse(url);
    final schemeCompatible = switch (to) {
      SttServiceKind.openaiCompatible =>
        uri != null && (uri.scheme == 'http' || uri.scheme == 'https'),
      SttServiceKind.volcSeedAsr =>
        uri != null && (uri.scheme == 'ws' || uri.scheme == 'wss'),
    };
    if (url.isEmpty || !schemeCompatible) {
      _sttBaseUrlController.text = toDefaults.url;
      if (model.isEmpty || model == fromDefaults.model || !schemeCompatible) {
        _sttModelController.text = toDefaults.model;
      }
    } else if (model.isEmpty || model == fromDefaults.model) {
      _sttModelController.text = toDefaults.model;
    }
  }

  SttSettingsDraft? _readSttDraft() {
    if (_sttBaseUrlController.text.trim().isEmpty ||
        _sttModelController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请填写语音服务地址和模型名称。')));
      return null;
    }
    final key = _sttApiKeyController.text.trim();
    return SttSettingsDraft(
      provider: _sttProvider,
      baseUrl: _sttBaseUrlController.text.trim(),
      model: _sttModelController.text.trim(),
      apiKey: key.isEmpty ? null : key,
    );
  }

  Future<void> _saveStt(SttSettingsViewModel viewModel) async {
    final draft = _readSttDraft();
    if (draft == null) {
      return;
    }
    final saved = await viewModel.save(draft);
    if (saved && mounted) {
      _sttApiKeyController.clear();
    }
  }

  Future<void> _confirmForgetSttKey(SttSettingsViewModel viewModel) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('stt-forget-key-dialog'),
        title: const Text('忘记语音服务的 API Key？'),
        content: const Text(
          '忘记后本机不再保存这个 Key，语音输入暂时不可用，直到你重新输入。'
          '语音服务的地址和模型不受影响。',
        ),
        actions: [
          TextButton(
            key: const Key('stt-forget-key-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('再想想'),
          ),
          FilledButton(
            key: const Key('stt-forget-key-confirm'),
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

  @override
  Widget build(BuildContext context) {
    return Consumer<SttSettingsViewModel>(
      builder: (context, viewModel, child) {
        _syncStt(viewModel.settings);
        final theme = Theme.of(context);
        final keySet = viewModel.settings?.keySet ?? false;
        return _SettingsPanel(
          children: [
            Text(
              '语音输入',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w500,
                letterSpacing: -0.8,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _sttProvider == SttServiceKind.volcSeedAsr
                  ? '把说的话转成文字。豆包走官方语音识别协议；'
                        'Key 只保存在本机 provider.json；录音只存在内存里，'
                        '转写完成即丢弃，不会进入会话与记忆。'
                  : '把说的话转成文字的服务（OpenAI 兼容转写，如 whisper 系列）。'
                        'Key 只保存在本机 provider.json；录音只存在内存里，'
                        '转写完成即丢弃，不会进入会话与记忆。',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 16),
            _ControlledDropdown(
              dropdownKey: const Key('stt-provider'),
              label: '服务类型',
              value: _sttProvider == SttServiceKind.volcSeedAsr
                  ? 'volc_seed_asr'
                  : 'openai_compatible',
              items: const [
                DropdownMenuItem(
                  value: 'openai_compatible',
                  child: Text('OpenAI 兼容转写'),
                ),
                DropdownMenuItem(
                  value: 'volc_seed_asr',
                  child: Text('豆包流式语音识别'),
                ),
              ],
              onChanged: _selectSttProvider,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('stt-base-url'),
              controller: _sttBaseUrlController,
              focusNode: _sttBaseUrlFocusNode,
              decoration: InputDecoration(
                labelText: '服务地址',
                hintText: _sttProtocolDefaults(_sttProvider).urlHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('stt-model'),
              controller: _sttModelController,
              focusNode: _sttModelFocusNode,
              decoration: InputDecoration(
                labelText: _sttProvider == SttServiceKind.volcSeedAsr
                    ? 'Resource-Id'
                    : '模型名称',
                hintText: _sttProtocolDefaults(_sttProvider).modelHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              keySet ? 'API Key 已保存在本机 provider.json' : '尚未保存语音服务的 API Key',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('stt-api-key'),
              controller: _sttApiKeyController,
              focusNode: _sttApiKeyFocusNode,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: keySet
                    ? '留空即可继续使用已保存的 Key'
                    : '保存后写入本机 provider.json',
                border: const OutlineInputBorder(),
              ),
            ),
            if (keySet) ...[
              const SizedBox(height: 8),
              TextButton(
                key: const Key('forget-stt-key'),
                onPressed: viewModel.saving
                    ? null
                    : () => unawaited(_confirmForgetSttKey(viewModel)),
                child: const Text('忘记语音服务的 Key'),
              ),
            ],
            const SizedBox(height: 20),
            if (viewModel.errorMessage case final message?)
              _StatusMessage(message: message, succeeded: false),
            if (viewModel.testResult case final result?)
              _StatusMessage(
                message: result.message,
                succeeded: result.succeeded,
              ),
            if (viewModel.errorMessage != null || viewModel.testResult != null)
              const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  key: const Key('save-stt-settings'),
                  onPressed: viewModel.saving
                      ? null
                      : () => unawaited(_saveStt(viewModel)),
                  icon: _busyOr(viewModel.saving, Icons.lock_outline),
                  label: const Text('保存到本机'),
                ),
                OutlinedButton.icon(
                  key: const Key('test-stt-connection'),
                  onPressed: viewModel.testing
                      ? null
                      : () {
                          final draft = _readSttDraft();
                          if (draft != null) {
                            unawaited(viewModel.testConnection(draft));
                          }
                        },
                  icon: _busyOr(viewModel.testing, Icons.bolt_outlined),
                  label: const Text('测试连接'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// 语音朗读（TTS）服务配置区块：音色选择、语速微调、高级参数与试听。
class _TtsSection extends StatefulWidget {
  const _TtsSection();

  @override
  State<_TtsSection> createState() => _TtsSectionState();
}

class _TtsSectionState extends State<_TtsSection> {
  final _ttsBaseUrlController = TextEditingController();
  final _ttsModelController = TextEditingController();
  final _ttsApiKeyController = TextEditingController();
  final _ttsVoiceController = TextEditingController();
  final _ttsExtraParamsController = TextEditingController();

  final _ttsBaseUrlFocusNode = FocusNode();
  final _ttsModelFocusNode = FocusNode();
  final _ttsApiKeyFocusNode = FocusNode();
  final _ttsVoiceFocusNode = FocusNode();
  final _ttsExtraParamsFocusNode = FocusNode();

  TtsServiceKind _ttsProvider = TtsServiceKind.openAiCompatible;
  bool _customTtsVoice = false;
  double? _ttsSpeed;
  TtsSettings? _syncedTtsSettings;

  @override
  void dispose() {
    _ttsBaseUrlController.dispose();
    _ttsModelController.dispose();
    _ttsApiKeyController.dispose();
    _ttsVoiceController.dispose();
    _ttsExtraParamsController.dispose();
    _ttsBaseUrlFocusNode.dispose();
    _ttsModelFocusNode.dispose();
    _ttsApiKeyFocusNode.dispose();
    _ttsVoiceFocusNode.dispose();
    _ttsExtraParamsFocusNode.dispose();
    super.dispose();
  }

  void _syncTts(TtsSettings? settings) {
    if (settings == null || identical(settings, _syncedTtsSettings)) {
      return;
    }
    _syncedTtsSettings = settings;
    _ttsProvider = settings.provider;
    final presets = ttsVoicePresetsFor(_ttsProvider);
    if (settings.configured) {
      _syncField(
        _ttsBaseUrlController,
        _ttsBaseUrlFocusNode,
        settings.baseUrl ?? '',
      );
      _syncField(
        _ttsModelController,
        _ttsModelFocusNode,
        settings.model ?? '',
      );
      final voice = settings.voice?.trim() ?? '';
      _syncField(_ttsVoiceController, _ttsVoiceFocusNode, voice);
      _customTtsVoice = voice.isNotEmpty && !presets.any((p) => p.id == voice);
      _ttsSpeed = settings.speed;
      final extraText =
          (settings.extraParams != null && settings.extraParams!.isNotEmpty)
              ? const JsonEncoder.withIndent('  ').convert(settings.extraParams)
              : '';
      _syncField(
        _ttsExtraParamsController,
        _ttsExtraParamsFocusNode,
        extraText,
      );
    } else {
      final defaults = _ttsProtocolDefaults(_ttsProvider);
      _syncField(_ttsBaseUrlController, _ttsBaseUrlFocusNode, defaults.url);
      _syncField(_ttsModelController, _ttsModelFocusNode, defaults.model);
      final defaultVoice = presets.isNotEmpty ? presets.first.id : '';
      _syncField(_ttsVoiceController, _ttsVoiceFocusNode, defaultVoice);
      _customTtsVoice = false;
      _ttsSpeed = null;
      _syncField(_ttsExtraParamsController, _ttsExtraParamsFocusNode, '');
    }
    if (!_ttsApiKeyFocusNode.hasFocus && _ttsApiKeyController.text.isNotEmpty) {
      _ttsApiKeyController.clear();
    }
  }

  void _selectTtsProvider(String wireName) {
    final next = wireName == 'volc_tts'
        ? TtsServiceKind.volcTts
        : TtsServiceKind.openAiCompatible;
    if (next == _ttsProvider) {
      return;
    }
    setState(() {
      _ttsProvider = next;
      _customTtsVoice = false;
      final presets = ttsVoicePresetsFor(next);
      final defaults = _ttsProtocolDefaults(next);
      _ttsBaseUrlController.text = defaults.url;
      _ttsModelController.text = defaults.model;
      _ttsVoiceController.text = presets.isNotEmpty ? presets.first.id : '';
    });
  }

  void _selectTtsVoice(String voice) {
    setState(() {
      _customTtsVoice = voice == customVoiceValue;
      _ttsVoiceController.text = _customTtsVoice ? '' : voice;
    });
  }

  TtsSettingsDraft? _readTtsDraft() {
    if (_ttsBaseUrlController.text.trim().isEmpty ||
        _ttsModelController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请填写语音合成服务地址和模型名称。')));
      return null;
    }
    final key = _ttsApiKeyController.text.trim();
    final voice = _ttsVoiceController.text.trim();
    Map<String, Object?>? extraParams;
    final extraText = _ttsExtraParamsController.text.trim();
    if (extraText.isNotEmpty) {
      try {
        final decoded = jsonDecode(extraText);
        if (decoded is! Map) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('自定义高级参数必须是 JSON 对象。')),
          );
          return null;
        }
        extraParams = decoded.cast<String, Object?>();
      } on FormatException {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('自定义高级参数 JSON 格式不正确，请检查语法。')),
        );
        return null;
      }
    }
    return TtsSettingsDraft(
      provider: _ttsProvider,
      baseUrl: _ttsBaseUrlController.text.trim(),
      model: _ttsModelController.text.trim(),
      apiKey: key.isEmpty ? null : key,
      voice: voice.isEmpty ? null : voice,
      speed: _ttsSpeed,
      extraParams: extraParams,
    );
  }

  Future<void> _saveTts(TtsSettingsViewModel viewModel) async {
    final draft = _readTtsDraft();
    if (draft == null) {
      return;
    }
    final saved = await viewModel.save(draft);
    if (saved && mounted) {
      _ttsApiKeyController.clear();
    }
  }

  Future<void> _confirmForgetTtsKey(TtsSettingsViewModel viewModel) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('tts-forget-key-dialog'),
        title: const Text('忘记语音合成的 API Key？'),
        content: const Text(
          '忘记后本机不再保存这个 Key，栖语暂时读不出声，直到你重新输入。'
          '语音合成服务的地址、模型、音色和语速不受影响。',
        ),
        actions: [
          TextButton(
            key: const Key('tts-forget-key-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('再想想'),
          ),
          FilledButton(
            key: const Key('tts-forget-key-confirm'),
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

  @override
  Widget build(BuildContext context) {
    return Consumer<TtsSettingsViewModel>(
      builder: (context, viewModel, child) {
        _syncTts(viewModel.settings);
        final theme = Theme.of(context);
        final keySet = viewModel.settings?.keySet ?? false;
        final testResult = viewModel.testResult;
        return _SettingsPanel(
          children: [
            Text(
              '语音朗读',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w500,
                letterSpacing: -0.8,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _ttsProvider == TtsServiceKind.volcTts
                  ? '把栖语写完的话读出来。豆包语音合成走火山方舟的 HTTP 接口，'
                        '模型名称填 Resource-Id；Key 只存本机 provider.json；'
                        '音频只存在内存，播完即丢。'
                  : '把栖语写完的话读出来的服务（OpenAI 兼容语音合成，如 tts-1）。'
                        '她先把每句完整写好、过了安全检查才开口读；音频只存在内存，'
                        '播完即丢，本机不留声音文件。',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 16),
            _ControlledDropdown(
              dropdownKey: const Key('tts-provider'),
              label: '服务类型',
              value: _ttsProvider == TtsServiceKind.volcTts
                  ? 'volc_tts'
                  : 'openai_compatible',
              items: const [
                DropdownMenuItem(
                  value: 'openai_compatible',
                  child: Text('OpenAI 兼容语音合成'),
                ),
                DropdownMenuItem(value: 'volc_tts', child: Text('豆包语音合成')),
              ],
              onChanged: _selectTtsProvider,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('tts-base-url'),
              controller: _ttsBaseUrlController,
              focusNode: _ttsBaseUrlFocusNode,
              decoration: InputDecoration(
                labelText: '服务地址',
                hintText: _ttsProtocolDefaults(_ttsProvider).urlHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('tts-model'),
              controller: _ttsModelController,
              focusNode: _ttsModelFocusNode,
              decoration: InputDecoration(
                labelText: _ttsProvider == TtsServiceKind.volcTts
                    ? 'Resource-Id'
                    : '模型名称',
                hintText: _ttsProtocolDefaults(_ttsProvider).modelHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Builder(
              builder: (context) {
                final voicePresets = ttsVoicePresetsFor(_ttsProvider);
                final currentVoice = _ttsVoiceController.text.trim();
                final effectiveVoiceValue = _customTtsVoice
                    ? customVoiceValue
                    : (currentVoice.isEmpty
                        ? (voicePresets.isNotEmpty
                            ? voicePresets.first.id
                            : customVoiceValue)
                        : (voicePresets.any((p) => p.id == currentVoice)
                            ? currentVoice
                            : customVoiceValue));
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ControlledDropdown(
                      dropdownKey: const Key('tts-voice-preset'),
                      label: '朗读音色',
                      value: effectiveVoiceValue,
                      items: [
                        for (final preset in voicePresets)
                          DropdownMenuItem(
                            value: preset.id,
                            child: Text(
                              preset.category != null
                                  ? '【${preset.category}】${preset.label}'
                                  : preset.label,
                            ),
                          ),
                        const DropdownMenuItem(
                          value: customVoiceValue,
                          child: Row(
                            children: [
                              Icon(Icons.edit_outlined, size: 18),
                              SizedBox(width: 8),
                              Text('输入其他音色 ID'),
                            ],
                          ),
                        ),
                      ],
                      onChanged: _selectTtsVoice,
                    ),
                    if (_customTtsVoice ||
                        (currentVoice.isNotEmpty &&
                            voicePresets.every((p) => p.id != currentVoice))) ...[
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('tts-voice'),
                        controller: _ttsVoiceController,
                        focusNode: _ttsVoiceFocusNode,
                        decoration: InputDecoration(
                          labelText: '音色 ID',
                          hintText: _ttsProvider == TtsServiceKind.volcTts
                              ? 'zh_female_vv_uranus_bigtts'
                              : 'alloy',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            MergeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _ttsSpeed == null
                              ? '语速：默认'
                              : '语速：${_ttsSpeed!.toStringAsFixed(2)} 倍',
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      if (_ttsSpeed != null)
                        TextButton(
                          key: const Key('tts-speed-reset'),
                          onPressed: () => setState(() => _ttsSpeed = null),
                          child: const Text('默认'),
                        ),
                    ],
                  ),
                  Slider(
                    key: const Key('tts-speed-slider'),
                    value: _ttsSpeed ?? 1.0,
                    min: 0.5,
                    max: 2.0,
                    divisions: 6,
                    label: (_ttsSpeed ?? 1.0).toStringAsFixed(2),
                    onChanged: (value) => setState(() => _ttsSpeed = value),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              keySet ? 'API Key 已保存在本机 provider.json' : '尚未保存语音合成的 API Key',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('tts-api-key'),
              controller: _ttsApiKeyController,
              focusNode: _ttsApiKeyFocusNode,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: keySet
                    ? '留空即可继续使用已保存的 Key'
                    : '保存后写入本机 provider.json',
                border: const OutlineInputBorder(),
              ),
            ),
            if (keySet) ...[
              const SizedBox(height: 8),
              TextButton(
                key: const Key('forget-tts-key'),
                onPressed: viewModel.saving
                    ? null
                    : () => unawaited(_confirmForgetTtsKey(viewModel)),
                child: const Text('忘记语音合成的 Key'),
              ),
            ],
            const SizedBox(height: 16),
            ExpansionTile(
              key: const Key('tts-advanced-params-tile'),
              title: const Text('高级参数'),
              subtitle: const Text('自定义云端扩展参数 (JSON)'),
              tilePadding: EdgeInsets.zero,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8.0, bottom: 8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _ttsProvider == TtsServiceKind.volcTts
                            ? '配置豆包语音合成的深合并参数，例如：\n'
                              '{\n'
                              '  "audio_params": { "sample_rate": 16000 },\n'
                              '  "additions": { "explicit_dialect": "sichuan" }\n'
                              '}'
                            : '配置 OpenAI 兼容语音合成的顶层扩展参数，例如：\n'
                              '{\n'
                              '  "response_format": "mp3"\n'
                              '}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        key: const Key('tts-extra-params'),
                        controller: _ttsExtraParamsController,
                        focusNode: _ttsExtraParamsFocusNode,
                        keyboardType: TextInputType.multiline,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: '自定义扩展参数 (JSON)',
                          hintText:
                              '{\n  "audio_params": {\n    "sample_rate": 16000\n  }\n}',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (viewModel.errorMessage case final message?)
              _StatusMessage(message: message, succeeded: false),
            if (viewModel.errorMessage == null)
              if (testResult case final result?)
                _StatusMessage(
                  message: result.message,
                  succeeded: result.succeeded,
                ),
            if (testResult != null && testResult.succeeded) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                key: const Key('tts-replay-preview'),
                onPressed: () => unawaited(viewModel.replayPreview()),
                icon: const Icon(Icons.volume_up_outlined),
                label: const Text('再听一次试听'),
              ),
            ],
            if (viewModel.errorMessage != null || testResult != null)
              const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  key: const Key('save-tts-settings'),
                  onPressed: viewModel.saving
                      ? null
                      : () => unawaited(_saveTts(viewModel)),
                  icon: _busyOr(viewModel.saving, Icons.lock_outline),
                  label: const Text('保存到本机'),
                ),
                OutlinedButton.icon(
                  key: const Key('test-tts-connection'),
                  onPressed: viewModel.testing
                    ? null
                    : () {
                        final draft = _readTtsDraft();
                        if (draft != null) {
                          unawaited(viewModel.testConnection(draft));
                        }
                      },
                  icon: _busyOr(viewModel.testing, Icons.bolt_outlined),
                  label: const Text('测试连接并试听'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// 本地数据管理区块：本地路径、备份恢复、记忆控制总览与清除数据。
class _LocalDataSection extends StatefulWidget {
  const _LocalDataSection({
    this.backupGateway,
    this.backupPlatform,
  });

  final BackupGateway? backupGateway;
  final BackupPlatform? backupPlatform;

  @override
  State<_LocalDataSection> createState() => _LocalDataSectionState();
}

class _LocalDataSectionState extends State<_LocalDataSection> {
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
    return Consumer<SettingsViewModel>(
      builder: (context, viewModel, child) {
        final theme = Theme.of(context);
        final preview = viewModel.clearPreview;
        return _SettingsPanel(
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
                  icon: _busyOr(viewModel.clearing, Icons.delete_outline),
                  label: const Text('清除产品数据'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// 隐私与边界区块：展示隐私说明入口。
class _PrivacySection extends StatelessWidget {
  const _PrivacySection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _SettingsPanel(
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
    );
  }
}

/// 体验与开发者选项区块：开发者模式开关与开发者诊断入口。
class _DeveloperSection extends StatefulWidget {
  const _DeveloperSection();

  @override
  State<_DeveloperSection> createState() => _DeveloperSectionState();
}

class _DeveloperSectionState extends State<_DeveloperSection> {
  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsViewModel>(
      builder: (context, viewModel, child) {
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SettingsPanel(
              children: [
                Text('体验与开发者选项', style: theme.textTheme.titleMedium),
                const SizedBox(height: 10),
                MergeSemantics(
                  child: Row(
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
                            : (value) => unawaited(
                                viewModel.setDeveloperMode(value),
                              ),
                      ),
                    ],
                  ),
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
            if (viewModel.errorMessage case final message?) ...[
              const SizedBox(height: 16),
              _StatusMessage(message: message, succeeded: false),
            ],
          ],
        );
      },
    );
  }
}

/// 设置分区面板的统一外观：surfaceContainer 底、18px 圆角与细描边。
class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

/// 按钮图标在忙碌时换成小号进度指示，动作按钮共用同一形态。
Widget _busyOr(bool busy, IconData icon) => busy
    ? const SizedBox.square(
        dimension: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      )
    : Icon(icon);

/// 记忆控制总览对话框：冻结与禁提逐条列出，删除只给数量；具体
/// 管理去记忆中心。
class _MemoryControlsDialog extends StatefulWidget {
  const _MemoryControlsDialog();

  @override
  State<_MemoryControlsDialog> createState() => _MemoryControlsDialogState();
}

class _MemoryControlsDialogState extends State<_MemoryControlsDialog> {
  /// 冻结/禁提两组共用同一呈现：计数标题、空态说明与逐条安全摘要。
  List<Widget> _controlGroup(
    ThemeData theme, {
    required String title,
    required String emptyText,
    required List<MemoryControlRecord> entries,
  }) => [
    Text(title, style: theme.textTheme.titleSmall),
    if (entries.isEmpty)
      Text(
        emptyText,
        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
      )
    else
      for (final entry in entries)
        Text('· ${entry.summary}', style: theme.textTheme.bodyMedium),
  ];

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<SettingsViewModel>();
    final controls = viewModel.controls;
    final theme = Theme.of(context);
    return AlertDialog(
      key: const Key('memory-controls-dialog'),
      title: const Text('记忆控制总览'),
      content: ConstrainedBox(
        // 上限而非定宽：窄窗口下随对话框收缩，不溢出（ticket 24）。
        constraints: const BoxConstraints(maxWidth: 460),
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
                    ..._controlGroup(
                      theme,
                      title: '已冻结（${controls.frozen.length}）',
                      emptyText: '没有冻结的记忆。',
                      entries: controls.frozen,
                    ),
                    const SizedBox(height: 12),
                    ..._controlGroup(
                      theme,
                      title: '已禁提（${controls.banned.length}）',
                      emptyText: '没有禁提的内容。',
                      entries: controls.banned,
                    ),
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
          ? ConstrainedBox(
              // 与内容分支同口径：上限而非定宽，窄窗口不溢出（ticket 24）。
              constraints: const BoxConstraints(maxWidth: 460),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          : ConstrainedBox(
              // 上限而非定宽：窄窗口下随对话框收缩，不溢出（ticket 24）。
              constraints: const BoxConstraints(maxWidth: 460),
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
                    '聊天模型与语音设置及其 API Key 不受影响；AnySearch API Key 会一并删除。'
                    '清除后栖语会像第一次见面一样重新开始。',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
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

({String url, String model, String urlHint, String modelHint})
_sttProtocolDefaults(SttServiceKind kind) => switch (kind) {
  SttServiceKind.openaiCompatible => (
    url: '',
    model: '',
    urlHint: 'https://api.example.com/v1',
    modelHint: 'whisper-1',
  ),
  SttServiceKind.volcSeedAsr => (
    url: 'wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream',
    model: 'volc.seedasr.sauc.duration',
    urlHint:
        'wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream',
    modelHint: 'volc.seedasr.sauc.duration',
  ),
};

({String url, String model, String urlHint, String modelHint})
_ttsProtocolDefaults(TtsServiceKind kind) => switch (kind) {
  TtsServiceKind.openAiCompatible => (
    url: '',
    model: '',
    urlHint: 'https://api.example.com/v1',
    modelHint: 'tts-1',
  ),
  // 豆包走火山方舟订阅专属 HTTP 端点（官方文档 2026-08-23 核实）：
  // 地址是完整端点、模型名称字段填 Resource-Id（不带 volc. 前缀）。
  TtsServiceKind.volcTts => (
    url: 'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
    model: 'seed-tts-2.0',
    urlHint: 'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
    modelHint: 'seed-tts-2.0',
  ),
};

class _ControlledDropdown extends StatelessWidget {
  const _ControlledDropdown({
    required this.dropdownKey,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final Key dropdownKey;
  final String label;
  final String value;
  final List<DropdownMenuItem<String>> items;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        key: dropdownKey,
        value: value,
        isExpanded: true,
        items: items,
        onChanged: (next) {
          if (next != null) {
            onChanged(next);
          }
        },
      ),
    ),
  );
}

class _ResolvedConnection extends StatelessWidget {
  const _ResolvedConnection({required this.provider, required this.baseUrl});

  final ProviderKind provider;
  final String baseUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${provider.label}协议与服务地址已自动配置',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectionArea(
                    child: Text(
                      baseUrl,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
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
    // 校验与连通测试的结果作为 live region 播报：屏幕阅读器不在输入
    // 框上也能听到成败（ticket 24 错误关联）。
    return Semantics(
      liveRegion: true,
      child: Row(
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
      ),
    );
  }
}
