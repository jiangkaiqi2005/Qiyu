import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_tokens.dart';
import 'settings_section_shell.dart';
import 'settings_strings.dart';
import 'embedding_settings_client.dart';
import 'embedding_settings_view_model.dart';

/// 记忆召回（Episode RAG）设置领域：独立的 embedding 服务地址、模型与
/// API Key，以及显式启用后的状态展示与重建入口（票 03）。
///
/// 领域的深模块边界在这里收口——控制器与焦点管理、设置同步、草稿校验
/// 与保存编排都落在 [EmbeddingSettingsForm]；[EmbeddingSettingsSection]
/// 只负责把这些状态画出来。异步编排（网关调用、加载与错误态）仍归
/// [EmbeddingSettingsViewModel]。
///
/// 启用语义（Spec）：保存配置与启用分开；首次启用前明确说明外发范围
/// 与费用（历史有效 episodes 的日期与摘要发给所配置服务、查询发送语义
/// 搜索词、费用按该服务计费、证据摘录不发给 embedding）；启用后的故障
/// 如实展示，不静默回退旧召回。
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

  /// 轮询轻刷新（票 03）每次经 fromJson 产生**新**快照对象，表单回显
  /// 因此按内容判等（壳层 [SettingsCredentialForm.sync] 的收口）：地址
  /// 、模型与 Key 保存态都没变就跳过同步——值未变的轮询快照不得重灌
  /// 失焦字段的草稿、不得清 Key 草稿；保存成功、忘记／更换 Key 这类
  /// 内容确实变化的显式动作照常回显。启用态与 RAG 状态行不进表单，
  /// 由 build 直接读视图模型，不参与判等。
  @override
  bool settingsContentEquals(EmbeddingSettings a, EmbeddingSettings b) =>
      a.configured == b.configured &&
      a.keySet == b.keySet &&
      a.baseUrl == b.baseUrl &&
      a.model == b.model;

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

/// 记忆召回设置区块。状态行与操作按钮按可见生命周期刷新：挂载期间
/// 周期重读（准备中的进度会随后台构建推进），离开页面或应用进入后台
/// 时停止刷新，不留全局轮询。
class EmbeddingSettingsSection extends StatefulWidget {
  const EmbeddingSettingsSection({super.key});

  @override
  State<EmbeddingSettingsSection> createState() =>
      _EmbeddingSettingsSectionState();
}

class _EmbeddingSettingsSectionState extends State<EmbeddingSettingsSection>
    with SettingsSaveFeedback, WidgetsBindingObserver {
  final _form = EmbeddingSettingsForm();
  Timer? _refreshTimer;

  /// 可见期的状态刷新节奏：与聊天页旁路状态同拍（2 秒），足以呈现
  /// 构建进度的推进，又不构成常驻全局轮询。
  static const _refreshInterval = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startRefreshTimer();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _form.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startRefreshTimer();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _stopRefreshTimer();
    }
  }

  void _startRefreshTimer() {
    _refreshTimer ??= Timer.periodic(_refreshInterval, (_) {
      final viewModel = context.read<EmbeddingSettingsViewModel>();
      unawaited(viewModel.refresh());
    });
  }

  void _stopRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
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

  /// 首次启用前的确认：如实说明外发范围与费用（Spec 用户故事 18），
  /// 用户确认后才触发后台完整构建。
  Future<void> _confirmAndEnable(EmbeddingSettingsViewModel viewModel) async {
    final draft = _form.readDraftOrReport(_reportInvalidDraft);
    if (draft == null) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          settingsTextNow(
            dialogContext,
            '启用记忆召回？',
            'Enable memory recall?',
          ),
        ),
        content: Text(
          settingsTextNow(
            dialogContext,
            '启用后，你有效记忆条目的日期与摘要会发送到所配置的 embedding 服务'
            '用于建索引，查询时发送语义搜索词，费用按该服务计费。'
            '记忆的证据摘录不会发给这个服务，只会按现有回答模型的规则使用。'
            '首次启用会在后台完整建索引，期间正常聊天不受影响。',
            'Once enabled, the dates and summaries of your valid memory entries are sent to the '
            'configured embedding service to build an index; queries are sent as semantic search '
            'terms and costs are billed by that service. Memory excerpts are never sent to it and '
            'are only used under the existing reply-model rules. The first build runs in the '
            'background; normal chatting is unaffected.',
          ),
        ),
        actions: [
          TextButton(
            key: const Key('embedding-enable-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(settingsTextNow(dialogContext, '先不启用', 'Not now')),
          ),
          FilledButton(
            key: const Key('embedding-enable-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(settingsTextNow(dialogContext, '启用', 'Enable')),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await viewModel.enable();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<EmbeddingSettingsViewModel>(
      builder: (context, viewModel, child) {
        _form.sync(viewModel.settings);
        final theme = Theme.of(context);
        final keySet = viewModel.settings?.keySet ?? false;
        final enabled = viewModel.settings?.enabled ?? false;
        return SettingsSectionPanel(
          sectionId: SettingsSectionId.memoryRecall,
          title: settingsText(context, '记忆召回', 'Memory recall'),
          children: [
            Text(
              settingsText(
                context,
                '配置一个兼容 OpenAI 的向量（embedding）服务。'
                '现在保存只是存下配置：不会启用召回，也不会发送任何记忆。'
                '启用后，你有效记忆条目的日期与摘要会发送到这里配置的服务，'
                '查询时发送语义搜索词，费用按该服务计费；'
                '记忆的证据摘录不会发给这个服务，只会按现有回答模型的规则使用。',
                'Configure an OpenAI-compatible embedding service for memory recall. '
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
              _RecallStatusView(
                status: viewModel.settings?.rag,
                enabled: enabled,
                configured: viewModel.settings?.configured ?? false,
                keySet: keySet,
                toggling: viewModel.toggling,
                rebuilding: viewModel.rebuilding,
                onEnable: () => unawaited(_confirmAndEnable(viewModel)),
                onDisable: () => unawaited(viewModel.disable()),
                onRebuild: () => unawaited(viewModel.rebuild()),
              ),
              const SizedBox(height: 16),
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

/// 记忆召回状态与操作行（票 03/04）：状态名 + 进度/待处理量 + 人话
/// 原因，启用前呈现确认说明，就绪/故障时给出停用与重建入口；就绪但
/// 有未完成更新时给出增量重试入口。
class _RecallStatusView extends StatelessWidget {
  const _RecallStatusView({
    required this.status,
    required this.enabled,
    required this.configured,
    required this.keySet,
    required this.toggling,
    required this.rebuilding,
    required this.onEnable,
    required this.onDisable,
    required this.onRebuild,
  });

  final MemoryRecallStatus? status;
  final bool enabled;
  final bool configured;
  final bool keySet;
  final bool toggling;
  final bool rebuilding;
  final VoidCallback onEnable;
  final VoidCallback onDisable;
  final VoidCallback onRebuild;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = status?.state ?? (enabled ? 'ready' : 'disabled');
    final reason = status?.reason;
    final pending = status?.pendingCount ?? 0;
    final (label, tone) = switch (state) {
      'preparing' => (
        settingsText(
          context,
          '准备中：${status?.progressDone ?? 0}/${status?.progressTotal ?? 0}',
          'Preparing: ${status?.progressDone ?? 0}/${status?.progressTotal ?? 0}',
        ),
        theme.colorScheme.onSurfaceVariant,
      ),
      // 更新中（票 04）：增量同步在途，显示待处理量；已有索引照常可查。
      'updating' => (
        settingsText(
          context,
          '更新中：待处理 $pending',
          'Updating: $pending pending',
        ),
        theme.colorScheme.onSurfaceVariant,
      ),
      'ready' => (
        settingsText(context, '已就绪', 'Ready'),
        theme.colorScheme.primary,
      ),
      'rebuildNeeded' => (
        settingsText(context, '需要重建', 'Rebuild needed'),
        theme.colorScheme.error,
      ),
      'unavailable' => (
        settingsText(context, '暂不可用', 'Unavailable'),
        theme.colorScheme.error,
      ),
      _ => (
        settingsText(context, '未启用', 'Not enabled'),
        theme.colorScheme.onSurfaceVariant,
      ),
    };
    final busy = toggling || rebuilding;
    // 就绪但有未完成更新（票 04）：给「重试更新」入口——只补待处理
    // 条目，不整库重算；需重建/暂不可用仍给完整重建。
    final showRetryUpdate = state == 'ready' && pending > 0;
    final showRebuild =
        enabled && (state == 'rebuildNeeded' || state == 'unavailable');
    return Container(
      key: const Key('embedding-recall-status'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: QiyuColors.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                settingsText(context, '召回状态', 'Recall status'),
                style: theme.textTheme.titleSmall,
              ),
              const Spacer(),
              Text(
                label,
                key: const Key('embedding-recall-state'),
                style: TextStyle(color: tone),
              ),
            ],
          ),
          if (state == 'preparing') ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              key: const Key('embedding-recall-progress'),
              value: (status?.progressTotal ?? 0) > 0
                  ? (status!.progressDone / status!.progressTotal).clamp(0.0, 1.0)
                  : null,
            ),
          ],
          if (reason != null && reason.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              reason,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              if (!enabled)
                FilledButton(
                  key: const Key('enable-memory-recall'),
                  onPressed: (!configured || !keySet || busy) ? null : onEnable,
                  child: Text(settingsText(context, '启用记忆召回', 'Enable memory recall')),
                )
              else ...[
                OutlinedButton(
                  key: const Key('disable-memory-recall'),
                  onPressed: busy ? null : onDisable,
                  child: Text(settingsText(context, '停用', 'Disable')),
                ),
                if (showRetryUpdate) ...[
                  const SizedBox(width: 10),
                  FilledButton.tonal(
                    key: const Key('retry-memory-recall-update'),
                    onPressed: busy ? null : onRebuild,
                    child: Text(settingsText(context, '重试更新', 'Retry update')),
                  ),
                ],
                if (showRebuild) ...[
                  const SizedBox(width: 10),
                  FilledButton.tonal(
                    key: const Key('rebuild-memory-recall'),
                    onPressed: busy ? null : onRebuild,
                    child: Text(settingsText(context, '重建索引', 'Rebuild index')),
                  ),
                ],
              ],
            ],
          ),
          if (!enabled)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                !configured || !keySet
                    ? settingsText(
                        context,
                        '先保存服务地址、模型与 Key，再启用记忆召回。',
                        'Save the service URL, model and key before enabling memory recall.',
                      )
                    : settingsText(
                        context,
                        '启用后使用语义查找定位旧事；未启用时按原目录方式查找。',
                        'Once enabled, past events are located by semantic search; the directory-based search stays in use until then.',
                      ),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
