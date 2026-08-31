import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_tokens.dart';
import '../navigation.dart';
import 'settings_client.dart';
import 'settings_view_model.dart';

/// 开发者诊断页（ticket 23）：最近请求来源与回退原因、后台整理
/// 状态、Dream 资格、本地文件健康度。只读页面；入口只在设置页
/// 开启开发者模式后出现，未开启时端点按不存在处理。
class DiagnosticsView extends StatefulWidget {
  const DiagnosticsView({super.key});

  @override
  State<DiagnosticsView> createState() => _DiagnosticsViewState();
}

/// **设计内**降级的回退原因（wire 名，取自 `FallbackReason`）：这两类发生时系统
/// 一切正常，故诊断页的结果芯片不给暗红底。判据见 design-system §1 与决策日志
/// 第五轮 #15、#23。往这里加成员等于放宽危险色的使用范围，只能按裁定改。
const _designedFallbackReasons = <String>{'safety', 'no_llm_config'};

class _DiagnosticsViewState extends State<DiagnosticsView> {
  bool _requested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_requested) {
      return;
    }
    _requested = true;
    unawaited(context.read<SettingsViewModel>().loadDiagnostics());
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<SettingsViewModel>();
    final theme = Theme.of(context);
    final snapshot = viewModel.diagnostics;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: QiyuLayout.pageReadingMaxWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 48),
              children: [
                Row(
                  children: [
                    IconButton(
                      key: const Key('diagnostics-back'),
                      onPressed: () => backToPrevious(context),
                      tooltip: '返回设置',
                      icon: const Icon(QiyuIcons.arrow_back),
                    ),
                    const SizedBox(width: 8),
                    Text('开发者诊断', style: theme.textTheme.headlineSmall),
                    const Spacer(),
                    IconButton(
                      key: const Key('diagnostics-refresh'),
                      onPressed: viewModel.busy
                          ? null
                          : () => unawaited(viewModel.loadDiagnostics()),
                      tooltip: '刷新诊断',
                      icon: const Icon(QiyuIcons.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '只读快照，不修改任何数据；只在本机展示，不包含对话正文。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                if (viewModel.errorMessage case final message?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      message,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                if (snapshot == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  _section(
                    context,
                    '最近请求（本次启动以来）',
                    _recentRequests(context, snapshot.recentRequests),
                  ),
                  _section(
                    context,
                    '后台整理',
                    _finalization(context, snapshot.finalization),
                  ),
                  _section(
                    context,
                    'Dream 资格',
                    _dream(context, snapshot.dream),
                  ),
                  _section(
                    context,
                    '本地文件健康',
                    _fileHealth(context, snapshot.fileHealth),
                  ),
                  _section(
                    context,
                    '数据位置',
                    Text(
                      snapshot.memoryDirectory,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title, Widget child) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _recentRequests(BuildContext context, List<RecentRequest> requests) {
    final theme = Theme.of(context);
    if (requests.isEmpty) {
      return Text(
        '本次启动后还没有请求记录。',
        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < requests.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: QiyuSpacing.xs,
              runSpacing: 4,
              children: [
                Text(
                  requests[i].at.toLocal().toString().substring(0, 19),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                _chip(context, _sourceLabel(requests[i].source)),
                _chip(
                  context,
                  _resultLabel(requests[i]),
                  // 定位键：这一页唯一的着色判断就是「算不算故障」，用例必须能
                  // 逐颗读到真落在那枚芯片上的底色，不能靠文案反推。
                  key: Key('diagnostics-result-$i'),
                  emphasized: _isFault(requests[i]),
                ),
                if (requests[i].fallbackReason case final reason?)
                  _chip(context, reason),
              ],
            ),
          ),
      ],
    );
  }

  /// 这条请求算不算 §1 三色纪律里的「故障 / 失败态」（决策日志第五轮 #15、#23）。
  ///
  /// `result == 'fallback'` 覆盖 `FallbackReason` 全集，其中两枚是**设计内**降级：
  /// `safety` 是危机 / 敏感输入命中本地分类，按规则**根本不该**调用 Provider；
  /// `no_llm_config` 是没配模型，本机规则引擎就是产品形态。把这两样也标成暗红，
  /// 等于用危险色宣布「一切正常」为异常。其余回退——模型超时、网络、鉴权、空回复、
  /// 违禁词、人格越界、结构不合……都是模型侧没交付合格结果，属故障。
  bool _isFault(RecentRequest request) => switch (request.result) {
    'failed' => true,
    'fallback' => !_designedFallbackReasons.contains(request.fallbackReason),
    _ => false,
  };

  Widget _finalization(BuildContext context, FinalizationHealth? health) {
    final theme = Theme.of(context);
    if (health == null) {
      return Text('未启用日终整理。', style: theme.textTheme.bodyMedium);
    }
    final todayState = switch (health.todayFinalized) {
      true => '今天（${health.today}）已归档',
      false => '今天（${health.today}）尚未归档',
      null => '今天的归档状态未知',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(todayState, style: theme.textTheme.bodyMedium),
        Text(
          '待补归档 ${health.pendingDays} 天 · 不可读 ${health.unreadableDays} 天',
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }

  Widget _dream(BuildContext context, DreamHealth? dream) {
    final theme = Theme.of(context);
    if (dream == null) {
      return Text('未启用 Dream。', style: theme.textTheme.bodyMedium);
    }
    final lastSuccess = dream.lastSuccessAt == null
        ? '还没有成功运行过 Dream'
        : '上次成功：${dream.lastSuccessAt!.toLocal().toString().substring(0, 10)}'
              '（${dream.daysSinceLastSuccess} 天前）';
    final interval = dream.minIntervalDays == null
        ? ''
        : '最小间隔 ${dream.minIntervalDays} 天';
    final pending = dream.pending ? '有待补跑的晚安请求' : '没有待补跑请求';
    final provider = dream.providerConfigured == true
        ? '模型服务已配置'
        : '未配置模型服务（不会运行）';
    final eligible = dream.eligible == true ? '当前具备资格' : '当前不具备资格';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in [lastSuccess, interval, pending, provider, eligible])
          if (line.isNotEmpty) Text(line, style: theme.textTheme.bodyMedium),
      ],
    );
  }

  Widget _fileHealth(BuildContext context, Map<String, Object?> health) {
    final theme = Theme.of(context);
    final rows = <String>[
      '会话文件：可读 ${health['sessionsReadable'] ?? 0} 份，'
          '不可读 ${health['sessionsUnavailable'] ?? 0} 份',
      '每日记录：共 ${health['episodeDays'] ?? 0} 天，'
          '未归档 ${health['episodeUnfinalized'] ?? 0} 天，'
          '不可读 ${health['episodeUnreadable'] ?? 0} 天',
      '长期印象：${_readability(health['longMemory'])}',
      'Dream 状态：${_readability(health['dreamState'])}',
      '记忆控制：${_readability(health['memoryControls'])}',
      '画像树：${_boolReadability(health['personaTreeReadable'])}',
    ];
    final recovery = health['recovery'];
    if (recovery is Map<String, Object?>) {
      rows.add(
        recovery['reportExists'] == true
            ? '恢复扫描：隔离原件 ${recovery['quarantinedFiles'] ?? 0} 份'
            : '恢复扫描：还没有运行过',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows) Text(row, style: theme.textTheme.bodyMedium),
      ],
    );
  }

  String _readability(Object? value) {
    if (value is! Map<String, Object?>) {
      return '未知';
    }
    if (value['exists'] != true) {
      return '尚未创建';
    }
    return value['readable'] == true ? '可读' : '不可读';
  }

  String _boolReadability(Object? value) => switch (value) {
    true => '可读',
    false => '不可读',
    _ => '未启用',
  };

  Widget _chip(
    BuildContext context,
    String label, {
    bool emphasized = false,
    Key? key,
  }) {
    final theme = Theme.of(context);
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: emphasized
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: emphasized
              ? theme.colorScheme.onErrorContainer
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  String _sourceLabel(String source) => switch (source) {
    'chat' => '聊天',
    'provider-test' => '连接测试',
    'finalization' => '日终整理',
    'dream' => 'Dream',
    _ => source,
  };

  String _resultLabel(RecentRequest request) => switch (request.result) {
    'ok' => request.replySource == 'local' ? '本地规则回应' : '模型回应',
    'fallback' => '已回退本地',
    'failed' => '失败',
    'skipped' => '跳过',
    'cancelled' => '已停止',
    _ => request.result,
  };
}
