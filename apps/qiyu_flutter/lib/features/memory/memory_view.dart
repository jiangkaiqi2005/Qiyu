import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import '../accessibility.dart';
import '../navigation.dart';
import '../shell/qiyu_shell.dart';
import '../shell/qiyu_widgets.dart';
import '../time_format.dart';
import 'backup_client.dart';
import 'backup_platform.dart';
import 'backup_view.dart';
import 'memory_actions.dart';
import 'memory_client.dart';
import 'memory_view_model.dart';

const _maskedPlaceholder = '这条内容涉及私密信息，暂不直接展示。';

/// 四区记忆中心（ticket 19 读取 / ticket 20 控制）：最近发生、长期
/// 印象、关于你、我们的关系。导航只用用户语言；条目操作按钮常驻，
/// 冻结/解除冻结与解除禁提直接执行，修正先过预填当下已有原文的对话框，
/// 敏感揭示先取回原文再在一次性对话框里展示，禁提与删除先经明确确认；
/// 结果以成功、部分失败、可恢复失败三态呈现。
class MemoryView extends StatelessWidget {
  const MemoryView({super.key, this.backupGateway, this.backupPlatform});

  /// 备份网关与浏览器能力接缝：缺省走真实 HTTP 与 Web 实现；
  /// widget 测试注入桩。
  final BackupGateway? backupGateway;
  final BackupPlatform? backupPlatform;

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<MemoryCenterViewModel>();
    return Scaffold(
      body: SafeArea(
        child: DefaultTabController(
          length: 4,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: QiyuLayout.pageReadingMaxWidth,
              ),
              child: Column(
                children: [
                  Padding(
                    // 窄屏被壳包住时，三条杠浮在左上角：页头左内缩在自身 24 之外
                    // 再让开它的占位（差额由壳给出），「记忆」标题才不会被压住。
                    padding: EdgeInsets.fromLTRB(
                      24 + QiyuShellScope.headerLeftOverrun(context),
                      QiyuLayout.pageHeaderBaseTopPadding,
                      24,
                      4,
                    ),
                    child: Row(
                      children: [
                        // 返回箭头何时让位给三条杠由壳判定（窄屏且被壳包住时
                        // 整块不出现），见 [QiyuPageHeaderBackButton]。
                        const QiyuPageHeaderBackButton(
                          buttonKey: Key('memory-back'),
                        ),
                        Text(
                          '记忆',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const Spacer(),
                        QiyuFocusRingScope(
                          borderRadius: QiyuRadii.circleBorder,
                          child: IconButton(
                            key: const Key('memory-backup'),
                            onPressed: () => unawaited(
                              showBackupDialog(
                                context,
                                gateway: backupGateway,
                                platform: backupPlatform,
                              ),
                            ),
                            tooltip: '备份与恢复',
                            icon: const Icon(QiyuIcons.archive),
                          ),
                        ),
                        QiyuFocusRingScope(
                          borderRadius: QiyuRadii.circleBorder,
                          child: IconButton(
                            key: const Key('refresh-memory'),
                            onPressed: viewModel.loading
                                ? null
                                : () => unawaited(viewModel.refresh()),
                            tooltip: '刷新记忆',
                            icon: const Icon(QiyuIcons.refresh),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 四区图标取 §4 定案选型（时钟 / 山形 / 单人 / 双人）；选中态
                  // 的近白文字与淡白下划线全部由主题层 `tabBarTheme` 供给，页面
                  // 不自写颜色。§8「横向滚动容器不留滚动控件」这一条**不在这里写
                  // 代码**：它由框架档满足——`MaterialScrollBehavior.buildScrollbar`
                  // 对 `Axis.horizontal` 直接 `return child`（SDK 3.44.8
                  // `packages/flutter/lib/src/material/app.dart`），TabBar
                  // 这个 `isScrollable` 的横滚容器本来就不画滚动条，纵向内容区仍按
                  // 同一档规则画。故意不再包一层 `ScrollConfiguration`：换到基类
                  // `ScrollBehavior` 唯有点名的横滚仍是空操作，代价却是把该容器的
                  // 越界回弹从 M3 的 `StretchingOverscrollIndicator` 换成基类的
                  // `GlowingOverscrollIndicator`（对比 `widgets/scroll_configuration.dart`
                  // 的 `ScrollBehavior.buildOverscrollIndicator` 与 `material/app.dart`
                  // 的 `MaterialScrollBehavior.buildOverscrollIndicator`，本主题
                  // `useMaterial3: true`），并把 `getPlatform` 从 `Theme.of(context)
                  // .platform` 换成 `defaultTargetPlatform`。SDK 侧只按版本 + 方法名
                  // 指路：行号会随版本漂移，按名 grep 才复核得动。结果由
                  // test/memory_view_test.dart 锁住。
                  const TabBar(
                    isScrollable: true,
                    tabs: [
                      Tab(
                        key: Key('memory-tab-recent'),
                        icon: Icon(QiyuIcons.schedule),
                        text: '最近发生',
                      ),
                      Tab(
                        key: Key('memory-tab-longterm'),
                        icon: Icon(QiyuIcons.landscape),
                        text: '长期印象',
                      ),
                      Tab(
                        key: Key('memory-tab-persona'),
                        icon: Icon(QiyuIcons.person),
                        text: '关于你',
                      ),
                      Tab(
                        key: Key('memory-tab-relationship'),
                        icon: Icon(QiyuIcons.groups),
                        text: '我们的关系',
                      ),
                    ],
                  ),
                  const Divider(height: 1),
                  ?_recoveryBanner(viewModel.overview),
                  Expanded(child: _body(context, viewModel)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, MemoryCenterViewModel viewModel) {
    if (viewModel.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (viewModel.errorMessage case final message?) {
      return QiyuErrorRetryState(
        message: message,
        messageStyle: TextStyle(color: Theme.of(context).colorScheme.error),
        retryKey: const Key('retry-memory'),
        onRetry: () => unawaited(viewModel.refresh()),
      );
    }
    final overview = viewModel.overview;
    if (overview == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return TabBarView(
      children: [
        _RecentTab(section: overview.recent),
        _LongTermTab(section: overview.longTerm),
        _PersonaTab(section: overview.persona),
        _RelationshipTab(section: overview.relationship),
      ],
    );
  }

  /// 恢复状态横幅（ticket 21）：有损坏发现或保留的隔离原件时才呈现；
  /// 展开可见受影响范围、采用的证据、恢复结果与仍无法恢复的内容。
  Widget? _recoveryBanner(MemoryOverview? overview) {
    final recovery = overview?.recovery;
    if (recovery == null || recovery.healthy || recovery.findings.isEmpty) {
      return null;
    }
    return _RecoveryBanner(section: recovery);
  }
}

class _RecoveryBanner extends StatelessWidget {
  const _RecoveryBanner({required this.section});

  final MemoryRecoverySection section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = section.findings
        .where((finding) => finding.outcome == MemoryRecoveryOutcome.pending)
        .length;
    final partial = section.findings
        .where((finding) => finding.outcome == MemoryRecoveryOutcome.partial)
        .length;
    final subtitle = [
      if (pending > 0) '$pending 项待恢复',
      if (partial > 0) '$partial 项部分恢复',
      if (section.quarantinedFiles > 0) '${section.quarantinedFiles} 份原件保留在隔离区',
    ].join('，');
    return QiyuFocusRingScope(
      borderRadius: QiyuRadii.cardBorder,
      child: Card(
        key: const Key('memory-recovery-banner'),
        margin: const EdgeInsets.fromLTRB(24, 8, 24, 0),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          shape: const Border(),
          collapsedShape: const Border(),
          leading: Icon(
            QiyuIcons.health_and_safety,
            color: theme.colorScheme.error,
          ),
          title: const Text('部分记忆文件出现过损坏'),
          subtitle: subtitle.isEmpty ? null : Text(subtitle),
          children: [
            for (final finding in section.findings)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_findingText(finding)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _findingText(MemoryRecoveryFindingCard finding) {
    final buffer = StringBuffer(
      '${finding.layer}：${finding.kindLabel}，${finding.outcomeLabel}',
    );
    final evidence = finding.evidence;
    if (evidence != null && evidence.isNotEmpty) {
      buffer.write('\n采用证据：$evidence');
    }
    final loss = finding.loss;
    if (loss != null && loss.isNotEmpty) {
      buffer.write('\n仍无法恢复：$loss');
    }
    return buffer.toString();
  }
}

class _RecentTab extends StatelessWidget {
  const _RecentTab({required this.section});

  final MemoryRecentSection section;

  @override
  Widget build(BuildContext context) {
    if (section.days.isEmpty) {
      return const _EmptyState(
        key: Key('memory-empty-recent'),
        text: '还没有最近的记录。\n聊过之后，这里会出现整理好的记忆。',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        for (final day in section.days) ...[
          Row(
            children: [
              Text(
                formatDayHeader(day.date),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (!day.finalized) ...[
                const SizedBox(width: 8),
                const _StatusChip(
                  key: Key('memory-day-organizing'),
                  label: '整理中',
                ),
              ] else if (day.finalizedAt case final organizedAt?) ...[
                const SizedBox(width: 8),
                Text(
                  '整理于 ${formatClock(organizedAt)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
          if (day.summary case final summary?)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(
                _visibleOr(day.summaryMasked, summary),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 4),
          for (final entry in day.entries)
            _EntryTile(key: Key('memory-entry-${entry.id}'), entry: entry),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _LongTermTab extends StatelessWidget {
  const _LongTermTab({required this.section});

  final MemoryLongTermSection section;

  @override
  Widget build(BuildContext context) {
    if (!section.present) {
      return const _EmptyState(
        key: Key('memory-empty-longterm'),
        text: '还没有形成长期印象。\n长期印象来自周期性的深度整理，需要一些积累。',
      );
    }
    if (!section.readable) {
      return const _EmptyState(
        key: Key('memory-unreadable-longterm'),
        text: '这一部分记忆暂时读不出来，不影响其他内容。',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        for (final group in section.groups) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: Text(
              group.section,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final item in group.items)
            _LongTermTile(key: Key('memory-longterm-${item.id}'), item: item),
        ],
        if (section.organizedAt case final organizedAt?)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              '最近一次深度整理：${formatTime(organizedAt)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _PersonaTab extends StatelessWidget {
  const _PersonaTab({required this.section});

  final MemoryPersonaSection section;

  @override
  Widget build(BuildContext context) {
    // 称呼设定卡常驻（称呼定稿 2026-09-03）：错过首见也能在这里补设；
    // 没设称呼且画像未成时仍保留诚实空态。
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _AppellationCard(appellation: section.appellation),
        if (section.appellation == null && section.isEmpty)
          const _EmptyState(
            key: Key('memory-empty-persona'),
            text: '还没有形成关于你的画像。\n画像来自一次次聊天里的积累，慢慢来。',
          ),
        for (final branch in section.branches) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: Text(
              branch.title,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (!branch.readable)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('这一部分暂时读不出来，不影响其他内容。'),
            )
          else if (branch.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('还没有形成这一部分画像。'),
            )
          else ...[
            for (final root in branch.roots)
              _RootTile(key: Key('memory-root-${root.id}'), root: root),
            for (final middle in branch.unrooted)
              _MiddleTile(
                key: Key('memory-middle-${middle.id}'),
                middle: middle,
              ),
          ],
        ],
      ],
    );
  }
}

/// 称呼设定卡：展示栖语当前怎么称呼用户，可修改——称呼始终由用户
/// 掌握；未设置时安静留空，绝不替用户编一个。
class _AppellationCard extends StatelessWidget {
  const _AppellationCard({required this.appellation});

  final String? appellation;

  @override
  Widget build(BuildContext context) {
    final busy = context.select<MemoryCenterViewModel, bool>(
      (viewModel) => viewModel.acting,
    );
    return _MemoryCard(
      child: ListTile(
        title: Text('栖语这样叫你', style: Theme.of(context).textTheme.titleSmall),
        subtitle: Text(
          appellation ?? '还没设置',
          key: const Key('memory-appellation-value'),
        ),
        trailing: QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            key: const Key('memory-appellation-edit'),
            onPressed: busy ? null : () => unawaited(_edit(context)),
            child: Text(appellation == null ? '设置' : '修改'),
          ),
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context) async {
    // await 之前取齐上下文依赖：发起处界面销毁后不再挂结果横幅。
    final viewModel = context.read<MemoryCenterViewModel>();
    final messenger = ScaffoldMessenger.of(context);
    final updated = await showDialog<String>(
      context: context,
      builder: (dialogContext) => const _AppellationEditDialog(),
    );
    if (updated == null) {
      return;
    }
    final trimmed = updated.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final result = await viewModel.setAppellation(trimmed);
    messenger.showSnackBar(memoryActionResultSnackBar(result));
  }
}

/// 称呼编辑对话框：只此一项，不追问任何其他信息。
class _AppellationEditDialog extends StatefulWidget {
  const _AppellationEditDialog();

  @override
  State<_AppellationEditDialog> createState() => _AppellationEditDialogState();
}

class _AppellationEditDialogState extends State<_AppellationEditDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: context.read<MemoryCenterViewModel>().overview?.persona.appellation,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('栖语怎么称呼你？'),
      content: TextField(
        key: const Key('memory-appellation-field'),
        controller: _controller,
        autofocus: true,
        maxLength: 20,
        decoration: const InputDecoration(
          hintText: '名字、昵称、代号都行',
          counterText: '',
        ),
      ),
      actions: [
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ),
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            key: const Key('memory-appellation-save'),
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: const Text('保存'),
          ),
        ),
      ],
    );
  }
}

class _RelationshipTab extends StatelessWidget {
  const _RelationshipTab({required this.section});

  final MemoryRelationshipSection section;

  @override
  Widget build(BuildContext context) {
    if (section.isEmpty) {
      return const _EmptyState(
        key: Key('memory-empty-relationship'),
        text: '还没有形成关系记录。\n相处方式会随着一次次的聊天慢慢清晰。',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (section.present) ...[
          Text(
            section.since == null
                ? '当前阶段：${section.stage}'
                : '当前阶段：${section.stage} · 自 ${section.since}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          // 相处方式/试探/近期变化三组同为状态包投影，展示口径一致。
          for (final (title, items) in [
            ('当前相处方式', section.confirmed),
            ('试探中', section.probes),
            ('近期变化', section.recentChanges),
          ]) ...[
            if (items.isNotEmpty) ...[
              _sectionTitle(context, title),
              for (final item in items)
                _LongTermTile(
                  key: Key('memory-relationship-${item.id}'),
                  item: item,
                  statePack: true,
                ),
            ],
          ],
        ],
        if (section.sharedPast.isNotEmpty) ...[
          _sectionTitle(context, '共同过往'),
          for (final item in section.sharedPast)
            _LongTermTile(key: Key('memory-longterm-${item.id}'), item: item),
        ],
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 8),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
  );
}

/// 条目详情/证据追溯页：episode 条目、画像根路径、画像中间理解与
/// 某一天的记录都在这里展开。episode 条目支持修正、控制、删除与
/// 敏感内容的临时揭示（ticket 20）。
class MemoryItemView extends StatefulWidget {
  const MemoryItemView({super.key, required this.itemId});

  final String itemId;

  @override
  State<MemoryItemView> createState() => _MemoryItemViewState();
}

class _RevealState {
  _RevealState(this.text, this.timer);

  final String text;
  final Timer timer;
}

class _MemoryItemViewState extends State<MemoryItemView> {
  MemoryItemDetail? _detail;
  bool _loading = true;
  bool _gone = false;
  bool _failed = false;

  /// 临时揭示状态：字段 → 原文与自动重新遮罩计时器。离开页面即
  /// 全部作废，绝不持久化。
  final Map<String, _RevealState> _reveals = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final reveal in _reveals.values) {
      reveal.timer.cancel();
    }
    _reveals.clear();
    super.dispose();
  }

  Future<void> _load() async {
    final viewModel = context.read<MemoryCenterViewModel>();
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final detail = await viewModel.itemDetail(widget.itemId);
      if (!mounted) {
        return;
      }
      setState(() {
        _detail = detail;
        _gone = detail == null;
        _loading = false;
      });
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  /// 明确的临时揭示动作：只取一次原文，超时自动重新遮罩；原文
  /// 只存在于本页面的临时状态里。执行与存活防护统一走共享动作
  /// 执行器，揭示成功的落点回本页的临时揭示状态。
  Future<void> _reveal(String field) => runMemoryAction(
    context,
    action: MemoryAction.reveal,
    itemId: widget.itemId,
    revealField: field,
    onRevealed: (text) {
      if (!mounted) {
        return;
      }
      setState(() {
        _reveals.remove(field)?.timer.cancel();
        _reveals[field] = _RevealState(
          text,
          Timer(revealTimeout, () {
            if (!mounted) {
              return;
            }
            setState(() => _reveals.remove(field));
          }),
        );
      });
    },
  );

  @override
  Widget build(BuildContext context) {
    final acting = context.watch<MemoryCenterViewModel>().acting;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: QiyuLayout.pageReadingMaxWidth,
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                  child: Row(
                    children: [
                      QiyuFocusRingScope(
                        borderRadius: QiyuRadii.circleBorder,
                        child: IconButton(
                          key: const Key('memory-item-back'),
                          onPressed: () => backToPrevious(context),
                          tooltip: '返回记忆',
                          icon: const Icon(QiyuIcons.arrow_back),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '记忆详情',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      if (acting) ...[
                        const Spacer(),
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            key: Key('memory-item-acting'),
                            strokeWidth: 2,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text('整理中'),
                      ],
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: _body(acting: acting)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body({required bool acting}) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed) {
      return QiyuErrorRetryState(
        message: '记忆中心暂时不可用，请稍后重试。',
        messageKey: const Key('memory-item-error'),
        retryKey: const Key('memory-item-retry'),
        onRetry: () => unawaited(_load()),
      );
    }
    if (_gone) {
      return const Center(
        child: Text('这条记忆不存在或已经变化，请返回后刷新。', key: Key('memory-item-gone')),
      );
    }
    final detail = _detail!;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: switch (detail) {
        EpisodeEntryDetail() => _episodeEntryBody(detail, acting: acting),
        PersonaRootDetail() => _personaRootBody(detail),
        PersonaMiddleDetail() => _personaMiddleBody(detail),
        MemoryDayDetail() => _dayBody(detail),
      },
    );
  }

  /// 遮罩内容的揭示展示：已揭示时显示原文与倒计时提示，未揭示时
  /// 显示占位与「临时查看」入口。
  Widget _maskedOrRevealed(String field) {
    final reveal = _reveals[field];
    if (reveal != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            reveal.text,
            key: Key('memory-revealed-$field'),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          const _StatusChip(
            key: Key('memory-reveal-countdown'),
            label: '仅本次展示，稍后自动重新遮罩',
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_maskedPlaceholder, style: Theme.of(context).textTheme.bodyMedium),
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            key: Key('memory-reveal-$field'),
            onPressed: _revealEnabled()
                ? () => unawaited(_reveal(field))
                : null,
            child: const Text('临时查看'),
          ),
        ),
      ],
    );
  }

  /// 字段旁揭示入口的可点性，与列表侧揭示按钮取同一份计划：在场性
  /// 由本方法只在遮罩分支被调用给出（计划里 reveal 的在场条件就是
  /// 遮罩，快照如实带这一态）；控制状态不参与揭示的可用性，条目被
  /// 暂停或禁提时入口照给，与列表一致。busy 期间与列表按钮同步灰掉
  /// ——同一计划的 busy 规则，一处可点另一处灰掉的矛盾在这里杜绝。
  bool _revealEnabled() {
    final plan = MemoryActionPlan(
      state: const MemoryItemActionState(control: null, masked: true),
      busy: context.watch<MemoryCenterViewModel>().acting,
    );
    return plan.enabled(MemoryAction.reveal);
  }

  List<Widget> _episodeEntryBody(
    EpisodeEntryDetail detail, {
    required bool acting,
  }) {
    return [
      Row(
        children: [
          _StatusChip(label: detail.kindLabel),
          const SizedBox(width: 8),
          if (detail.userEdited) ...[
            const _StatusChip(
              key: Key('memory-entry-user-edited'),
              label: '由你修正',
            ),
            const SizedBox(width: 8),
          ],
          if (detail.control case final control?)
            _StatusChip(label: control.label),
        ],
      ),
      const SizedBox(height: 12),
      if (detail.masked)
        _maskedOrRevealed('content')
      else
        Text(
          detail.content ?? '',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      const SizedBox(height: 8),
      Text(
        '${formatDayHeader(detail.date)} · ${formatClock(detail.at)}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      if (detail.evidenceMasked || detail.evidence != null) ...[
        const SizedBox(height: 16),
        Text('当时的摘录', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        if (detail.evidenceMasked)
          _maskedOrRevealed('evidence')
        else
          Text(
            detail.evidence ?? '',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
      ],
      if (detail.daySummary case final summary?) ...[
        const SizedBox(height: 16),
        Text('当天小结', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(summary, style: Theme.of(context).textTheme.bodyMedium),
      ],
      if (!detail.finalized) ...[
        const SizedBox(height: 16),
        const _StatusChip(label: '整理中'),
      ],
      const SizedBox(height: 16),
      QiyuFocusRingScope(
        borderRadius: QiyuRadii.circleBorder,
        child: TextButton(
          key: const Key('memory-item-day'),
          onPressed: () => openInFront(context, '/memory/item/${detail.dayId}'),
          child: const Text('查看这一天的记录'),
        ),
      ),
      if (detail.sessionId case final sessionId?)
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            key: const Key('memory-item-session'),
            onPressed: () => openInFront(context, '/history/$sessionId'),
            child: const Text('查看当时的对话'),
          ),
        ),
      const SizedBox(height: 8),
      _DetailActionRow(itemId: widget.itemId, detail: detail, acting: acting),
    ];
  }

  List<Widget> _personaRootBody(PersonaRootDetail detail) {
    return [
      _StatusChip(label: detail.branchTitle),
      const SizedBox(height: 12),
      if (detail.masked)
        _maskedOrRevealed('claim')
      else
        Text(
          detail.claim ?? '',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      if (detail.control case final control?) ...[
        const SizedBox(height: 8),
        _StatusChip(label: control.label),
      ],
      const SizedBox(height: 16),
      Text('支持它的理解', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 4),
      if (detail.middles.isEmpty)
        const Text('暂时没有记录支持它的依据。')
      else
        for (final middle in detail.middles)
          _MiddleTile(
            key: Key('memory-root-middle-${middle.id}'),
            middle: middle,
          ),
    ];
  }

  List<Widget> _personaMiddleBody(PersonaMiddleDetail detail) {
    return [
      Row(
        children: [
          _StatusChip(label: detail.branchTitle),
          const SizedBox(width: 8),
          _StatusChip(label: detail.type),
          if (detail.control case final control?) ...[
            const SizedBox(width: 8),
            _StatusChip(label: control.label),
          ],
        ],
      ),
      const SizedBox(height: 12),
      if (detail.masked)
        _maskedOrRevealed('claim')
      else
        Text(
          detail.claim ?? '',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      const SizedBox(height: 8),
      Text(
        '形成于 ${detail.formedOn} · 最近复核 ${detail.reviewedOn}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      if (detail.rootClaim case final rootClaim?) ...[
        const SizedBox(height: 8),
        Text('所属结论：$rootClaim', style: Theme.of(context).textTheme.bodySmall),
      ],
      const SizedBox(height: 16),
      Text('证据', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 4),
      if (detail.leaves.isEmpty)
        const Text('暂时没有记录在案的证据。')
      else
        for (final leaf in detail.leaves)
          _LeafTile(
            key: Key('memory-leaf-${detail.branch}-${leaf.date}-${leaf.dayId}'),
            leaf: leaf,
          ),
    ];
  }

  List<Widget> _dayBody(MemoryDayDetail detail) {
    return [
      Row(
        children: [
          Text(
            formatDayHeader(detail.date),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (!detail.finalized) ...[
            const SizedBox(width: 8),
            const _StatusChip(label: '整理中'),
          ],
        ],
      ),
      // 遮罩时 summary 为 null：仍要给出临时查看入口。
      if (detail.summary != null || detail.summaryMasked)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: detail.summaryMasked
              ? _maskedOrRevealed('summary')
              : Text(
                  detail.summary ?? '',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
        ),
      const SizedBox(height: 12),
      if (detail.entries.isEmpty)
        const Text('这一天没有可展示的记录。')
      else
        for (final entry in detail.entries)
          _EntryTile(key: Key('memory-day-entry-${entry.id}'), entry: entry),
    ];
  }
}

/// 详情页的动作行：在场与可点一律取共享动作计划，与列表按钮同键、
/// 同标签、同确认流程、同执行器；呈现差异只有图标按钮换文字按钮。
/// 按钮键与列表一致（`memory-action-<id>-<动作>`）：同一记忆状态下
/// 两处的可用性由同一份 [MemoryActionPlan] 给出，一致性测试按键逐颗
/// 对照两处。
///
/// 揭示不进动作行：详情页的敏感字段（正文、摘录、主张、小结）各自
/// 在字段旁内联「临时查看」，走同一执行器。
class _DetailActionRow extends StatelessWidget {
  const _DetailActionRow({
    required this.itemId,
    required this.detail,
    required this.acting,
  });

  /// 条目 id 来自路由：EpisodeEntryDetail 本身不带 id，与列表卡片
  /// 共用同一键位全靠它。
  final String itemId;
  final EpisodeEntryDetail detail;
  final bool acting;

  @override
  Widget build(BuildContext context) {
    final plan = MemoryActionPlan(
      state: MemoryItemActionState(
        control: detail.control,
        masked: detail.masked,
        editable: true,
      ),
      busy: acting,
    );
    return Wrap(
      spacing: QiyuSpacing.xs,
      children: [
        for (final action in plan.offeredActions)
          if (action != MemoryAction.reveal)
            QiyuFocusRingScope(
              borderRadius: QiyuRadii.circleBorder,
              child: TextButton(
                key: Key('memory-action-$itemId-${action.name}'),
                onPressed: plan.enabled(action)
                    ? () => unawaited(
                        runMemoryAction(
                          context,
                          action: action,
                          itemId: itemId,
                          currentText: detail.content ?? '',
                        ),
                      )
                    : null,
                child: Text(action.label),
              ),
            ),
      ],
    );
  }
}

/// 记忆卡片的统一外观：底部留白，圆角与 `line` 发丝描边由主题层
/// `cardTheme.shape`（[qiyuCardShape]，design-system §8 卡片档）给出，页面不再
/// 覆盖 shape——shape 是整体覆盖的，只写圆角会把发丝边一起吃掉。
class _MemoryCard extends StatelessWidget {
  const _MemoryCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return QiyuFocusRingScope(
      borderRadius: QiyuRadii.cardBorder,
      child: Card(margin: const EdgeInsets.only(bottom: 8), child: child),
    );
  }
}

/// 可点记忆卡片的统一骨架：[_MemoryCard] 外观 + 卡片圆角 `InkWell` +
/// 16/12 内衬 + 纵向左对齐内容列。条目、画像根与中间理解三处列表卡
/// 共用；onTap 目标与内容键全部由调用方给定，提取只收骨架不动语义。
class _TappableMemoryCard extends StatelessWidget {
  const _TappableMemoryCard({required this.onTap, required this.children});

  final VoidCallback onTap;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return _MemoryCard(
      child: InkWell(
        borderRadius: QiyuRadii.cardBorder,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// 条目头部的一行：左侧信息簇，右侧「时间/说明 + 常驻操作」簇。
///
/// 不用 Row：右侧操作簇的宽度由按钮颗数定死、自身不收缩，而 Row 的非 flex 子项
/// 是先按可用全宽量好的——窗口足够窄、字号足够大时两者相加会超过这一行，违反
/// ticket 24 立下的「小窗 / 字号放大绝不产生 RenderFlex 溢出」不变量。Wrap 是同
/// 时做得到「贴右」与「换行」的容器：外层先用 [SizedBox] 撑满整行宽，
/// `spaceBetween` 才有自由空间可分配。两侧各有一条用例兜着，都在
/// `test/memory_view_test.dart`：极窄那一头锁 300 逻辑像素叠 1.4 倍字号下这一行
/// 不产生溢出、条目时间与四颗常驻按钮一颗都不少（溢出属布局异常，用例直接判
/// 红）；宽屏那一头锁信息在左、时间与常驻操作同处一行且贴到内容区右边界。信息
/// 一颗都不隐藏，换的只有排法。与改造前的 Row 有一处确有意的不同：簇之间新留了
/// [QiyuSpacing.xs] 的呼吸位，操作簇内部颗与颗之间不再另加容器间距。
class _MemoryHeaderLine extends StatelessWidget {
  const _MemoryHeaderLine({required this.leading, required this.trailing});

  /// 左侧信息簇：状态芯片、正文或证据行。
  final Widget leading;

  /// 右侧簇，按传入顺序排入（时间戳 / 说明文字，最后是 [MemoryActionButtons]）。
  /// 传空表是真实语义：状态包行只读，右侧没有任何东西（T24 定稿），此时整行
  /// 只剩左侧信息簇。
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        spacing: QiyuSpacing.xs,
        runSpacing: QiyuSpacing.xs,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          leading,
          if (trailing.isNotEmpty)
            Wrap(
              spacing: QiyuSpacing.xs,
              runSpacing: QiyuSpacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: trailing,
            ),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({super.key, required this.entry});

  final MemoryEntryCard entry;

  @override
  Widget build(BuildContext context) {
    return _TappableMemoryCard(
      onTap: () => openInFront(context, '/memory/item/${entry.id}'),
      children: [
        _MemoryHeaderLine(
          // 状态芯片可换行：窄窗口下不撑破布局（ticket 24）。
          leading: Wrap(
            spacing: QiyuSpacing.xs,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _StatusChip(label: entry.kindLabel),
              if (entry.userEdited) const _StatusChip(label: '由你修正'),
              if (entry.control case final control?)
                _StatusChip(
                  key: Key('memory-entry-control-${entry.id}'),
                  label: control.label,
                ),
              if (entry.hasEvidence) const _StatusChip(label: '有摘录'),
            ],
          ),
          trailing: [
            Text(
              formatClock(entry.at),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            MemoryActionButtons(
              key: Key('memory-actions-${entry.id}'),
              itemId: entry.id,
              control: entry.control,
              masked: entry.masked,
              editable: true,
              currentText: entry.content,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(_visibleOr(entry.masked, entry.content)),
      ],
    );
  }
}

class _LongTermTile extends StatelessWidget {
  const _LongTermTile({super.key, required this.item, this.statePack = false});

  final MemoryLongTermItem item;

  /// 状态包各行（相处方式/试探/近期变化）不是控制对象（T24 定稿）：
  /// 只读展示，不提供编辑、控制或删除入口。
  final bool statePack;

  @override
  Widget build(BuildContext context) {
    return _MemoryCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: _MemoryHeaderLine(
          leading: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_visibleOr(item.masked, item.content)),
          ),
          trailing: [
            if (item.control case final control?)
              _StatusChip(label: control.label),
            if (!statePack)
              MemoryActionButtons(
                key: Key('memory-actions-${item.id}'),
                itemId: item.id,
                control: item.control,
                masked: item.masked,
                editable: true,
                currentText: item.content,
              ),
          ],
        ),
      ),
    );
  }
}

class _RootTile extends StatelessWidget {
  const _RootTile({super.key, required this.root});

  final MemoryPersonaRootCard root;

  @override
  Widget build(BuildContext context) {
    return _TappableMemoryCard(
      onTap: () => openInFront(context, '/memory/item/${root.id}'),
      children: [
        Text(_visibleOr(root.masked, root.claim)),
        const SizedBox(height: 6),
        _MemoryHeaderLine(
          leading: Wrap(
            spacing: QiyuSpacing.xs,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (root.control case final control?)
                _StatusChip(label: control.label),
              Text(
                _evidenceSpanText(root),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          trailing: [
            MemoryActionButtons(
              key: Key('memory-actions-${root.id}'),
              itemId: root.id,
              control: root.control,
              masked: root.masked,
            ),
          ],
        ),
      ],
    );
  }

  String _evidenceSpanText(MemoryPersonaRootCard root) {
    final count = '${root.leafCount} 条证据';
    final earliest = root.earliestEvidence;
    final latest = root.latestEvidence;
    if (earliest == null || latest == null) {
      return count;
    }
    return '$count · $earliest → $latest';
  }
}

class _MiddleTile extends StatelessWidget {
  const _MiddleTile({super.key, required this.middle});

  final MemoryPersonaMiddleCard middle;

  @override
  Widget build(BuildContext context) {
    return _TappableMemoryCard(
      onTap: () => openInFront(context, '/memory/item/${middle.id}'),
      children: [
        Text(_visibleOr(middle.masked, middle.claim)),
        const SizedBox(height: 6),
        _MemoryHeaderLine(
          leading: Wrap(
            spacing: QiyuSpacing.xs,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _StatusChip(label: middle.type),
              if (middle.control case final control?)
                _StatusChip(label: control.label),
              if (middle.hasConflict) const _StatusChip(label: '有冲突证据'),
            ],
          ),
          trailing: [
            Text(
              '形成 ${middle.formedOn} · 复核 ${middle.reviewedOn}',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.end,
            ),
            MemoryActionButtons(
              key: Key('memory-actions-${middle.id}'),
              itemId: middle.id,
              control: middle.control,
              masked: middle.masked,
            ),
          ],
        ),
      ],
    );
  }
}

class _LeafTile extends StatelessWidget {
  const _LeafTile({super.key, required this.leaf});

  final MemoryPersonaLeafCard leaf;

  @override
  Widget build(BuildContext context) {
    return _MemoryCard(
      child: InkWell(
        borderRadius: QiyuRadii.cardBorder,
        onTap: () => openInFront(context, '/memory/item/${leaf.dayId}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: QiyuSpacing.xs,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _StatusChip(label: leaf.nature),
                        if (leaf.relation == 'conflict')
                          const _StatusChip(label: '冲突'),
                        if (leaf.control case final control?)
                          _StatusChip(label: control.label),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(leaf.date, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
              const SizedBox(height: 6),
              Text(_visibleOr(leaf.masked, leaf.summary)),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.fromBorderSide(highContrastSide(context)),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

/// 遮罩展示的统一出口：敏感内容只呈现占位说明，原文不出现在界面上。
String _visibleOr(bool masked, String? content) =>
    masked ? _maskedPlaceholder : (content ?? '');
