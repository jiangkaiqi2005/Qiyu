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
import 'memory_client.dart';
import 'memory_view_model.dart';

const _maskedPlaceholder = '这条内容涉及私密信息，暂不直接展示。';

/// 临时揭示的自动重新遮罩时间：只作本次展示，离开页面立即失效。
const _revealTimeout = Duration(seconds: 20);

/// 四区记忆中心（ticket 19 读取 / ticket 20 控制）：最近发生、长期
/// 印象、关于你、我们的关系。导航只用用户语言；条目操作按钮常驻，
/// 冻结/解除、修正与敏感揭示直接执行，禁提与删除先经明确确认，
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
                      20,
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
                  // design-system §4 定案选型：时钟 / 山形 / 单人 / 双人。
                  // 选中态取色（近白文字与图标 + 淡白下划线）全部由主题层
                  // `tabBarTheme` 供给，页面不自写颜色。
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 12),
            QiyuFocusRingScope(
              borderRadius: QiyuRadii.circleBorder,
              child: TextButton(
                key: const Key('retry-memory'),
                onPressed: () => unawaited(viewModel.refresh()),
                child: const Text('重试'),
              ),
            ),
          ],
        ),
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
                  '整理于 ${twoDigits(organizedAt.toLocal().hour)}:'
                  '${twoDigits(organizedAt.toLocal().minute)}',
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
    if (section.isEmpty) {
      return const _EmptyState(
        key: Key('memory-empty-persona'),
        text: '还没有形成关于你的画像。\n画像来自一次次聊天里的积累，慢慢来。',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
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
  /// 只存在于本页面的临时状态里。
  Future<void> _reveal(String field) async {
    final viewModel = context.read<MemoryCenterViewModel>();
    final messenger = ScaffoldMessenger.of(context);
    final result = await viewModel.reveal(widget.itemId, field: field);
    if (!mounted) {
      return;
    }
    if (result.status != MemoryActionStatus.success || result.text == null) {
      messenger.showSnackBar(SnackBar(content: Text(result.message)));
      return;
    }
    setState(() {
      _reveals.remove(field)?.timer.cancel();
      _reveals[field] = _RevealState(
        result.text!,
        Timer(_revealTimeout, () {
          if (!mounted) {
            return;
          }
          setState(() => _reveals.remove(field));
        }),
      );
    });
  }

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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('记忆中心暂时不可用，请稍后重试。', key: Key('memory-item-error')),
            const SizedBox(height: 12),
            QiyuFocusRingScope(
              borderRadius: QiyuRadii.circleBorder,
              child: TextButton(
                key: const Key('memory-item-retry'),
                onPressed: () => unawaited(_load()),
                child: const Text('重试'),
              ),
            ),
          ],
        ),
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
  Widget _maskedOrRevealed(String field, {Key? textKey}) {
    final reveal = _reveals[field];
    if (reveal != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            reveal.text,
            key: textKey ?? Key('memory-revealed-$field'),
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
            onPressed: () => unawaited(_reveal(field)),
            child: const Text('临时查看'),
          ),
        ),
      ],
    );
  }

  List<Widget> _episodeEntryBody(
    EpisodeEntryDetail detail, {
    required bool acting,
  }) {
    final time = detail.at.toLocal();
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
        '${formatDayHeader(detail.date)} · ${twoDigits(time.hour)}:'
        '${twoDigits(time.minute)}',
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
      Wrap(
        spacing: 8,
        children: [
          QiyuFocusRingScope(
            borderRadius: QiyuRadii.circleBorder,
            child: TextButton(
              key: const Key('memory-item-edit'),
              onPressed: detail.masked || acting
                  ? null
                  : () => unawaited(
                      _editFlow(
                        context,
                        id: widget.itemId,
                        current: detail.content ?? '',
                      ),
                    ),
              child: const Text('修正'),
            ),
          ),
          QiyuFocusRingScope(
            borderRadius: QiyuRadii.circleBorder,
            child: TextButton(
              key: const Key('memory-item-freeze'),
              onPressed: acting
                  ? null
                  : () => unawaited(
                      detail.control == MemoryControlStatus.frozen
                          ? _runControl(
                              (viewModel) => viewModel.unfreeze(widget.itemId),
                            )
                          : _runControl(
                              (viewModel) => viewModel.freeze(widget.itemId),
                            ),
                    ),
              child: Text(
                detail.control == MemoryControlStatus.frozen ? '恢复使用' : '暂停使用',
              ),
            ),
          ),
          QiyuFocusRingScope(
            borderRadius: QiyuRadii.circleBorder,
            child: TextButton(
              key: const Key('memory-item-ban'),
              onPressed: acting
                  ? null
                  : () => unawaited(
                      detail.control == MemoryControlStatus.banned
                          ? _runControl(
                              (viewModel) => viewModel.unban(widget.itemId),
                            )
                          : _banFlow(context, widget.itemId),
                    ),
              child: Text(
                detail.control == MemoryControlStatus.banned ? '解除禁提' : '不再提起',
              ),
            ),
          ),
          QiyuFocusRingScope(
            borderRadius: QiyuRadii.circleBorder,
            child: TextButton(
              key: const Key('memory-item-delete'),
              onPressed: acting
                  ? null
                  : () => unawaited(_deleteFlow(context, widget.itemId)),
              child: const Text('删除'),
            ),
          ),
        ],
      ),
    ];
  }

  /// 详情页控制动作的统一出口（冻结/解除/禁提解除）：调用方显式
  /// 指定要执行的动作；禁提确认与删除走各自的确认流程。
  Future<void> _runControl(
    Future<MemoryActionResult> Function(MemoryCenterViewModel) action,
  ) async {
    final viewModel = context.read<MemoryCenterViewModel>();
    final messenger = ScaffoldMessenger.of(context);
    final result = await action(viewModel);
    messenger.showSnackBar(_resultSnackBar(result));
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

/// 记忆卡片的统一外观：底部留白、18px 圆角（[QiyuRadii.cardBorder]，design-system
/// §8 卡片与列表项档；12px 及以下的方正小圆角已验证偏 AI 感，除小元素外不再使用）
/// 与高对比模式下的可见描边。
class _MemoryCard extends StatelessWidget {
  const _MemoryCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return QiyuFocusRingScope(
      borderRadius: QiyuRadii.cardBorder,
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        shape: RoundedRectangleBorder(
          borderRadius: QiyuRadii.cardBorder,
          side: highContrastSide(context),
        ),
        child: child,
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({super.key, required this.entry});

  final MemoryEntryCard entry;

  @override
  Widget build(BuildContext context) {
    final time = entry.at.toLocal();
    return _MemoryCard(
      child: InkWell(
        borderRadius: QiyuRadii.cardBorder,
        onTap: () => openInFront(context, '/memory/item/${entry.id}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // 状态芯片可换行：窄窗口下不撑破布局（ticket 24）。
                  Expanded(
                    child: Wrap(
                      spacing: 8,
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
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${twoDigits(time.hour)}:${twoDigits(time.minute)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  _MemoryActionButtons(
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
          ),
        ),
      ),
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
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_visibleOr(item.masked, item.content)),
              ),
            ),
            if (item.control case final control?) ...[
              const SizedBox(width: 8),
              _StatusChip(label: control.label),
            ],
            if (!statePack)
              _MemoryActionButtons(
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
    return _MemoryCard(
      child: InkWell(
        borderRadius: QiyuRadii.cardBorder,
        onTap: () => openInFront(context, '/memory/item/${root.id}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_visibleOr(root.masked, root.claim)),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (root.control case final control?) ...[
                    _StatusChip(label: control.label),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      _evidenceSpanText(root),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  _MemoryActionButtons(
                    key: Key('memory-actions-${root.id}'),
                    itemId: root.id,
                    control: root.control,
                    masked: root.masked,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
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
    return _MemoryCard(
      child: InkWell(
        borderRadius: QiyuRadii.cardBorder,
        onTap: () => openInFront(context, '/memory/item/${middle.id}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_visibleOr(middle.masked, middle.claim)),
              const SizedBox(height: 6),
              Row(
                children: [
                  Flexible(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _StatusChip(label: middle.type),
                        if (middle.control case final control?)
                          _StatusChip(label: control.label),
                        if (middle.hasConflict)
                          const _StatusChip(label: '有冲突证据'),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '形成 ${middle.formedOn} · 复核 ${middle.reviewedOn}',
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.end,
                    ),
                  ),
                  _MemoryActionButtons(
                    key: Key('memory-actions-${middle.id}'),
                    itemId: middle.id,
                    control: middle.control,
                    masked: middle.masked,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
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
                      spacing: 8,
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

/// 条目可执行的动作：一个值对应一颗常驻按钮。
///
/// [label] 是按钮的 tooltip 文案，按钮键的尾段取枚举名（`freeze`、`unban`…）；
/// 动作与图形的对应关系在 [_MemoryActionButtons._actions]。
enum _MemoryActionChoice {
  edit('修正'),
  reveal('临时查看'),
  freeze('暂停使用'),
  unfreeze('恢复使用'),
  ban('不再提起'),
  unban('解除禁提'),
  delete('删除');

  const _MemoryActionChoice(this.label);

  final String label;
}

/// 条目操作按钮组（ticket 20）：把 [_MemoryActionChoice] 里的动作**常驻**摆在
/// 条目上，不再收进「⋯」菜单——记忆控制权是产品的信任承诺，必须随时看得见
/// （design-system §8 补充约定、Spec Implementation Decision 14、决策日志第二轮 4）。
///
/// 呈现是次要色图标按钮 + 悬停提亮，取值在主题层 [qiyuQuietIconButtonStyle]。
/// 改的只有入口形态：动作语义、出现条件与确认流程与收在菜单里时逐项一致。
class _MemoryActionButtons extends StatelessWidget {
  const _MemoryActionButtons({
    super.key,
    required this.itemId,
    required this.control,
    required this.masked,
    this.editable = false,
    this.currentText,
  });

  final String itemId;
  final MemoryControlStatus? control;
  final bool masked;
  final bool editable;
  final String? currentText;

  /// 这一条目当前该出现哪些操作：与改造前菜单逐项出现的条件完全一致。
  /// 图形取 design-system §4 定案的五枚（铅笔 / 雪花 / 禁止圈 / 垃圾桶 /
  /// 眼睛）；恢复使用与解除禁提沿用同一图形，两态靠条目上的状态芯片与
  /// tooltip 上的动作名区分。
  List<({IconData icon, _MemoryActionChoice choice})> _actions() {
    final actions = <({IconData icon, _MemoryActionChoice choice})>[];
    if (editable && !masked) {
      actions.add((icon: QiyuIcons.edit, choice: _MemoryActionChoice.edit));
    }
    if (masked) {
      actions.add((
        icon: QiyuIcons.visibility,
        choice: _MemoryActionChoice.reveal,
      ));
    }
    switch (control) {
      case MemoryControlStatus.frozen:
        actions.add((
          icon: QiyuIcons.ac_unit,
          choice: _MemoryActionChoice.unfreeze,
        ));
      case MemoryControlStatus.banned:
        actions.add((
          icon: QiyuIcons.block,
          choice: _MemoryActionChoice.unban,
        ));
      case null:
        actions.addAll([
          (icon: QiyuIcons.ac_unit, choice: _MemoryActionChoice.freeze),
          (icon: QiyuIcons.block, choice: _MemoryActionChoice.ban),
        ]);
    }
    actions.add((icon: QiyuIcons.delete, choice: _MemoryActionChoice.delete));
    return actions;
  }

  Future<void> _selected(
    BuildContext context,
    _MemoryActionChoice choice,
  ) async {
    final viewModel = context.read<MemoryCenterViewModel>();
    final messenger = ScaffoldMessenger.of(context);
    switch (choice) {
      case _MemoryActionChoice.edit:
        await _editFlow(context, id: itemId, current: currentText ?? '');
      case _MemoryActionChoice.reveal:
        await _revealTileFlow(context, itemId);
      case _MemoryActionChoice.freeze:
        messenger.showSnackBar(_resultSnackBar(await viewModel.freeze(itemId)));
      case _MemoryActionChoice.unfreeze:
        messenger.showSnackBar(
          _resultSnackBar(await viewModel.unfreeze(itemId)),
        );
      case _MemoryActionChoice.ban:
        await _banFlow(context, itemId);
      case _MemoryActionChoice.unban:
        messenger.showSnackBar(_resultSnackBar(await viewModel.unban(itemId)));
      case _MemoryActionChoice.delete:
        await _deleteFlow(context, itemId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final acting = context.watch<MemoryCenterViewModel>().acting;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final action in _actions())
          QiyuFocusRingScope(
            borderRadius: QiyuRadii.circleBorder,
            child: IconButton(
              key: Key('memory-action-$itemId-${action.choice.name}'),
              onPressed: acting
                  ? null
                  : () => unawaited(_selected(context, action.choice)),
              tooltip: action.choice.label,
              style: qiyuQuietIconButtonStyle(),
              icon: Icon(action.icon),
            ),
          ),
      ],
    );
  }
}

// ---------- 记忆动作流程（ticket 20） ----------

/// 修正流程：对话框预填现有文本，保存按用户声明落盘。遮罩条目
/// 不提供修正入口（不揭示原文就不能改）。
Future<void> _editFlow(
  BuildContext context, {
  required String id,
  required String current,
}) async {
  final viewModel = context.read<MemoryCenterViewModel>();
  final messenger = ScaffoldMessenger.of(context);
  final updated = await showDialog<String>(
    context: context,
    builder: (dialogContext) => _EditDialog(initial: current),
  );
  if (updated == null || updated.trim().isEmpty) {
    return;
  }
  final result = await viewModel.edit(id, updated.trim());
  messenger.showSnackBar(_resultSnackBar(result));
}

/// 列表遮罩条目的临时揭示：原文只出现在一次性对话框里，关闭即
/// 重新遮罩，超时自动关闭；不落任何状态。
Future<void> _revealTileFlow(BuildContext context, String id) async {
  final viewModel = context.read<MemoryCenterViewModel>();
  final messenger = ScaffoldMessenger.of(context);
  final result = await viewModel.reveal(id);
  if (!context.mounted) {
    return;
  }
  if (result.status != MemoryActionStatus.success || result.text == null) {
    messenger.showSnackBar(_resultSnackBar(result));
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => _RevealDialog(text: result.text!),
  );
}

/// 禁提确认流程（T25 定稿：禁提需要确认，冻结直接生效）。
Future<void> _banFlow(BuildContext context, String id) async {
  final viewModel = context.read<MemoryCenterViewModel>();
  final messenger = ScaffoldMessenger.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('不再提起这条记忆？'),
      content: const Text('确认后，栖语不会再主动提起它，聊天和整理都会避开这条内容。以后可以随时解除。'),
      actions: [
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('先不用'),
          ),
        ),
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            key: const Key('memory-ban-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('不再提起'),
          ),
        ),
      ],
    ),
  );
  if (confirmed != true) {
    return;
  }
  final result = await viewModel.ban(id);
  messenger.showSnackBar(_resultSnackBar(result));
}

/// 删除流程：先取准确影响范围，展示后确认执行；影响范围取不到
/// （条目已变化）时如实告知，不执行删除。
Future<void> _deleteFlow(BuildContext context, String id) async {
  final viewModel = context.read<MemoryCenterViewModel>();
  final messenger = ScaffoldMessenger.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) =>
        _DeletePreviewDialog(impact: viewModel.deletePreview(id)),
  );
  if (confirmed != true) {
    return;
  }
  final result = await viewModel.delete(id);
  messenger.showSnackBar(_resultSnackBar(result));
}

SnackBar _resultSnackBar(MemoryActionResult result) {
  // partial 底色加深到与白字对比 ≥4.5:1（AA），failed 维持原色（ticket 24）。
  final color = switch (result.status) {
    MemoryActionStatus.success => null,
    MemoryActionStatus.partial => const Color(0xFF9C5C13),
    MemoryActionStatus.failed => const Color(0xFFB3261E),
  };
  return SnackBar(
    key: const Key('memory-action-result'),
    // 自定义深色底必须显式配白字，保住对比度（ticket 24）。
    content: Text(
      result.message,
      style: color == null ? null : const TextStyle(color: Color(0xFFFFFFFF)),
    ),
    backgroundColor: color,
  );
}

class _EditDialog extends StatefulWidget {
  const _EditDialog({required this.initial});

  final String initial;

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修正这条记忆'),
      content: TextField(
        key: const Key('memory-edit-field'),
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        maxLength: 120,
        decoration: const InputDecoration(hintText: '按你的说法写'),
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
            key: const Key('memory-edit-save'),
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: const Text('保存'),
          ),
        ),
      ],
    );
  }
}

/// 临时揭示对话框：原文只作本次展示，超时自动关闭；关闭即重新
/// 遮罩。
class _RevealDialog extends StatefulWidget {
  const _RevealDialog({required this.text});

  final String text;

  @override
  State<_RevealDialog> createState() => _RevealDialogState();
}

class _RevealDialogState extends State<_RevealDialog> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_revealTimeout, () {
      if (mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('memory-reveal-dialog'),
      title: const Text('仅本次展示'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 不提供选择复制：敏感原文只作本次呈现，不进剪贴板。
          Text(widget.text),
          const SizedBox(height: 8),
          Text('关闭或稍后会自动重新遮罩。', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      actions: [
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ),
      ],
    );
  }
}

/// 删除确认对话框：先呈现只读的影响范围预览，确认后返回 true。
class _DeletePreviewDialog extends StatelessWidget {
  const _DeletePreviewDialog({required this.impact});

  final Future<MemoryDeleteImpact?> impact;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('删除这条记忆？'),
      content: FutureBuilder<MemoryDeleteImpact?>(
        future: impact,
        builder: (context, snapshot) {
          if (!snapshot.hasData && !snapshot.hasError) {
            return const SizedBox(
              height: 80,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 8),
                    Text('正在核对影响范围…'),
                  ],
                ),
              ),
            );
          }
          final preview = snapshot.data;
          if (preview == null) {
            return const Text('这条记忆不存在或已经变化，请返回后刷新。');
          }
          return ConstrainedBox(
            // 上限而非定宽：窄窗口下随对话框收缩，不溢出（ticket 24）。
            // 内层用 Column 而非视口类列表（对话框要测量内容固有尺寸，
            // ListView 无法参与），外裹 SingleChildScrollView 兜住
            // 字号放大或小窗下的超高内容，与记忆控制总览对话框同模式。
            constraints: const BoxConstraints(
              maxWidth: QiyuLayout.evidenceDialogMaxWidth,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in preview.lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(line),
                    ),
                ],
              ),
            ),
          );
        },
      ),
      actions: [
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('先不用'),
          ),
        ),
        FutureBuilder<MemoryDeleteImpact?>(
          future: impact,
          builder: (context, snapshot) {
            final ready = snapshot.hasData && snapshot.data != null;
            return QiyuFocusRingScope(
              borderRadius: QiyuRadii.circleBorder,
              child: TextButton(
                key: const Key('memory-delete-confirm'),
                onPressed: ready ? () => Navigator.of(context).pop(true) : null,
                child: const Text('确认删除'),
              ),
            );
          },
        ),
      ],
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
