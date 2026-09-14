import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:qiyu_local_host/src/onboarding_routes.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support/in_process_chat_host.dart';

void main() {
  group('维护与用户操作准入', () {
    for (final action in ['edit', 'freeze', 'ban', 'delete', 'appellation']) {
      test('维护等待已准入的 $action 完整结束', () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        final write = fixture.writer.pauseNext();
        final pendingAction = fixture.act(action);
        await write.entered.future;
        final maintenanceEntered = Completer<void>();
        final maintenance = fixture.chat.runExclusively(() async {
          maintenanceEntered.complete();
        });
        await Future<void>.delayed(Duration.zero);
        final enteredEarly = maintenanceEntered.isCompleted;
        write.release.complete();
        await pendingAction;
        await maintenance;
        expect(enteredEarly, isFalse);
      });

      test('维护先准入时新的 $action 等待维护完成', () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        final entered = Completer<void>();
        final release = Completer<void>();
        final maintenance = fixture.chat.runExclusively(() async {
          entered.complete();
          await release.future;
        });
        await entered.future;
        final writesBefore = fixture.writer.writes;
        var completed = false;
        final pendingAction = fixture.act(action).then((value) {
          completed = true;
          return value;
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final completedEarly = completed;
        final writesDuringMaintenance = fixture.writer.writes - writesBefore;
        release.complete();
        await maintenance;
        await pendingAction;
        expect(completedEarly, isFalse);
        expect(writesDuringMaintenance, 0);
        expect(fixture.writer.writes, greaterThan(writesBefore));
      });
    }

    test('等待在途 UI 时先保留聊天维护位置，新聊天不会插队', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final write = fixture.writer.pauseNext();
      final uiAction = fixture.tree.setAppellation('老王');
      await write.entered.future;
      final events = <String>[];
      final maintenance = fixture.chat.runExclusively(() async {
        events.add('maintenance');
      });
      final chat = fixture.chat
          .deliver(requestId: 'queued', text: '今天有点累')
          .toList()
          .then((_) => events.add('chat'));
      await Future<void>.delayed(Duration.zero);
      write.release.complete();
      await uiAction;
      await Future.wait([maintenance, chat]);
      expect(events, ['maintenance', 'chat']);
    });

    test('维护内部称呼修改可完成，失败后重新开放用户准入', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      await expectLater(
        fixture.chat.runExclusively(() async {
          await fixture.tree.setAppellation('老王');
          throw StateError('maintenance failed');
        }),
        throwsStateError,
      );
      expect(await fixture.tree.setAppellation('小林'), '小林');
    });

    test('首见称呼与完成标记属于同一项在途操作', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final onboardingWriter = _GatedWriter();
      final onboardingFile = path.join(
        fixture.directory.path,
        'onboarding.json',
      );
      final routes = OnboardingRoutes(
        onboardingRepository: JsonOnboardingRepository(
          filePath: onboardingFile,
          writer: onboardingWriter,
        ),
        personaTree: fixture.tree,
      );
      final write = onboardingWriter.pauseNext();
      final complete = routes.handle(
        Request(
          'POST',
          Uri.parse('http://localhost/api/onboarding/complete'),
          body: jsonEncode({'appellation': '老王'}),
        ),
      );
      await write.entered.future;
      final maintenanceEntered = Completer<void>();
      final maintenance = fixture.chat.runExclusively(() async {
        maintenanceEntered.complete();
        if (await File(onboardingFile).exists()) {
          await File(onboardingFile).delete();
        }
      });
      await Future<void>.delayed(Duration.zero);
      final enteredEarly = maintenanceEntered.isCompleted;
      write.release.complete();
      expect((await complete)!.statusCode, HttpStatus.ok);
      await maintenance;
      expect(enteredEarly, isFalse);
      expect(await File(onboardingFile).exists(), isFalse);
    });
  });

  group('真实 Host 的维护写入顺序', () {
    for (final operation in ['clear', 'import', 'rollback']) {
      test('$operation 的维护快照包含在途称呼写入', () async {
        final writer = _GatedWriter();
        final harness = await InProcessChatHost.start(atomicWriter: writer);
        addTearDown(harness.dispose);
        await harness.host.memoryCadence.finalizePending();
        expect(
          (await harness.postJson('/api/memory/appellation', {
            'appellation': '小林',
          })).statusCode,
          HttpStatus.ok,
        );
        final (exportStatus, bundle) = await harness.getBytes(
          '/api/backup/export',
        );
        expect(exportStatus, HttpStatus.ok);
        if (operation == 'rollback') {
          expect(
            (await harness.postJson('/api/backup/import', {
              'dataBase64': base64.encode(bundle),
            })).statusCode,
            HttpStatus.ok,
          );
        }
        final write = writer.pauseNext();
        final uiAction = harness.postJson('/api/memory/appellation', {
          'appellation': '老王',
        });
        await write.entered.future;
        final maintenance = operation == 'clear'
            ? harness.postJson('/api/data/clear', {'confirm': true})
            : harness.postJson('/api/backup/$operation', {
                if (operation == 'import') 'dataBase64': base64.encode(bundle),
              });
        final result = await maintenance.timeout(
          const Duration(seconds: 1),
          onTimeout: () {
            write.release.complete();
            return maintenance;
          },
        );
        if (!write.release.isCompleted) write.release.complete();
        expect((await uiAction).statusCode, HttpStatus.ok);
        expect(result.statusCode, HttpStatus.ok);
        final json = jsonDecode(result.body) as Map<String, Object?>;
        final snapshotId =
            json[operation == 'rollback' ? 'safetySnapshotId' : 'snapshotId'];
        expect(snapshotId, isA<String>());
        final snapshot = File(
          path.join(
            harness.memoryDirectory,
            'backups',
            snapshotId! as String,
            'persona.md',
          ),
        );
        expect(await snapshot.readAsString(), contains('老王'));
        if (operation == 'clear') {
          expect(
            File(path.join(harness.memoryDirectory, 'persona.md')).existsSync(),
            isFalse,
          );
        }
      });
    }

    test('聊天禁提不会与正在排空聊天的维护互相等待', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final harness = await InProcessChatHost.start(
        modelGateway: ScriptedModelGateway(
          streamScript: const [ScriptedStreamReply('''记住了，以后就不提这件事了。
<qiyu-actions>
[{"action":"memory_ban","summary":"合成演讲"}]
</qiyu-actions>''')],
        ),
        deliveryPause: (_) async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        },
      );
      addTearDown(harness.dispose);
      final chat = harness.openChat(requestId: 'ban', text: '以后别提合成演讲');
      await entered.future;
      final backup = harness.getBytes('/api/backup/export');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      release.complete();
      await chat.done.timeout(const Duration(seconds: 3));
      expect((await backup).$1, HttpStatus.ok);
      final controls = await MemoryControlsStore(
        memoryDirectory: harness.memoryDirectory,
      ).load();
      expect(controls.banned.single.summary, '合成演讲');
      expect(controls.banned.single.origin, 'chat');
    });
    test('聊天交付中的称呼更新不会与排队维护互相等待', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final harness = await InProcessChatHost.start(
        modelGateway: ScriptedModelGateway(
          streamScript: const [ScriptedStreamReply('记住了，今晚慢慢休息，明天再聊也可以。')],
        ),
        deliveryPause: (_) async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        },
      );
      addTearDown(harness.dispose);
      final chat = harness.openChat(requestId: 'name', text: '以后叫我老王');
      await entered.future;
      final backup = harness.getBytes('/api/backup/export');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      release.complete();
      await chat.done.timeout(const Duration(seconds: 3));
      expect((await backup).$1, HttpStatus.ok);
      expect(
        await File(
          path.join(harness.memoryDirectory, 'persona.md'),
        ).readAsString(),
        contains('老王'),
      );
    });
  });
}

final class _Fixture {
  _Fixture(this.directory, this.writer, this.tree, this.actions, this.chat);
  final Directory directory;
  final _GatedWriter writer;
  final PersonaTreeStore tree;
  final MemoryActionService actions;
  final LocalChatService chat;

  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp('qiyu-admission-');
    final writer = _GatedWriter();
    final pipeline = EpisodeMemoryPipeline(
      memoryDirectory: directory.path,
      atomicWriter: writer,
    );
    final controls = MemoryControlsStore(
      memoryDirectory: directory.path,
      commits: pipeline.commits,
      atomicWriter: writer,
    );
    final loops = OpenLoopStore(
      memoryDirectory: directory.path,
      memoryControls: controls,
      atomicWriter: writer,
    );
    final tree = PersonaTreeStore(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      openLoopStore: loops,
      atomicWriter: writer,
    );
    final monthly = MonthlySummaryStore(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      atomicWriter: writer,
    );
    final actions = MemoryActionService(
      memoryDirectory: directory.path,
      episodePipeline: pipeline,
      personaTree: tree,
      memoryControls: controls,
      openLoopStore: loops,
      monthlySummary: monthly,
      relationshipLifecycle: RelationshipLifecycle(
        memoryDirectory: directory.path,
      ),
      atomicWriter: writer,
    );
    final chat = LocalChatService(
      MarkdownMemoryRepository(memoryDirectory: directory.path),
      episodePipeline: pipeline,
      personaTree: tree,
      deliveryPause: (_) async {},
    );
    await chat.initialize();
    await File(
      path.join(directory.path, 'long-memory.md'),
    ).writeAsString('# long-memory\n\n## 人与关系\n- 用户养了一只猫\n');
    return _Fixture(directory, writer, tree, actions, chat);
  }

  Future<Object?> act(String action) {
    const ref = MemoryLongTermRef('人与关系', '用户养了一只猫');
    return switch (action) {
      'edit' => actions.edit(ref, '用户养了一只狗'),
      'freeze' => actions.freeze(ref),
      'ban' => actions.ban(ref),
      'delete' => actions.delete(ref),
      'appellation' => tree.setAppellation('老王'),
      _ => throw ArgumentError.value(action),
    };
  }

  Future<void> dispose() => directory.delete(recursive: true);
}

final class _WriteGate {
  final entered = Completer<void>();
  final release = Completer<void>();
}

final class _GatedWriter implements AtomicTextWriter {
  _WriteGate? _next;
  int writes = 0;
  _WriteGate pauseNext() => _next = _WriteGate();

  @override
  Future<void> replace(String target, String contents) async {
    writes += 1;
    final gate = _next;
    _next = null;
    if (gate != null) {
      gate.entered.complete();
      await gate.release.future;
    }
    await const IoAtomicTextWriter().replace(target, contents);
  }
}
