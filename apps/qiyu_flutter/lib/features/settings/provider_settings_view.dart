import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_tokens.dart';
import '../memory/backup_client.dart';
import '../memory/backup_platform.dart';
import '../memory/backup_view.dart';
import '../onboarding/onboarding_view_model.dart';
import '../shell/qiyu_shell.dart';
import '../shell/qiyu_widgets.dart';
import 'provider_settings_section.dart';
import 'provider_settings_view_model.dart';
import 'proxy_settings_view_model.dart';
import 'settings_client.dart';
import 'settings_collapse_platform.dart';
import 'settings_section_shell.dart';
import 'settings_view_model.dart';
import 'stt_settings_section.dart';
import 'stt_settings_view_model.dart';
import 'tts_settings_section.dart';
import 'tts_settings_view_model.dart';
import 'web_search_settings_section.dart';
import 'web_search_settings_view_model.dart';

/// 设置中心（ticket 23）：模型连接、本地数据管理（备份 / 记忆控制
/// 总览 / 清除产品数据）、隐私说明与开发者选项。危险操作（忘记
/// Key、清除产品数据）都有明确影响说明与确认。
///
/// 页面本体只承担**页面级**职责：分节折叠状态的持久化、四个设置领域
/// 区块的装配、以及不属任何领域的三节（本地数据 / 隐私 / 开发者）。
/// 各领域的控制器、默认值、校验与保存编排内聚在各自的领域模块里
/// （`provider_settings_section.dart` 等）。
class ProviderSettingsView extends StatefulWidget {
  const ProviderSettingsView({
    super.key,
    this.backupGateway,
    this.backupPlatform,
    this.collapseStore,
  });

  /// 备份网关与浏览器能力接缝：缺省走真实 HTTP 与 Web 实现；
  /// widget 测试注入桩。
  final BackupGateway? backupGateway;
  final BackupPlatform? backupPlatform;

  /// 分节折叠状态的本地存储：缺省走当前环境的实现（Web＝浏览器
  /// localStorage，其余＝内存）。**只是 UI 状态**——不经 Host `/api`、
  /// 不进 Markdown 会话（design-system §8）；widget 测试注入一份，
  /// 用来核「离开再进来还收着」。
  final SettingsCollapseStore? collapseStore;

  @override
  State<ProviderSettingsView> createState() => _ProviderSettingsViewState();
}

class _ProviderSettingsViewState extends State<ProviderSettingsView> {
  bool _requestedInitialization = false;

  /// 折叠状态的本地存储：同步读写，只存 UI 状态（design-system §8）。
  late final SettingsCollapseStore _collapseStore =
      widget.collapseStore ?? createSettingsCollapseStore();

  /// 当前**收起**的分节 id 集合。初值在 [initState] 从本地存储读一次
  /// （见 [_readCollapsedSections]）；之后每次折叠都会换成一个新集合。
  late Set<String> _collapsedSections;

  @override
  void initState() {
    super.initState();
    _collapsedSections = _readCollapsedSections();
  }

  /// §8 的默认档与本机存过的档二选一：存过（含「存过空集＝上次是全部展开」）
  /// 就照存过的来，没存过才用默认档。存储里出现名单外的 id 一律不采纳——
  /// 一节平白收起而用户找不回出口，比退回默认档更糟。
  Set<String> _readCollapsedSections() {
    final stored = _collapseStore.readCollapsed();
    if (stored == null) {
      return SettingsSectionId.defaultCollapsed;
    }
    return Set<String>.unmodifiable(stored.intersection(SettingsSectionId.all));
  }

  void _toggleSection(String sectionId) {
    final collapsed = _collapsedSections.contains(sectionId)
        ? _collapsedSections.difference(<String>{sectionId})
        : _collapsedSections.union(<String>{sectionId});
    setState(() => _collapsedSections = Set<String>.unmodifiable(collapsed));
    // 写回是同步的，且实现侧吞掉异常：折叠偏好丢了只是下次进来回到默认档。
    _collapseStore.writeCollapsed(_collapsedSections);
  }

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
      unawaited(context.read<ProxySettingsViewModel>().initialize());
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
            // 与历史/记忆中心同一档功能页阅读列宽：三页页头返回键的左缘
            // 必须对齐，列宽分档会让宽窗口下居中的内容列各偏各的。
            constraints: const BoxConstraints(
              maxWidth: QiyuLayout.pageReadingMaxWidth,
            ),
            // 折叠状态由这一层下发：七节各自透传两个参数会把表单代码埋掉，
            // 壳与记忆中心同样用 InheritedWidget 传这类页面级 UI 状态。
            child: SettingsSectionCollapseScope(
              collapsed: _collapsedSections,
              onToggle: _toggleSection,
              child: Theme(
                data: theme.copyWith(
                  inputDecorationTheme: theme.inputDecorationTheme.copyWith(
                    border: settingsOutlineBorder(color: QiyuColors.line),
                    enabledBorder: settingsOutlineBorder(color: QiyuColors.line),
                    focusedBorder: settingsOutlineBorder(
                      color: QiyuColors.composerFocusLine,
                    ),
                    errorBorder: settingsOutlineBorder(color: QiyuColors.danger),
                    focusedErrorBorder: settingsOutlineBorder(
                      color: QiyuColors.danger,
                    ),
                  ),
                ),
                child: ListView(
                key: const Key('settings-scroll'),
                // 顶留白取无环页头档：与记忆/历史页页头返回键的纵向同位
                // 由页头同位回归测试锁定。
                padding: const EdgeInsets.fromLTRB(
                  24,
                  QiyuLayout.pageHeaderTopPaddingNoRing,
                  24,
                  48,
                ),
                // 分节之间不再另写 SizedBox：阅读式下节与节的留白由
                // [SettingsSectionPanel] 按原型变体 B 自己给（展开 24 + 24，收起 8）。
                children: [
                  // 窄屏被壳包住时，三条杠浮在左上角：页头 Row 排在整列的 24 左留白
                  // 之内，所以在它身上再补一段壳给出的差额，「设置」标题才不会被压住。
                  Padding(
                    padding: EdgeInsets.only(
                      left: QiyuShellScope.headerLeftOverrun(context),
                    ),
                    child: Row(
                      children: [
                        // 返回箭头何时让位给三条杠由壳判定（窄屏且被壳包住时
                        // 整块不出现），见 [QiyuPageHeaderBackButton]。
                        const QiyuPageHeaderBackButton(
                          buttonKey: Key('settings-back'),
                        ),
                        Text('设置', style: theme.textTheme.headlineSmall),
                      ],
                    ),
                  ),
                  const SizedBox(height: 30),
                  // 分节顺序由 design-system §8 固定（模型连接 → 语音朗读 →
                  // 语音转写 → 联网搜索 → 本地数据 → 隐私与边界 →
                  // 体验与开发者选项），settings_view_test 按各节标题在页面上的
                  // 纵向位置核这条次序。第三节的叫法两处不同且 §8 已登记：规范按
                  // **机制**叫「语音转写」，[SttSettingsSection] 渲染的标题是「语音输入」，
                  // §8 明写不声称页面上有「语音转写」四个字——这里只按 §8 排
                  // **次序**，不改标题文案。
                  const ProviderSettingsSection(),
                  const TtsSettingsSection(),
                  const SttSettingsSection(),
                  const WebSearchSettingsSection(),
                  _LocalDataSection(
                    backupGateway: widget.backupGateway,
                    backupPlatform: widget.backupPlatform,
                  ),
                  const _PrivacySection(),
                  const _DeveloperSection(),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
}

/// 本地数据管理区块：本地路径、备份恢复、记忆控制总览与清除数据。
class _LocalDataSection extends StatefulWidget {
  const _LocalDataSection({this.backupGateway, this.backupPlatform});

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
        return SettingsSectionPanel(
          sectionId: SettingsSectionId.localData,
          title: '本地数据',
          children: [
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
              spacing: QiyuSpacing.sm,
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
                  icon: const Icon(QiyuIcons.archive),
                  label: const Text('备份与恢复'),
                ),
                OutlinedButton.icon(
                  key: const Key('settings-memory-center'),
                  onPressed: () => context.push('/memory'),
                  icon: const Icon(QiyuIcons.menu_book),
                  label: const Text('记忆中心'),
                ),
                OutlinedButton.icon(
                  key: const Key('settings-memory-controls'),
                  onPressed: () => unawaited(_showMemoryControls(viewModel)),
                  icon: const Icon(QiyuIcons.shield),
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
                  icon: settingsBusyOr(viewModel.clearing, QiyuIcons.delete),
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
    return SettingsSectionPanel(
      sectionId: SettingsSectionId.privacy,
      title: '隐私与边界',
      children: [
        Text(
          '数据只在本机；只有你配置了模型服务才会联网；敏感信息永不被记住。',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          key: const Key('settings-privacy'),
          onPressed: () => context.push('/privacy'),
          icon: const Icon(QiyuIcons.privacy_tip),
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
        return SettingsSectionPanel(
          sectionId: SettingsSectionId.developer,
          title: '体验与开发者选项',
          // §8 固定顺序里的末节：不画下沿发丝线（原型 `last-of-type`）。
          isLast: true,
          children: [
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
                        : (value) =>
                              unawaited(viewModel.setDeveloperMode(value)),
                  ),
                ],
              ),
            ),
            if (viewModel.developerMode)
              OutlinedButton.icon(
                key: const Key('settings-diagnostics'),
                onPressed: () => context.push('/settings/diagnostics'),
                icon: const Icon(QiyuIcons.monitor_heart),
                label: const Text('开发者诊断'),
              ),
            if (viewModel.errorMessage case final message?) ...[
              const SizedBox(height: 16),
              SettingsStatusMessage(message: message, succeeded: false),
            ],
          ],
        );
      },
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
        constraints: const BoxConstraints(
          maxWidth: QiyuLayout.dialogContentMaxWidth,
        ),
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
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            key: const Key('memory-controls-close'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
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
      content: ConstrainedBox(
        // 上限而非定宽：窄窗口下随对话框收缩，不溢出（ticket 24）。
        constraints: const BoxConstraints(
          maxWidth: QiyuLayout.dialogContentMaxWidth,
        ),
        child: preview == null
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
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
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            key: const Key('clear-data-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('先不清除'),
          ),
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
