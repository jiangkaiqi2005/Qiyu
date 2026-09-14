import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/in_process_chat_host.dart';
import 'support/failing_atomic_writer.dart';

const _target = '被夸时用玩笑卸力';
final _now = DateTime(2026, 9, 14, 22);

void main() {
  for (final accepted in [false, true]) {
    test(
      'unaccepted ban candidate completed=$accepted leaves memory intact',
      () async {
        final harness = await InProcessChatHost.start(
          clock: () => _now,
          modelGateway: ScriptedModelGateway(
            streamScript: [
              ScriptedStreamEvents([
                ModelStreamEvent.delta('''${accepted ? '我理解你的感受' : '好，以后不提了。'}
<qiyu-actions>
[{"action":"memory_ban","summary":"被夸时用玩笑卸力"}]
</qiyu-actions>'''),
                if (accepted)
                  const ModelStreamEvent.done()
                else
                  const ModelStreamEvent.failure(
                    ModelFailureKind.provider,
                    '脚本故障',
                  ),
              ]),
            ],
          ),
        );
        addTearDown(harness.dispose);
        await harness.finalizePending();
        await _seed(harness.memoryDirectory);
        final branch = File(
          path.join(harness.memoryDirectory, 'persona-tree', 'expression.md'),
        );
        final before = branch.readAsStringSync();
        final trace = await harness.sendChat(
          requestId: 'unaccepted',
          text: '以后别提这件事了',
        );
        if (accepted) {
          expect(trace.state.fallbackReason, FallbackReason.forbiddenPhrases);
        }
        expect(
          (await MemoryControlsStore(
            memoryDirectory: harness.memoryDirectory,
          ).load()).banned,
          isEmpty,
        );
        expect(branch.readAsStringSync(), before);
        expect(
          File(
            path.join(harness.memoryDirectory, 'open-loops.md'),
          ).readAsStringSync(),
          contains(_target),
        );
      },
    );
  }
  for (final entry in ['chat', 'memory-center']) {
    for (final failures in <Set<String>>[
      {},
      {'memory-controls.md'},
      {'open-loops.md'},
      {'expression.md'},
      {'open-loops.md', 'expression.md'},
    ]) {
      test(
        '$entry ban failures=$failures and retry preserves first origin',
        () async {
          final injectedFailures = <String>{};
          final attempts = <String>[];
          final writer = FailingAtomicTextWriter(
            exception: const FileSystemException('synthetic-private-failure'),
            shouldFail: (targetPath) {
              attempts.add(path.basename(targetPath));
              return injectedFailures.contains(path.basename(targetPath));
            },
          );
          final diagnostics = <String>[];
          final harness = await InProcessChatHost.start(
            clock: () => _now,
            atomicWriter: writer,
            diagnosticsSink: diagnostics.add,
            modelGateway: ScriptedModelGateway(
              streamScript: [
                const ScriptedStreamReply('''好，以后不提了。
<qiyu-actions>
[{"action":"memory_ban","summary":"被夸时用玩笑卸力"}]
</qiyu-actions>'''),
              ],
            ),
          );
          addTearDown(harness.dispose);
          await harness.finalizePending();
          await _seed(harness.memoryDirectory);
          attempts.clear();
          injectedFailures.addAll(failures);
          final controlsFailed = failures.contains('memory-controls.md');
          final deferred = [
            if (!controlsFailed && failures.contains('open-loops.md'))
              '未闭环事项的移出',
            if (!controlsFailed && failures.contains('expression.md')) '画像的清理',
          ];
          Future<Map?> execute(String channel, String requestId) async {
            if (channel == 'chat') {
              final gateway = harness.modelGateway! as ScriptedModelGateway;
              final callsBefore = gateway.streamCalls.length;
              final response = await harness.sendChat(
                requestId: requestId,
                text: '以后别提这件事了',
              );
              expect(response.statusCode, 200);
              expect(gateway.streamCalls.length, callsBefore + 1);
              expect(
                response.body,
                isNot(contains('synthetic-private-failure')),
              );
              return null;
            } else {
              final overview = await harness.getBytes('/api/memory');
              final data =
                  jsonDecode(utf8.decode(overview.$2)) as Map<String, dynamic>;
              final days = data['recent']['days'] as List;
              final id = days.first['entries'].first['id'];
              final response = await harness.postJson('/api/memory/action', {
                'action': 'ban',
                'id': id,
              });
              final result = jsonDecode(response.body) as Map;
              expect(
                response.body,
                isNot(contains('synthetic-private-failure')),
              );
              return result;
            }
          }

          final result = await execute(entry, 'ban-1');
          if (entry == 'chat') {
            for (final kind in [
              'controls not writable',
              'open-loops',
              'persona',
            ]) {
              final expected = kind == 'controls not writable'
                  ? controlsFailed
                  : !controlsFailed &&
                        failures.contains(
                          kind == 'open-loops'
                              ? 'open-loops.md'
                              : 'expression.md',
                        );
              expect(
                diagnostics.any(
                  (line) =>
                      line.contains('memory ban deferred [$kind]') &&
                      line.contains('ban-1'),
                ),
                expected,
              );
            }
          } else {
            expect(
              result!['status'],
              controlsFailed
                  ? 'failed'
                  : deferred.isEmpty
                  ? 'success'
                  : 'partial',
            );
            expect(result['deferred'] ?? [], deferred);
            if (controlsFailed) {
              expect(result['code'], 'memory_controls_not_writable');
              expect(result['retryable'], isTrue);
            }
          }
          expect(
            diagnostics.join('\n'),
            isNot(contains('synthetic-private-failure')),
          );
          final controls = await MemoryControlsStore(
            memoryDirectory: harness.memoryDirectory,
          ).load();
          if (controlsFailed) {
            expect(controls.banned, isEmpty);
            expect(attempts, isNot(contains('open-loops.md')));
            expect(attempts, isNot(contains('expression.md')));
          } else {
            expect(controls.banned.single.summary, _target);
            expect(controls.banned.single.origin, entry);
          }
          expect(
            File(
              path.join(harness.memoryDirectory, 'open-loops.md'),
            ).readAsStringSync().contains(_target),
            controlsFailed || failures.contains('open-loops.md'),
          );
          final branch = File(
            path.join(harness.memoryDirectory, 'persona-tree', 'expression.md'),
          );
          expect(
            branch.readAsStringSync().contains(_target),
            controlsFailed || failures.contains('expression.md'),
          );
          expect(branch.readAsStringSync(), contains('沉默时会先整理想法'));
          injectedFailures.clear();
          await execute(entry, 'ban-2');
          final firstSuccessful = await MemoryControlsStore(
            memoryDirectory: harness.memoryDirectory,
          ).load();
          expect(firstSuccessful.banned, hasLength(1));
          await execute(entry == 'chat' ? 'memory-center' : 'chat', 'ban-3');
          final retried = await MemoryControlsStore(
            memoryDirectory: harness.memoryDirectory,
          ).load();
          expect(retried.banned, hasLength(1));
          expect(retried.banned.single.id, firstSuccessful.banned.single.id);
          expect(retried.banned.single.origin, entry);
          expect(
            File(
              path.join(harness.memoryDirectory, 'open-loops.md'),
            ).readAsStringSync(),
            isNot(contains(_target)),
          );
          expect(branch.readAsStringSync(), isNot(contains(_target)));
        },
      );
    }
  }
}

Future<void> _seed(String directory) async {
  final pipeline = EpisodeMemoryPipeline(
    memoryDirectory: directory,
    clock: () => _now,
  );
  final controls = MemoryControlsStore(memoryDirectory: directory);
  final loops = OpenLoopStore(
    memoryDirectory: directory,
    memoryControls: controls,
  );
  final persona = PersonaTreeStore(
    memoryDirectory: directory,
    episodePipeline: pipeline,
    openLoopStore: loops,
    diagnosticsSink: (_) {},
  );
  for (final date in ['2026-09-12', '2026-09-13']) {
    await pipeline.synchronizedOnDayFiles(
      () => pipeline.writeFinalization(
        date,
        entries: [
          for (final summary in [_target, '沉默时会先整理想法'])
            EpisodeEntry(
              id: 'seed:$date:${summary == _target ? 0 : 1}',
              sessionId: 'seed-session',
              requestId: 'seed',
              summary: summary,
              at: DateTime.parse('${date}T20:00:00Z'),
              personaBranch: 'expression',
              personaNature: 'behavior',
            ),
        ],
        summary: _target,
        finalized: true,
        finalizedAt: DateTime.parse('${date}T23:00:00Z'),
      ),
    );
    await persona.processDay(date);
  }
  expect(
    File(
      path.join(directory, 'persona-tree', 'expression.md'),
    ).readAsStringSync(),
    contains(_target),
  );
  await File(path.join(directory, 'open-loops.md')).writeAsString(
    '''# open-loops

- [o1] $_target
  proactive: yes
  status: active
''',
  );
}
