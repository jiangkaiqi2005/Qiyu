import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_tokens.dart';
import '../shell/qiyu_widgets.dart';
import 'provider_catalog.dart';
import 'provider_settings_client.dart';
import 'provider_settings_view_model.dart';
import 'settings_section_shell.dart';

/// 模型连接（Provider）设置领域：模型连接、参数设置与 API Key 凭据管理。
///
/// 领域的深模块边界在这里收口——控制器与焦点管理、默认值（服务商目录
/// 套餐回填）、设置同步、草稿校验与保存编排都落在 [ProviderSettingsForm]；
/// [ProviderSettingsSection] 只负责把这些状态画出来。新增或修改本领域的
/// 一条校验、一个默认值或一段保存编排，只动本文件：理解一次保存不必再在
/// 视图、视图模型与网关之间往返。异步编排（网关调用、加载与错误态）仍归
/// [ProviderSettingsViewModel]。

/// 模型连接领域的表单控制器：页面里每一个输入框的控制器与焦点、
/// 服务商/套餐/模型三级选择态、已保存设置的同步、草稿校验与保存编排。
///
/// 本类不是 widget，也不持有任何 UI 呈现；错误提示等「怎么说给人听」
/// 的呈现通过 [readDraftOrReport] 的回调交给区块 widget。
final class ProviderSettingsForm {
  ProviderSettingsForm();

  final baseUrlController = TextEditingController();
  final modelController = TextEditingController();
  final temperatureController = TextEditingController(text: '0.7');
  final timeoutController = TextEditingController(text: '60');
  final apiKeyController = TextEditingController();

  final baseUrlFocusNode = FocusNode();
  final modelFocusNode = FocusNode();
  final temperatureFocusNode = FocusNode();
  final timeoutFocusNode = FocusNode();
  final apiKeyFocusNode = FocusNode();

  String _selectedProviderId = 'openai';
  String _selectedConnectionId = 'official';
  bool _customModel = false;
  ProviderSettings? _syncedSettings;
  bool _disposed = false;

  String get selectedProviderId => _selectedProviderId;

  String get selectedConnectionId => _selectedConnectionId;

  bool get customModel => _customModel;

  ProviderPreset get selectedProvider =>
      providerPresetById(_selectedProviderId);

  ProviderConnectionPreset get selectedConnection => selectedProvider
      .connections
      .firstWhere((connection) => connection.id == _selectedConnectionId);

  /// 模型下拉的当前值：自定义模型态显示「输入其他模型名称」那一档。
  String get modelDropdownValue =>
      _customModel || !selectedConnection.models.contains(modelController.text)
      ? customModelValue
      : modelController.text;

  /// 页面卸载时释放全部控制器与焦点节点。
  void dispose() {
    _disposed = true;
    baseUrlController.dispose();
    modelController.dispose();
    temperatureController.dispose();
    timeoutController.dispose();
    apiKeyController.dispose();
    baseUrlFocusNode.dispose();
    modelFocusNode.dispose();
    temperatureFocusNode.dispose();
    timeoutFocusNode.dispose();
    apiKeyFocusNode.dispose();
  }

  /// 已保存设置同步进表单：只处理新出现的设置对象（同一对象重复同步
  /// 直接返回，用户的选择与草稿不被重置）；未配置时按当前套餐回填
  /// 缺省地址与模型。Key 永不回显——只在未获焦时清掉旧草稿。
  void sync(ProviderSettings? settings) {
    if (settings == null || identical(settings, _syncedSettings)) {
      return;
    }
    _syncedSettings = settings;
    final selection = matchProviderSettings(settings);
    _selectedProviderId = selection.providerId;
    _selectedConnectionId = selection.connectionId;
    _customModel = selection.customModel;
    if (settings.configured) {
      syncFocusProtectedField(
        baseUrlController,
        baseUrlFocusNode,
        settings.baseUrl ?? '',
      );
      syncFocusProtectedField(
        modelController,
        modelFocusNode,
        settings.model ?? '',
      );
      syncFocusProtectedField(
        temperatureController,
        temperatureFocusNode,
        settings.temperature != null ? '${settings.temperature}' : '',
      );
      syncFocusProtectedField(
        timeoutController,
        timeoutFocusNode,
        settings.timeoutSeconds != null ? '${settings.timeoutSeconds}' : '',
      );
    } else {
      syncFocusProtectedField(
        baseUrlController,
        baseUrlFocusNode,
        selectedConnection.baseUrl,
      );
      syncFocusProtectedField(
        modelController,
        modelFocusNode,
        selectedConnection.models.isNotEmpty
            ? selectedConnection.models.first
            : '',
      );
    }
    if (!apiKeyFocusNode.hasFocus && apiKeyController.text.isNotEmpty) {
      apiKeyController.clear();
    }
  }

  /// 切换服务商：落到该商第一个套餐，并应用其地址与模型。
  void selectProvider(String providerId) {
    final provider = providerPresetById(providerId);
    _selectedProviderId = provider.id;
    _selectedConnectionId = provider.connections.first.id;
    _applyConnection(provider.connections.first);
  }

  /// 切换套餐：应用该套餐的地址与模型。
  void selectConnection(String connectionId) {
    final connection = selectedProvider.connections.firstWhere(
      (candidate) => candidate.id == connectionId,
    );
    _selectedConnectionId = connection.id;
    _applyConnection(connection);
  }

  void _applyConnection(ProviderConnectionPreset connection) {
    baseUrlController.text = connection.baseUrl;
    _customModel = connection.models.isEmpty;
    modelController.text = connection.models.isEmpty
        ? ''
        : connection.models.first;
  }

  /// 选择模型：预设模型直接落名，「输入其他模型名称」切到自定义态并
  /// 清空等待输入。
  void selectModel(String model) {
    _customModel = model == customModelValue;
    modelController.text = _customModel ? '' : model;
  }

  /// 读草稿：数值解析与必填校验都在领域内。草稿不合法时经 [report]
  /// 给出人话并返回 null——呈现方式（SnackBar）由区块决定。
  ProviderSettingsDraft? readDraftOrReport(
    void Function(String message) report,
  ) {
    final temperature = double.tryParse(temperatureController.text.trim());
    final timeout = int.tryParse(timeoutController.text.trim());
    if (temperature == null || timeout == null) {
      report('请检查 temperature 和超时时间。');
      return null;
    }
    if (baseUrlController.text.trim().isEmpty ||
        modelController.text.trim().isEmpty) {
      report('请填写服务地址和模型名称。');
      return null;
    }
    final key = apiKeyController.text.trim();
    return ProviderSettingsDraft(
      provider: selectedConnection.provider,
      baseUrl: baseUrlController.text.trim(),
      model: modelController.text.trim(),
      temperature: temperature,
      timeoutSeconds: timeout,
      apiKey: key.isEmpty ? null : key,
    );
  }

  /// 一次保存的领域编排：读草稿 → 交视图模型 → 成功后清掉 Key 草稿，
  /// 不把明文留在输入框。返回是否真的保存成功。
  Future<bool> save(
    ProviderSettingsViewModel viewModel, {
    void Function(String message)? report,
  }) async {
    final draft = readDraftOrReport(report ?? (_) {});
    if (draft == null) {
      return false;
    }
    final saved = await viewModel.save(draft);
    if (saved && !_disposed) {
      apiKeyController.clear();
    }
    return saved;
  }
}

/// 模型连接设置区块。
class ProviderSettingsSection extends StatefulWidget {
  const ProviderSettingsSection({super.key});

  @override
  State<ProviderSettingsSection> createState() =>
      _ProviderSettingsSectionState();
}

class _ProviderSettingsSectionState extends State<ProviderSettingsSection> {
  final _form = ProviderSettingsForm();

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  /// 领域校验结论的呈现：SnackBar 播报。
  void _reportInvalidDraft(String message) =>
      showSettingsSnackBar(context, message);

  Future<void> _save(ProviderSettingsViewModel viewModel) async {
    await _form.save(viewModel, report: _reportInvalidDraft);
  }

  Future<void> _confirmForgetKey(ProviderSettingsViewModel viewModel) async {
    final confirmed = await confirmSettingsForgetKey(
      context: context,
      // 模型连接域的对话框定位键没有领域前缀（历史如此），空串沿用。
      keyPrefix: '',
      title: '忘记已保存的 API Key？',
      content:
          '忘记后本机不再保存这个 Key，栖语将无法调用模型服务，'
          '直到你重新输入。模型连接的其他设置不受影响。',
    );
    if (confirmed) {
      await viewModel.forgetApiKey();
    }
  }

  Widget _credentialSection(
    BuildContext context,
    ProviderSettingsViewModel viewModel,
  ) {
    final keySet = viewModel.settings?.keySet ?? false;
    // 凭据块嵌在「模型连接」节内，不是分节：不套 [SettingsSectionPanel]，因此它
    // 没有可点的分节头、不参与折叠，也不画外层分节的那道发丝线。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
          controller: _form.apiKeyController,
          focusNode: _form.apiKeyFocusNode,
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
          QiyuFocusRingScope(
            borderRadius: QiyuRadii.circleBorder,
            child: TextButton(
              key: const Key('forget-api-key'),
              onPressed: viewModel.saving
                  ? null
                  : () => unawaited(_confirmForgetKey(viewModel)),
              child: const Text('忘记已保存的 Key'),
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ProviderSettingsViewModel>(
      builder: (context, viewModel, child) {
        _form.sync(viewModel.settings);
        final theme = Theme.of(context);
        final connection = _form.selectedConnection;
        return SettingsSectionPanel(
          sectionId: SettingsSectionId.provider,
          title: '模型连接',
          children: [
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
              SettingsControlledDropdown(
                dropdownKey: const Key('provider-preset'),
                label: '提供商',
                value: _form.selectedProviderId,
                items: [
                  for (final provider in providerCatalog)
                    DropdownMenuItem(
                      value: provider.id,
                      child: Text(provider.label),
                    ),
                ],
                onChanged: (providerId) =>
                    setState(() => _form.selectProvider(providerId)),
              ),
              const SizedBox(height: 16),
              SettingsControlledDropdown(
                dropdownKey: const Key('provider-connection'),
                label: '套餐 / 接口类型',
                value: _form.selectedConnectionId,
                items: [
                  for (final connection in _form.selectedProvider.connections)
                    DropdownMenuItem(
                      value: connection.id,
                      child: Text(connection.label),
                    ),
                ],
                onChanged: (connectionId) =>
                    setState(() => _form.selectConnection(connectionId)),
              ),
              const SizedBox(height: 16),
              SettingsControlledDropdown(
                dropdownKey: const Key('provider-model-preset'),
                label: '模型',
                value: _form.modelDropdownValue,
                items: [
                  for (final model in connection.models)
                    DropdownMenuItem(value: model, child: Text(model)),
                  const DropdownMenuItem(
                    value: customModelValue,
                    child: Row(
                      children: [
                        Icon(QiyuIcons.edit, size: 18),
                        SizedBox(width: 8),
                        Text('输入其他模型名称'),
                      ],
                    ),
                  ),
                ],
                onChanged: (model) => setState(() => _form.selectModel(model)),
              ),
              if (_form.customModel) ...[
                const SizedBox(height: 16),
                TextField(
                  key: const Key('provider-model'),
                  controller: _form.modelController,
                  focusNode: _form.modelFocusNode,
                  decoration: const InputDecoration(
                    labelText: '模型名称',
                    hintText: '输入服务商提供的 Model ID',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (connection.editableBaseUrl)
                TextField(
                  key: const Key('provider-base-url'),
                  controller: _form.baseUrlController,
                  focusNode: _form.baseUrlFocusNode,
                  decoration: const InputDecoration(
                    labelText: '服务地址',
                    hintText: 'https://example.com/v1',
                    border: OutlineInputBorder(),
                  ),
                )
              else
                _ResolvedConnection(
                  provider: connection.provider,
                  baseUrl: connection.baseUrl,
                ),
              const SizedBox(height: 8),
              ExpansionTile(
                key: const Key('provider-advanced-settings'),
                tilePadding: EdgeInsets.zero,
                // ExpansionTile 展开体自带恒裁剪的 ClipRect，完全展开时裁剪
                // 上沿与首行字段顶边重合；InputDecorator 的悬浮标签以边框线
                // 为中心、向上伸出约 5px，顶部留 8px 防截断（与 TTS 设置 tile
                // 的 Padding(top: 8) 同值）。
                childrenPadding: const EdgeInsets.only(top: 8, bottom: 8),
                title: const Text('高级参数'),
                subtitle: const Text('temperature 与请求超时'),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('provider-temperature'),
                          controller: _form.temperatureController,
                          focusNode: _form.temperatureFocusNode,
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
                          controller: _form.timeoutController,
                          focusNode: _form.timeoutFocusNode,
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
                SettingsStatusMessage(message: message, succeeded: false),
              if (viewModel.testResult case final result?)
                SettingsStatusMessage(
                  key: const Key('settings-status-connection'),
                  message: result.message,
                  succeeded: result.succeeded,
                ),
              if (viewModel.errorMessage != null ||
                  viewModel.testResult != null)
                const SizedBox(height: 18),
              Wrap(
                spacing: QiyuSpacing.sm,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    key: const Key('save-provider-settings'),
                    onPressed: viewModel.saving
                        ? null
                        : () => unawaited(_save(viewModel)),
                    icon: settingsBusyOr(viewModel.saving, QiyuIcons.lock),
                    label: const Text('保存到本机'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('test-provider-connection'),
                    onPressed: viewModel.testing
                        ? null
                        : () {
                            final draft = _form.readDraftOrReport(
                              _reportInvalidDraft,
                            );
                            if (draft != null) {
                              unawaited(viewModel.testConnection(draft));
                            }
                          },
                    icon: settingsBusyOr(viewModel.testing, QiyuIcons.bolt),
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
        // 内衬块取 8px 小元素档（design-system §8）：它嵌在分节之内，不是
        // 顶层卡片也不是列表项，套 18 会与外层分节的同档圆角打架。
        borderRadius: QiyuRadii.smallBorder,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              QiyuIcons.check_circle,
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
