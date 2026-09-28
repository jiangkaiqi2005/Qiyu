import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_tokens.dart';
import '../baseline/host_api_gateway.dart';
import '../shell/qiyu_ui_locale.dart';
import 'backup_client.dart';
import 'backup_platform.dart';
import 'memory_view_model.dart';
import 'memory_strings.dart';
import '../time_format.dart';

String _categoryEn(BackupItemCategory category) => switch (category) {
  BackupItemCategory.added => 'Added',
  BackupItemCategory.replaced => 'Replaced',
  BackupItemCategory.conflict => 'Conflict',
  BackupItemCategory.skipped => 'Skipped',
  BackupItemCategory.unrecoverable => 'Unrecoverable',
};

String _previewNoteEn(String note) => switch (note) {
  '备份中的会话结构无法识别，未导入' => 'Conversation structure not recognized; not imported',
  '本机已有同名原始会话，保留本机版本' =>
    'An original conversation with this name exists locally; local version kept',
  '与本机控制记录一致' => 'Matches local memory controls',
  '与本机控制记录按并集合并，保留更保守的隐私结果' =>
    'Merged with local memory controls; more private outcome kept',
  _ => note,
};

String _controlsMergeEn(String controlsMerge) => switch (controlsMerge) {
  'union' =>
    'Memory controls will be combined with local controls, keeping the more private outcome.',
  'identical' => 'Memory controls match local controls.',
  _ =>
    'No memory controls in the backup. Local controls will stay as they are.',
};

/// 备份与恢复对话框（ticket 22）：导出下载、导入前差异预览与确认后
/// 写入、快照回滚。默认不静默覆盖：导入必须先经用户确认，确认后
/// 由 Host 先创建可回滚快照再原子写入。
Future<void> showBackupDialog(
  BuildContext context, {
  BackupGateway? gateway,
  BackupPlatform? platform,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => _BackupDialog(
      gateway: gateway ?? _resolveDefaultGateway(context),
      platform: platform ?? createBackupPlatform(),
    ),
  );
}

/// 备份网关解析（与聊天页 STT 设置网关同一先例）：注入优先；其次
/// 复用 app Provider 树的共享实例（安卓壳由此拿到会话接管 client 与
/// 显式基址）；只有脱离 app 树单独 pump 的测试才回退自建——测试里
/// 平台接缝是 stub，不会真正发请求。
BackupGateway _resolveDefaultGateway(BuildContext context) {
  try {
    return context.read<BackupGateway>();
  } on ProviderNotFoundException {
    return HttpBackupGateway();
  }
}

enum _ImportPhase { idle, reading, previewing, previewed, importing, done }

class _BackupDialog extends StatefulWidget {
  const _BackupDialog({required this.gateway, required this.platform});

  final BackupGateway gateway;
  final BackupPlatform platform;

  @override
  State<_BackupDialog> createState() => _BackupDialogState();
}

class _BackupDialogState extends State<_BackupDialog> {
  // 导出
  bool _exporting = false;
  String? _exportMessage;

  // 导入
  _ImportPhase _phase = _ImportPhase.idle;
  Uint8List? _pickedBundle;
  BackupPreview? _preview;
  BackupImportResult? _importResult;
  String? _importError;

  // 回滚
  List<BackupSnapshotInfo> _snapshots = const [];
  bool _snapshotsLoading = true;
  bool _rollingBack = false;
  String? _rollbackMessage;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSnapshots());
  }

  Future<void> _loadSnapshots() async {
    try {
      final snapshots = await widget.gateway.snapshots();
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshots = snapshots;
        _snapshotsLoading = false;
      });
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() => _snapshotsLoading = false);
    }
  }

  Future<void> _export() async {
    final shareTitle = qiyuIsEnNow(context) ? 'Qiyu backup' : '栖语备份';
    setState(() {
      _exporting = true;
      _exportMessage = null;
    });
    try {
      final export = await widget.gateway.exportBundle();
      final downloaded = await widget.platform.downloadBackup(
        export.fileName,
        export.bytes,
        shareTitle: shareTitle,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _exportMessage = downloaded
            ? (qiyuIsEnNow(context)
                  ? 'Backup exported: ${export.fileName}'
                  : '备份已导出：${export.fileName}')
            : (qiyuIsEnNow(context)
                  ? 'Backup was not exported. Export is unavailable here, or sharing was canceled.'
                  : '备份没有导出：当前环境不支持导出，或分享已取消。');
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _exportMessage = _readable(error));
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  Future<void> _pickAndPreview() async {
    setState(() {
      _phase = _ImportPhase.reading;
      _importError = null;
      _preview = null;
      _importResult = null;
    });
    Uint8List? bundle;
    try {
      bundle = await widget.platform.pickBackupFile();
    } on Object {
      bundle = null;
    }
    if (!mounted) {
      return;
    }
    if (bundle == null) {
      setState(() => _phase = _ImportPhase.idle);
      return;
    }
    setState(() {
      _pickedBundle = bundle;
      _phase = _ImportPhase.previewing;
    });
    try {
      final preview = await widget.gateway.previewBundle(bundle);
      if (!mounted) {
        return;
      }
      setState(() {
        _preview = preview;
        _phase = _ImportPhase.previewed;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _phase = _ImportPhase.idle;
        _pickedBundle = null;
        _importError = _readable(error);
      });
    }
  }

  Future<void> _confirmImport() async {
    final bundle = _pickedBundle;
    if (bundle == null) {
      return;
    }
    setState(() {
      _phase = _ImportPhase.importing;
      _importError = null;
    });
    try {
      final result = await widget.gateway.importBundle(bundle);
      if (!mounted) {
        return;
      }
      setState(() {
        _importResult = result;
        _phase = _ImportPhase.done;
        _pickedBundle = null;
        _preview = null;
      });
      unawaited(context.read<MemoryCenterViewModel>().refresh());
      unawaited(_loadSnapshots());
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _phase = _ImportPhase.idle;
        _pickedBundle = null;
        _preview = null;
        _importError = _readable(error);
      });
    }
  }

  Future<void> _rollback() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (confirmContext) => AlertDialog(
        key: const Key('backup-rollback-confirm'),
        title: Text(BackupLabel.rollbackQuestion.of(context)),
        content: Text(BackupLabel.rollbackDescription.of(context)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(confirmContext).pop(false),
            child: Text(BackupLabel.notNow.of(context)),
          ),
          TextButton(
            key: const Key('backup-rollback-go'),
            onPressed: () => Navigator.of(confirmContext).pop(true),
            child: Text(BackupLabel.confirmRollback.of(context)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() {
      _rollingBack = true;
      _rollbackMessage = null;
    });
    try {
      final result = await widget.gateway.rollback();
      if (!mounted) {
        return;
      }
      setState(
        () => _rollbackMessage = qiyuIsEnNow(context)
            ? 'Restored ${result.restoredFiles} files to their state before import. A snapshot of the previous state was also kept.'
            : '已恢复到导入之前（${result.restoredFiles} 份文件），刚才的状态也留了快照。',
      );
      unawaited(context.read<MemoryCenterViewModel>().refresh());
      unawaited(_loadSnapshots());
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _rollbackMessage = _readable(error));
    } finally {
      if (mounted) {
        setState(() => _rollingBack = false);
      }
    }
  }

  String _readable(Object error) => readableError(
    error,
    fallback: qiyuIsEnNow(context)
        ? BackupLabel.error.en
        : BackupLabel.error.zh,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: QiyuLayout.backupDialogMaxWidth,
          maxHeight: QiyuLayout.backupDialogMaxHeight,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    MemoryLabel.backup.of(context),
                    style: theme.textTheme.titleLarge,
                  ),
                  const Spacer(),
                  IconButton(
                    key: const Key('backup-close'),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: MemoryLabel.close.of(context),
                    icon: const Icon(QiyuIcons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _sectionCard(
                theme,
                title: BackupLabel.exportTitle.of(context),
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(BackupLabel.exportDescription.of(context)),
                    const SizedBox(height: 8),
                    // 数据警示（ticket 07）：导出是端内形态唯一的跨设备
                    // 通道，卸载即随沙盒清空——这句必须在入口旁可见。
                    Text(
                      BackupLabel.dataWarning.of(context),
                      key: const Key('backup-data-warning'),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        key: const Key('backup-export'),
                        onPressed: _exporting ? null : _export,
                        icon: _exporting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(QiyuIcons.download),
                        label: Text(
                          _exporting
                              ? BackupLabel.packing.of(context)
                              : BackupLabel.exportTitle.of(context),
                        ),
                      ),
                    ),
                    if (_exportMessage case final message?) ...[
                      const SizedBox(height: 8),
                      Text(message),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _sectionCard(
                theme,
                title: BackupLabel.importTitle.of(context),
                body: _importBody(theme),
              ),
              const SizedBox(height: 12),
              _sectionCard(
                theme,
                title: BackupLabel.rollbackTitle.of(context),
                body: _rollbackBody(theme),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionCard(
    ThemeData theme, {
    required String title,
    required Widget body,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            body,
          ],
        ),
      ),
    );
  }

  Widget _importBody(ThemeData theme) {
    switch (_phase) {
      case _ImportPhase.idle:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(BackupLabel.importDescription.of(context)),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const Key('backup-import-pick'),
                onPressed: widget.platform.supported ? _pickAndPreview : null,
                icon: const Icon(QiyuIcons.upload_file),
                label: Text(BackupLabel.chooseFile.of(context)),
              ),
            ),
            if (!widget.platform.supported)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(BackupLabel.fileUnsupported.of(context)),
              ),
            if (_importError case final error?) ...[
              const SizedBox(height: 8),
              Text(error, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        );
      case _ImportPhase.reading:
        return Text(BackupLabel.reading.of(context));
      case _ImportPhase.previewing:
        return _busyRow(BackupLabel.previewing.of(context));
      case _ImportPhase.previewed:
        final preview = _preview!;
        return _previewBody(theme, preview);
      case _ImportPhase.importing:
        return _busyRow(BackupLabel.importing.of(context));
      case _ImportPhase.done:
        final result = _importResult!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              qiyuIsEn(context)
                  ? 'Import complete: ${result.added} added, ${result.replaced} replaced, ${result.skipped} skipped${result.conflicts > 0 ? ', ${result.conflicts} conflicts kept locally' : ''}${result.unrecoverable > 0 ? ', ${result.unrecoverable} not imported' : ''}.'
                  : '导入完成：新增 ${result.added} 项、替换 ${result.replaced} 项、跳过 ${result.skipped} 项${result.conflicts > 0 ? '、冲突保留本机 ${result.conflicts} 项' : ''}${result.unrecoverable > 0 ? '、未导入 ${result.unrecoverable} 项' : ''}。',
            ),
            const SizedBox(height: 4),
            Text(
              (result.controlsMerged
                      ? BackupLabel.controlsMerged
                      : BackupLabel.controlsUnchanged)
                  .of(context),
            ),
            const SizedBox(height: 4),
            Text(BackupLabel.rollbackHint.of(context)),
          ],
        );
    }
  }

  Widget _previewBody(ThemeData theme, BackupPreview preview) {
    final summary = qiyuIsEn(context)
        ? [
            '${preview.countOf(BackupItemCategory.added)} added',
            '${preview.countOf(BackupItemCategory.replaced)} replaced',
            '${preview.countOf(BackupItemCategory.conflict)} conflicts',
            '${preview.countOf(BackupItemCategory.skipped)} skipped',
            '${preview.countOf(BackupItemCategory.unrecoverable)} unrecoverable',
          ].join(', ')
        : [
            '新增 ${preview.countOf(BackupItemCategory.added)}',
            '替换 ${preview.countOf(BackupItemCategory.replaced)}',
            '冲突 ${preview.countOf(BackupItemCategory.conflict)}',
            '跳过 ${preview.countOf(BackupItemCategory.skipped)}',
            '不可恢复 ${preview.countOf(BackupItemCategory.unrecoverable)}',
          ].join('、');
    final conflicted = preview.items
        .where((item) => item.category == BackupItemCategory.conflict)
        .toList();
    final unrecoverable = preview.items
        .where((item) => item.category == BackupItemCategory.unrecoverable)
        .toList();
    // 五类项目都逐条可见：跳过项最多列 20 条，其余以计数说明。
    const skippedShownMax = 20;
    final skippedItems = preview.items
        .where((item) => item.category == BackupItemCategory.skipped)
        .toList();
    final visibleItems = [
      ...preview.items.where(
        (item) => item.category != BackupItemCategory.skipped,
      ),
      ...skippedItems.take(skippedShownMax),
    ];
    return Column(
      key: const Key('backup-preview'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          qiyuIsEn(context)
              ? 'Backup created ${formatTime(preview.generatedAt)}. Verified. Compared with local data: $summary.'
              : '备份生成于 ${formatTime(preview.generatedAt)}，验证通过。与本机数据对比：$summary。',
        ),
        const SizedBox(height: 4),
        Text(
          qiyuIsEn(context)
              ? _controlsMergeEn(preview.controlsMerge)
              : preview.controlsMergeText,
        ),
        if (visibleItems.isNotEmpty) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final item in visibleItems)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '${qiyuIsEn(context) ? _categoryEn(item.category) : item.category.label}${qiyuIsEn(context) ? ': ' : '：'}${item.path}'
                        '${item.note == null
                            ? ''
                            : qiyuIsEn(context)
                            ? ' (${_previewNoteEn(item.note!)})'
                            : '（${item.note}）'}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  if (skippedItems.length > skippedShownMax)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        qiyuIsEn(context)
                            ? '…${skippedItems.length - skippedShownMax} more skipped (same as local data; not written)'
                            : '…另有 ${skippedItems.length - skippedShownMax} 项跳过（与本机内容一致，不写入）',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        if (conflicted.isNotEmpty || unrecoverable.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            BackupLabel.conflictWarning.of(context),
            style: theme.textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 12),
        Text(BackupLabel.importConfirmHint.of(context)),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton(
              key: const Key('backup-import-confirm'),
              onPressed: _confirmImport,
              child: Text(BackupLabel.confirmImport.of(context)),
            ),
            const SizedBox(width: 12),
            TextButton(
              key: const Key('backup-import-cancel'),
              onPressed: () => setState(() {
                _phase = _ImportPhase.idle;
                _pickedBundle = null;
                _preview = null;
              }),
              child: Text(MemoryLabel.cancel.of(context)),
            ),
          ],
        ),
      ],
    );
  }

  /// 导入进行中的提示行：小号进度指示加一句说明。
  Widget _busyRow(String text) {
    return Row(
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Text(text),
      ],
    );
  }

  Widget _rollbackBody(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_snapshotsLoading)
          Text(BackupLabel.checkingSnapshots.of(context))
        else if (_snapshots.isEmpty)
          Text(BackupLabel.noSnapshots.of(context))
        else ...[
          Text(
            qiyuIsEn(context)
                ? 'Latest snapshot: ${formatTime(_snapshots.first.createdAt)} (${_snapshots.first.fileCount} files), ${_snapshots.length} total.'
                : '最近快照：${formatTime(_snapshots.first.createdAt)}（${_snapshots.first.fileCount} 份文件），共 ${_snapshots.length} 份。',
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              key: const Key('backup-rollback'),
              onPressed: _rollingBack ? null : _rollback,
              child: Text(
                (_rollingBack
                        ? BackupLabel.restoring
                        : BackupLabel.rollbackBeforeImport)
                    .of(context),
              ),
            ),
          ),
        ],
        if (_rollbackMessage case final message?) ...[
          const SizedBox(height: 8),
          Text(message),
        ],
      ],
    );
  }
}
