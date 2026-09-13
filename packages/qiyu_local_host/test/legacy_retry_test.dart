import 'dart:convert';
import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/failing_atomic_writer.dart';
import 'support/in_process_chat_host.dart';

const _sessionId = 'legacy-pending-session';
const _requestId = 'legacy-pending';
const _legacyText = '{"password":"audit-only-legacy","count":42}';
const _safeText = '{"password":"[已脱敏]","count":42}';
final _userAt = DateTime.utc(2026, 8, 11, 12);

void main() {
  for (final useRestoredText in [false, true]) {
    test('旧 pending 以${useRestoredText ? '公开脱敏文本' : '原文'}重试复用原轮', () async {
      final gateway = ScriptedModelGateway(
        streamScript: [const ScriptedStreamReply('慢慢说。')],
      );
      final harness = await InProcessChatHost.start(
        modelGateway: gateway,
        clock: () => DateTime(2026, 8, 11, 22, 30),
        seedMemory: _seedLegacySession,
      );
      addTearDown(harness.dispose);
      final file = _sessionFile(Directory(harness.memoryDirectory));
      final original = await file.readAsString();
      final restoredText = await _restoredUserText(harness);
      expect(restoredText, _safeText);
      expect(await file.readAsString(), original);

      final completed = await harness.sendChat(
        requestId: _requestId,
        text: useRestoredText ? restoredText : _legacyText,
        sessionId: _sessionId,
      );
      expect(completed.sessionId, _sessionId);
      expect(completed.message.messages, ['慢慢说。']);
      expect(completed.eventsOf(ChatDeliveryEventKind.done), hasLength(1));
      final stored = await harness.storedSession(_sessionId);
      expect(stored.turns.map((turn) => turn.speaker), [
        Speaker.user,
        Speaker.qiyu,
      ]);
      expect(stored.turns.map((turn) => turn.requestId), [
        _requestId,
        _requestId,
      ]);
      expect(stored.turns.first.at, _userAt);
      // 完成只追加回复，不以新用户 turn 替换旧 marker。
      expect(stored.turns.first.text, _legacyText);

      final completedMarkdown = await file.readAsString();
      for (final restart in [false, true]) {
        if (restart) await harness.restart();
        final replay = await harness.sendChat(
          requestId: _requestId,
          text: await _restoredUserText(harness),
          sessionId: _sessionId,
        );
        expect(replay.message.messages, completed.message.messages);
        expect(replay.eventsOf(ChatDeliveryEventKind.done), hasLength(1));
        expect(await file.readAsString(), completedMarkdown);
      }
      expect(gateway.streamCalls, hasLength(1));
      expect(harness.zoneErrors, isEmpty);
    });
  }

  test('旧 completed 以原文或公开脱敏文本重放正常既有回复且不改文件', () async {
    final gateway = ScriptedModelGateway();
    final reply = _storedReply();
    final harness = await InProcessChatHost.start(
      modelGateway: gateway,
      clock: () => DateTime(2026, 8, 11, 22, 30),
      seedMemory: (directory) => _seedLegacySession(directory, reply: reply),
    );
    addTearDown(harness.dispose);
    final file = _sessionFile(Directory(harness.memoryDirectory));
    final original = await file.readAsString();
    for (final restart in [false, true]) {
      if (restart) await harness.restart();
      for (final text in [_legacyText, await _restoredUserText(harness)]) {
        final replay = await harness.sendChat(
          requestId: _requestId,
          text: text,
          sessionId: _sessionId,
        );
        expect(replay.sessionId, _sessionId);
        expect(replay.message.messages, reply.messages);
        expect(replay.state.source, reply.source);
        expect(replay.state.fallbackReason, reply.fallbackReason);
        expect(replay.state.mode, reply.mode);
        expect(replay.eventsOf(ChatDeliveryEventKind.done), hasLength(1));
        expect(await file.readAsString(), original);
      }
    }
    expect(gateway.streamCalls, isEmpty);
    expect(gateway.completeCalls, isEmpty);
    expect(harness.zoneErrors, isEmpty);
  });

  for (final restart in [false, true]) {
    test('旧 pending 取消后${restart ? '跨日重启' : '原实例'}仍可复用原轮重试', () async {
      var now = DateTime(2026, 8, 11, 22, 30);
      final gateway = ScriptedModelGateway(
        streamScript: [
          const ScriptedLiveStream(),
          const ScriptedStreamReply('这次说完。'),
        ],
      );
      final harness = await InProcessChatHost.start(
        modelGateway: gateway,
        clock: () => now,
        seedMemory: _seedLegacySession,
      );
      addTearDown(harness.dispose);
      final file = _sessionFile(Directory(harness.memoryDirectory));
      final original = await file.readAsString();
      final stream = harness.openChat(
        requestId: _requestId,
        text: await _restoredUserText(harness),
        sessionId: _sessionId,
      );
      await gateway.awaitStreamOpened().timeout(const Duration(seconds: 5));
      gateway.liveController.add(const ModelStreamEvent.delta('尚未完成'));
      expect(await harness.cancelChat(_requestId), isTrue);
      await stream.done;
      expect(stream.terminationError, isNull);
      expect(stream.received.last.kind, ChatDeliveryEventKind.cancelled);
      expect(
        stream.received.map((event) => event.kind),
        isNot(contains(ChatDeliveryEventKind.delta)),
      );
      expect(await file.readAsString(), original);
      expect((await harness.storedSession(_sessionId)).turns, hasLength(1));
      await gateway.liveController.close();

      if (restart) {
        now = DateTime(2026, 8, 12, 0, 30);
        await harness.restart();
      }
      final retry = await harness.sendChat(
        requestId: _requestId,
        text: await _restoredUserText(harness),
        sessionId: _sessionId,
      );
      expect(retry.sessionId, _sessionId);
      expect(retry.message.messages, ['这次说完。']);
      final stored = await harness.storedSession(_sessionId);
      expect(stored.turns.map((turn) => turn.speaker), [
        Speaker.user,
        Speaker.qiyu,
      ]);
      expect(stored.turns.first.at, _userAt);
      expect(stored.turns.first.requestId, _requestId);
      expect(harness.zoneErrors, isEmpty);
    });
  }

  test('旧 pending 回复写入失败仍保留原轮并可在重启后重试', () async {
    var failReply = true;
    final harness = await InProcessChatHost.start(
      configureProvider: false,
      clock: () => DateTime(2026, 8, 11, 22, 30),
      seedMemory: _seedLegacySession,
      atomicWriter: FailingAtomicTextWriter(
        shouldFail: (path) => failReply && path.endsWith('2026-08-11-001.md'),
      ),
    );
    addTearDown(harness.dispose);
    final file = _sessionFile(Directory(harness.memoryDirectory));
    final original = await file.readAsString();
    final interrupted = harness.openChat(
      requestId: _requestId,
      text: _legacyText,
      sessionId: _sessionId,
    );
    await interrupted.done;
    expect(interrupted.terminationError, isNotNull);
    expect(
      harness.zoneErrors,
      contains(
        isA<MemoryRepositoryException>().having(
          (error) => error.code,
          'code',
          'session_write_failed',
        ),
      ),
    );
    expect(await file.readAsString(), original);
    failReply = false;
    await harness.restart();
    final retry = await harness.sendChat(
      requestId: _requestId,
      text: await _restoredUserText(harness),
      sessionId: _sessionId,
    );
    expect(retry.eventsOf(ChatDeliveryEventKind.done), hasLength(1));
    final stored = await harness.storedSession(_sessionId);
    expect(stored.turns, hasLength(2));
    expect(stored.turns.first.at, _userAt);
    expect(stored.turns.first.requestId, _requestId);
  });

  for (final completed in [false, true]) {
    final cases = [
      (_legacyText, '{"password":"audit-only-legacy","count":43}'),
      ('今天有点累', '今天很开心'),
      ('{"count":42,"note":"正常"}', '{"count":43,"note":"正常"}'),
      ('编号 987654321', '编号 987654322'),
      ('<b>今天有点累</b>', '今天有点累'),
    ];
    for (var index = 0; index < cases.length; index += 1) {
      final (originalText, differentText) = cases[index];
      test(
        '旧 ${completed ? 'completed' : 'pending'} 正常内容差异 $index 仍冲突，相同内容仍幂等',
        () async {
          final gateway = ScriptedModelGateway(
            streamScript: [const ScriptedStreamReply('慢慢说。')],
          );
          final harness = await InProcessChatHost.start(
            modelGateway: gateway,
            clock: () => DateTime(2026, 8, 11, 22, 30),
            seedMemory: (directory) => _seedLegacySession(
              directory,
              text: originalText,
              reply: completed ? _storedReply() : null,
            ),
          );
          addTearDown(harness.dispose);
          final file = _sessionFile(Directory(harness.memoryDirectory));
          final original = await file.readAsString();
          await expectLater(
            harness.sendChat(
              requestId: _requestId,
              text: differentText,
              sessionId: _sessionId,
            ),
            throwsA(isA<HttpException>()),
          );
          expect(
            harness.zoneErrors,
            contains(
              isA<LocalChatException>()
                  .having((error) => error.code, 'code', 'request_id_conflict')
                  .having((error) => error.retryable, 'retryable', isFalse),
            ),
          );
          expect(await file.readAsString(), original);
          expect(gateway.streamCalls, isEmpty);
          // 正常文本、JSON、数字和标记原样重试都应继续成立。
          for (var attempt = 0; attempt < 2; attempt += 1) {
            final retry = await harness.sendChat(
              requestId: _requestId,
              text: originalText,
              sessionId: _sessionId,
            );
            expect(retry.message.messages, ['慢慢说。']);
            expect(retry.eventsOf(ChatDeliveryEventKind.done), hasLength(1));
            expect(
              (await harness.storedSession(_sessionId)).turns,
              hasLength(2),
            );
            expect(
              await _restoredUserText(harness),
              index == 0 ? _safeText : originalText,
            );
          }
          expect(gateway.streamCalls, hasLength(completed ? 0 : 1));
        },
      );
    }
  }
}

Future<String> _restoredUserText(InProcessChatHost harness) async {
  final response = await harness.readSession(sessionId: _sessionId);
  expect(response.statusCode, HttpStatus.ok);
  final body = jsonDecode(response.body) as Map<String, Object?>;
  final turns = (body['turns']! as List<Object?>).cast<Map<String, Object?>>();
  return turns.first['text']! as String;
}

File _sessionFile(Directory directory) =>
    File('${directory.path}/sessions/2026/08/2026-08-11-001.md');

// 直接渲染旧 marker；appendTurn 会使用当前脱敏规则，无法重现旧数据。
Future<void> _seedLegacySession(
  Directory directory, {
  String text = _legacyText,
  RawSessionTurn? reply,
}) async {
  final session = RawSession(
    id: _sessionId,
    date: '2026-08-11',
    segment: 1,
    createdAt: _userAt,
    updatedAt: reply?.at ?? _userAt,
    turns: [
      RawSessionTurn.user(requestId: _requestId, text: text, at: _userAt),
      ?reply,
    ],
  );
  final file = _sessionFile(directory);
  await file.parent.create(recursive: true);
  await file.writeAsString(renderSessionMarkdown(session));
}

RawSessionTurn _storedReply() => RawSessionTurn.qiyu(
  requestId: _requestId,
  messages: const ['慢慢说。'],
  at: _userAt.add(const Duration(minutes: 1)),
  source: ReplySource.local,
  mode: 'local',
);
