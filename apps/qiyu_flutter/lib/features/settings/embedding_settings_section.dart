import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_tokens.dart';
import 'settings_section_shell.dart';
import 'settings_strings.dart';
import 'embedding_settings_client.dart';
import 'embedding_settings_view_model.dart';

/// 记忆召回（Episode RAG）设置领域：独立的 embedding 服务地址、模型与
/// API Key。
///
/// 领域的深模块边界在这里收口——控制器与焦点管理、设置同步、草稿校验
/// 与保存编排都落在 [EmbeddingSettingsForm]；[EmbeddingSettingsSection]
/// 只负责把这些状态画出来。异步编排（网关调用、加载与错误态）仍归
/// [EmbeddingSettingsViewModel]。
///
/// 本票只交付保存／测试／忘记 Key：页面不出现「启用」或「就绪」状态，
/// 也不伪装召回可用——真正启用、索引状态与召回由后续票接入（Spec 票
/// 02 范围边界）。启用后的发送范围与费用在此如实说明，用户据此决定
/// 是否配置。
final class EmbeddingSettingsForm
    extends
        SettingsCredentialForm<
          EmbeddingSettings,
          EmbeddingSettingsDraft,
          EmbeddingSettingsViewModel
        > {
  EmbeddingSettingsForm();

  @override
  TextEditingController get apiKeyDraftController => apiKeyController;

  @override
  FocusNode get apiKeyDraftFocusNode => apiKeyFocusNode;

  final baseUrlController = TextEditingController();
  final modelController = TextEditingController();
  final apiKeyController = TextEditingController();

  final baseUrlFocusNode = FocusNode();
  final modelFocusNode = FocusNode();
  final apiKeyFocusNode = FocusNode();

  @override
  void disposeFields() {
    baseUrlController.dispose();
    modelController.dispose();
    apiKeyController.dispose();
    baseUrlFocusNode.dispose();
    modelFocusNode.dispose();
    apiKeyFocusNode.dispose();
  }

  /// 同步一个新出现的设置对象：回显已存的地址与模型。Key 永不回显
  /// （壳层 sync 的收尾清掉未获焦的旧 Key 草稿）。
  @override
  void syncNewSettings(EmbeddingSettings settings) {
    if (!settings.configured) {
      syncFocusProtectedField(baseUrlController, baseUrlFocusNode, '');
      syncFocusProtectedField(modelController, modelFocusNode, '');
      return;
    }
    syncFocusProtectedField(
      baseUrlController,
      baseUrlFocusNode,
      settings.baseUrl ?? '',
    );
    syncFocusProtectedField(modelController, modelFocusNode, settings.model ?? '');
  }

  /// 读草稿：地址与模型必填。草稿不合法时经 [report] 给出人话并返回
  /// null——呈现方式（渐隐提示）由区块决定。地址作用域等凭据语义在
  /// Host 保存事务里裁定，表单不复制。
  @override
  EmbeddingSettingsDraft? readDraftOrReport(
    void Function(String message) report,
  ) {
    if (baseUrlController.text.trim().isEmpty ||
        modelController.text.trim().isEmpty) {
      report('请填写记忆召回服务地址和模型名称。');
      return null;
    }
    final key = apiKeyController.text.trim();
    return EmbeddingSettingsDraft(
      baseUrl: baseUrlController.text.trim(),
      model: modelController.text.trim(),
      apiKey: key.isEmpty ? null : key,
    );
  }
}

/// 记忆召回设置区块。
class EmbeddingSettingsSection extends StatefulWidget {
  const EmbeddingSettingsSection({super.key});

  @override
  State<EmbeddingSettingsSection> createState() =>
      _EmbeddingSettingsSectionState();
}

class _EmbeddingSettingsSectionState extends State<EmbeddingSettingsSection>
    with SettingsSaveFeedback {
  final _form = EmbeddingSettingsForm();

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  /// 一次保存：读草稿 → 交视图模型，成功收尾（统一轻提示与挂载检查）
  /// 归壳层 [SettingsSaveFeedback]。
  Future<void> _save(EmbeddingSettingsViewModel viewModel) async {
    final saved = await _form.save(viewModel, report: _reportInvalidDraft);
    reportSettingsSaved(saved);
  }

  void _reportInvalidDraft(String message) {
    if (mounted) {
      showSettingsNotice(context, message);
    }
  }

  Future<void> _confirmForgetKey(EmbeddingSettingsViewModel viewModel) async {
    final confirmed = await confirmSettingsForgetKey(
      context: context,
      keyPrefix: 'embedding-',
      title: settingsTextNow(context, '忘记记忆召回服务的 API Key？', 'Forget the memory recall service API key?'),
      content: settingsTextNow(
        context,
        '忘记后本机不再保存这个 Key，地址和模型不受影响；在启用记忆召回前不会向这个服务发送任何内容。',
        'The key will be removed from this device. The service URL and model are unaffected; nothing is sent to this service before memory recall is enabled.',
      ),
    );
    if (confirmed) {
      await viewModel.forgetApiKey();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<EmbeddingSettingsViewModel>(
      builder: (context, viewModel, child) {
        _form.sync(viewModel.settings);
        final theme = Theme.of(context);
        final keySet = viewModel.settings?.keySet ?? false;
        return SettingsSectionPanel(
          sectionId: SettingsSectionId.memoryRecall,
          title: settingsText(context, '记忆召回', 'Memory recall'),
          children: [
            Text(
              settingsText(
                context,
                '配置一个兼容 OpenAI 的向量（embedding）服务，供日后启用记忆召回。'
                '现在保存只是存下配置：不会启用召回，也不会发送任何记忆。'
                '启用后，你有效记忆条目的日期与摘要会发送到这里配置的服务，'
                '查询时发送语义搜索词，费用按该服务计费；'
                '记忆的证据摘录不会发给这个服务，只会按现有回答模型的规则使用。',
                'Configure an OpenAI-compatible embedding service for memory recall, which you can enable later. '
                'Saving now only stores the configuration: recall stays off and no memories are sent. '
                'Once enabled, the dates and summaries of your valid memory entries are sent to this service, '
                'queries are sent as semantic search terms, and costs are billed by that service; '
                'memory excerpts are never sent to it and are only used under the existing reply-model rules.',
              ),
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 16),
            if (viewModel.loading)
              const Center(child: CircularProgressIndicator())
            else ...[
              TextField(
                key: const Key('embedding-base-url'),
                controller: _form.baseUrlController,
                focusNode: _form.baseUrlFocusNode,
                decoration: InputDecoration(
                  labelText: settingsText(context, '服务地址', 'Service URL'),
                  hintText: 'https://api.example.com/v1',
                  border: settingsOutlineBorder(color: QiyuColors.line),
                  enabledBorder: settingsOutlineBorder(color: QiyuColors.line),
                  focusedBorder: settingsOutlineBorder(
                    color: QiyuColors.composerFocusLine,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('embedding-model'),
                controller: _form.modelController,
                focusNode: _form.modelFocusNode,
                decoration: InputDecoration(
                  labelText: settingsText(context, '模型名称', 'Model name'),
                  hintText: 'text-embedding-3-small',
                  border: settingsOutlineBorder(color: QiyuColors.line),
                  enabledBorder: settingsOutlineBorder(color: QiyuColors.line),
                  focusedBorder: settingsOutlineBorder(
                    color: QiyuColors.composerFocusLine,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SettingsApiKeyField(
                fieldKey: const Key('embedding-api-key'),
                controller: _form.apiKeyController,
                focusNode: _form.apiKeyFocusNode,
                keySet: keySet,
                title: keySet
                    ? settingsText(context, 'Key 已保存在本机', 'Key saved locally')
                    : settingsText(context, '尚未保存 API Key', 'No API key saved'),
                titleStyle: theme.textTheme.titleSmall,
                label: 'API Key',
                hint: keySet
                    ? settingsText(context, '留空即可继续使用已保存的 Key', 'Leave blank to keep using the saved key')
                    : settingsText(context, '保存后写入本机 provider.json', 'Saved locally to provider.json'),
                forgetButtonKey: const Key('forget-embedding-key'),
                forgetLabel: settingsText(context, '忘记记忆召回服务的 Key', 'Forget memory recall key'),
                onForgetKey: viewModel.saving
                    ? null
                    : () => unawaited(_confirmForgetKey(viewModel)),
              ),
              const SizedBox(height: 20),
              ...settingsStatusBanners(
                errorMessage: viewModel.errorMessage,
                testResult: viewModel.testResult == null
                    ? null
                    : (
                        message: viewModel.testResult!.message,
                        succeeded: viewModel.testResult!.succeeded,
                      ),
                trailingGap: 14,
              ),
              SettingsSaveTestButtons(
                saveButtonKey: const Key('save-embedding-settings'),
                saveLabel: settingsText(context, '保存到本机', 'Save locally'),
                saveBusy: viewModel.saving,
                onSave: () => unawaited(_save(viewModel)),
                test: (
                  buttonKey: const Key('test-embedding-connection'),
                  label: settingsText(context, '测试连接', 'Test connection'),
                  busy: viewModel.testing,
                  onPressed: () {
                    final draft = _form.readDraftOrReport(_reportInvalidDraft);
                    if (draft != null) {
                      unawaited(viewModel.testConnection(draft));
                    }
                  },
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
