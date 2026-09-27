import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_tokens.dart';
import '../baseline/host_api_gateway.dart';
import 'backup_client.dart';
import 'backup_platform.dart';
import 'memory_view_model.dart';
import '../time_format.dart';

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
    setState(() {
      _exporting = true;
      _exportMessage = null;
    });
    try {
      final export = await widget.gateway.exportBundle();
      final downloaded = await widget.platform.downloadBackup(
        export.fileName,
        export.bytes,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _exportMessage = downloaded
            ? '备份已导出：${export.fileName}'
            : '备份没有导出：当前环境不支持导出，或分享已取消。';
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
        title: const Text('回滚到导入之前？'),
        content: const Text(
          '记忆会恢复到最近一次导入前的状态。'
          '回滚前会先给当前状态留一份保底快照。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(confirmContext).pop(false),
            child: const Text('先不回滚'),
          ),
          TextButton(
            key: const Key('backup-rollback-go'),
            onPressed: () => Navigator.of(confirmContext).pop(true),
            child: const Text('确认回滚'),
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
        () => _rollbackMessage =
            '已恢复到导入之前（${result.restoredFiles} 份文件），'
            '刚才的状态也留了快照。',
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

  String _readable(Object error) =>
      readableError(error, fallback: '备份操作没有成功，可稍后重试。');

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
                  Text('备份与恢复', style: theme.textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    key: const Key('backup-close'),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: '关闭',
                    icon: const Icon(QiyuIcons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _sectionCard(
                theme,
                title: '导出备份',
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '把栖语的完整本地记忆打包为可阅读、可携带的 Markdown '
                      '备份。API Key 与模型凭据从不进入备份。',
                    ),
                    const SizedBox(height: 8),
                    // 数据警示（ticket 07）：导出是端内形态唯一的跨设备
                    // 通道，卸载即随沙盒清空——这句必须在入口旁可见。
                    const Text(
                      '会话与记忆只存在这台设备上：未导出即随卸载永久丢失，'
                      '换机前记得先导出。',
                      key: Key('backup-data-warning'),
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
                        label: Text(_exporting ? '正在打包…' : '导出备份'),
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
              _sectionCard(theme, title: '导入备份', body: _importBody(theme)),
              const SizedBox(height: 12),
              _sectionCard(theme, title: '回滚', body: _rollbackBody(theme)),
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
            const Text(
              '导入前会先验证备份的版本与完整性，并展示与本机数据的差异；'
              '确认后先创建可回滚快照，再写入。本机已有的禁提与删除控制'
              '会继续生效。',
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const Key('backup-import-pick'),
                onPressed: widget.platform.supported ? _pickAndPreview : null,
                icon: const Icon(QiyuIcons.upload_file),
                label: const Text('选择备份文件'),
              ),
            ),
            if (!widget.platform.supported)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('当前环境不支持选择文件，请改用桌面版栖语导入。'),
              ),
            if (_importError case final error?) ...[
              const SizedBox(height: 8),
              Text(error, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        );
      case _ImportPhase.reading:
        return const Text('正在读取备份文件…');
      case _ImportPhase.previewing:
        return _busyRow('正在验证备份并比对差异…');
      case _ImportPhase.previewed:
        final preview = _preview!;
        return _previewBody(theme, preview);
      case _ImportPhase.importing:
        return _busyRow('正在创建快照并写入，请不要关闭栖语…');
      case _ImportPhase.done:
        final result = _importResult!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '导入完成：新增 ${result.added} 项、替换 ${result.replaced} 项、'
              '跳过 ${result.skipped} 项'
              '${result.conflicts > 0 ? '、冲突保留本机 ${result.conflicts} 项' : ''}'
              '${result.unrecoverable > 0 ? '、未导入 ${result.unrecoverable} 项' : ''}。',
            ),
            const SizedBox(height: 4),
            Text(
              result.controlsMerged ? '记忆控制已按并集合并，更保守的隐私结果保留。' : '记忆控制保持不变。',
            ),
            const SizedBox(height: 4),
            const Text('如果结果不对，可以在下方「回滚」恢复原样。'),
          ],
        );
    }
  }

  Widget _previewBody(ThemeData theme, BackupPreview preview) {
    final summary = [
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
          '备份生成于 ${formatTime(preview.generatedAt)}，'
          '验证通过。与本机数据对比：$summary。',
        ),
        const SizedBox(height: 4),
        Text(preview.controlsMergeText),
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
                        '${item.category.label}：${item.path}'
                        '${item.note == null ? '' : '（${item.note}）'}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  if (skippedItems.length > skippedShownMax)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '…另有 ${skippedItems.length - skippedShownMax} 项跳过'
                        '（与本机内容一致，不写入）',
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
            '冲突与不可恢复的内容不会写入本机；同名原始会话一律保留本机版本。',
            style: theme.textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 12),
        const Text('确认后栖语会先创建一份可回滚的快照，再写入备份内容。'),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton(
              key: const Key('backup-import-confirm'),
              onPressed: _confirmImport,
              child: const Text('确认导入'),
            ),
            const SizedBox(width: 12),
            TextButton(
              key: const Key('backup-import-cancel'),
              onPressed: () => setState(() {
                _phase = _ImportPhase.idle;
                _pickedBundle = null;
                _preview = null;
              }),
              child: const Text('取消'),
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
          const Text('正在查看快照…')
        else if (_snapshots.isEmpty)
          const Text('还没有快照。导入备份时会自动创建。')
        else ...[
          Text(
            '最近快照：${formatTime(_snapshots.first.createdAt)}'
            '（${_snapshots.first.fileCount} 份文件），共 '
            '${_snapshots.length} 份。',
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              key: const Key('backup-rollback'),
              onPressed: _rollingBack ? null : _rollback,
              child: Text(_rollingBack ? '正在恢复…' : '回滚到导入之前'),
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
