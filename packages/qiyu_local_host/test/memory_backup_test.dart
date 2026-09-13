import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:path/path.dart' as path;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late String memoryDirectory;
  late EpisodeMemoryPipeline pipeline;
  late MemoryControlsStore memoryControls;
  late OpenLoopStore openLoopStore;
  late PersonaTreeStore personaTree;
  late MonthlySummaryStore monthlySummary;
  late RelationshipLifecycle relationshipLifecycle;
  late MemoryActionService actions;
  late MemoryBackupService backup;

  final clock = DateTime(2026, 8, 19, 21);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qiyu-backup-test-',
    );
    memoryDirectory = path.join(temporaryDirectory.path, 'memories');
    await Directory(memoryDirectory).create(recursive: true);
    pipeline = EpisodeMemoryPipeline(memoryDirectory: memoryDirectory);
    memoryControls = MemoryControlsStore(
      memoryDirectory: memoryDirectory,
      diagnosticsSink: (_) {},
    );
    openLoopStore = OpenLoopStore(
      memoryDirectory: memoryDirectory,
      memoryControls: memoryControls,
    );
    personaTree = PersonaTreeStore(
      memoryDirectory: memoryDirectory,
      episodePipeline: pipeline,
      openLoopStore: openLoopStore,
      diagnosticsSink: (_) {},
    );
    monthlySummary = MonthlySummaryStore(
      memoryDirectory: memoryDirectory,
      episodePipeline: pipeline,
      diagnosticsSink: (_) {},
    );
    relationshipLifecycle = RelationshipLifecycle(
      memoryDirectory: memoryDirectory,
    );
    actions = MemoryActionService(
      memoryDirectory: memoryDirectory,
      episodePipeline: pipeline,
      personaTree: personaTree,
      memoryControls: memoryControls,
      openLoopStore: openLoopStore,
      monthlySummary: monthlySummary,
      relationshipLifecycle: relationshipLifecycle,
      diagnosticsSink: (_) {},
    );
    backup = MemoryBackupService(
      memoryDirectory: memoryDirectory,
      memoryControls: memoryControls,
      episodePipeline: pipeline,
      personaTree: personaTree,
      memoryActions: actions,
      clock: () => clock,
      diagnosticsSink: (_) {},
    );
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  Future<File> seedSession(
    String date,
    int segment,
    List<(String speaker, String text)> turns,
  ) async {
    final session = RawSession(
      id: 'session-$date-$segment',
      date: date,
      segment: segment,
      createdAt: DateTime.parse('${date}T20:00:00').toUtc(),
      updatedAt: DateTime.parse('${date}T20:30:00').toUtc(),
      turns: [
        for (var index = 0; index < turns.length; index += 1)
          turns[index].$1 == '用户'
              ? RawSessionTurn.user(
                  requestId: 'r$index',
                  text: turns[index].$2,
                  at: DateTime.parse(
                    '${date}T20:${(10 + index).toString().padLeft(2, '0')}:00',
                  ).toUtc(),
                )
              : RawSessionTurn.qiyu(
                  requestId: 'r$index',
                  messages: [turns[index].$2],
                  at: DateTime.parse(
                    '${date}T20:${(10 + index).toString().padLeft(2, '0')}:30',
                  ).toUtc(),
                  source: ReplySource.local,
                  mode: 'local',
                ),
      ],
    );
    final file = File(
      path.join(
        memoryDirectory,
        'sessions',
        date.substring(0, 4),
        date.substring(5, 7),
        '$date-${segment.toString().padLeft(3, '0')}.md',
      ),
    );
    await file.create(recursive: true);
    await file.writeAsString(renderSessionMarkdown(session), flush: true);
    return file;
  }

  EpisodeEntry entry(String date, String id, String summary) => EpisodeEntry(
    id: id,
    sessionId: 'seed-session',
    requestId: 'seed',
    summary: summary,
    at: DateTime.parse('${date}T20:00:00').toUtc(),
  );

  Future<void> seedEpisodeDay(String date, List<EpisodeEntry> entries) =>
      pipeline.synchronizedOnDayFiles(
        () => pipeline.writeFinalization(
          date,
          entries: entries,
          summary: '当日摘要',
          finalized: true,
          finalizedAt: DateTime.parse('${date}T23:00:00').toUtc(),
        ),
      );

  Future<void> seedRichMemory() async {
    await seedSession('2026-08-05', 1, [('用户', '今天有点累'), ('栖语', '早点休息。')]);
    await seedEpisodeDay(
      '2026-08-05',
      [entry('2026-08-05', 'e1', '用户那天很累')],
    );
    await File(path.join(memoryDirectory, 'long-memory.md')).writeAsString(
      '# long-memory\n\n## 人与关系\n- 一条长期印象\n',
      flush: true,
    );
  }

  /// 手工构造备份包：按给定记忆文件生成清单与 zip，可注入版本与完整性
  /// 故障。
  Uint8List buildBundle(
    Map<String, String> files, {
    int schemaVersion = backupSchemaVersion,
    bool dropManifestEntry = false,
    String extraEntryPath = '',
    String tamperEntryPath = '',
  }) {
    final entries = <Map<String, Object?>>[];
    final archive = Archive();
    for (final MapEntry(:key, :value) in files.entries) {
      var bytes = Uint8List.fromList(utf8.encode(value));
      if (key == tamperEntryPath) {
        bytes = Uint8List.fromList(utf8.encode('$value（被篡改）'));
      }
      if (!dropManifestEntry || key != tamperEntryPath) {
        entries.add({
          'path': 'memory/$key',
          'bytes':
              key == tamperEntryPath && !dropManifestEntry
                  ? utf8.encode(value).length
                  : bytes.length,
          'sha256': sha256.convert(utf8.encode(value)).toString(),
        });
      }
      archive.addFile(ArchiveFile('memory/$key', bytes.length, bytes));
    }
    if (extraEntryPath.isNotEmpty) {
      final bytes = Uint8List.fromList(utf8.encode('多余内容'));
      archive.addFile(ArchiveFile(extraEntryPath, bytes.length, bytes));
    }
    final manifestJson = {
      'kind': 'qiyu-memory-backup',
      'schemaVersion': schemaVersion,
      'generatedAt': clock.toUtc().toIso8601String(),
      'fileCount': entries.length,
      'files': entries,
    };
    final manifest =
        '# 栖语记忆备份\n\n'
        '<!-- qiyu-backup-manifest:'
        '${base64Url.encode(utf8.encode(jsonEncode(manifestJson))).replaceAll('=', '')} -->\n';
    final manifestBytes = Uint8List.fromList(utf8.encode(manifest));
    archive.addFile(
      ArchiveFile('manifest.md', manifestBytes.length, manifestBytes),
    );
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }
  /// 手工拼装 zip 字节：本地头、中心目录与结束记录，固定字段按
  /// 小端写入，条目按 [_RawZipEntry] 的声明取值。
  Uint8List buildRawZip(List<_RawZipEntry> entries) {
    void uint16(BytesBuilder sink, int value) {
      final data = ByteData(2)..setUint16(0, value, Endian.little);
      sink.add(data.buffer.asUint8List());
    }

    void uint32(BytesBuilder sink, int value) {
      final data = ByteData(4)..setUint32(0, value, Endian.little);
      sink.add(data.buffer.asUint8List());
    }

    final body = BytesBuilder();
    final central = BytesBuilder();
    var bodyLength = 0;
    for (final entry in entries) {
      final compressed = entry.compressedBytes ??
          (entry.compressionMethod == 8
              ? Uint8List.fromList(
                  ZLibCodec(raw: true).encoder.convert(entry.realBytes),
                )
              : entry.realBytes);
      final name = Uint8List.fromList(utf8.encode(entry.name));
      final headerOffset = bodyLength;

      uint32(body, 0x04034b50);
      uint16(body, 20);
      uint16(body, 0);
      uint16(body, entry.compressionMethod);
      uint16(body, 0);
      uint16(body, 0x21);
      uint32(body, 0);
      uint32(body, compressed.length);
      uint32(body, entry.declaredUncompressed);
      uint16(body, name.length);
      uint16(body, 0);
      body.add(name);
      body.add(compressed);
      bodyLength += 30 + name.length + compressed.length;

      final comment = Uint8List.fromList(utf8.encode(entry.fileComment));
      uint32(central, 0x02014b50);
      uint16(central, entry.versionMadeBy);
      uint16(central, 20);
      uint16(central, 0);
      uint16(central, entry.compressionMethod);
      uint16(central, 0);
      uint16(central, 0x21);
      uint32(central, 0);
      uint32(central, compressed.length);
      uint32(central, entry.declaredUncompressed);
      uint16(central, name.length);
      uint16(central, 0);
      uint16(central, comment.length);
      uint16(central, 0);
      uint16(central, 0);
      uint32(central, entry.externalAttributes);
      uint32(central, headerOffset);
      central.add(name);
      central.add(comment);
    }

    final centralBytes = central.toBytes();
    final eocd = BytesBuilder();
    uint32(eocd, 0x06054b50);
    uint16(eocd, 0);
    uint16(eocd, 0);
    uint16(eocd, entries.length);
    uint16(eocd, entries.length);
    uint32(eocd, centralBytes.length);
    uint32(eocd, bodyLength);
    uint16(eocd, 0);
    return Uint8List.fromList([
      ...body.toBytes(),
      ...centralBytes,
      ...eocd.toBytes(),
    ]);
  }

  /// 组装带清单的原始 zip：[declared] 是清单声明（可虚报），[entries]
  /// 是包内真实条目。ZipEncoder 只能写诚实头部，谎报声明必须手工
  /// 拼装字节。
  Uint8List buildRawBackup({
    required List<(String, int, String)> declared,
    required List<_RawZipEntry> entries,
  }) {
    final manifestJson = {
      'kind': 'qiyu-memory-backup',
      'schemaVersion': backupSchemaVersion,
      'generatedAt': clock.toUtc().toIso8601String(),
      'fileCount': declared.length,
      'files': [
        for (final (entryPath, bytes, sha) in declared)
          {'path': entryPath, 'bytes': bytes, 'sha256': sha},
      ],
    };
    final manifestContent =
        '# 栖语记忆备份\n\n'
        '<!-- qiyu-backup-manifest:'
        '${base64Url.encode(utf8.encode(jsonEncode(manifestJson))).replaceAll('=', '')} -->\n';
    final manifestBytes = Uint8List.fromList(utf8.encode(manifestContent));
    return buildRawZip([
      _RawZipEntry(
        'manifest.md',
        realBytes: manifestBytes,
        compressionMethod: 0,
      ),
      ...entries,
    ]);
  }


  Map<String, String> snapshotMemoryTree() {
    final result = <String, String>{};
    final root = Directory(memoryDirectory);
    if (!root.existsSync()) {
      return result;
    }
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final relative = path.relative(entity.path, from: memoryDirectory);
      if (relative.startsWith('backups${Platform.pathSeparator}')) {
        continue;
      }
      result[relative] = entity.readAsStringSync();
    }
    return result;
  }

  group('导出', () {
    test('导出包含全部记忆层，且不含 Key、凭据、缓存、日志与快照', () async {
      await seedRichMemory();
      expect(await memoryControls.ban('秘密项目', origin: 'user'), isTrue);
      // 记忆目录外的宿主配置与凭据（含假 API Key）。
      final fakeKey = 'sk-test-do-not-export-1234567890';
      await File(
        path.join(temporaryDirectory.path, 'provider.json'),
      ).writeAsString('{"apiKey":"$fakeKey"}');
      // 损坏隔离区与恢复日志（ticket 21 的诊断区）。
      final quarantine = Directory(
        path.join(memoryDirectory, 'recovery', 'quarantine'),
      );
      await quarantine.create(recursive: true);
      await File(path.join(quarantine.path, '1__session__bad.md'))
          .writeAsString('损坏原件');
      await File(
        path.join(memoryDirectory, 'recovery', 'recovery.log'),
      ).writeAsString('2026-08-19 | 原始会话 | 待恢复 | 无\n');

      final export = await backup.exportBundle();

      expect(export.fileName, startsWith('qiyu-backup-'));
      final archive = ZipDecoder().decodeBytes(export.bytes);
      final names = archive.files.map((file) => file.name).toSet();
      expect(names, contains('manifest.md'));
      expect(names, contains('memory/long-memory.md'));
      expect(names, contains('memory/memory-controls.md'));
      expect(
        names.any((name) => name.contains('sessions/')),
        isTrue,
      );
      expect(
        names.any((name) => name.contains('episodes/2026/08/2026-08-05.md')),
        isTrue,
      );
      // 绝不包含：Key、宿主配置、隔离区、日志、快照。
      for (final file in archive.files) {
        final content = utf8.decode(file.content as List<int>);
        expect(content, isNot(contains(fakeKey)));
        expect(file.name, isNot(contains('provider.json')));
        expect(file.name, isNot(contains('recovery/')));
        expect(file.name, isNot(contains('backups/')));
        expect(file.name, isNot(endsWith('.tmp')));
      }
      // 清单人类可读：版本、时间与文件清单不依赖数据库工具。
      final manifestContent = utf8.decode(
        archive.files.firstWhere((file) => file.name == 'manifest.md').content
            as List<int>,
      );
      expect(manifestContent, contains('# 栖语记忆备份'));
      expect(manifestContent, contains('qiyu-backup-manifest:'));
      expect(manifestContent, contains('memory/long-memory.md'));
      expect(manifestContent, contains('如何导入'));
    });
  });

  group('导出脱敏', () {
    test('旧记忆的秘密在导出处过滤：可见文本与载荷，干净文件逐字节保持', () async {
      // 旧会话：手工构造「旧规则时代」落盘形态，turn 载荷与可见行都带
      // 当时的脱敏规则漏掉的秘密。全部为固定合成文本。
      const jsonSecret = 'audit-only-password';
      const cookieSecret = 'audit-only-cookie';
      const legacyUserText =
          '{"password":"$jsonSecret"}\n'
          '{"client_secret":"audit-only-client",'
          '"cookie":"sid=$cookieSecret; refresh=audit-only-refresh",'
          '"password":987654321,"count":42}\n'
          'Cookie: theme=dark; sid=$cookieSecret\n'
          '-----BEGIN PRIVATE KEY-----\nAUDITONLYFAKEPKCS8\n'
          '-----END PRIVATE KEY-----';
      final at = DateTime.parse('2026-08-05T12:00:00Z').toUtc();
      final legacySessionFile = File(
        path.join(
          memoryDirectory,
          'sessions',
          '2026',
          '08',
          '2026-08-05-002.md',
        ),
      )..createSync(recursive: true);
      legacySessionFile.writeAsStringSync(
        renderSessionMarkdown(
          RawSession(
            id: 'legacy-secret-session',
            date: '2026-08-05',
            segment: 2,
            createdAt: at,
            updatedAt: at.add(const Duration(minutes: 1)),
            turns: [
              RawSessionTurn.user(
                requestId: 'legacy-1',
                text: legacyUserText,
                at: at,
              ),
              RawSessionTurn.qiyu(
                requestId: 'legacy-1',
                messages: const ['好的。'],
                at: at.add(const Duration(minutes: 1)),
                source: ReplySource.local,
                mode: 'local',
              ),
            ],
          ),
        ),
        flush: true,
      );
      // 现规则写入的干净会话：正常往返必须逐字节保持。
      await seedSession(
        '2026-08-05',
        1,
        [('用户', '今天有点累'), ('栖语', '早点休息。')],
      );
      // 旧 episode 日文件：秘密同时藏在 base64url 载荷与可见行里。
      final legacyDay = _renderLegacyEpisodeDay(
        date: '2026-08-05',
        summary: '当日摘要',
        entrySummary: '服务器密码：$jsonSecret',
        evidence: '用户原话：Cookie: sid=$cookieSecret',
      );
      File(
        path.join(
          memoryDirectory,
          'episodes',
          '2026',
          '08',
          '2026-08-05.md',
        ),
      )
        ..createSync(recursive: true)
        ..writeAsStringSync(legacyDay, flush: true);
      await File(
        path.join(memoryDirectory, 'long-memory.md'),
      ).writeAsString('# long-memory\n\n- 服务器密码：$jsonSecret\n', flush: true);
      // 控制记录是记忆元数据：结构标记原样，自由文本摘要仍按同一份
      // 规则过滤（旧规则时代的摘要可能残留秘密）。
      expect(await memoryControls.freeze('旧习惯', origin: 'user'), isTrue);
      expect(
        await memoryControls.freeze('服务器密码：audit-only-controls'),
        isTrue,
      );

      final export = await backup.exportBundle();
      final archive = ZipDecoder().decodeBytes(export.bytes);

      // 任何条目都不再携带旧秘密——包括 base64url 载荷与控制摘要里的那份。
      for (final file in archive.files) {
        final content = utf8.decode(file.content as List<int>);
        expect(content, isNot(contains(jsonSecret)), reason: file.name);
        expect(content, isNot(contains(cookieSecret)), reason: file.name);
        expect(content, isNot(contains('audit-only-client')), reason: file.name);
        expect(content, isNot(contains('audit-only-refresh')), reason: file.name);
        expect(content, isNot(contains('987654321')), reason: file.name);
        expect(
          content,
          isNot(contains('AUDITONLYFAKEPKCS8')),
          reason: file.name,
        );
        expect(content, isNot(contains(legacyUserText)), reason: file.name);
        expect(content, isNot(contains('audit-only-controls')), reason: file.name);
      }

      // 干净会话逐字节保持：未命中替换就不动文件。
      final cleanEntry = archive.files.firstWhere(
        (file) => file.name == 'memory/sessions/2026/08/2026-08-05-001.md',
      );
      expect(
        utf8.decode(cleanEntry.content as List<int>),
        await File(
          path.join(
            memoryDirectory,
            'sessions',
            '2026',
            '08',
            '2026-08-05-001.md',
          ),
        ).readAsString(),
      );
      // 控制记录结构标记保持可读：干净的摘要原样，脏摘要就地遮蔽。
      final exportedControls = utf8.decode(
        archive.files
            .firstWhere((file) => file.name == 'memory/memory-controls.md')
            .content as List<int>,
      );
      expect(exportedControls, contains('## frozen'));
      expect(exportedControls, contains('- [MC001] user | 旧习惯'));
      expect(
        exportedControls,
        contains('- [MC002] chat | 服务器密码：[已脱敏]'),
      );

      // 校验与回导一致：清空后整包导入成功，读回内容已脱敏、结构完好。
      await Directory(memoryDirectory).delete(recursive: true);
      await Directory(memoryDirectory).create(recursive: true);
      final result = await backup.importBundle(export.bytes);
      expect(result.conflicts, 0);
      expect(result.unrecoverable, 0);

      final importedSession = await MarkdownMemoryRepository(
        memoryDirectory: memoryDirectory,
      ).openSession(sessionId: 'legacy-secret-session');
      expect(
        importedSession.turns.first.text,
        isNot(contains(jsonSecret)),
      );
      expect(importedSession.turns.first.text, contains('[已脱敏]'));
      expect(importedSession.turns.first.text, isNot(contains('audit-only-')));
      expect(importedSession.turns.first.text, isNot(contains('987654321')));
      expect(importedSession.turns.first.text, contains('"count":42'));

      final day = await pipeline.readDay('2026-08-05');
      expect(day.readable, isTrue);
      expect(day.entries, hasLength(1));
      expect(day.entries.single.summary, isNot(contains(jsonSecret)));
      expect(day.entries.single.summary, contains('[已脱敏]'));

      final controls = await memoryControls.load();
      expect(controls.readable, isTrue);
      expect(controls.frozenSummaries, contains('旧习惯'));
      expect(controls.frozenSummaries, contains('服务器密码：[已脱敏]'));
    });

    test('无法按文本解读的文件导出时跳过并记诊断，其余文件不受影响', () async {
      await seedRichMemory();
      final diagnostics = <String>[];
      final observing = MemoryBackupService(
        memoryDirectory: memoryDirectory,
        memoryControls: memoryControls,
        episodePipeline: pipeline,
        personaTree: personaTree,
        memoryActions: actions,
        clock: () => clock,
        diagnosticsSink: diagnostics.add,
      );
      // 记忆目录内混入一份带非法字节序列的文件：无法可靠脱敏，
      // 导出侧整份跳过。
      await File(
        path.join(memoryDirectory, 'long-memory.md'),
      ).writeAsBytes(
        Uint8List.fromList(const [0x23, 0x20, 0x6c, 0x6f, 0x6e, 0x67, 0xff, 0xfe]),
        flush: true,
      );

      final export = await observing.exportBundle();

      final names = ZipDecoder()
          .decodeBytes(export.bytes)
          .files
          .map((file) => file.name)
          .toSet();
      expect(names, isNot(contains('memory/long-memory.md')));
      expect(names.any((name) => name.contains('sessions/')), isTrue);
      expect(names, contains('manifest.md'));
      expect(diagnostics, hasLength(1));
      expect(diagnostics.single, contains('backup export skipped'));
    });
  });

  group('完整往返', () {
    test('导出后清空再导入，历史、记忆与最近会话都能重新打开', () async {
      await seedRichMemory();
      expect(await memoryControls.freeze('旧习惯', origin: 'user'), isTrue);
      final export = await backup.exportBundle();

      // 清空记忆目录，模拟换机或整体丢失。
      await Directory(memoryDirectory).delete(recursive: true);
      await Directory(memoryDirectory).create(recursive: true);

      final preview = await backup.previewImport(export.bytes);
      expect(preview.countOf(BackupItemCategory.added), 3);
      expect(preview.countOf(BackupItemCategory.conflict), 0);

      final result = await backup.importBundle(export.bytes);
      expect(result.added, 3);
      expect(result.replaced, 0);
      expect(result.conflicts, 0);
      expect(result.snapshotId, isNotEmpty);

      // 历史（sessions）可重新打开。
      final listing = await MarkdownMemoryRepository(
        memoryDirectory: memoryDirectory,
      ).readHistory();
      expect(listing.sessions, hasLength(1));
      expect(listing.sessions.single.turns, hasLength(2));

      // 最近会话与记忆（episodes、控制）可读。
      final day = await pipeline.readDay('2026-08-05');
      expect(day.readable, isTrue);
      expect(day.entries.single.summary, '用户那天很累');
      final controls = await memoryControls.load();
      expect(controls.frozenSummaries, contains('旧习惯'));

      // 重复导入同一备份：全部跳过，不产生重复。
      final second = await backup.importBundle(export.bytes);
      expect(second.added, 0);
      expect(second.replaced, 0);
      expect(second.skipped, 3);
    });
  });

  group('版本与完整性', () {
    test('旧版本备份被拒绝，现有数据不变', () async {
      await seedRichMemory();
      final before = snapshotMemoryTree();
      final bundle = buildBundle({
        'long-memory.md': '# long-memory\n\n## 人与关系\n- 旧版备份的印象\n',
      }, schemaVersion: 0);

      await expectLater(
        () => backup.importBundle(bundle),
        throwsA(
          isA<BackupValidationException>().having(
            (error) => error.code,
            'code',
            'incompatible-version',
          ),
        ),
      );
      expect(snapshotMemoryTree(), before);
    });

    test('更高版本的备份被拒绝，现有数据不变', () async {
      await seedRichMemory();
      final before = snapshotMemoryTree();
      final bundle = buildBundle({
        'long-memory.md': '# long-memory\n\n## 人与关系\n- 新备份的印象\n',
      }, schemaVersion: 2);

      await expectLater(
        () => backup.previewImport(bundle),
        throwsA(
          isA<BackupValidationException>().having(
            (error) => error.code,
            'code',
            'incompatible-version',
          ),
        ),
      );
      expect(snapshotMemoryTree(), before);
      expect(Directory(path.join(memoryDirectory, 'backups')).existsSync(), isFalse);
    });

    test('清单校验和损坏的备份被拒绝，现有数据不变', () async {
      await seedRichMemory();
      final before = snapshotMemoryTree();
      final bundle = buildBundle({
        'long-memory.md': '# long-memory\n\n## 人与关系\n- 一条印象\n',
      }, tamperEntryPath: 'long-memory.md');

      await expectLater(
        () => backup.importBundle(bundle),
        throwsA(
          isA<BackupValidationException>().having(
            (error) => error.code,
            'code',
            'integrity-mismatch',
          ),
        ),
      );
      expect(snapshotMemoryTree(), before);
    });

    test('文件与清单不一致（多余文件）的备份被拒绝', () async {
      final bundle = buildBundle({
        'long-memory.md': '# long-memory\n',
      }, extraEntryPath: 'memory/evil.md');

      await expectLater(
        () => backup.previewImport(bundle),
        throwsA(
          isA<BackupValidationException>().having(
            (error) => error.code,
            'code',
            'integrity-mismatch',
          ),
        ),
      );
    });

    test('不是 zip 的字节流被拒绝', () async {
      await expectLater(
        () => backup.previewImport(
          Uint8List.fromList(utf8.encode('这不是备份')),
        ),
        throwsA(
          isA<BackupValidationException>().having(
            (error) => error.code,
            'code',
            'not-a-backup',
          ),
        ),
      );
    });
  });

  group('冲突与控制', () {
    test('同名原始会话内容不同时保留本机版本并如实报冲突', () async {
      await seedSession('2026-08-05', 1, [('用户', '本机的原始证据')]);
      final bundle = buildBundle({
        'sessions/2026/08/2026-08-05-001.md': renderSessionMarkdown(
          RawSession(
            id: 'session-2026-08-05-1',
            date: '2026-08-05',
            segment: 1,
            createdAt: DateTime.parse('2026-08-05T20:00:00').toUtc(),
            updatedAt: DateTime.parse('2026-08-05T20:30:00').toUtc(),
            turns: [
              RawSessionTurn.user(
                requestId: 'r0',
                text: '备份里的不同内容',
                at: DateTime.parse('2026-08-05T20:10:00').toUtc(),
              ),
            ],
          ),
        ),
      });

      final preview = await backup.previewImport(bundle);
      expect(preview.countOf(BackupItemCategory.conflict), 1);

      final result = await backup.importBundle(bundle);
      expect(result.conflicts, 1);
      expect(result.added, 0);
      expect(result.replaced, 0);
      final kept = await File(
        path.join(
          memoryDirectory,
          'sessions',
          '2026',
          '08',
          '2026-08-05-001.md',
        ),
      ).readAsString();
      expect(kept, contains('本机的原始证据'));
      expect(kept, isNot(contains('备份里的不同内容')));
    });

    test('导入尊重本机现有删除控制，被控内容不随备份复活', () async {
      // 本机现行控制：已删除「痛苦回忆」。
      expect(
        await memoryControls.recordDelete('痛苦回忆', origin: 'user'),
        isTrue,
      );
      // 备份定格在删除之前：长期印象与控制记录都还带着它。
      final bundle = buildBundle({
        'long-memory.md': '# long-memory\n\n## 人与关系\n'
            '- 痛苦回忆的细节\n- 一条正常印象\n',
        'memory-controls.md': '# memory-controls\n'
            '## frozen\n## banned\n## deleted\n',
      });

      final preview = await backup.previewImport(bundle);
      // 备份控制是本机控制的子集：并集不变，但清除仍按现行控制执行。
      expect(preview.controlsMerge, 'identical');

      final result = await backup.importBundle(bundle);
      expect(result.controlsMerged, isFalse);

      final controls = await memoryControls.load();
      expect(controls.deletedSummaries, contains('痛苦回忆'));
      final restored = await File(
        path.join(memoryDirectory, 'long-memory.md'),
      ).readAsString();
      expect(restored, contains('一条正常印象'));
      expect(restored, isNot(contains('痛苦回忆')));
    });

    test('备份中的控制记录与本机按并集合并', () async {
      expect(await memoryControls.ban('本机禁提', origin: 'user'), isTrue);
      final bundle = buildBundle({
        'memory-controls.md': '# memory-controls\n'
            '## frozen\n'
            '- [MC001] chat | 备份冻结\n'
            '## banned\n'
            '- [MC002] chat | 备份禁提\n'
            '## deleted\n',
      });

      final result = await backup.importBundle(bundle);
      expect(result.controlsMerged, isTrue);
      final controls = await memoryControls.load();
      expect(controls.bannedSummaries, containsAll(['本机禁提', '备份禁提']));
      expect(controls.frozenSummaries, contains('备份冻结'));
    });

    test('结构无法识别的会话归为不可恢复且不导入', () async {
      final bundle = buildBundle({
        'sessions/2026/08/2026-08-05-001.md': '无法识别的乱码',
      });

      final preview = await backup.previewImport(bundle);
      expect(preview.countOf(BackupItemCategory.unrecoverable), 1);

      final result = await backup.importBundle(bundle);
      expect(result.unrecoverable, 1);
      expect(
        File(
          path.join(
            memoryDirectory,
            'sessions',
            '2026',
            '08',
            '2026-08-05-001.md',
          ),
        ).existsSync(),
        isFalse,
      );
    });
  });

  group('取消、中断与回滚', () {
    test('只预览不确认：不创建快照、不改变任何数据', () async {
      await seedRichMemory();
      final before = snapshotMemoryTree();
      final export = await backup.exportBundle();
      await Directory(memoryDirectory).delete(recursive: true);
      await Directory(memoryDirectory).create(recursive: true);

      final preview = await backup.previewImport(export.bytes);
      expect(preview.items, isNotEmpty);

      expect(snapshotMemoryTree(), isEmpty);
      expect(
        Directory(path.join(memoryDirectory, 'backups')).existsSync(),
        isFalse,
      );
      expect(before, isNotEmpty);
    });

    test('导入中途失败时恢复到导入前状态', () async {
      await seedRichMemory();
      final indexStore = EpisodeIndexStore(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
      );
      await pipeline.synchronizedOnDayFiles(
        () => indexStore.rebuild(includeUnfinalized: true),
      );
      // 导入前基准：索引已存在，恢复后的重建不会额外改变文件集合。
      final before = snapshotMemoryTree();
      // 备份带一个替换（long-memory 内容不同）与一个新增（daily-state），
      // 第二次写入失败：第一次已写入的文件必须被恢复流程还原。
      final bundle = buildBundle({
        'daily-state.md': '# daily-state\n\n- 备份带来的近况\n',
        'long-memory.md': '# long-memory\n\n## 人与关系\n- 备份里的印象\n',
      });

      final failingWriter = _FailingByteWriter(failOnWrite: {2});
      final failingBackup = MemoryBackupService(
        memoryDirectory: memoryDirectory,
        memoryControls: memoryControls,
        episodePipeline: pipeline,
        personaTree: personaTree,
        memoryActions: actions,
        clock: () => clock,
        byteWriter: failingWriter,
        diagnosticsSink: (_) {},
      );
      await expectLater(
        () => failingBackup.importBundle(bundle),
        throwsA(
          isA<BackupValidationException>().having(
            (error) => error.code,
            'code',
            'import-failed',
          ),
        ),
      );
      expect(snapshotMemoryTree(), before);
    });

    test('恢复写回失败时如实报告未恢复，快照保留可再次恢复', () async {
      await seedRichMemory();
      final indexStore = EpisodeIndexStore(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
      );
      await pipeline.synchronizedOnDayFiles(
        () => indexStore.rebuild(includeUnfinalized: true),
      );
      // 导入前基准：索引已存在，恢复后的重建不会额外改变文件集合。
      final before = snapshotMemoryTree();
      final bundle = buildBundle({
        'daily-state.md': '# daily-state\n\n- 备份带来的近况\n',
        'long-memory.md': '# long-memory\n\n## 人与关系\n- 备份里的印象\n',
      });

      // 导入第 2 次写入失败进入自动恢复；恢复的第一次写回再次失败：
      // 自动恢复没有完成，绝不能声称数据已经回到导入前的状态。
      final failingBackup = MemoryBackupService(
        memoryDirectory: memoryDirectory,
        memoryControls: memoryControls,
        episodePipeline: pipeline,
        personaTree: personaTree,
        memoryActions: actions,
        clock: () => clock,
        byteWriter: _FailingByteWriter(failOnWrite: {2, 3}),
        diagnosticsSink: (_) {},
      );
      await expectLater(
        () => failingBackup.importBundle(bundle),
        throwsA(
          isA<BackupValidationException>()
              .having((error) => error.code, 'code', 'restore-incomplete')
              .having(
                (error) => error.message,
                'message',
                isNot(contains(memoryDirectory)),
              ),
        ),
      );
      // 失败恢复所需的快照没有被提前清理，用正常写入可再次恢复。
      final snapshots = await backup.listSnapshots();
      expect(snapshots, isNotEmpty);
      final restored = await backup.rollbackTo();
      expect(restored.snapshotId, snapshots.first.id);
      expect(snapshotMemoryTree(), before);
    });

    test('恢复清理失败时如实报告未恢复，快照保留', () async {
      await seedRichMemory();
      final bundle = buildBundle({
        'daily-state.md': '# daily-state\n\n- 备份带来的近况\n',
        'long-memory.md': '# long-memory\n\n## 人与关系\n- 备份里的印象\n',
      });

      // 导入第 2 次写入失败进入自动恢复；恢复的写回全部成功，但
      // 删除导入新增文件的必要清理失败：本机没有回到导入前的状态，
      // 必要清理失败计入恢复失败，不声称已恢复。
      final failingBackup = MemoryBackupService(
        memoryDirectory: memoryDirectory,
        memoryControls: memoryControls,
        episodePipeline: pipeline,
        personaTree: personaTree,
        memoryActions: actions,
        clock: () => clock,
        byteWriter: _FailingByteWriter(failOnWrite: {2}),
        restoreFileDeleter: (targetPath) async {
          if (targetPath == path.join(memoryDirectory, 'daily-state.md')) {
            throw const FileSystemException('simulated undeletable file');
          }
          await File(targetPath).delete();
        },
        diagnosticsSink: (_) {},
      );
      await expectLater(
        () => failingBackup.importBundle(bundle),
        throwsA(
          isA<BackupValidationException>()
              .having((error) => error.code, 'code', 'restore-incomplete')
              .having(
                (error) => error.message,
                'message',
                isNot(contains(memoryDirectory)),
              ),
        ),
      );
      // 失败恢复所需的快照没有被提前清理，用正常服务可再次恢复。
      final snapshots = await backup.listSnapshots();
      expect(snapshots, isNotEmpty);
      await backup.rollbackTo();
      expect(
        File(path.join(memoryDirectory, 'daily-state.md')).existsSync(),
        isFalse,
      );
    });

    test('清理之后冒出的快照外文件同样被核对拦下，不声称已恢复', () async {
      await seedRichMemory();
      final bundle = buildBundle({
        'daily-state.md': '# daily-state\n\n- 备份带来的近况\n',
        'long-memory.md': '# long-memory\n\n## 人与关系\n- 备份里的印象\n',
      });

      // 导入第 2 次写入失败进入自动恢复；恢复写回全部成功、清理也能
      // 删掉导入新增的文件，但删除动作本身顺带制造了一个新的快照外
      // 文件：核对按最终状态如实判定恢复未完成，绝不声称已恢复。
      final failingBackup = MemoryBackupService(
        memoryDirectory: memoryDirectory,
        memoryControls: memoryControls,
        episodePipeline: pipeline,
        personaTree: personaTree,
        memoryActions: actions,
        clock: () => clock,
        byteWriter: _FailingByteWriter(failOnWrite: {2}),
        restoreFileDeleter: (targetPath) async {
          await File(targetPath).delete();
          File(path.join(memoryDirectory, 'sneaky-extra.md'))
              .writeAsStringSync('清理之后冒出来的文件', flush: true);
        },
        diagnosticsSink: (_) {},
      );
      await expectLater(
        () => failingBackup.importBundle(bundle),
        throwsA(
          isA<BackupValidationException>().having(
            (error) => error.code,
            'code',
            'restore-incomplete',
          ),
        ),
      );
      // 快照保留：换回正常服务可再次恢复，把多出来的文件收拾干净。
      expect(await backup.listSnapshots(), isNotEmpty);
      await backup.rollbackTo();
      expect(
        File(path.join(memoryDirectory, 'sneaky-extra.md')).existsSync(),
        isFalse,
      );
    });

    test('回滚写回失败时返回恢复未完成且不删快照', () async {
      await seedSession('2026-08-05', 1, [('用户', '旧会话')]);
      await File(path.join(memoryDirectory, 'long-memory.md')).writeAsString(
        '# long-memory\n\n## 人与关系\n- 导入前的印象\n',
        flush: true,
      );
      final before = snapshotMemoryTree();
      final bundle = buildBundle({
        'long-memory.md': '# long-memory\n\n## 人与关系\n- 导入后的印象\n',
      });
      final result = await backup.importBundle(bundle);

      // 回滚的第一次写回就失败：恢复没有完成要如实反馈，错误不携带
      // 本机路径，快照不清理。
      final failingBackup = MemoryBackupService(
        memoryDirectory: memoryDirectory,
        memoryControls: memoryControls,
        episodePipeline: pipeline,
        personaTree: personaTree,
        memoryActions: actions,
        clock: () => clock,
        byteWriter: _FailingByteWriter(failOnWrite: {1}),
        diagnosticsSink: (_) {},
      );
      await expectLater(
        () => failingBackup.rollbackTo(result.snapshotId),
        throwsA(
          isA<BackupValidationException>()
              .having((error) => error.code, 'code', 'restore-incomplete')
              .having(
                (error) => error.message,
                'message',
                isNot(contains(memoryDirectory)),
              ),
        ),
      );
      final snapshots = await backup.listSnapshots();
      expect(
        snapshots.map((snapshot) => snapshot.id),
        contains(result.snapshotId),
      );

      // 快照还在：换回正常写入即可完成恢复。
      await backup.rollbackTo(result.snapshotId);
      expect(snapshotMemoryTree(), before);
    });

    test('导入成功后可回滚到导入前，回滚本身也有保底快照', () async {
      await seedSession('2026-08-05', 1, [('用户', '旧会话')]);
      await File(path.join(memoryDirectory, 'long-memory.md')).writeAsString(
        '# long-memory\n\n## 人与关系\n- 导入前的印象\n',
        flush: true,
      );
      final before = snapshotMemoryTree();

      final bundle = buildBundle({
        'long-memory.md': '# long-memory\n\n## 人与关系\n- 导入后的印象\n',
        'relationship.md': '# relationship\n\nstage: familiar\n',
      });
      final result = await backup.importBundle(bundle);
      expect(result.replaced, 1);
      expect(result.added, 1);
      expect(
        await File(path.join(memoryDirectory, 'long-memory.md'))
            .readAsString(),
        contains('导入后的印象'),
      );

      final snapshots = await backup.listSnapshots();
      expect(snapshots, isNotEmpty);
      expect(snapshots.first.id, result.snapshotId);

      final rollback = await backup.rollbackTo();
      expect(rollback.snapshotId, result.snapshotId);
      expect(rollback.safetySnapshotId, isNot(result.snapshotId));
      expect(snapshotMemoryTree(), before);

      // 回滚后再导入：导入前的状态仍可再次恢复（保底快照在）。
      final snapshotsAfter = await backup.listSnapshots();
      expect(snapshotsAfter.length, greaterThanOrEqualTo(2));
    });
  });


  group('受限解压预算', () {
    MemoryBackupService budgeted(MemoryBackupBudget budget) =>
        MemoryBackupService(
          memoryDirectory: memoryDirectory,
          memoryControls: memoryControls,
          episodePipeline: pipeline,
          personaTree: personaTree,
          memoryActions: actions,
          clock: () => clock,
          diagnosticsSink: (_) {},
          budget: budget,
        );

    Matcher rejectedWith(String code) => throwsA(
      isA<BackupValidationException>().having(
        (error) => error.code,
        'code',
        code,
      ),
    );

    test('高压缩率小体积包超出总预算被拒绝，现有数据不变', () async {
      await seedRichMemory();
      final before = snapshotMemoryTree();
      // 一兆字节的零经 deflate 压到几 KB：小体积大展开的典型形态。
      final bundle = buildBundle({
        'sessions/2026/08/bomb.md': '0' * (1024 * 1024),
      });

      await expectLater(
        () => budgeted(
          const MemoryBackupBudget(maxTotalBytes: 64 * 1024),
        ).previewImport(bundle),
        rejectedWith('unexpected-content'),
      );
      expect(snapshotMemoryTree(), before);
    });

    test('虚报声明大小不能绕过单项预算：按真实解压输出计数', () async {
      // 头部与清单都按 8 字节谎报，真实解压输出是一兆字节的零。
      final realBytes = Uint8List(1024 * 1024);
      final bundle = buildRawBackup(
        declared: [
          (
            'memory/sessions/2026/08/lie.md',
            8,
            sha256.convert(realBytes).toString(),
          ),
        ],
        entries: [
          _RawZipEntry(
            'memory/sessions/2026/08/lie.md',
            realBytes: realBytes,
            declaredUncompressed: 8,
          ),
        ],
      );

      await expectLater(
        () => budgeted(
          const MemoryBackupBudget(
            maxTotalBytes: 4 * 1024 * 1024,
            maxEntryBytes: 32 * 1024,
          ),
        ).previewImport(bundle),
        rejectedWith('unexpected-content'),
      );
    });

    test('虚报声明大小不能绕过总量预算：逐块计数中途失败', () async {
      // 第一条诚实（store，40 KB）；第二条头部与清单谎报 8 字节、
      // 真实展开 40 KB：总账只能在第二条解压途中超限。
      final honest = Uint8List.fromList(utf8.encode('a' * (40 * 1024)));
      final lie = Uint8List(40 * 1024);
      final bundle = buildRawBackup(
        declared: [
          (
            'memory/sessions/2026/08/first.md',
            honest.length,
            sha256.convert(honest).toString(),
          ),
          (
            'memory/sessions/2026/08/second.md',
            8,
            sha256.convert(lie).toString(),
          ),
        ],
        entries: [
          _RawZipEntry(
            'memory/sessions/2026/08/first.md',
            realBytes: honest,
            compressionMethod: 0,
          ),
          _RawZipEntry(
            'memory/sessions/2026/08/second.md',
            realBytes: lie,
            declaredUncompressed: 8,
          ),
        ],
      );

      await expectLater(
        () => budgeted(
          const MemoryBackupBudget(
            maxTotalBytes: 64 * 1024,
            maxEntryBytes: 1024 * 1024,
          ),
        ).previewImport(bundle),
        rejectedWith('unexpected-content'),
      );
    });

    test('单项声明超出预算在展开前拒绝', () async {
      final bundle = buildBundle({
        'sessions/2026/08/big-one.md': 'a' * (40 * 1024),
        'sessions/2026/08/big-two.md': 'a' * (40 * 1024),
      });

      await expectLater(
        () => budgeted(
          const MemoryBackupBudget(
            maxTotalBytes: 4 * 1024 * 1024,
            maxEntryBytes: 32 * 1024,
          ),
        ).previewImport(bundle),
        rejectedWith('unexpected-content'),
      );
    });

    test('恰好在单项预算边界的内容可以预览，超出一个字节拒绝', () async {
      const budget = MemoryBackupBudget(
        maxTotalBytes: 1024 * 1024,
        maxEntryBytes: 32 * 1024,
      );
      final atLimit = await budgeted(budget).previewImport(
        buildBundle({'long-memory.md': 'a' * (32 * 1024)}),
      );
      expect(atLimit.countOf(BackupItemCategory.added), 1);

      final overByOne = buildBundle({
        'long-memory.md': 'a' * (32 * 1024 + 1),
      });
      await expectLater(
        () => budgeted(budget).previewImport(overByOne),
        rejectedWith('unexpected-content'),
      );
    });

    test('条目数量超出预算被拒绝', () async {
      final bundle = buildBundle({
        for (var index = 0; index < 201; index += 1)
          'sessions/2026/08/filler-$index.md': '- 一条印象\n',
      });

      await expectLater(
        () => budgeted(
          const MemoryBackupBudget(maxEntries: 200),
        ).previewImport(bundle),
        rejectedWith('unexpected-content'),
      );
    });

    // 中心目录名称 = 'memory/' + 相对路径，UTF-8 字节 32767；256 个
    // 条目加上 'manifest.md' 条目名后合计 8388363 字节，恰在 8 MiB
    // （生产默认目录元数据预算）之内；257 个条目即超出。
    String longName(int index) =>
        'sessions/2026/08/${index.toString().padRight(32740, 'a')}.md';

    test('目录元数据恰在预算内可以预览', () async {
      final preview = await backup.previewImport(
        buildBundle({
          for (var index = 0; index < 256; index += 1)
            longName(index): '- 一条印象\n',
        }),
      );
      // 会话结构无法识别归为不可恢复，但预览本身完成：预算内不拒绝。
      expect(preview.countOf(BackupItemCategory.unrecoverable), 256);
    });

    test('目录元数据超出预算被拒绝', () async {
      final bundle = buildBundle({
        for (var index = 0; index < 257; index += 1)
          longName(index): '- 一条印象\n',
      });

      await expectLater(
        () => backup.previewImport(bundle),
        rejectedWith('unexpected-content'),
      );
    });

    test('符号链接形态的条目被拒绝', () async {
      final bytes = Uint8List.fromList(utf8.encode('../outside/target\n'));
      final bundle = buildRawBackup(
        declared: [
          (
            'memory/long-memory.md',
            bytes.length,
            sha256.convert(bytes).toString(),
          ),
        ],
        entries: [
          _RawZipEntry(
            'memory/long-memory.md',
            realBytes: bytes,
            compressionMethod: 0,
            versionMadeBy: (3 << 8) | 20,
            externalAttributes: 0xa1a4 << 16,
          ),
        ],
      );

      await expectLater(
        () => backup.previewImport(bundle),
        rejectedWith('unexpected-content'),
      );
    });

    test('越界路径、绝对路径与反斜杠路径被拒绝', () async {
      for (final evil in ['../evil.md', '/etc/evil.md']) {
        final bundle = buildBundle({
          'long-memory.md': '# ok\n',
        }, extraEntryPath: evil);
        await expectLater(
          () => backup.previewImport(bundle),
          rejectedWith('unexpected-content'),
        );
      }
      // 反斜杠分隔名会被 ZipEncoder 规范化成斜杠，需要手工 zip 保留。
      final okBytes = Uint8List.fromList(utf8.encode('# ok\n'));
      final evilBytes = Uint8List.fromList(utf8.encode('evil\n'));
      final bundle = buildRawBackup(
        declared: [
          (
            'memory/long-memory.md',
            okBytes.length,
            sha256.convert(okBytes).toString(),
          ),
        ],
        entries: [
          _RawZipEntry(
            'memory/long-memory.md',
            realBytes: okBytes,
            compressionMethod: 0,
          ),
          _RawZipEntry(
            'memory\\evil.md',
            realBytes: evilBytes,
            compressionMethod: 0,
          ),
        ],
      );
      await expectLater(
        () => backup.previewImport(bundle),
        rejectedWith('unexpected-content'),
      );
    });

    test('导入路径超出预算同样拒绝，不建快照不变更数据', () async {
      await seedRichMemory();
      final before = snapshotMemoryTree();
      final bundle = buildBundle({
        'sessions/2026/08/bomb.md': '0' * (1024 * 1024),
      });

      await expectLater(
        () => budgeted(
          const MemoryBackupBudget(maxTotalBytes: 64 * 1024),
        ).importBundle(bundle),
        rejectedWith('unexpected-content'),
      );
      expect(snapshotMemoryTree(), before);
      // 预算失败发生在快照之前：不得出现任何保底快照。
      expect(
        Directory(path.join(memoryDirectory, 'backups')).existsSync(),
        isFalse,
      );
    });

    test('目录元数据按真实字节数计：非 ASCII 名称不能放大预算', () async {
      // 每个名称约 9900 个汉字：码元数 3×9927+11≈2.98 万在注入预算内，
      // UTF-8 字节数 3×29727+11≈8.9 万远超预算——按字节计必须拒绝。
      String cjkName(int index) =>
          'sessions/2026/08/${index.toString().padRight(9900, '记')}.md';
      final bundle = buildBundle({
        for (var index = 0; index < 3; index += 1) cjkName(index): '- 一条印象\n',
      });

      await expectLater(
        () => budgeted(
          const MemoryBackupBudget(maxMetadataBytes: 30000),
        ).previewImport(bundle),
        rejectedWith('unexpected-content'),
      );
    });

    test('解压期间的意外失败留下诊断，仍按无效备份拒绝', () async {
      final diagnostics = <String>[];
      final probing = MemoryBackupService(
        memoryDirectory: memoryDirectory,
        memoryControls: memoryControls,
        episodePipeline: pipeline,
        personaTree: personaTree,
        memoryActions: actions,
        clock: () => clock,
        diagnosticsSink: diagnostics.add,
      );
      // 压缩流是坏字节：解压立即失败。拒绝类别不变，但不能无声。
      final bundle = buildRawBackup(
        declared: [
          (
            'memory/long-memory.md',
            8,
            sha256.convert(Uint8List(8)).toString(),
          ),
        ],
        entries: [
          _RawZipEntry(
            'memory/long-memory.md',
            realBytes: Uint8List(8),
            declaredUncompressed: 8,
            compressedBytes: Uint8List.fromList(const [
              0xff,
              0xff,
              0xff,
              0xff,
            ]),
          ),
        ],
      );

      await expectLater(
        () => probing.previewImport(bundle),
        rejectedWith('not-a-backup'),
      );
      expect(diagnostics, isNotEmpty);
    });

    test('AES 形态与方法号不可识别的条目被拒绝', () async {
      // 方法号 99（AES）在解码库里被归一成无压缩且加密位不置位：
      // 按中心头方法号原值拒绝，绝不当作明文内容放行。
      final bytes = Uint8List.fromList(utf8.encode('aes-ciphertext\n'));
      final bundle = buildRawBackup(
        declared: [
          (
            'memory/long-memory.md',
            bytes.length,
            sha256.convert(bytes).toString(),
          ),
        ],
        entries: [
          _RawZipEntry(
            'memory/long-memory.md',
            realBytes: bytes,
            compressionMethod: 99,
          ),
        ],
      );

      await expectLater(
        () => backup.previewImport(bundle),
        throwsA(
          isA<BackupValidationException>()
              .having((error) => error.code, 'code', 'unexpected-content')
              .having(
                (error) => error.message,
                'message',
                '备份包含不支持的加密或压缩方式，已拒绝。',
              ),
        ),
      );
    });

    test('目录元数据把条目注释计入预算', () async {
      // 条目注释同属中心目录元数据：约 6 万字节的注释远超注入预算。
      final okBytes = Uint8List.fromList(utf8.encode('# ok\n'));
      final bundle = buildRawBackup(
        declared: [
          (
            'memory/long-memory.md',
            okBytes.length,
            sha256.convert(okBytes).toString(),
          ),
        ],
        entries: [
          _RawZipEntry(
            'memory/long-memory.md',
            realBytes: okBytes,
            compressionMethod: 0,
            fileComment: '注' * 20000,
          ),
        ],
      );

      await expectLater(
        () => budgeted(
          const MemoryBackupBudget(maxMetadataBytes: 8 * 1024),
        ).previewImport(bundle),
        rejectedWith('unexpected-content'),
      );
    });
  });
}

/// 手工构造的原始 zip 条目：内容按 [realBytes] 真实编码，头部的解压
/// 声明、制造系统、条目注释与外部属性可独立指定，用来验证验证器
/// 不信任头部声明、并识别符号链接形态；[compressedBytes] 可手工指定
/// 坏压缩流。
final class _RawZipEntry {
  const _RawZipEntry(
    this.name, {
    required this.realBytes,
    this.compressionMethod = 8,
    int? declaredUncompressed,
    this.compressedBytes,
    this.fileComment = '',
    this.versionMadeBy = 20,
    this.externalAttributes = 0,
  }) : declaredUncompressed = declaredUncompressed ?? realBytes.length;

  final String name;
  final Uint8List realBytes;
  final int compressionMethod;
  final int declaredUncompressed;
  final Uint8List? compressedBytes;
  final String fileComment;
  final int versionMadeBy;
  final int externalAttributes;
}

/// 与 EpisodeMemoryPipeline 写入端同构的日文件渲染：手工构造「旧规则
/// 时代」的日文件——标记载荷与可见行都带未脱敏秘密。
String _renderLegacyEpisodeDay({
  required String date,
  required String summary,
  required String entrySummary,
  required String evidence,
}) {
  final at = DateTime.parse('${date}T20:00:00Z').toUtc();
  final meta = encodeMarkerPayload({
    'schemaVersion': 1,
    'date': date,
    'updatedAt': at.toIso8601String(),
    'summary': summary,
    'finalized': true,
    'finalizedAt': DateTime.parse(
      '${date}T23:00:00Z',
    ).toUtc().toIso8601String(),
  });
  final entry = encodeMarkerPayload({
    'id': 'legacy-e1',
    'sessionId': 'legacy-secret-session',
    'requestId': 'legacy-1',
    'summary': entrySummary,
    'evidence': evidence,
    'at': at.toIso8601String(),
  });
  return '# 栖语每日记录\n\n'
      '<!-- qiyu-episode:$meta -->\n\n'
      '## summary\n$summary\n\n'
      '<!-- qiyu-episode-entry:$entry -->\n'
      '## ${at.toLocal().toIso8601String()} · $entrySummary\n\n'
      '> $evidence\n\n';
}

/// 导入与恢复中断模拟：[failOnWrite] 中任一序号的写入抛错，其余正常
/// 落盘——模拟磁盘偶发故障，覆盖导入与恢复两个阶段。
final class _FailingByteWriter implements BackupByteWriter {
  _FailingByteWriter({this.failOnWrite = const {}});

  final Set<int> failOnWrite;
  var _writes = 0;

  @override
  Future<void> write(String targetPath, Uint8List bytes) async {
    _writes += 1;
    if (failOnWrite.contains(_writes)) {
      throw const FileSystemException('simulated disk failure');
    }
    final target = File(targetPath);
    await target.create(recursive: true);
    await target.writeAsBytes(bytes, flush: true);
  }
}
