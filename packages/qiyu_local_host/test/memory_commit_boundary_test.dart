import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/failing_atomic_writer.dart';

const _original = '用户完成了第一次演讲';
const _corrected = '用户还没有完成第一次演讲';
final _now = DateTime(2026, 9, 14, 23);

void main() {
  test(
    'completed writes invalidate a candidate even when content is restored',
    () async {
      final fixture = await _fixture();
      final originalFile = await fixture.longMemory.readAsString();
      final pending = fixture.dream.run(bedtime: true);
      await fixture.client.entered.future;
      await fixture.actions.edit(
        const MemoryLongTermRef('重要事件', _original),
        _corrected,
      );
      await fixture.actions.edit(
        const MemoryLongTermRef('重要事件', _corrected),
        _original,
      );
      expect(await fixture.longMemory.readAsString(), originalFile);
      fixture.client.answer.complete(ModelCompletion.reply(_candidate()));
      expect((await pending).status, DreamStatus.deferredConflict);
    },
  );

  test(
    'a success-state failure after replacement retains catch-up eligibility',
    () async {
      var stateWrites = 0;
      final writer = FailingAtomicTextWriter(
        shouldFail: (target) =>
            path.basename(target) == 'state.md' && ++stateWrites == 2,
      );
      final fixture = await _fixture(writer: writer);
      fixture.client.next = ModelCompletion.reply(_candidate(_corrected));
      final outcome = await fixture.dream.run(bedtime: true);
      expect(outcome.status, DreamStatus.writeFailed);
      expect(await fixture.longMemory.readAsString(), contains(_corrected));
      final state = await fixture.dream.readState();
      expect(state.lastSuccess, isNull);
      expect(state.pending, isTrue);
      expect(
        (await fixture.dream.run(bedtime: false)).status,
        DreamStatus.accepted,
      );
    },
  );

  for (final operation in ['edit', 'delete']) {
    test(
      'a saved $operation invalidates the waiting Dream candidate',
      () async {
        final fixture = await _fixture();
        final pending = fixture.dream.run(bedtime: true);
        await fixture.client.entered.future;
        const ref = MemoryLongTermRef('重要事件', _original);
        final result = operation == 'edit'
            ? await fixture.actions.edit(ref, _corrected)
            : await fixture.actions.delete(ref);
        expect(result.status, MemoryActionStatus.success);
        final saved = await fixture.longMemory.readAsString();
        expect(saved, isNot(contains('- $_original')));
        fixture.client.answer.complete(ModelCompletion.reply(_candidate()));

        final outcome = await pending;
        expect(outcome.status, isNot(DreamStatus.accepted));
        expect(await fixture.longMemory.readAsString(), saved);
        final state = await fixture.dream.readState();
        expect(state.lastSuccess, isNull);
        expect(state.pending, isTrue);
        if (operation == 'edit') {
          fixture.client.next = ModelCompletion.reply(_candidate(_corrected));
          expect(
            (await fixture.dream.run(bedtime: false)).status,
            DreamStatus.accepted,
          );
          expect(await fixture.longMemory.readAsString(), contains(_corrected));
          expect((await fixture.dream.readState()).pending, isFalse);
        }
      },
    );
  }

  for (final operation in [
    'freeze',
    'ban',
    'unfreeze',
    'unban',
    'appellation',
  ]) {
    test('$operation invalidates the waiting candidate', () async {
      final fixture = await _fixture();
      const ref = MemoryLongTermRef('重要事件', _original);
      final pending = fixture.dream.run(bedtime: true);
      await fixture.client.entered.future;
      switch (operation) {
        case 'freeze':
          await fixture.actions.freeze(ref);
        case 'ban':
          await fixture.actions.ban(ref);
        case 'unfreeze':
          await fixture.actions.freeze(ref);
          await fixture.actions.unfreeze(ref);
        case 'unban':
          await fixture.actions.ban(ref);
          await fixture.actions.unban(ref);
        case 'appellation':
          await fixture.actions.personaTree.setAppellation('小禾');
      }
      final saved = await fixture.longMemory.readAsString();
      fixture.client.answer.complete(ModelCompletion.reply(_candidate()));
      expect((await pending).status, DreamStatus.deferredConflict);
      expect(await fixture.longMemory.readAsString(), saved);
      if (operation == 'appellation') {
        expect(await fixture.actions.personaTree.readAppellation(), '小禾');
      }
    });
  }

  for (final external in [false, true]) {
    test(
      'same-time same-size ${external ? 'external' : 'product'} edit invalidates Dream',
      () async {
        final fixture = await _fixture();
        final pending = fixture.dream.run(bedtime: true);
        await fixture.client.entered.future;
        final before = await fixture.longMemory.stat();
        const replacement = '用户放弃了第一次演讲';
        if (external) {
          final contents = await fixture.longMemory.readAsString();
          await fixture.longMemory.writeAsString(
            contents.replaceAll(_original, replacement),
          );
        } else {
          await fixture.actions.edit(
            const MemoryLongTermRef('重要事件', _original),
            replacement,
          );
        }
        await fixture.longMemory.setLastModified(before.modified);
        final after = await fixture.longMemory.stat();
        expect(after.size, before.size);
        expect(after.modified, before.modified);
        fixture.client.answer.complete(ModelCompletion.reply(_candidate()));
        expect((await pending).status, DreamStatus.deferredConflict);
        expect(await fixture.longMemory.readAsString(), contains(replacement));
      },
    );
  }

  test(
    'saved control invalidates Dream while derived cleanup waits for the day task',
    () async {
      final writer = _ObservedWriter(memoryControlsFileName);
      final fixture = await _fixture(writer: writer);
      final pending = fixture.dream.run(bedtime: true);
      await fixture.client.entered.future;
      final dayEntered = Completer<void>();
      final releaseDay = Completer<void>();
      final dayTask = fixture.actions.episodePipeline.synchronizedOnDayFiles(
        () async {
          dayEntered.complete();
          await releaseDay.future;
        },
      );
      await dayEntered.future;
      var deleteFinished = false;
      final deleting = fixture.actions.delete(
        const MemoryLongTermRef('重要事件', _original),
      )..then((_) => deleteFinished = true);
      await writer.written.future;
      fixture.client.answer.complete(ModelCompletion.reply(_candidate()));
      try {
        expect(
          (await pending.timeout(const Duration(seconds: 3))).status,
          DreamStatus.deferredConflict,
        );
        expect(deleteFinished, isFalse);
        expect((await fixture.dream.readState()).pending, isTrue);
      } finally {
        releaseDay.complete();
        await dayTask;
        await deleting;
      }
      expect(
        await fixture.longMemory.readAsString(),
        isNot(contains(_original)),
      );
    },
  );

  test('partial cleanup cannot preserve an old Dream credential', () async {
    var fail = false;
    final writer = FailingAtomicTextWriter(
      shouldFail: (target) =>
          fail && path.basename(target) == longMemoryFileName,
    );
    final fixture = await _fixture(writer: writer);
    final pending = fixture.dream.run(bedtime: true);
    await fixture.client.entered.future;
    fail = true;
    final result = await fixture.actions.delete(
      const MemoryLongTermRef('重要事件', _original),
    );
    expect(result.status, MemoryActionStatus.partial);
    fail = false;
    fixture.client.answer.complete(ModelCompletion.reply(_candidate()));
    expect((await pending).status, DreamStatus.deferredConflict);
    expect(
      (await fixture.actions.freeze(
        const MemoryLongTermRef('重要事件', _original),
      )).status,
      MemoryActionStatus.success,
    );
  });

  test(
    'an episode edit followed by index failure reports the saved correction',
    () async {
      final fixture = await _fixture();
      final pending = fixture.dream.run(bedtime: true);
      await fixture.client.entered.future;
      final index = Directory(
        path.join(
          fixture.actions.memoryDirectory,
          'episodes',
          '2026',
          '09',
          'index.md',
        ),
      );
      await index.create(recursive: true);
      final result = await fixture.actions.edit(
        const MemoryEntryRef('2026-09-13', 'seed:0'),
        _corrected,
      );
      expect(result.status, MemoryActionStatus.partial);
      expect(result.message, contains('已保存'));
      expect(
        (await fixture.actions.episodePipeline.readDay(
          '2026-09-13',
        )).entries.single.summary,
        _corrected,
      );
      fixture.client.answer.complete(ModelCompletion.reply(_candidate()));
      expect((await pending).status, DreamStatus.deferredConflict);
    },
  );

  test(
    'a failed write releases coordination for a later edit and Dream',
    () async {
      var fail = true;
      final writer = FailingAtomicTextWriter(
        shouldFail: (target) =>
            fail && path.basename(target) == longMemoryFileName,
      );
      final fixture = await _fixture(writer: writer);
      const ref = MemoryLongTermRef('重要事件', _original);
      expect(
        (await fixture.actions.edit(ref, _corrected)).status,
        MemoryActionStatus.failed,
      );
      expect(await fixture.longMemory.readAsString(), contains(_original));
      fail = false;
      expect(
        (await fixture.actions.edit(ref, _corrected)).status,
        MemoryActionStatus.success,
      );
      fixture.client.next = ModelCompletion.reply(_candidate(_corrected));
      expect(
        (await fixture.dream.run(bedtime: true)).status,
        DreamStatus.accepted,
      );
    },
  );

  for (final correction in ['long-memory', 'persona-leaf', 'appellation']) {
    test(
      '$correction also prevents an old root proposal from being adopted',
      () async {
        final fixture = await _fixture();
        final branch = File(
          path.join(
            fixture.actions.memoryDirectory,
            'persona-tree',
            'expression.md',
          ),
        );
        await branch.parent.create(recursive: true);
        await branch.writeAsString('''# 性格表达

## 未归根中间节点

### [EX-M001] 重复模式｜用户尴尬时倾向自嘲
- 形成: 2026-07-20 · 复核: 2026-08-02
- [EX-L001] 2026-07-20 | 明确自述 | support | 用户尴尬时倾向自嘲 | episodes/2026/07/2026-07-20.md [m1]
- [EX-L002] 2026-08-02 | 明确自述 | support | 用户尴尬时倾向自嘲 | episodes/2026/08/2026-08-02.md [m2]
''');
        final candidate = jsonDecode(_candidate()) as Map<String, Object?>;
        candidate['rootProposals'] = [
          {
            'op': 'promote',
            'branch': 'expression',
            'claim': '用户尴尬时倾向自嘲',
            'middles': ['EX-M001'],
          },
        ];
        final pending = fixture.dream.run(bedtime: true);
        await fixture.client.entered.future;
        switch (correction) {
          case 'long-memory':
            await fixture.actions.edit(
              const MemoryLongTermRef('重要事件', _original),
              _corrected,
            );
          case 'persona-leaf':
            expect(
              await fixture.actions.personaTree.resyncLeafSummaries(
                'm1',
                '用户认真面对尴尬',
              ),
              1,
            );
          case 'appellation':
            await fixture.actions.personaTree.setAppellation('小禾');
        }
        final savedTree = await branch.readAsString();
        fixture.client.answer.complete(
          ModelCompletion.reply(jsonEncode(candidate)),
        );
        expect((await pending).status, DreamStatus.deferredConflict);
        expect(await branch.readAsString(), savedTree);
        expect(await branch.readAsString(), isNot(contains('## [EX-R001]')));
        // 同一份合法根提案在新快照无冲突时仍可正常接纳。
        fixture.client.next = ModelCompletion.reply(jsonEncode(candidate));
        final retry = await fixture.dream.run(bedtime: false);
        expect(retry.status, DreamStatus.accepted);
        expect(retry.rootOpsApplied, 1);
        if (correction == 'appellation') {
          expect(await fixture.actions.personaTree.readAppellation(), '小禾');
        }
      },
    );
  }
}

String _candidate([String text = _original]) => jsonEncode({
  'items': [
    {
      'section': '重要事件',
      'text': text,
      'evidence': ['2026-09-13'],
    },
  ],
});

Future<
  ({
    MemoryActionService actions,
    DreamService dream,
    _GatedClient client,
    File longMemory,
  })
>
_fixture({AtomicTextWriter? writer}) async {
  final directory = await Directory.systemTemp.createTemp('qiyu-commit-test-');
  addTearDown(() => directory.delete(recursive: true));
  final pipeline = EpisodeMemoryPipeline(
    memoryDirectory: directory.path,
    clock: () => _now,
    atomicWriter: writer,
  );
  await pipeline.synchronizedOnDayFiles(
    () => pipeline.writeFinalization(
      '2026-09-13',
      entries: [
        EpisodeEntry(
          id: 'seed:0',
          sessionId: 'seed',
          requestId: 'seed',
          summary: _original,
          at: _now.toUtc(),
        ),
      ],
      summary: _original,
      finalized: true,
      finalizedAt: _now.toUtc(),
    ),
  );
  await pipeline.synchronizedOnDayFiles(
    () => pipeline.writeFinalization(
      '2026-09-12',
      entries: const [],
      summary: '用户读了一本小说',
      finalized: true,
      finalizedAt: _now.toUtc(),
    ),
  );
  final file = File(path.join(directory.path, 'long-memory.md'));
  await file.writeAsString(
    renderLongMemory({
      for (final section in longMemorySections)
        section: section == '重要事件' ? [_original] : <String>[],
    }),
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
    diagnosticsSink: (_) {},
  );
  final months = MonthlySummaryStore(
    memoryDirectory: directory.path,
    episodePipeline: pipeline,
    diagnosticsSink: (_) {},
  );
  final actions = MemoryActionService(
    memoryDirectory: directory.path,
    episodePipeline: pipeline,
    personaTree: tree,
    memoryControls: controls,
    openLoopStore: loops,
    monthlySummary: months,
    relationshipLifecycle: RelationshipLifecycle(
      memoryDirectory: directory.path,
      atomicWriter: pipeline.commits.wrap(writer),
    ),
    atomicWriter: writer,
    diagnosticsSink: (_) {},
  );
  final client = _GatedClient();
  final dream = DreamService(
    memoryDirectory: directory.path,
    episodePipeline: pipeline,
    openLoopStore: loops,
    personaTree: tree,
    modelClient: client,
    clock: () => _now,
    atomicWriter: writer,
    diagnosticsSink: (_) {},
  );
  return (actions: actions, dream: dream, client: client, longMemory: file);
}

final class _GatedClient implements ProviderChatClient {
  final entered = Completer<void>();
  final answer = Completer<ModelCompletion?>();
  ModelCompletion? next;
  @override
  Future<ModelCompletion?> complete(
    List<ModelMessage> messages, {
    int? maxTokens,
  }) {
    if (next != null) return Future.value(next);
    entered.complete();
    return answer.future;
  }
}

final class _ObservedWriter implements AtomicTextWriter {
  _ObservedWriter(this.target);
  final String target;
  final written = Completer<void>();
  @override
  Future<void> replace(String targetPath, String contents) async {
    await const IoAtomicTextWriter().replace(targetPath, contents);
    if (path.basename(targetPath) == target && !written.isCompleted) {
      written.complete();
    }
  }
}
