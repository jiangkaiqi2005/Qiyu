import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'memory_client.dart';
import 'memory_view_model.dart';

const _maskedPlaceholder = '这条内容涉及私密信息，暂不直接展示。';

/// 四区只读记忆中心（ticket 19）：最近发生、长期印象、关于你、
/// 我们的关系。导航只用用户语言；页面只读取，不提供任何编辑、
/// 控制或揭示入口。
class MemoryView extends StatelessWidget {
  const MemoryView({super.key});

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<MemoryCenterViewModel>();
    return Scaffold(
      body: SafeArea(
        child: DefaultTabController(
          length: 4,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
                    child: Row(
                      children: [
                        IconButton(
                          key: const Key('memory-back'),
                          onPressed: () => context.go('/'),
                          tooltip: '返回首页',
                          icon: const Icon(Icons.arrow_back),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '记忆',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const Spacer(),
                        IconButton(
                          key: const Key('refresh-memory'),
                          onPressed: viewModel.loading
                              ? null
                              : () => unawaited(viewModel.refresh()),
                          tooltip: '刷新记忆',
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                  ),
                  const TabBar(
                    isScrollable: true,
                    tabs: [
                      Tab(
                        key: Key('memory-tab-recent'),
                        text: '最近发生',
                      ),
                      Tab(
                        key: Key('memory-tab-longterm'),
                        text: '长期印象',
                      ),
                      Tab(key: Key('memory-tab-persona'), text: '关于你'),
                      Tab(
                        key: Key('memory-tab-relationship'),
                        text: '我们的关系',
                      ),
                    ],
                  ),
                  const Divider(height: 1),
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
            TextButton(
              key: const Key('retry-memory'),
              onPressed: () => unawaited(viewModel.refresh()),
              child: const Text('重试'),
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
                _formatDayHeader(day.date),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (!day.finalized) ...[
                const SizedBox(width: 8),
                const _StatusChip(key: Key('memory-day-organizing'), label: '整理中'),
              ] else if (day.finalizedAt case final organizedAt?) ...[
                const SizedBox(width: 8),
                Text(
                  '整理于 ${_twoDigits(organizedAt.toLocal().hour)}:'
                  '${_twoDigits(organizedAt.toLocal().minute)}',
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
            _LongTermTile(key: UniqueKey(), item: item),
        ],
        if (section.organizedAt case final organizedAt?)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              '最近一次深度整理：${_formatTime(organizedAt)}',
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
          if (section.confirmed.isNotEmpty) ...[
            _sectionTitle(context, '当前相处方式'),
            for (final item in section.confirmed)
              _LongTermTile(key: UniqueKey(), item: item),
          ],
          if (section.probes.isNotEmpty) ...[
            _sectionTitle(context, '试探中'),
            for (final item in section.probes)
              _LongTermTile(key: UniqueKey(), item: item),
          ],
          if (section.recentChanges.isNotEmpty) ...[
            _sectionTitle(context, '近期变化'),
            for (final item in section.recentChanges)
              _LongTermTile(key: UniqueKey(), item: item),
          ],
        ],
        if (section.sharedPast.isNotEmpty) ...[
          _sectionTitle(context, '共同过往'),
          for (final item in section.sharedPast)
            _LongTermTile(key: UniqueKey(), item: item),
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
/// 某一天的记录都在这里展开；打开即只读，不提供任何写入入口。
class MemoryItemView extends StatefulWidget {
  const MemoryItemView({super.key, required this.itemId});

  final String itemId;

  @override
  State<MemoryItemView> createState() => _MemoryItemViewState();
}

class _MemoryItemViewState extends State<MemoryItemView> {
  MemoryItemDetail? _detail;
  bool _loading = true;
  bool _gone = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                  child: Row(
                    children: [
                      IconButton(
                        key: const Key('memory-item-back'),
                        onPressed: () => context.pop(),
                        tooltip: '返回记忆',
                        icon: const Icon(Icons.arrow_back),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '记忆详情',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: _body()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '记忆中心暂时不可用，请稍后重试。',
              key: Key('memory-item-error'),
            ),
            const SizedBox(height: 12),
            TextButton(
              key: const Key('memory-item-retry'),
              onPressed: () => unawaited(_load()),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_gone) {
      return const Center(
        child: Text(
          '这条记忆不存在或已经变化，请返回后刷新。',
          key: Key('memory-item-gone'),
        ),
      );
    }
    final detail = _detail!;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: switch (detail) {
        EpisodeEntryDetail() => _episodeEntryBody(detail),
        PersonaRootDetail() => _personaRootBody(detail),
        PersonaMiddleDetail() => _personaMiddleBody(detail),
        MemoryDayDetail() => _dayBody(detail),
      },
    );
  }

  List<Widget> _episodeEntryBody(EpisodeEntryDetail detail) {
    final time = detail.at.toLocal();
    return [
      Row(
        children: [
          _StatusChip(label: detail.kindLabel),
          const SizedBox(width: 8),
          if (detail.control case final control?) _StatusChip(label: control.label),
        ],
      ),
      const SizedBox(height: 12),
      Text(
        _visibleOr(detail.masked, detail.content),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      Text(
        '${_formatDayHeader(detail.date)} · ${_twoDigits(time.hour)}:'
        '${_twoDigits(time.minute)}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      if (detail.evidenceMasked || detail.evidence != null) ...[
        const SizedBox(height: 16),
        Text('当时的摘录', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          _visibleOr(detail.evidenceMasked, detail.evidence),
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
      TextButton(
        key: const Key('memory-item-day'),
        onPressed: () => context.push('/memory/item/${detail.dayId}'),
        child: const Text('查看这一天的记录'),
      ),
      if (detail.sessionId case final sessionId?)
        TextButton(
          key: const Key('memory-item-session'),
          onPressed: () => context.push('/history/$sessionId'),
          child: const Text('查看当时的对话'),
        ),
    ];
  }

  List<Widget> _personaRootBody(PersonaRootDetail detail) {
    return [
      _StatusChip(label: detail.branchTitle),
      const SizedBox(height: 12),
      Text(
        _visibleOr(detail.masked, detail.claim),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (detail.control case final control?) ...[
        const SizedBox(height: 8),
        _StatusChip(label: control.label),
      ],
      const SizedBox(height: 16),
      Text(
        '支持它的理解',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      const SizedBox(height: 4),
      if (detail.middles.isEmpty)
        const Text('暂时没有记录支持它的依据。')
      else
        for (final middle in detail.middles)
          _MiddleTile(key: Key('memory-root-middle-${middle.id}'), middle: middle),
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
      Text(
        _visibleOr(detail.masked, detail.claim),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      Text(
        '形成于 ${detail.formedOn} · 最近复核 ${detail.reviewedOn}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      if (detail.rootClaim case final rootClaim?) ...[
        const SizedBox(height: 8),
        Text(
          '所属结论：$rootClaim',
          style: Theme.of(context).textTheme.bodySmall,
        ),
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
            _formatDayHeader(detail.date),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (!detail.finalized) ...[
            const SizedBox(width: 8),
            const _StatusChip(label: '整理中'),
          ],
        ],
      ),
      if (detail.summary case final summary?)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _visibleOr(detail.summaryMasked, summary),
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

class _EntryTile extends StatelessWidget {
  const _EntryTile({super.key, required this.entry});

  final MemoryEntryCard entry;

  @override
  Widget build(BuildContext context) {
    final time = entry.at.toLocal();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => unawaited(context.push('/memory/item/${entry.id}')),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _StatusChip(label: entry.kindLabel),
                  const SizedBox(width: 8),
                  if (entry.control case final control?) ...[
                    _StatusChip(
                      key: Key('memory-entry-control-${entry.id}'),
                      label: control.label,
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (entry.hasEvidence) ...[
                    const _StatusChip(label: '有摘录'),
                    const SizedBox(width: 8),
                  ],
                  const Spacer(),
                  Text(
                    '${_twoDigits(time.hour)}:${_twoDigits(time.minute)}',
                    style: Theme.of(context).textTheme.bodySmall,
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
  const _LongTermTile({super.key, required this.item});

  final MemoryLongTermItem item;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(child: Text(_visibleOr(item.masked, item.content))),
            if (item.control case final control?) ...[
              const SizedBox(width: 8),
              _StatusChip(label: control.label),
            ],
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
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => unawaited(context.push('/memory/item/${root.id}')),
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
                  Text(
                    _evidenceSpanText(root),
                    style: Theme.of(context).textTheme.bodySmall,
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
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => unawaited(context.push('/memory/item/${middle.id}')),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_visibleOr(middle.masked, middle.claim)),
              const SizedBox(height: 6),
              Row(
                children: [
                  _StatusChip(label: middle.type),
                  const SizedBox(width: 8),
                  if (middle.control case final control?) ...[
                    _StatusChip(label: control.label),
                    const SizedBox(width: 8),
                  ],
                  if (middle.hasConflict) ...[
                    const _StatusChip(label: '有冲突证据'),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      '形成 ${middle.formedOn} · 复核 ${middle.reviewedOn}',
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.end,
                    ),
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
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => unawaited(context.push('/memory/item/${leaf.dayId}')),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _StatusChip(label: leaf.nature),
                  const SizedBox(width: 8),
                  if (leaf.relation == 'conflict') ...[
                    const _StatusChip(label: '冲突'),
                    const SizedBox(width: 8),
                  ],
                  if (leaf.control case final control?) ...[
                    _StatusChip(label: control.label),
                    const SizedBox(width: 8),
                  ],
                  const Spacer(),
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

String _twoDigits(int value) => value.toString().padLeft(2, '0');

String _formatTime(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${_twoDigits(local.month)}-${_twoDigits(local.day)} '
      '${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
}

String _formatDayHeader(String date) {
  final parsed = DateTime.tryParse(date);
  if (parsed == null) {
    return date;
  }
  final day = DateTime(parsed.year, parsed.month, parsed.day);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final difference = today.difference(day).inDays;
  if (difference == 0) {
    return '今天';
  }
  if (difference == 1) {
    return '昨天';
  }
  return '${parsed.year}年${parsed.month}月${parsed.day}日';
}
