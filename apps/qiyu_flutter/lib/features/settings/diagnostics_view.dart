import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_tokens.dart';
import '../navigation.dart';
import '../shell/qiyu_ui_locale.dart';
import 'diagnostics_strings.dart';
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
    final strings = DiagnosticsStrings.of(qiyuIsEn(context));
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
                      tooltip: strings.backToSettings,
                      icon: const Icon(QiyuIcons.arrow_back),
                    ),
                    const SizedBox(width: 8),
                    Text(strings.title, style: theme.textTheme.headlineSmall),
                    const Spacer(),
                    IconButton(
                      key: const Key('diagnostics-refresh'),
                      onPressed: viewModel.busy
                          ? null
                          : () => unawaited(viewModel.loadDiagnostics()),
                      tooltip: strings.refresh,
                      icon: const Icon(QiyuIcons.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  strings.description,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                if (viewModel.errorMessage case final message?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      qiyuStrings(context).localizeStatus(message),
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
                    strings.recentRequests,
                    _recentRequests(context, snapshot.recentRequests),
                  ),
                  _section(
                    context,
                    strings.finalization,
                    _finalization(context, snapshot.finalization),
                  ),
                  _section(
                    context,
                    strings.dream,
                    _dream(context, snapshot.dream),
                  ),
                  _section(
                    context,
                    strings.fileHealth,
                    _fileHealth(context, snapshot.fileHealth),
                  ),
                  _section(
                    context,
                    strings.dataLocation,
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
    final strings = DiagnosticsStrings.of(qiyuIsEn(context));
    if (requests.isEmpty) {
      return Text(
        strings.noRequests,
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
                _chip(context, strings.source(requests[i].source)),
                _chip(
                  context,
                  strings.result(
                    requests[i].result,
                    local: requests[i].replySource == 'local',
                  ),
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
  /// `safety` 是危机等敏感输入的本地兜底话术——模型没回应时由它接住；
  /// `no_llm_config` 是没配模型，本机规则引擎就是产品形态。把这两样也标成暗红，
  /// 等于用危险色宣布「一切正常」为异常。其余回退——模型超时、网络、鉴权、空回复、
  /// 结构不合、超长……都是模型侧没交付合格结果，属故障（话术与人格约束在提示词层
  /// 由模型自判断，输出侧不再正则判决——ADR 0017）。
  bool _isFault(RecentRequest request) => switch (request.result) {
    'failed' => true,
    'fallback' => !_designedFallbackReasons.contains(request.fallbackReason),
    _ => false,
  };

  Widget _finalization(BuildContext context, FinalizationHealth? health) {
    final theme = Theme.of(context);
    final strings = DiagnosticsStrings.of(qiyuIsEn(context));
    if (health == null) {
      return Text(
        strings.finalizationDisabled,
        style: theme.textTheme.bodyMedium,
      );
    }
    final todayState = switch (health.todayFinalized) {
      true => strings.todayArchived(health.today),
      false => strings.todayPending(health.today),
      null => strings.todayUnknown,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(todayState, style: theme.textTheme.bodyMedium),
        Text(
          strings.pendingDays(health.pendingDays, health.unreadableDays),
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }

  Widget _dream(BuildContext context, DreamHealth? dream) {
    final theme = Theme.of(context);
    final strings = DiagnosticsStrings.of(qiyuIsEn(context));
    if (dream == null) {
      return Text(strings.dreamDisabled, style: theme.textTheme.bodyMedium);
    }
    final lastSuccess = dream.lastSuccessAt == null
        ? strings.dreamNeverRan
        : strings.dreamLastSuccess(
            dream.lastSuccessAt!.toLocal().toString().substring(0, 10),
            dream.daysSinceLastSuccess,
          );
    final interval = dream.minIntervalDays == null
        ? ''
        : strings.dreamInterval(dream.minIntervalDays!);
    final pending = strings.dreamPending(dream.pending);
    final provider = strings.modelConfigured(dream.providerConfigured == true);
    final eligible = strings.dreamEligible(dream.eligible == true);
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
    final strings = DiagnosticsStrings.of(qiyuIsEn(context));
    final rows = <String>[
      strings.sessions(
        health['sessionsReadable'] ?? 0,
        health['sessionsUnavailable'] ?? 0,
      ),
      strings.episodes(
        health['episodeDays'] ?? 0,
        health['episodeUnfinalized'] ?? 0,
        health['episodeUnreadable'] ?? 0,
      ),
      strings.longMemory(_readability(health['longMemory'], strings)),
      strings.dreamState(_readability(health['dreamState'], strings)),
      strings.memoryControls(_readability(health['memoryControls'], strings)),
      strings.personaTree(
        _boolReadability(health['personaTreeReadable'], strings),
      ),
    ];
    final recovery = health['recovery'];
    if (recovery is Map<String, Object?>) {
      rows.add(
        recovery['reportExists'] == true
            ? strings.recoveryScanned(recovery['quarantinedFiles'] ?? 0)
            : strings.recoveryNeverRan,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows) Text(row, style: theme.textTheme.bodyMedium),
      ],
    );
  }

  String _readability(Object? value, DiagnosticsStrings strings) {
    if (value is! Map<String, Object?>) {
      return strings.unknown;
    }
    if (value['exists'] != true) {
      return strings.notCreated;
    }
    return value['readable'] == true ? strings.readable : strings.unreadable;
  }

  String _boolReadability(Object? value, DiagnosticsStrings strings) =>
      switch (value) {
        true => strings.readable,
        false => strings.unreadable,
        _ => strings.disabled,
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
}
