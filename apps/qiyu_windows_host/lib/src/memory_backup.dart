import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:path/path.dart' as path;

import 'episode_index.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_actions.dart';
import 'memory_controls.dart';
import 'persona_tree.dart';

/// 备份包 schema 版本：导入时只接受完全一致的版本，不兼容即拒绝。
const backupSchemaVersion = 1;

/// 备份包内的清单标记（与记忆文件同一 base64url 约定）。
const _manifestMarker = '<!-- qiyu-backup-manifest:';
const _snapshotMarker = '<!-- qiyu-backup-snapshot:';

/// 备份/快照内文件数量与解压总量的保守上限：本机备份防御异常大
/// 包，不是存储限额。
const _maxBackupEntries = 20000;
const _maxBackupTotalBytes = 1 << 30;

/// 快照保留份数：导入与回滚都会新增快照，只保留最近几份。
const _snapshotKeepCount = 5;

/// 导入预览中每个文件的归类（ticket 22）：新增、替换、冲突、跳过、
/// 不可恢复。冲突与不可恢复的项目一律不写入本机。
enum BackupItemCategory {
  added('新增'),
  replaced('替换'),
  conflict('冲突'),
  skipped('跳过'),
  unrecoverable('不可恢复');

  const BackupItemCategory(this.label);

  final String label;
}

final class MemoryBackupPreviewItem {
  const MemoryBackupPreviewItem({
    required this.path,
    required this.category,
    this.note,
  });

  final String path;
  final BackupItemCategory category;
  final String? note;

  Map<String, Object?> toJson() => {
    'path': path,
    'category': category.name,
    if (note != null) 'note': note,
  };
}

/// 导入前验证与差异结果：结构、版本、完整性全部通过才有效；有效时
/// 逐项展示新增/替换/冲突/跳过/不可恢复，绝不静默覆盖。
final class MemoryBackupPreview {
  const MemoryBackupPreview({
    required this.schemaVersion,
    required this.generatedAt,
    required this.controlsMerge,
    required this.items,
  });

  final int schemaVersion;
  final DateTime generatedAt;

  /// 控制记录处理：none=备份中没有控制文件；identical=与本机一致；
  /// union=将按并集合并（更保守的隐私结果）。
  final String controlsMerge;
  final List<MemoryBackupPreviewItem> items;

  int countOf(BackupItemCategory category) =>
      items.where((item) => item.category == category).length;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'controlsMerge': controlsMerge,
    'counts': {
      for (final category in BackupItemCategory.values)
        category.name: countOf(category),
    },
    'items': items.map((item) => item.toJson()).toList(),
  };
}

final class MemoryBackupExport {
  const MemoryBackupExport({required this.bytes, required this.fileName});

  final Uint8List bytes;
  final String fileName;
}

final class MemoryBackupImportResult {
  const MemoryBackupImportResult({
    required this.added,
    required this.replaced,
    required this.skipped,
    required this.conflicts,
    required this.unrecoverable,
    required this.controlsMerged,
    required this.snapshotId,
  });

  final int added;
  final int replaced;
  final int skipped;
  final int conflicts;
  final int unrecoverable;
  final bool controlsMerged;
  final String snapshotId;

  Map<String, Object?> toJson() => {
    'added': added,
    'replaced': replaced,
    'skipped': skipped,
    'conflicts': conflicts,
    'unrecoverable': unrecoverable,
    'controlsMerged': controlsMerged,
    'snapshotId': snapshotId,
  };
}

final class MemoryBackupSnapshotInfo {
  const MemoryBackupSnapshotInfo({
    required this.id,
    required this.createdAt,
    required this.fileCount,
  });

  final String id;
  final DateTime createdAt;
  final int fileCount;

  Map<String, Object?> toJson() => {
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'fileCount': fileCount,
  };
}

final class MemoryBackupRollbackResult {
  const MemoryBackupRollbackResult({
    required this.snapshotId,
    required this.restoredFiles,
    required this.safetySnapshotId,
  });

  final String snapshotId;
  final int restoredFiles;

  /// 回滚前先给当前状态留的保底快照。
  final String safetySnapshotId;

  Map<String, Object?> toJson() => {
    'snapshotId': snapshotId,
    'restoredFiles': restoredFiles,
    'safetySnapshotId': safetySnapshotId,
  };
}

/// 备份验证失败：结构、版本或完整性不通过。任何失败都发生在写入
/// 之前，现有数据不被改变。
final class BackupValidationException implements Exception {
  const BackupValidationException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// 字节级原子写入接缝：temp+rename，与文本原子写同律。导入与快照
/// 恢复共用；测试可注入失败模拟中断。
abstract interface class BackupByteWriter {
  Future<void> write(String targetPath, Uint8List bytes);
}

final class IoBackupByteWriter implements BackupByteWriter {
  const IoBackupByteWriter();

  @override
  Future<void> write(String targetPath, Uint8List bytes) async {
    final target = File(targetPath);
    await target.parent.create(recursive: true);
    final temporary = File(
      '$targetPath.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(targetPath);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }
}

final _sessionMetaMarkerPattern = RegExp(
  r'^<!-- qiyu-session:([A-Za-z0-9_-]+) -->\r?$',
  multiLine: true,
);

/// Markdown 备份导出与导入（ticket 22）。
///
/// 纪律：
/// - 导出只收记忆目录内的原始会话、派生记忆、用户控制与必要状态
///   （sessions、episodes、热层、persona-tree、dream 状态与备份），
///   绝不包含 API Key、宿主凭据、Provider 配置、缓存、日志、损坏
///   隔离区与快照本身；
/// - 备份是可读 Markdown 文件 + 人类可读清单，不依赖数据库工具检查；
/// - 导入前完整验证结构、版本与 sha256 完整性，并展示与本机数据
///   的差异（新增/替换/冲突/跳过/不可恢复），默认不静默覆盖；
/// - 确认导入时先创建可回滚快照，再逐文件 temp+rename 原子写入；
///   中途失败按快照恢复，现有数据保持原样；
/// - 导入后按现行（含并集合并后的）禁提与删除控制再清除一遍派生
///   内容，冲突一律取更保守的隐私结果；
/// - 不兼容或损坏备份在写入前被拒绝。
final class MemoryBackupService {
  MemoryBackupService({
    required this.memoryDirectory,
    required this.memoryControls,
    required this.episodePipeline,
    required this.personaTree,
    required this.memoryActions,
    EpisodeIndexStore? indexStore,
    Clock? clock,
    BackupByteWriter? byteWriter,
    void Function(String message)? diagnosticsSink,
  }) : _indexStore = indexStore ??
           EpisodeIndexStore(
             memoryDirectory: memoryDirectory,
             episodePipeline: episodePipeline,
           ),
       _clock = clock ?? DateTime.now,
       _byteWriter = byteWriter ?? const IoBackupByteWriter(),
       _diagnosticsSink = diagnosticsSink ?? stderrDiagnostics;

  final String memoryDirectory;
  final MemoryControlsStore memoryControls;
  final EpisodeMemoryPipeline episodePipeline;
  final PersonaTreeStore personaTree;
  final MemoryActionService memoryActions;
  final EpisodeIndexStore _indexStore;
  final Clock _clock;
  final BackupByteWriter _byteWriter;
  final void Function(String) _diagnosticsSink;

  Directory get _backupsDirectory =>
      Directory(path.join(memoryDirectory, 'backups'));

  // ---------- 导出 ----------

  /// 把记忆目录打包为 zip：manifest.md（版本、时间、sha256 清单与
  /// 人类可读说明）+ memory/ 镜像。
  Future<MemoryBackupExport> exportBundle() async {
    final generatedAt = _clock().toUtc();
    final files = await _collectExportFiles();
    final manifestEntries = [
      for (final MapEntry(:key, :value) in files.entries)
        {
          'path': 'memory/$key',
          'bytes': value.length,
          'sha256': sha256.convert(value).toString(),
        },
    ];
    final manifestJson = {
      'kind': 'qiyu-memory-backup',
      'schemaVersion': backupSchemaVersion,
      'generatedAt': generatedAt.toIso8601String(),
      'fileCount': manifestEntries.length,
      'files': manifestEntries,
    };
    final manifestContent = _renderManifest(manifestJson, files);

    final archive = Archive();
    final manifestBytes = Uint8List.fromList(utf8.encode(manifestContent));
    archive.addFile(
      ArchiveFile('manifest.md', manifestBytes.length, manifestBytes),
    );
    for (final MapEntry(:key, :value) in files.entries) {
      archive.addFile(ArchiveFile('memory/$key', value.length, value));
    }
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final stamp = generatedAt
        .toIso8601String()
        .replaceAll(RegExp(r'[-:]'), '')
        .replaceAll('.000', '');
    return MemoryBackupExport(
      bytes: bytes,
      fileName: 'qiyu-backup-$stamp.zip',
    );
  }

  /// 导出范围：记忆目录内白名单路径的全部文件。恢复隔离区、快照、
  /// Dream 草稿与诊断档案、临时文件一律不导出。
  Future<Map<String, Uint8List>> _collectExportFiles() async {
    final root = Directory(memoryDirectory);
    final files = <String, Uint8List>{};
    if (!await root.exists()) {
      return files;
    }
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final relative = path
          .relative(entity.path, from: memoryDirectory)
          .replaceAll(r'\', '/');
      if (!_allowedMemoryPath(relative)) {
        continue;
      }
      try {
        files[relative] = await entity.readAsBytes();
      } on Object catch (error) {
        _diagnosticsSink('backup export skipped unreadable file [$error]');
      }
    }
    return files;
  }

  String _renderManifest(
    Map<String, Object?> manifestJson,
    Map<String, Uint8List> files,
  ) {
    final buffer = StringBuffer()
      ..writeln('# 栖语记忆备份')
      ..writeln()
      ..writeln('$_manifestMarker${_encodeJson(manifestJson)} -->')
      ..writeln()
      ..writeln('## 这份备份是什么')
      ..writeln()
      ..writeln(
        '这是栖语在本机的完整记忆备份：原始会话、整理后的每日记录与索引、'
        '长期印象、画像树、关系与近日状态、记忆控制，以及 Dream 状态与备份。'
        '全部是纯 Markdown 文件，用任何文本编辑器都可以直接打开检查。',
      )
      ..writeln()
      ..writeln('## 不包含的内容')
      ..writeln()
      ..writeln(
        'API Key 与模型凭据保存在系统凭据库，从不写入记忆目录，因此绝不'
        '会出现在备份里；宿主配置、缓存、日志、损坏隔离区与历史快照'
        '同样不包含。',
      )
      ..writeln()
      ..writeln('## 如何导入')
      ..writeln()
      ..writeln(
        '在栖语记忆页选择「导入备份」。导入前会先验证版本与完整性，并展示'
        '与本机数据的差异；确认后先创建可回滚快照，再写入。本机已有的'
        '禁提与删除控制会继续生效。',
      )
      ..writeln()
      ..writeln('## 文件清单（${files.length} 份）')
      ..writeln();
    final paths = files.keys.toList()..sort();
    for (final relative in paths) {
      final size = files[relative]!.length;
      buffer.writeln('- memory/$relative（${_humanSize(size)}）');
    }
    return buffer.toString();
  }

  // ---------- 验证 ----------

  /// 完整验证备份包并解出文件；任何失败抛 [BackupValidationException]。
  /// 只读操作，不触碰本机数据。返回记忆相对路径 → 字节与清单生成时间。
  Future<({Map<String, Uint8List> files, DateTime generatedAt})>
  _validateBundle(Uint8List bundle) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bundle);
    } on Object {
      throw const BackupValidationException(
        'not-a-backup',
        '这不是有效的栖语备份文件。',
      );
    }
    if (archive.files.isEmpty) {
      throw const BackupValidationException(
        'not-a-backup',
        '这不是有效的栖语备份文件。',
      );
    }
    if (archive.files.length > _maxBackupEntries) {
      throw const BackupValidationException(
        'unexpected-content',
        '备份包含的文件数量超出预期，已拒绝。',
      );
    }

    Map<String, Object?>? manifest;
    final files = <String, Uint8List>{};
    var totalBytes = 0;
    for (final entry in archive.files) {
      if (!entry.isFile) {
        continue;
      }
      final name = entry.name;
      if (!_safeZipEntryName(name)) {
        throw const BackupValidationException(
          'unexpected-content',
          '备份包含不安全的文件路径，已拒绝。',
        );
      }
      final bytes = Uint8List.fromList(entry.content as List<int>);
      totalBytes += bytes.length;
      if (totalBytes > _maxBackupTotalBytes) {
        throw const BackupValidationException(
          'unexpected-content',
          '备份解压后的体积超出预期，已拒绝。',
        );
      }
      if (name == 'manifest.md') {
        manifest = _parseManifest(utf8.decode(bytes, allowMalformed: false));
        continue;
      }
      files[name] = bytes;
    }
    if (manifest == null) {
      throw const BackupValidationException(
        'missing-manifest',
        '备份缺少清单，无法验证来源与完整性。',
      );
    }
    final schemaVersion = manifest['schemaVersion'];
    if (schemaVersion != backupSchemaVersion) {
      throw const BackupValidationException(
        'incompatible-version',
        '备份版本与当前栖语不兼容，已拒绝。',
      );
    }

    final declaredRaw = manifest['files'];
    if (declaredRaw is! List<Object?>) {
      throw const BackupValidationException(
        'missing-manifest',
        '备份清单不完整，无法验证。',
      );
    }
    final declared = <String, ({int bytes, String sha256})>{};
    for (final item in declaredRaw) {
      if (item is! Map<String, Object?>) {
        throw const BackupValidationException(
          'missing-manifest',
          '备份清单不完整，无法验证。',
        );
      }
      final entryPath = item['path'];
      final entryBytes = item['bytes'];
      final entrySha = item['sha256'];
      if (entryPath is! String || entryBytes is! int || entrySha is! String) {
        throw const BackupValidationException(
          'missing-manifest',
          '备份清单不完整，无法验证。',
        );
      }
      declared['memory/$entryPath'.replaceFirst(RegExp('^memory/'), '')] =
          (bytes: entryBytes, sha256: entrySha);
    }
    // 清单与包内文件必须完全一致：缺失、多余都按损坏拒绝。
    final declaredNames = declared.keys.toSet();
    final actualNames = files.keys.toSet();
    if (!declaredNames.containsAll(actualNames) ||
        !actualNames.containsAll(declaredNames)) {
      throw const BackupValidationException(
        'integrity-mismatch',
        '备份文件与清单不一致，已拒绝。',
      );
    }
    for (final MapEntry(:key, :value) in declared.entries) {
      final content = files[key];
      if (content == null ||
          content.length != value.bytes ||
          sha256.convert(content).toString() != value.sha256) {
        throw const BackupValidationException(
          'integrity-mismatch',
          '备份完整性校验未通过，已拒绝。',
        );
      }
      final relative = key.substring('memory/'.length);
      if (!key.startsWith('memory/') || !_allowedMemoryPath(relative)) {
        throw const BackupValidationException(
          'unexpected-content',
          '备份包含记忆范围之外的文件，已拒绝。',
        );
      }
    }

    final generatedAtRaw = manifest['generatedAt'];
    DateTime generatedAt;
    if (generatedAtRaw is! String) {
      throw const BackupValidationException(
        'missing-manifest',
        '备份清单缺少生成时间，无法验证。',
      );
    }
    try {
      generatedAt = DateTime.parse(generatedAtRaw).toUtc();
    } on Object {
      throw const BackupValidationException(
        'missing-manifest',
        '备份清单的生成时间无法读取，已拒绝。',
      );
    }

    return (
      files: {
        for (final MapEntry(:key, :value) in files.entries)
          key.substring('memory/'.length): value,
      },
      generatedAt: generatedAt,
    );
  }

  Map<String, Object?> _parseManifest(String contents) {
    try {
      final start = contents.indexOf(_manifestMarker);
      if (start < 0) {
        throw const FormatException('manifest marker missing');
      }
      final payloadStart = start + _manifestMarker.length;
      final payloadEnd = contents.indexOf(' -->', payloadStart);
      if (payloadEnd < 0) {
        throw const FormatException('manifest marker unterminated');
      }
      final json = _decodeJson(
        contents.substring(payloadStart, payloadEnd).trim(),
      );
      if (json['kind'] != 'qiyu-memory-backup') {
        throw const FormatException('manifest kind mismatch');
      }
      return json;
    } on FormatException {
      throw const BackupValidationException(
        'missing-manifest',
        '备份清单无法读取，已拒绝。',
      );
    }
  }

  bool _safeZipEntryName(String name) {
    if (name.isEmpty || name.startsWith('/') || name.contains(r'\')) {
      return false;
    }
    for (final segment in name.split('/')) {
      if (segment.isEmpty || segment == '.' || segment == '..') {
        return false;
      }
    }
    return true;
  }

  /// 记忆目录内允许进入备份的相对路径（导出与导入共用同一白名单）。
  bool _allowedMemoryPath(String relative) {
    const rootFiles = {
      'persona.md',
      'relationship.md',
      'open-loops.md',
      'open-loops.archive.md',
      'daily-state.md',
      'long-memory.md',
      'memory-controls.md',
    };
    if (relative.endsWith('.tmp')) {
      return false;
    }
    if (rootFiles.contains(relative)) {
      return true;
    }
    return relative.startsWith('persona-tree/') ||
        relative.startsWith('episodes/') ||
        relative.startsWith('sessions/') ||
        relative == 'dream/state.md' ||
        relative.startsWith('dream/backup/');
  }

  // ---------- 差异预览 ----------

  /// 导入前验证与差异展示；只读，不写任何文件、不创建快照。
  Future<MemoryBackupPreview> previewImport(Uint8List bundle) async {
    final validated = await _validateBundle(bundle);
    return _diff(validated.files, validated.generatedAt);
  }

  Future<MemoryBackupPreview> _diff(
    Map<String, Uint8List> files,
    DateTime generatedAt,
  ) async {
    final currentControls = await memoryControls.load();
    MemoryControls? backupControls;
    final backupControlsBytes = files['memory-controls.md'];
    if (backupControlsBytes != null) {
      try {
        backupControls = parseMemoryControls(
          utf8.decode(backupControlsBytes),
        );
      } on Object {
        backupControls = const MemoryControls(readable: false);
      }
      if (!backupControls.readable) {
        throw const BackupValidationException(
          'unexpected-content',
          '备份中的记忆控制记录无法读取，已拒绝。',
        );
      }
    }

    String controlsMerge;
    if (backupControls == null) {
      controlsMerge = 'none';
    } else {
      final merged = _mergeControls(currentControls, backupControls);
      controlsMerge = merged.changed ? 'union' : 'identical';
    }

    final items = <MemoryBackupPreviewItem>[];
    final paths = files.keys.toList()..sort();
    for (final relative in paths) {
      if (relative == 'memory-controls.md') {
        continue; // 控制记录走并集合并，不按文件替换。
      }
      final backupBytes = files[relative]!;
      if (!_sessionStructurallyValid(relative, backupBytes)) {
        items.add(
          MemoryBackupPreviewItem(
            path: relative,
            category: BackupItemCategory.unrecoverable,
            note: '备份中的会话结构无法识别，未导入',
          ),
        );
        continue;
      }
      final currentFile = File(path.join(memoryDirectory, relative));
      final exists = await currentFile.exists();
      if (!exists) {
        items.add(
          MemoryBackupPreviewItem(
            path: relative,
            category: BackupItemCategory.added,
          ),
        );
        continue;
      }
      Uint8List? currentBytes;
      try {
        currentBytes = await currentFile.readAsBytes();
      } on Object {
        currentBytes = null;
      }
      if (currentBytes != null && _bytesEqual(currentBytes, backupBytes)) {
        items.add(
          MemoryBackupPreviewItem(
            path: relative,
            category: BackupItemCategory.skipped,
          ),
        );
        continue;
      }
      if (relative.startsWith('sessions/')) {
        // 同名原始会话内容不同：两边都是唯一原始证据，保守做法是
        // 保留本机版本，备份版本不覆盖也不导入。
        items.add(
          MemoryBackupPreviewItem(
            path: relative,
            category: BackupItemCategory.conflict,
            note: '本机已有同名原始会话，保留本机版本',
          ),
        );
        continue;
      }
      items.add(
        MemoryBackupPreviewItem(
          path: relative,
          category: BackupItemCategory.replaced,
        ),
      );
    }
    if (backupControls != null) {
      items.add(
        MemoryBackupPreviewItem(
          path: 'memory-controls.md',
          category: controlsMerge == 'identical'
              ? BackupItemCategory.skipped
              : BackupItemCategory.replaced,
          note: controlsMerge == 'identical'
              ? '与本机控制记录一致'
              : '与本机控制记录按并集合并，保留更保守的隐私结果',
        ),
      );
    }

    return MemoryBackupPreview(
      schemaVersion: backupSchemaVersion,
      generatedAt: generatedAt,
      controlsMerge: controlsMerge,
      items: items,
    );
  }

  // ---------- 导入 ----------

  /// 确认后执行导入：重新验证 → 快照当前状态 → 原子写入 → 合并控制
  /// 并按现行控制清除派生内容 → 重建索引。中途失败按快照恢复。
  Future<MemoryBackupImportResult> importBundle(Uint8List bundle) async {
    final validated = await _validateBundle(bundle);
    final files = validated.files;
    final preview = await _diff(files, validated.generatedAt);
    final snapshotId = await _createSnapshot();

    try {
      // 控制纪律（Memory.md 写入边界）：先落控制记录，再写内容文件。
      // 备份带来的控制与本机按并集合并；中断在两步之间时，留下的是
      // 更保守的控制集合而不是更少的控制。
      var controlsMerged = false;
      final backupControlsBytes = files['memory-controls.md'];
      if (backupControlsBytes != null) {
        final currentControls = await memoryControls.load();
        final backupControls = parseMemoryControls(
          utf8.decode(backupControlsBytes),
        );
        if (!currentControls.readable || !backupControls.readable) {
          throw const BackupValidationException(
            'unexpected-content',
            '记忆控制记录当前无法安全合并，导入中止。',
          );
        }
        final merged = _mergeControls(currentControls, backupControls);
        if (merged.changed) {
          if (!await memoryControls.replaceForRecovery(merged.controls)) {
            throw const BackupValidationException(
              'unexpected-content',
              '记忆控制记录写入失败，导入中止。',
            );
          }
          controlsMerged = true;
        }
      }

      var added = 0;
      var replaced = 0;
      var skipped = 0;
      var conflicts = 0;
      var unrecoverable = 0;
      for (final item in preview.items) {
        if (item.path == 'memory-controls.md') {
          continue;
        }
        switch (item.category) {
          case BackupItemCategory.added:
            await _byteWriter.write(
              path.join(memoryDirectory, item.path),
              files[item.path]!,
            );
            added += 1;
          case BackupItemCategory.replaced:
            await _byteWriter.write(
              path.join(memoryDirectory, item.path),
              files[item.path]!,
            );
            replaced += 1;
          case BackupItemCategory.skipped:
            skipped += 1;
          case BackupItemCategory.conflict:
            conflicts += 1;
          case BackupItemCategory.unrecoverable:
            unrecoverable += 1;
        }
      }

      // 导入可能带回上次备份之后已被删除/禁提的内容：按合并后的
      // 控制集合再清除一遍派生层，绝不让被控内容随备份复活。
      final effectiveControls = await memoryControls.load();
      if (effectiveControls.readable) {
        for (final entry in [
          ...effectiveControls.banned,
          ...effectiveControls.deleted,
        ]) {
          try {
            await memoryActions.purgeDerivedScopes(
              {normalizeMemoryText(entry.summary)},
              text: entry.summary,
            );
          } on Object catch (error) {
            _diagnosticsSink('backup import purge deferred [$error]');
          }
        }
      }

      try {
        await episodePipeline.synchronizedOnDayFiles(
          () => _indexStore.rebuild(includeUnfinalized: true),
        );
      } on Object catch (error) {
        _diagnosticsSink('backup import index rebuild deferred [$error]');
      }
      try {
        final snapshot = await personaTree.readSnapshot();
        final allReadable = snapshot.branches.values.every(
          (branch) => branch.readable,
        );
        if (allReadable) {
          await personaTree.regeneratePersonaProjection();
        }
      } on Object catch (error) {
        _diagnosticsSink('backup import persona refresh deferred [$error]');
      }

      await _pruneSnapshots();
      return MemoryBackupImportResult(
        added: added,
        replaced: replaced,
        skipped: skipped,
        conflicts: conflicts,
        unrecoverable: unrecoverable,
        controlsMerged: controlsMerged,
        snapshotId: snapshotId,
      );
    } on Object catch (error) {
      // 导入失败：按刚创建的快照恢复原样，绝不留下半导入状态。
      try {
        await _restoreSnapshot(snapshotId);
      } on Object catch (restoreError) {
        _diagnosticsSink(
          'backup import rollback deferred [$restoreError]',
        );
      }
      if (error is BackupValidationException) {
        rethrow;
      }
      _diagnosticsSink('backup import deferred [$error]');
      throw const BackupValidationException(
        'import-failed',
        '导入没有完成，本机数据已恢复到导入前的状态。',
      );
    }
  }

  /// 控制记录并集合并：冻结、禁提、删除分别按规范化摘要取并集，
  /// 冲突一律保留更多控制（更保守的隐私结果）。
  ({MemoryControls controls, bool changed}) _mergeControls(
    MemoryControls current,
    MemoryControls backup,
  ) {
    List<MemoryControlEntry> mergeSection(
      List<MemoryControlEntry> currentEntries,
      List<MemoryControlEntry> backupEntries,
    ) {
      final seen = <String>{};
      final result = <MemoryControlEntry>[];
      for (final entry in [...currentEntries, ...backupEntries]) {
        final normalized = normalizeMemoryText(entry.summary);
        if (normalized.isEmpty || !seen.add(normalized)) {
          continue;
        }
        result.add(entry);
      }
      return result;
    }

    final frozen = mergeSection(current.frozen, backup.frozen);
    final banned = mergeSection(current.banned, backup.banned);
    final deleted = mergeSection(current.deleted, backup.deleted);
    var nextId = 1;
    MemoryControlEntry renumber(MemoryControlEntry entry) =>
        MemoryControlEntry(
          id: nextId++,
          origin: entry.origin,
          summary: entry.summary,
        );
    final merged = MemoryControls(
      readable: true,
      frozen: [for (final entry in frozen) renumber(entry)],
      banned: [for (final entry in banned) renumber(entry)],
      deleted: [for (final entry in deleted) renumber(entry)],
    );
    final changed = frozen.length != current.frozen.length ||
        banned.length != current.banned.length ||
        deleted.length != current.deleted.length;
    return (controls: merged, changed: changed);
  }

  /// sessions 层文件的最低结构校验：必须可 UTF-8 解码且带可解析的
  /// 会话头标记，否则归为不可恢复、不导入。
  bool _sessionStructurallyValid(String relative, Uint8List bytes) {
    if (!relative.startsWith('sessions/')) {
      return true;
    }
    String contents;
    try {
      contents = utf8.decode(bytes);
    } on Object {
      return false;
    }
    final match = _sessionMetaMarkerPattern.firstMatch(contents);
    if (match == null) {
      return false;
    }
    try {
      _decodeJson(match.group(1)!);
      return true;
    } on Object {
      return false;
    }
  }

  // ---------- 快照与回滚 ----------

  var _snapshotSequence = 0;

  /// 给当前记忆目录整体拍快照（快照目录自身除外）。全部文件落盘后
  /// 才写完成标记；没有完成标记的快照不参与回滚。快照是运行时产物，
  /// ID 与时间用真实时钟并附加实例内序号，固定时钟环境下也不冲突。
  Future<String> _createSnapshot() async {
    final now = DateTime.now().toUtc();
    _snapshotSequence += 1;
    final id = '${now.microsecondsSinceEpoch}-$_snapshotSequence';
    final directory = Directory(path.join(_backupsDirectory.path, id));
    await directory.create(recursive: true);
    var fileCount = 0;
    final root = Directory(memoryDirectory);
    if (await root.exists()) {
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) {
          continue;
        }
        final relative = path
            .relative(entity.path, from: memoryDirectory)
            .replaceAll(r'\', '/');
        if (relative.startsWith('backups/') || relative.endsWith('.tmp')) {
          continue;
        }
        final target = path.join(directory.path, relative);
        await File(target).parent.create(recursive: true);
        await entity.copy(target);
        fileCount += 1;
      }
    }
    final marker = {
      'kind': 'qiyu-memory-snapshot',
      'id': id,
      'createdAt': now.toIso8601String(),
      'fileCount': fileCount,
    };
    await File(path.join(directory.path, 'snapshot.md')).writeAsString(
      '# 栖语导入前快照\n\n$_snapshotMarker${_encodeJson(marker)} -->\n',
      encoding: utf8,
      flush: true,
    );
    return id;
  }

  Future<List<MemoryBackupSnapshotInfo>> listSnapshots() async {
    final directory = _backupsDirectory;
    if (!await directory.exists()) {
      return const [];
    }
    final snapshots = <MemoryBackupSnapshotInfo>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final info = await _readSnapshotInfo(entity);
      if (info != null) {
        snapshots.add(info);
      }
    }
    snapshots.sort((left, right) => right.createdAt.compareTo(left.createdAt));
    return snapshots;
  }

  Future<MemoryBackupSnapshotInfo?> _readSnapshotInfo(
    Directory directory,
  ) async {
    final marker = File(path.join(directory.path, 'snapshot.md'));
    if (!await marker.exists()) {
      return null;
    }
    try {
      final contents = await marker.readAsString(encoding: utf8);
      final start = contents.indexOf(_snapshotMarker);
      if (start < 0) {
        return null;
      }
      final payloadStart = start + _snapshotMarker.length;
      final payloadEnd = contents.indexOf(' -->', payloadStart);
      if (payloadEnd < 0) {
        return null;
      }
      final json = _decodeJson(
        contents.substring(payloadStart, payloadEnd).trim(),
      );
      final id = json['id'];
      final createdAt = json['createdAt'];
      final fileCount = json['fileCount'];
      if (id is! String || createdAt is! String || fileCount is! int) {
        return null;
      }
      return MemoryBackupSnapshotInfo(
        id: id,
        createdAt: DateTime.parse(createdAt).toUtc(),
        fileCount: fileCount,
      );
    } on Object {
      return null;
    }
  }

  /// 回滚到指定快照（缺省为最近一份）：回滚前先给当前状态拍一份
  /// 保底快照，再逐文件恢复，并清理快照中不存在的文件。
  Future<MemoryBackupRollbackResult> rollbackTo([String? snapshotId]) async {
    final snapshots = await listSnapshots();
    if (snapshots.isEmpty) {
      throw const BackupValidationException(
        'snapshot-not-found',
        '没有可回滚的快照。',
      );
    }
    final target = snapshotId == null
        ? snapshots.first
        : snapshots.where((snapshot) => snapshot.id == snapshotId).firstOrNull;
    if (target == null) {
      throw const BackupValidationException(
        'snapshot-not-found',
        '指定的快照不存在。',
      );
    }
    final safetySnapshotId = await _createSnapshot();
    final restored = await _restoreSnapshot(target.id);
    await _pruneSnapshots();
    return MemoryBackupRollbackResult(
      snapshotId: target.id,
      restoredFiles: restored,
      safetySnapshotId: safetySnapshotId,
    );
  }

  Future<int> _restoreSnapshot(String snapshotId) async {
    final directory = Directory(
      path.join(_backupsDirectory.path, snapshotId),
    );
    if (!await directory.exists() ||
        await _readSnapshotInfo(directory) == null) {
      // 没有完成标记的快照是半成品：绝不拿它做恢复来源。
      throw const BackupValidationException(
        'snapshot-not-found',
        '指定的快照不完整，无法恢复。',
      );
    }
    final snapshotFiles = <String, Uint8List>{};
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }
      final relative = path
          .relative(entity.path, from: directory.path)
          .replaceAll(r'\', '/');
      if (relative == 'snapshot.md') {
        continue;
      }
      snapshotFiles[relative] = await entity.readAsBytes();
    }
    for (final MapEntry(:key, :value) in snapshotFiles.entries) {
      await _byteWriter.write(path.join(memoryDirectory, key), value);
    }
    // 清理快照中不存在的文件（导入后新增的），快照本身不动。
    final root = Directory(memoryDirectory);
    if (await root.exists()) {
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) {
          continue;
        }
        final relative = path
            .relative(entity.path, from: memoryDirectory)
            .replaceAll(r'\', '/');
        if (relative.startsWith('backups/') || relative.endsWith('.tmp')) {
          continue;
        }
        if (!snapshotFiles.containsKey(relative)) {
          try {
            await entity.delete();
          } on Object catch (error) {
            _diagnosticsSink('snapshot restore cleanup deferred [$error]');
          }
        }
      }
    }
    try {
      await episodePipeline.synchronizedOnDayFiles(
        () => _indexStore.rebuild(includeUnfinalized: true),
      );
    } on Object catch (error) {
      _diagnosticsSink('snapshot restore index rebuild deferred [$error]');
    }
    return snapshotFiles.length;
  }

  /// 只保留最近 [_snapshotKeepCount] 份有效快照。
  Future<void> _pruneSnapshots() async {
    try {
      final snapshots = await listSnapshots();
      if (snapshots.length <= _snapshotKeepCount) {
        return;
      }
      for (final snapshot in snapshots.skip(_snapshotKeepCount)) {
        final directory = Directory(
          path.join(_backupsDirectory.path, snapshot.id),
        );
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    } on Object catch (error) {
      _diagnosticsSink('snapshot prune deferred [$error]');
    }
  }

  // ---------- 小工具 ----------

  bool _bytesEqual(Uint8List left, Uint8List right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

String _encodeJson(Map<String, Object?> value) =>
    base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

Map<String, Object?> _decodeJson(String value) {
  final padded = value.padRight(value.length + (4 - value.length % 4) % 4, '=');
  return jsonDecode(utf8.decode(base64Url.decode(padded)))
      as Map<String, Object?>;
}
