import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' show Digest, sha256;
import 'package:path/path.dart' as path;

import 'episode_index.dart';
import 'episode_memory.dart';
import 'markdown_memory_repository.dart';
import 'memory_actions.dart';
import 'memory_controls.dart';
import 'memory_marker_codec.dart';
import 'memory_text_primitives.dart';
import 'persona_tree.dart';

part 'memory_backup_zip_preflight.dart';

/// 备份包 schema 版本：导入时只接受完全一致的版本，不兼容即拒绝。
const backupSchemaVersion = 1;

/// 备份包内的清单标记（与记忆文件同一 base64url 约定）。
const _manifestMarker = '<!-- qiyu-backup-manifest:';
const _snapshotMarker = '<!-- qiyu-backup-snapshot:';

/// 备份/快照内文件数量、解压总量、单项解压量与目录元数据量的保守
/// 上限：本机备份防御异常大包与高压缩炸弹，不是存储限额。
const _maxBackupEntries = 20000;
const _maxBackupTotalBytes = 1 << 30;
const _maxBackupEntryBytes = 64 << 20;
const _maxBackupMetadataBytes = 8 << 20;

/// 受限解压的喂入块大小：输出经解码器固定内部缓冲逐块到达受限接收
/// 器，喂入块只影响中断粒度与事件循环节奏，不影响内存上界。
const _extractFeedChunkBytes = 256 * 1024;

/// 备份解压预算：预览与导入共用。默认值即生产上限；测试可注入小预算
/// 在安全资源规模内验证拒绝机制，不必真实撑大内存或磁盘。
final class MemoryBackupBudget {
  const MemoryBackupBudget({
    this.maxEntries = _maxBackupEntries,
    this.maxTotalBytes = _maxBackupTotalBytes,
    this.maxEntryBytes = _maxBackupEntryBytes,
    this.maxMetadataBytes = _maxBackupMetadataBytes,
  });

  /// 包内条目数量上限（含目录占位条目）。
  final int maxEntries;

  /// 全部条目解压输出的总量上限。
  final int maxTotalBytes;

  /// 单个条目解压输出的上限。
  final int maxEntryBytes;

  /// 中心目录名称、条目注释与扩展字段的总字节数上限。
  /// 可选目录签名记录的完整字节也计入此预算。
  /// 本地头扩展字段另用同量上限；本地名称须与中央名称逐字节一致。
  final int maxMetadataBytes;
}

/// 快照保留份数：导入与回滚都会新增快照，只保留最近几份。
const _snapshotKeepCount = 5;

/// 备份结构无效（不是 zip 或空包）的统一拒绝码与文案。
BackupValidationException _notABackup() => const BackupValidationException(
  'not-a-backup',
  '这不是有效的栖语备份文件。',
);

/// 备份清单缺失或条目不完整的统一拒绝码与文案。
BackupValidationException _manifestIncomplete() =>
    const BackupValidationException(
      'missing-manifest',
      '备份清单不完整，无法验证。',
    );

/// 恢复未完成的统一拒绝码与文案：恢复写回或必要清理未完成时，本机
/// 数据不能声称已回到目标状态；快照保留在本机，可再次恢复。
BackupValidationException _restoreIncomplete() =>
    const BackupValidationException(
      'restore-incomplete',
      '恢复没有完成，本机数据可能没有回到目标状态。快照已保留，可以稍后重试恢复。',
    );

/// 取备份文件里标记（`<!-- qiyu-backup-*:payload -->`）内嵌的载荷并
/// 解码；标记缺失或未闭合返回 null。清单与快照读取共用同一提取，
/// 载荷解码失败原样抛出，错误翻译留在各自调用侧。
Map<String, Object?>? _markerPayloadOrNull(String contents, String marker) {
  final start = contents.indexOf(marker);
  if (start < 0) {
    return null;
  }
  final payloadStart = start + marker.length;
  final payloadEnd = contents.indexOf(' -->', payloadStart);
  if (payloadEnd < 0) {
    return null;
  }
  return decodeMarkerPayload(
    contents.substring(payloadStart, payloadEnd).trim(),
  );
}

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

/// 备份领域对外的统一拒绝码：验证失败（结构、版本或完整性不通过，
/// 发生在写入之前，现有数据不被改变），以及导入中止、恢复未完成等
/// 写入之后如实反馈结果的失败。对外统一按同一错误 JSON 结构返回。
final class BackupValidationException implements Exception {
  const BackupValidationException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// 解压预算超限的内部信号：统一在提取入口翻译为现有的
/// unexpected-content 对外拒绝码，不新增对外错误类别。
final class _BudgetExceededException implements Exception {
  const _BudgetExceededException();
}

/// 受限解压的跨条目总账：同一包内所有条目的接收器共享一份累计值。
final class _ExtractionProgress {
  int totalWritten = 0;
}

/// 受限解压输出接收器：逐块累计条目与总量、滚动摘要并同步写临时
/// 文件；任一预算超限立即抛出，解压在产出一个内部缓冲之前终止，
/// 绝不在接收器内聚合整项输出。
final class _BoundedExtractSink implements Sink<List<int>> {
  _BoundedExtractSink({
    required this.handle,
    required this.hashSink,
    required this.entryLimit,
    required this.totalLimit,
    required this.progress,
  });

  final RandomAccessFile handle;
  final ByteConversionSink hashSink;
  final int entryLimit;
  final int totalLimit;
  final _ExtractionProgress progress;

  int entryWritten = 0;

  @override
  void add(List<int> chunk) {
    entryWritten += chunk.length;
    progress.totalWritten += chunk.length;
    if (entryWritten > entryLimit || progress.totalWritten > totalLimit) {
      throw const _BudgetExceededException();
    }
    hashSink.add(chunk);
    handle.writeFromSync(chunk);
  }

  @override
  void close() {}
}

/// sha256 滚动计算的收口：close 之后取最终摘要。
final class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 受限解压的完成态：隔离临时目录、记忆相对路径 → 临时文件与清单
/// 生成时间。临时目录由调用方用完负责清理。
final class _ExtractedBundle {
  const _ExtractedBundle({
    required this.directory,
    required this.files,
    required this.generatedAt,
  });

  final Directory directory;
  final Map<String, File> files;
  final DateTime generatedAt;
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

// 会话元数据标记（读取端）统一取自 memory_marker_codec.dart
//（唯一权威，禁止另写变体副本）。

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
    this.budget = const MemoryBackupBudget(),
    void Function(String message)? diagnosticsSink,
    Future<void> Function(String targetPath)? restoreFileDeleter,
  }) : _indexStore = indexStore ??
           EpisodeIndexStore(
             memoryDirectory: memoryDirectory,
             episodePipeline: episodePipeline,
           ),
       _clock = clock ?? DateTime.now,
       _byteWriter = byteWriter ?? const IoBackupByteWriter(),
       _restoreFileDeleter = restoreFileDeleter ?? _deleteMemoryFile,
       _diagnosticsSink = diagnosticsSink ?? stderrDiagnostics;

  final String memoryDirectory;
  final MemoryControlsStore memoryControls;
  final EpisodeMemoryPipeline episodePipeline;
  final PersonaTreeStore personaTree;
  final MemoryActionService memoryActions;
  final EpisodeIndexStore _indexStore;
  final Clock _clock;
  final BackupByteWriter _byteWriter;

  /// 恢复清理的删除接缝：清理「快照中不存在的文件」时使用，默认
  /// 直接删除真实文件；与字节写入接缝同构，测试可注入删除失败模拟
  /// 清理中断。
  final Future<void> Function(String targetPath) _restoreFileDeleter;

  /// 不可信备份包的解压预算：超限在写入任何产品数据之前拒绝。
  final MemoryBackupBudget budget;
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
    final diskFiles = await _listRelativeFiles(Directory(memoryDirectory));
    final files = <String, Uint8List>{};
    for (final MapEntry(:key, :value) in diskFiles.entries) {
      if (!_allowedMemoryPath(key)) {
        continue;
      }
      try {
        files[key] = await _exportFileBytes(key, value);
      } on Object catch (error) {
        _diagnosticsSink('backup export skipped unreadable file [$error]');
      }
    }
    return files;
  }

  /// 导出读取：全部记忆文件先过导出脱敏——可见文本、`qiyu-*` 标记
  /// 载荷里的自由文本与控制记录摘要共用会话脱敏规则，结构标记
  /// （控制记录的段与条目前缀）不受影响；未命中替换时保持原始字节
  /// （正常往返逐字节一致），文本解不开的文件跳过不导出。
  Future<Uint8List> _exportFileBytes(String relative, File file) async {
    final bytes = await file.readAsBytes();
    final contents = utf8.decode(bytes, allowMalformed: false);
    final redacted = redactMemoryMarkdown(contents);
    if (redacted == null) {
      return bytes;
    }
    return Uint8List.fromList(utf8.encode(redacted));
  }

  String _renderManifest(
    Map<String, Object?> manifestJson,
    Map<String, Uint8List> files,
  ) {
    final buffer = StringBuffer()
      ..writeln('# 栖语记忆备份')
      ..writeln()
      ..writeln('$_manifestMarker${encodeMarkerPayload(manifestJson)} -->')
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
        'API Key 保存在本机 provider.json（旧版本安装才在系统凭据库留有'
        '回退副本），从不写入记忆目录，因此绝不会出现在备份里；宿主配置、'
        '缓存、日志、损坏隔离区与历史快照同样不包含。',
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

  /// 完整验证备份包并把内容受限解压到隔离临时目录；任何失败抛
  /// [BackupValidationException]，临时目录整体清理，本机数据不被
  /// 触碰。返回记忆相对路径 → 临时文件与清单生成时间。
  ///
  /// 核验顺序（先验目录与声明，再按真实解压输出逐块计数）：原始目录
  /// 与本地头预算、范围预检 → 成熟解析器 → 路径与条目形态 → 清单与声明值 →
  /// 逐条受限解压并核对真实大小与摘要。声明值只用于提前拒绝，不能
  /// 替代实际计数。
  Future<_ExtractedBundle> _extractValidatedBundle(Uint8List bundle) async {
    _BackupZipPreflight(bundle, budget).validate();
    final zipDirectory = ZipDirectory();
    try {
      zipDirectory.read(InputMemoryStream(bundle));
    } on Object {
      throw _notABackup();
    }
    if (zipDirectory.filePosition < 0 || zipDirectory.fileHeaders.isEmpty) {
      throw _notABackup();
    }

    final headers = zipDirectory.fileHeaders;
    if (headers.length > budget.maxEntries) {
      throw const BackupValidationException(
        'unexpected-content',
        '备份包含的文件数量超出预期，已拒绝。',
      );
    }

    // 中心目录预检：条目名称、形态与声明尺寸，全部发生在任何内容
    // 解压之前。
    var metadataBytes = 0;
    var declaredTotalBytes = 0;
    final seenNames = <String>{};
    final contentHeaders = <ZipFileHeader>[];
    ZipFileHeader? manifestHeader;
    for (final header in headers) {
      // 目录元数据按中心目录里的名称、条目注释与扩展字段计，名称与
      // 注释精确按 UTF-8 字节计（按码元数近似会低估非 ASCII 内容，
      // 放大预算）。
      metadataBytes +=
          utf8.encode(header.filename).length +
          utf8.encode(header.fileComment).length +
          (header.extraField?.length ?? 0);
      if (metadataBytes > budget.maxMetadataBytes) {
        throw const BackupValidationException(
          'unexpected-content',
          '备份目录信息超出预期，已拒绝。',
        );
      }
      final name = header.filename;
      if (name.endsWith('/')) {
        continue; // 目录占位条目：只计入数量与元数据，没有内容。
      }
      // 符号链接形态（外部属性高位为链接类型）：栖语备份绝不包含，
      // 且解码器会为读取链接目标而提前解压内容，必须在解析层拒绝。
      if (!_safeZipEntryName(name) ||
          ((header.externalFileAttributes >> 16) & 0xf000) == 0xa000) {
        throw const BackupValidationException(
          'unexpected-content',
          '备份包含不安全的文件路径，已拒绝。',
        );
      }
      if (!seenNames.add(name)) {
        throw const BackupValidationException(
          'integrity-mismatch',
          '备份文件与清单不一致，已拒绝。',
        );
      }
      final file = header.file!;
      // 加密与压缩方式在触碰内容前拒绝：本地头的加密位与归一化后的
      // 方法号只允许未压缩或 deflate；中心目录里的原始方法号同样只认
      // 这两种——加密压缩等无法识别的号段会被解码库归一成未压缩且不
      // 置加密位，只看归一化结果会把密文当明文放行。
      if ((file.flags & 0x1) != 0 ||
          (header.compressionMethod != ZipFile.zipCompressionStore &&
              header.compressionMethod != ZipFile.zipCompressionDeflate) ||
          (file.compressionMethod != CompressionType.none &&
              file.compressionMethod != CompressionType.deflate)) {
        throw const BackupValidationException(
          'unexpected-content',
          '备份包含不支持的加密或压缩方式，已拒绝。',
        );
      }
      if (file.uncompressedSize > budget.maxEntryBytes ||
          (declaredTotalBytes += file.uncompressedSize) >
              budget.maxTotalBytes) {
        throw const BackupValidationException(
          'unexpected-content',
          '备份解压后的体积超出预期，已拒绝。',
        );
      }
      if (name == 'manifest.md') {
        manifestHeader = header;
      } else {
        contentHeaders.add(header);
      }
    }

    if (manifestHeader == null) {
      throw const BackupValidationException(
        'missing-manifest',
        '备份缺少清单，无法验证来源与完整性。',
      );
    }

    final extractionRoot = await Directory.systemTemp.createTemp(
      'qiyu-backup-extract-',
    );
    try {
      final progress = _ExtractionProgress();
      Future<({File file, int bytes, String sha256})> extractVerified(
        ZipFileHeader header,
        int index,
      ) async {
        try {
          return await _extractEntryBounded(
            extractionRoot,
            index,
            header.file!,
            entryLimit: budget.maxEntryBytes,
            totalLimit: budget.maxTotalBytes,
            progress: progress,
          );
        } on _BudgetExceededException {
          throw const BackupValidationException(
            'unexpected-content',
            '备份解压后的体积超出预期，已拒绝。',
          );
        } on Object catch (error) {
          // 预算之外的意外失败（坏压缩流、临时文件读写故障等）不能
          // 无声拒绝：先留诊断再按既有类别对外拒绝；临时文件读写
          // 故障与包本身无关，给出不同的拒绝文案，避免误指备份损坏。
          _diagnosticsSink('backup extraction deferred [$error]');
          if (error is FileSystemException) {
            throw const BackupValidationException(
              'not-a-backup',
              '备份暂时无法读取，请稍后重试。',
            );
          }
          throw _notABackup();
        }
      }

      final manifestExtracted = await extractVerified(manifestHeader, 0);
      final manifest = _parseManifest(
        utf8.decode(await manifestExtracted.file.readAsBytes()),
      );

      final schemaVersion = manifest['schemaVersion'];
      if (schemaVersion != backupSchemaVersion) {
        throw const BackupValidationException(
          'incompatible-version',
          '备份版本与当前栖语不兼容，已拒绝。',
        );
      }

      final declaredRaw = manifest['files'];
      if (declaredRaw is! List<Object?>) {
        throw _manifestIncomplete();
      }
      final declared = <String, ({int bytes, String sha256})>{};
      for (final item in declaredRaw) {
        if (item is! Map<String, Object?>) {
          throw _manifestIncomplete();
        }
        final entryPath = item['path'];
        final entryBytes = item['bytes'];
        final entrySha = item['sha256'];
        if (entryPath is! String || entryBytes is! int || entrySha is! String) {
          throw _manifestIncomplete();
        }
        declared['memory/$entryPath'.replaceFirst(RegExp('^memory/'), '')] = (
          bytes: entryBytes,
          sha256: entrySha,
        );
      }
      // 清单与包内条目必须完全一致：缺失、多余都按损坏拒绝。
      final declaredNames = declared.keys.toSet();
      final actualNames = contentHeaders
          .map((header) => header.filename)
          .toSet();
      if (!declaredNames.containsAll(actualNames) ||
          !actualNames.containsAll(declaredNames)) {
        throw const BackupValidationException(
          'integrity-mismatch',
          '备份文件与清单不一致，已拒绝。',
        );
      }

      final headerByName = {
        for (final header in contentHeaders) header.filename: header,
      };
      for (final MapEntry(:key, :value) in declared.entries) {
        if (!key.startsWith('memory/')) {
          throw const BackupValidationException(
            'unexpected-content',
            '备份包含记忆范围之外的文件，已拒绝。',
          );
        }
        final relative = key.substring('memory/'.length);
        if (!_allowedMemoryPath(relative)) {
          throw const BackupValidationException(
            'unexpected-content',
            '备份包含记忆范围之外的文件，已拒绝。',
          );
        }
        // 清单声明与压缩头部声明的解压尺寸必须一致；两边都说谎的
        // 由受限解压的真实计数兜底。
        if (headerByName[key]!.file!.uncompressedSize != value.bytes) {
          throw const BackupValidationException(
            'integrity-mismatch',
            '备份完整性校验未通过，已拒绝。',
          );
        }
      }

      final files = <String, File>{};
      var index = 1;
      for (final header in contentHeaders) {
        final extracted = await extractVerified(header, index);
        index += 1;
        final name = header.filename;
        final declaredEntry = declared[name]!;
        if (extracted.bytes != declaredEntry.bytes ||
            extracted.sha256 != declaredEntry.sha256) {
          throw const BackupValidationException(
            'integrity-mismatch',
            '备份完整性校验未通过，已拒绝。',
          );
        }
        files[name.substring('memory/'.length)] = extracted.file;
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

      return _ExtractedBundle(
        directory: extractionRoot,
        files: files,
        generatedAt: generatedAt,
      );
    } on Object {
      await _cleanupExtraction(extractionRoot);
      rethrow;
    }
  }

  /// 单个条目的受限解压：压缩数据按块喂入原生 zlib 分块解码器
  /// （store 条目直接按块复制），输出到达受限接收器时逐块计数并同步
  /// 写临时文件，任一预算超限立即抛出中断。临时文件名是平铺序号，
  /// 不使用包内路径。返回临时文件、真实解压字节数与同一遍滚动计算
  /// 的 sha256。
  Future<({File file, int bytes, String sha256})> _extractEntryBounded(
    Directory root,
    int index,
    ZipFile file, {
    required int entryLimit,
    required int totalLimit,
    required _ExtractionProgress progress,
  }) async {
    final target = File(path.join(root.path, index.toString().padLeft(8, '0')));
    final handle = await target.open(mode: FileMode.write);
    final digestCollector = _DigestCollector();
    final hashSink = sha256.startChunkedConversion(digestCollector);
    final sink = _BoundedExtractSink(
      handle: handle,
      hashSink: hashSink,
      entryLimit: entryLimit,
      totalLimit: totalLimit,
      progress: progress,
    );
    try {
      final rawStream = file.getStream(decompress: false);
      if (file.compressionMethod == CompressionType.deflate) {
        // 原生 zlib 分块解码：输出按解码器固定内部缓冲逐块到达受限
        // 接收器，接收器抛出即整段中止；不用 archive 内部先聚合再
        // 回调的便捷入口。
        final conversion = ZLibCodec(
          raw: true,
        ).decoder.startChunkedConversion(sink);
        while (!rawStream.isEOS) {
          final chunk = rawStream
              .readBytes(_extractFeedChunkBytes)
              .toUint8List();
          if (chunk.isEmpty) {
            break;
          }
          conversion.add(chunk);
        }
        conversion.close();
      } else {
        while (!rawStream.isEOS) {
          final chunk = rawStream
              .readBytes(_extractFeedChunkBytes)
              .toUint8List();
          if (chunk.isEmpty) {
            break;
          }
          sink.add(chunk);
        }
      }
      hashSink.close();
      await handle.flush();
      return (
        file: target,
        bytes: sink.entryWritten,
        sha256: digestCollector.value!.toString(),
      );
    } finally {
      await handle.close();
    }
  }

  /// 删除受限解压的临时目录；清理失败只记诊断，不影响导入结果。
  Future<void> _cleanupExtraction(Directory directory) async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on Object catch (error) {
      _diagnosticsSink('backup extraction cleanup deferred [$error]');
    }
  }

  Map<String, Object?> _parseManifest(String contents) {
    try {
      final json = _markerPayloadOrNull(contents, _manifestMarker);
      if (json == null) {
        throw const FormatException('manifest marker missing or unterminated');
      }
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

  /// 快照视角下的排除路径：快照目录自身（backups/）与临时文件
  /// （.tmp）既不进快照，也不参与恢复清理与残留核对。
  bool _isSnapshotExcludedPath(String relative) =>
      relative.startsWith('backups/') || relative.endsWith('.tmp');

  /// 记忆目录内允许进入备份的相对路径（导出与导入共用同一白名单）。
  bool _allowedMemoryPath(String relative) {
    const rootFiles = {
      'persona.md',
      'relationship.md',
      'open-loops.md',
      'open-loops.archive.md',
      'daily-state.md',
      'long-memory.md',
      memoryControlsFileName,
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

  /// 导入前验证与差异展示；只读，不写任何文件、不创建快照。验证与
  /// 受限解压在隔离临时目录内完成，返回前清理。
  Future<MemoryBackupPreview> previewImport(Uint8List bundle) async {
    final extracted = await _extractValidatedBundle(bundle);
    try {
      return (await _diff(extracted.files, extracted.generatedAt)).preview;
    } finally {
      await _cleanupExtraction(extracted.directory);
    }
  }

  /// 差异预览；备份带控制记录时一并返回已解析的备份控制记录——
  /// 此处已校验其可读（不可读直接拒绝），导入侧直接复用，不对同一
  /// 字节二次解析。
  Future<({MemoryBackupPreview preview, MemoryControls? backupControls})> _diff(
    Map<String, File> files,
    DateTime generatedAt,
  ) async {
    final currentControls = await memoryControls.load();
    MemoryControls? backupControls;
    final backupControlsFile = files[memoryControlsFileName];
    if (backupControlsFile != null) {
      try {
        backupControls = parseMemoryControls(
          utf8.decode(await backupControlsFile.readAsBytes()),
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
      if (relative == memoryControlsFileName) {
        continue; // 控制记录走并集合并，不按文件替换。
      }
      final backupBytes = await files[relative]!.readAsBytes();
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
          path: memoryControlsFileName,
          category: controlsMerge == 'identical'
              ? BackupItemCategory.skipped
              : BackupItemCategory.replaced,
          note: controlsMerge == 'identical'
              ? '与本机控制记录一致'
              : '与本机控制记录按并集合并，保留更保守的隐私结果',
        ),
      );
    }

    return (
      preview: MemoryBackupPreview(
        schemaVersion: backupSchemaVersion,
        generatedAt: generatedAt,
        controlsMerge: controlsMerge,
        items: items,
      ),
      backupControls: backupControls,
    );
  }

  // ---------- 导入 ----------

  /// 确认后执行导入：重新验证 → 快照当前状态 → 原子写入 → 合并控制
  /// 并按现行控制清除派生内容 → 重建索引。中途失败按快照恢复。
  /// 预算失败发生在验证与受限解压阶段，先于快照，不触碰产品数据。
  Future<MemoryBackupImportResult> importBundle(Uint8List bundle) async {
    final extracted = await _extractValidatedBundle(bundle);
    try {
      final files = extracted.files;
      final diff = await _diff(files, extracted.generatedAt);
      final preview = diff.preview;
      final snapshotId = await _createSnapshot();

      try {
        // 控制纪律（Memory.md 写入边界）：先落控制记录，再写内容文件。
        // 备份带来的控制与本机按并集合并；中断在两步之间时，留下的是
        // 更保守的控制集合而不是更少的控制。备份控制记录已在 _diff
        // 解析并校验可读，这里只复查本机控制记录可读。
        var controlsMerged = false;
        final backupControls = diff.backupControls;
        if (backupControls != null) {
          final currentControls = await memoryControls.load();
          if (!currentControls.readable) {
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
          if (item.path == memoryControlsFileName) {
            continue;
          }
          switch (item.category) {
            case BackupItemCategory.added || BackupItemCategory.replaced:
              await _byteWriter.write(
                path.join(memoryDirectory, item.path),
                await files[item.path]!.readAsBytes(),
              );
              if (item.category == BackupItemCategory.added) {
                added += 1;
              } else {
                replaced += 1;
              }
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
              await memoryActions.purgeDerivedScopes({
                normalizeMemoryText(entry.summary),
              }, text: entry.summary);
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
        // 导入失败：按刚创建的快照恢复原样。恢复本身失败时如实报告
        // 恢复未完成——快照保留在本机，用户可再次恢复，绝不声称数据
        // 已回到导入前的状态。
        try {
          await _restoreSnapshot(snapshotId);
        } on Object catch (restoreError) {
          _diagnosticsSink('backup import rollback failed [$restoreError]');
          throw _restoreIncomplete();
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
    } finally {
      await _cleanupExtraction(extracted.directory);
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
    final match = sessionMetaMarkerPattern.firstMatch(contents);
    if (match == null) {
      return false;
    }
    try {
      decodeMarkerPayload(match.group(1)!);
      return true;
    } on Object {
      return false;
    }
  }

  // ---------- 快照与回滚 ----------

  var _snapshotSequence = 0;

  /// 高风险写入前的保护快照（导入与「清除产品数据」共用，ticket 22/23）：
  /// 全部文件落盘后才写完成标记，没有完成标记的快照不参与回滚。
  Future<String> createSnapshot() => _createSnapshot();

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
    final memoryFiles = await _listRelativeFiles(Directory(memoryDirectory));
    for (final MapEntry(:key, :value) in memoryFiles.entries) {
      if (_isSnapshotExcludedPath(key)) {
        continue;
      }
      final target = path.join(directory.path, key);
      await File(target).parent.create(recursive: true);
      await value.copy(target);
      fileCount += 1;
    }
    final marker = {
      'kind': 'qiyu-memory-snapshot',
      'id': id,
      'createdAt': now.toIso8601String(),
      'fileCount': fileCount,
    };
    await File(path.join(directory.path, 'snapshot.md')).writeAsString(
      '# 栖语导入前快照\n\n$_snapshotMarker${encodeMarkerPayload(marker)} -->\n',
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
      final json = _markerPayloadOrNull(contents, _snapshotMarker);
      if (json == null) {
        return null;
      }
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
    final int restored;
    try {
      restored = await _restoreSnapshot(target.id);
    } on Object catch (restoreError) {
      // 恢复写回或必要清理失败：如实报告恢复未完成，不把底层文件
      // 系统异常（可能携带本机路径）透出；目标快照与保底快照都保留，
      // 可再次恢复。
      _diagnosticsSink('backup rollback failed [$restoreError]');
      throw _restoreIncomplete();
    }
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
    final snapshotEntries = await _listRelativeFiles(directory);
    snapshotEntries.remove('snapshot.md');
    final snapshotFiles = <String, Uint8List>{};
    for (final MapEntry(:key, :value) in snapshotEntries.entries) {
      snapshotFiles[key] = await value.readAsBytes();
    }
    for (final MapEntry(:key, :value) in snapshotFiles.entries) {
      await _byteWriter.write(path.join(memoryDirectory, key), value);
    }
    // 清理快照中不存在的文件（导入后新增的），快照本身不动。这是
    // 恢复的必要清理：删不掉本机就带着导入期间多出的文件，不是导入
    // 前的状态，失败如实计入恢复失败。
    final memoryFiles = await _listRelativeFiles(Directory(memoryDirectory));
    for (final MapEntry(:key, :value) in memoryFiles.entries) {
      if (_isSnapshotExcludedPath(key)) {
        continue;
      }
      if (!snapshotFiles.containsKey(key)) {
        try {
          await _restoreFileDeleter(value.path);
        } on Object catch (error) {
          _diagnosticsSink('snapshot restore cleanup failed [$error]');
          throw _restoreIncomplete();
        }
      }
    }
    // 恢复完整性核对：写回与必要清理之后，记忆目录必须恰好回到快照
    // 时点。任何原因留下的快照之外文件（含两趟之间的新增）都说明
    // 恢复没有完成，按实际结果如实判定，绝不声称已恢复。
    final remaining = await _listRelativeFiles(Directory(memoryDirectory));
    final hasResidue = remaining.keys.any(
      (key) =>
          !_isSnapshotExcludedPath(key) && !snapshotFiles.containsKey(key),
    );
    if (hasResidue) {
      _diagnosticsSink('snapshot restore residue detected');
      throw _restoreIncomplete();
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

/// 恢复清理的默认删除：直接删除真实文件。
Future<void> _deleteMemoryFile(String targetPath) => File(targetPath).delete();

/// 递归收集 [root] 下全部文件，键为正斜杠相对路径（导出、快照与
/// 回滚清理共用同一种目录遍历）；目录不存在时返回空映射。两趟语义：
/// 先整表列出目录，再由调用方逐个读文件，两趟之间文件系统发生的
/// 变化不在备份与回滚的原子性保证内。
Future<Map<String, File>> _listRelativeFiles(Directory root) async {
  final files = <String, File>{};
  if (!await root.exists()) {
    return files;
  }
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    files[path.relative(entity.path, from: root.path).replaceAll(r'\', '/')] =
        entity;
  }
  return files;
}
