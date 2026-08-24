import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_windows_host/qiyu_windows_host.dart';
import 'package:test/test.dart';

void main() {
  group('RequestDiagnosticsRecorder', () {
    test('keeps only the newest entries within capacity, newest first', () {
      final recorder = RequestDiagnosticsRecorder(capacity: 3);
      for (var index = 0; index < 5; index += 1) {
        recorder.record(
          source: RecentRequestSources.chat,
          result: RecentRequestResults.ok,
          detail: 'seq=$index',
        );
      }
      final recent = recorder.recent();
      expect(recent, hasLength(3));
      expect(recent.first.detail, 'seq=4');
      expect(recent.last.detail, 'seq=2');
    });

    test('redacts secrets out of detail before buffering', () {
      const bareSecrets = [
        'as_sk_abcdefghijklmnopqrstuvwxyz123456',
        'ghp_abcdefghijklmnopqrstuvwxyz1234567890',
        'github_pat_abcdefghijklmnopqrstuvwxyz_1234567890',
        'glpat-abcdefghijklmnopqrst',
        'xoxp-123456789012-abcdefghijklmnopqrstuvwx',
        'AKIAIOSFODNN7EXAMPLE',
        'AIzaSyA1234567890abcdefghijklmnopqrstuvwxyz',
        'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnop',
      ];
      final recorder = RequestDiagnosticsRecorder();
      recorder.record(
        source: RecentRequestSources.chat,
        result: RecentRequestResults.failed,
        detail:
            'provider rejected sk-abcdefABCDEF1234567890 and '
            '${bareSecrets.join(' ')} then continued',
      );
      final entry = recorder.recent().single;
      expect(entry.detail, contains('[已脱敏]'));
      expect(entry.detail, isNot(contains('sk-abcdefABCDEF1234567890')));
      for (final secret in bareSecrets) {
        expect(entry.detail, isNot(contains(secret)), reason: secret);
      }
    });

    test('entry json never carries user text fields', () {
      final recorder = RequestDiagnosticsRecorder();
      recorder.record(
        source: RecentRequestSources.chat,
        result: RecentRequestResults.fallback,
        replySource: 'local',
        fallbackReason: FallbackReason.modelTimeout.wireName,
      );
      final json = recorder.recent().single.toJson();
      expect(
        json.keys,
        everyElement(isIn(const [
          'at',
          'source',
          'result',
          'replySource',
          'fallbackReason',
          'detail',
        ])),
      );
      expect(json['fallbackReason'], 'model_timeout');
      expect(json['replySource'], 'local');
    });
  });

  group('JsonExperienceSettingsRepository', () {
    late Directory temporaryDirectory;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'qiyu-experience-test-',
      );
    });

    tearDown(() async {
      if (temporaryDirectory.existsSync()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    JsonExperienceSettingsRepository repository() =>
        JsonExperienceSettingsRepository(
          filePath: path.join(temporaryDirectory.path, 'experience.json'),
        );

    test('defaults to developer mode off when the file is missing', () async {
      final settings = await repository().load();
      expect(settings.developerMode, isFalse);
    });

    test('falls back to defaults when the file is unreadable', () async {
      File(
        path.join(temporaryDirectory.path, 'experience.json'),
      ).writeAsStringSync('这不是 JSON');
      final settings = await repository().load();
      expect(settings.developerMode, isFalse);
    });

    test('saves and reloads developer mode', () async {
      final repo = repository();
      await repo.save(const ExperienceSettings(developerMode: true));
      expect((await repo.load()).developerMode, isTrue);
      await repo.save(const ExperienceSettings(developerMode: false));
      expect((await repo.load()).developerMode, isFalse);
    });
  });

  group('DeveloperDiagnosticsService', () {
    late Directory temporaryDirectory;
    late String memoryDirectory;
    late EpisodeMemoryPipeline pipeline;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'qiyu-diagnostics-test-',
      );
      memoryDirectory = path.join(temporaryDirectory.path, 'memories');
      await Directory(memoryDirectory).create(recursive: true);
      pipeline = EpisodeMemoryPipeline(
        memoryDirectory: memoryDirectory,
        clock: () => DateTime(2026, 8, 14, 22),
      );
    });

    tearDown(() async {
      if (temporaryDirectory.existsSync()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    DeveloperDiagnosticsService service({
      RequestDiagnosticsRecorder? recorder,
      DreamService? dreamService,
      MemoryControlsStore? memoryControls,
      MemoryRepository? repository,
      Future<bool> Function()? providerConfiguredReader,
      Clock? clock,
    }) {
      return DeveloperDiagnosticsService(
        memoryDirectory: memoryDirectory,
        recorder: recorder ?? RequestDiagnosticsRecorder(),
        episodePipeline: pipeline,
        dreamService: dreamService,
        memoryControls: memoryControls,
        repository: repository,
        providerConfiguredReader: providerConfiguredReader,
        clock: clock ?? () => DateTime(2026, 8, 14, 22),
      );
    }

    /// episode 落盘日期跟随管线时钟，用一支指向目标日期的管线播种。
    Future<void> seedEpisodeDay(String date) async {
      final seeder = EpisodeMemoryPipeline(
        memoryDirectory: memoryDirectory,
        clock: () => DateTime.parse('${date}T22:00:00'),
      );
      await seeder.processReply(
        session: RawSession(
          id: 'session-$date',
          date: date,
          segment: 1,
          createdAt: DateTime.parse('${date}T22:00:00').toUtc(),
          updatedAt: DateTime.parse('${date}T22:00:00').toUtc(),
          turns: [
            RawSessionTurn.user(
              requestId: 'req-$date',
              text: '今天还好',
              at: DateTime.parse('${date}T22:00:00'),
            ),
          ],
        ),
        requestId: 'req-$date',
        hiddenActions: const [
          HiddenAction(
            kind: HiddenActionKind.memorySignal,
            summary: '用户那天过得还行',
            evidence: '今天还好',
          ),
        ],
      );
    }

    test('finalization health counts unfinalized days before today', () async {
      await seedEpisodeDay('2026-08-13');

      var snapshot = await service().snapshot();
      var finalization = snapshot['finalization']! as Map<String, Object?>;
      expect(finalization['today'], '2026-08-14');
      expect(finalization['todayFinalized'], isFalse);
      expect(finalization['pendingDays'], 1);
      expect(finalization['unreadableDays'], 0);

      final finalizer = DailyFinalizationService(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
        clock: () => DateTime(2026, 8, 14, 22),
      );
      await finalizer.finalizeDay('2026-08-13');

      snapshot = await service().snapshot();
      finalization = snapshot['finalization']! as Map<String, Object?>;
      expect(finalization['pendingDays'], 0);
    });

    test('dream eligibility reflects interval, pending and provider', () async {
      final dream = DreamService(
        memoryDirectory: memoryDirectory,
        episodePipeline: pipeline,
        clock: () => DateTime(2026, 8, 14, 22),
        diagnosticsSink: (_) {},
      );

      // 无状态文件：间隔天然满足，未配置 Provider 时仍不合格。
      var snapshot = await service(
        dreamService: dream,
        providerConfiguredReader: () async => false,
      ).snapshot();
      var dreamJson = snapshot['dream']! as Map<String, Object?>;
      expect(dreamJson['intervalSatisfied'], isTrue);
      expect(dreamJson['pending'], isFalse);
      expect(dreamJson['eligible'], isFalse);

      // 三天前刚成功：间隔未满，即使配置了 Provider 也不合格。
      await File(path.join(memoryDirectory, 'dream', 'state.md'))
          .create(recursive: true);
      await File(path.join(memoryDirectory, 'dream', 'state.md'))
          .writeAsString(_encodedDreamState(lastSuccess: DateTime(2026, 8, 11)));
      snapshot = await service(
        dreamService: dream,
        providerConfiguredReader: () async => true,
      ).snapshot();
      dreamJson = snapshot['dream']! as Map<String, Object?>;
      expect(dreamJson['daysSinceLastSuccess'], 3);
      expect(dreamJson['intervalSatisfied'], isFalse);
      expect(dreamJson['providerConfigured'], isTrue);
      expect(dreamJson['eligible'], isFalse);

      // 八天前成功：间隔已满且配置齐全 → 合格。
      await File(path.join(memoryDirectory, 'dream', 'state.md'))
          .writeAsString(_encodedDreamState(lastSuccess: DateTime(2026, 8, 6)));
      snapshot = await service(
        dreamService: dream,
        providerConfiguredReader: () async => true,
      ).snapshot();
      dreamJson = snapshot['dream']! as Map<String, Object?>;
      expect(dreamJson['daysSinceLastSuccess'], 8);
      expect(dreamJson['eligible'], isTrue);
    });

    test('file health reports corrupted long-memory and unreadable session', () async {
      File(
        path.join(memoryDirectory, 'long-memory.md'),
      ).writeAsStringSync('这根本不是 long-memory 结构');
      final sessionsDirectory = Directory(
        path.join(memoryDirectory, 'sessions', '2026', '08'),
      )..createSync(recursive: true);
      File(
        path.join(sessionsDirectory.path, 'broken.md'),
      ).writeAsStringSync('坏的会话文件');
      final repository = MarkdownMemoryRepository(
        memoryDirectory: memoryDirectory,
      );
      await repository.initialize();
      final controls = MemoryControlsStore(
        memoryDirectory: memoryDirectory,
        diagnosticsSink: (_) {},
      );

      final snapshot = await service(
        memoryControls: controls,
        repository: repository,
      ).snapshot();
      final health = snapshot['fileHealth']! as Map<String, Object?>;
      expect(health['longMemory'], {'exists': true, 'readable': false});
      expect(health['memoryControls'], {'exists': false, 'readable': true});
      expect(health['sessionsUnavailable'], 1);
      expect(health['episodeDays'], 0);
    });

    test('snapshot json survives the sensitive-field scan', () async {
      final recorder = RequestDiagnosticsRecorder();
      recorder.record(
        source: RecentRequestSources.providerTest,
        result: RecentRequestResults.failed,
        detail: 'authorization: Bearer sk-abcdefABCDEF1234567890 '
            'api_key: sk-9876543210zyxwvuSRQP '
            'cookie=session=abc123 '
            'prompt: 用户输入了密码=secret',
      );
      final encoded = jsonEncode(await service(recorder: recorder).snapshot());

      // 原始敏感值绝不出现；脱敏占位符保留。
      for (final secret in const [
        'sk-abcdefABCDEF1234567890',
        'sk-9876543210zyxwvuSRQP',
        'abc123',
        'secret',
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
      expect(encoded, contains('[已脱敏]'));

      // 敏感形态正则在整份快照里扫不出任何命中。
      const shapes = [
        'sk-[A-Za-z0-9_-]{16,}',
        'Bearer\\s+[A-Za-z0-9._~+/=-]{8,}',
        '(?<!\\d)\\d{17}[\\dXx](?!\\d)',
      ];
      for (final shape in shapes) {
        expect(
          RegExp(shape, caseSensitive: false).hasMatch(encoded),
          isFalse,
          reason: 'diagnostics leaked sensitive shape: $shape',
        );
      }
    });
  });
}

/// 与 DreamService 内部编码同构的测试夹具：直接落一份 state.md。
String _encodedDreamState({DateTime? lastSuccess, bool pending = false}) {
  final json = <String, Object?>{
    'schemaVersion': 1,
    if (lastSuccess != null) 'lastSuccess': lastSuccess.toUtc().toIso8601String(),
    'pending': pending,
  };
  final encoded = base64Url
      .encode(utf8.encode(jsonEncode(json)))
      .replaceAll('=', '');
  return '# dream-state\n\n<!-- qiyu-dream-state:$encoded -->\n';
}
