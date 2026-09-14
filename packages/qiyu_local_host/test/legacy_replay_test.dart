import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

import 'support/in_process_chat_host.dart';

const _sessionId = 'legacy-replay-session';
const _requestId = 'legacy-replay-request';
const _userText = '在吗';
const _secretMessages = [
  '{"password":"replay-only-synthetic-password","count":42}',
  '嗯，窗外还有风。',
];
const _safeMessages = ['{"password":"[已脱敏]","count":42}', '嗯，窗外还有风。'];
const _plainMessages = [
  '  嗯。\n{"count":42,"cookie":"饼干"}，今日步数 123456789。  ',
  '有什么可以帮你的吗？',
];

void main() {
  for (final textOnly in [false, true]) {
    final shape = textOnly ? 'text-only' : 'messages';
    test('旧 $shape 回复公开重放脱敏与 restore 一致', () async {
      final gateway = ScriptedModelGateway();
      final harness = await InProcessChatHost.start(
        modelGateway: gateway,
        clock: () => DateTime(2026, 8, 11, 22, 32),
        seedMemory: (directory) => _seedLegacyReply(
          directory,
          messages: _secretMessages,
          textOnly: textOnly,
        ),
      );
      addTearDown(harness.dispose);
      await harness.finalizePending();
      final memoryBefore = await _memoryBytes(harness);
      final file = _sessionFile(harness.memoryDirectory);
      final before = await file.readAsBytes();
      final restored = await harness.readSession(sessionId: _sessionId);
      expect(restored.statusCode, HttpStatus.ok);
      final snapshot = jsonDecode(restored.body) as Map<String, Object?>;
      final turns = (snapshot['turns']! as List).cast<Map<String, Object?>>();
      expect(turns.last['text'], _safeMessages.join('\n'));

      final replay = await harness.sendChat(
        requestId: _requestId,
        text: _userText,
        sessionId: _sessionId,
      );
      expect(replay.statusCode, HttpStatus.ok);
      // 查完整拼接，不能因密码被拆进多个 delta 就误判安全。
      expect(
        {
          'deltaJoined': replay
              .eventsOf(ChatDeliveryEventKind.delta)
              .map((event) => event.text)
              .join(),
          'messages': replay.message.messages,
        },
        {
          'deltaJoined': _safeMessages.join('\n'),
          'messages': textOnly ? [_safeMessages.join('\n')] : _safeMessages,
        },
      );
      expect(replay.eventsOf(ChatDeliveryEventKind.done), hasLength(1));
      expect(gateway.streamCalls, isEmpty);
      expect(gateway.completeCalls, isEmpty);
      expect(await file.readAsBytes(), before);
      expect(harness.zoneErrors, isEmpty);

      for (final restart in [false, true]) {
        if (restart) await harness.restart();
        final repeated = await harness.sendChat(
          requestId: _requestId,
          text: _userText,
          sessionId: _sessionId,
        );
        expect(repeated.body, replay.body);
        final restoredAgain = await harness.readSession(sessionId: _sessionId);
        expect(restoredAgain.body, restored.body);
        await harness.finalizePending();
        expect(await _memoryBytes(harness), memoryBefore);
      }
      expect(gateway.streamCalls, isEmpty);
      expect(gateway.completeCalls, isEmpty);
      expect(harness.zoneErrors, isEmpty);
    });

    for (final metadata in const [
      (name: '模型', source: 'llm', mode: 'model', fallback: null, safety: null),
      (
        name: '回退',
        source: 'local',
        mode: 'local',
        fallback: 'model_timeout',
        safety: null,
      ),
      (
        name: '安全',
        source: 'local',
        mode: 'safety',
        fallback: 'safety',
        safety: 'crisis',
      ),
      (name: '缺省', source: null, mode: null, fallback: null, safety: null),
    ]) {
      test('普通 $shape ${metadata.name}回复对照保持原文、状态与事件序', () async {
        final gateway = ScriptedModelGateway();
        final harness = await InProcessChatHost.start(
          modelGateway: gateway,
          clock: () => DateTime(2026, 8, 11, 22, 32),
          seedMemory: (directory) => _seedLegacyReply(
            directory,
            messages: _plainMessages,
            textOnly: textOnly,
            source: metadata.source,
            mode: metadata.mode,
            fallback: metadata.fallback,
            safety: metadata.safety,
            // 晚安的旧完成轮次也只重放，不重复日终或 Dream。
            userText: '晚安',
          ),
        );
        addTearDown(harness.dispose);
        await harness.finalizePending();
        final before = await _memoryBytes(harness);
        String? firstBody;
        for (final restart in [false, false, true]) {
          if (restart) await harness.restart();
          final trace = await harness.sendChat(
            requestId: _requestId,
            text: '晚安',
            sessionId: _sessionId,
          );
          expect(trace.statusCode, HttpStatus.ok);
          expect(
            trace.message.messages,
            textOnly ? [_plainMessages.join('\n')] : _plainMessages,
          );
          expect(
            trace
                .eventsOf(ChatDeliveryEventKind.delta)
                .map((e) => e.text)
                .join(),
            _plainMessages.join('\n'),
          );
          expect(trace.state.toJson(), {
            'event': 'state',
            'requestId': _requestId,
            'sessionId': _sessionId,
            'source': metadata.source ?? 'local',
            'mode': metadata.mode ?? 'local',
            if (metadata.fallback != null) 'fallbackReason': metadata.fallback,
            if (metadata.safety != null) 'safety': metadata.safety,
          });
          expect(trace.events.map((e) => e.kind), [
            ChatDeliveryEventKind.accepted,
            if (metadata.fallback != null) ChatDeliveryEventKind.fallback,
            ...List.filled(
              trace.eventsOf(ChatDeliveryEventKind.delta).length,
              ChatDeliveryEventKind.delta,
            ),
            ChatDeliveryEventKind.message,
            ChatDeliveryEventKind.state,
            ChatDeliveryEventKind.done,
          ]);
          if (metadata.fallback != null) {
            expect(trace.event(ChatDeliveryEventKind.fallback).toJson(), {
              'event': 'fallback',
              'requestId': _requestId,
              'sessionId': _sessionId,
              'fallbackReason': metadata.fallback,
            });
          }
          firstBody ??= trace.body;
          expect(trace.body, firstBody);
          final restored = await harness.readSession(sessionId: _sessionId);
          final body = jsonDecode(restored.body) as Map<String, Object?>;
          final turns = (body['turns']! as List).cast<Map<String, Object?>>();
          expect(turns, hasLength(2));
          expect(turns.last['text'], _plainMessages.join('\n'));
          await harness.finalizePending();
          expect(await _memoryBytes(harness), before);
        }
        expect(gateway.streamCalls, isEmpty);
        expect(gateway.completeCalls, isEmpty);
        expect(harness.zoneErrors, isEmpty);
      });
    }

    for (final secret in [false, true]) {
      test('${secret ? '凭据' : '普通'} $shape 回复取消对照不重写旧轮，重启仍可重放', () async {
        final paused = Completer<void>();
        final release = Completer<void>();
        var block = true;
        final gateway = ScriptedModelGateway();
        final harness = await InProcessChatHost.start(
          modelGateway: gateway,
          clock: () => DateTime(2026, 8, 11, 22, 32),
          deliveryPause: (_) {
            if (!block) return Future<void>.value();
            if (!paused.isCompleted) paused.complete();
            return release.future;
          },
          seedMemory: (directory) => _seedLegacyReply(
            directory,
            messages: secret ? _secretMessages : _plainMessages,
            textOnly: textOnly,
          ),
        );
        addTearDown(harness.dispose);
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        await harness.finalizePending();
        final before = await _memoryBytes(harness);
        final stream = harness.openChat(
          requestId: _requestId,
          text: _userText,
          sessionId: _sessionId,
        );
        // HTTP 会缓冲，用已批准的交付暂停接缝定位首个 delta 之后。
        await paused.future.timeout(const Duration(seconds: 5));
        expect(await harness.cancelChat(_requestId), isTrue);
        await stream.done;
        expect(await stream.statusCode, HttpStatus.ok);
        expect(stream.terminationError, isNull);
        expect(stream.received.map((e) => e.kind), [
          ChatDeliveryEventKind.accepted,
          ChatDeliveryEventKind.delta,
          ChatDeliveryEventKind.cancelled,
        ]);
        expect(
          stream.received
              .singleWhere((e) => e.kind == ChatDeliveryEventKind.delta)
              .text,
          secret ? '{"password":' : '  嗯。\n{"count',
        );
        await harness.finalizePending();
        expect(await _memoryBytes(harness), before);
        block = false;
        release.complete();
        await harness.restart();
        final retry = await harness.sendChat(
          requestId: _requestId,
          text: _userText,
          sessionId: _sessionId,
        );
        final expected = secret ? _safeMessages : _plainMessages;
        expect(
          retry.message.messages,
          textOnly ? [expected.join('\n')] : expected,
        );
        expect(
          retry.eventsOf(ChatDeliveryEventKind.delta).map((e) => e.text).join(),
          expected.join('\n'),
        );
        expect(retry.eventsOf(ChatDeliveryEventKind.done), hasLength(1));
        await harness.finalizePending();
        expect(await _memoryBytes(harness), before);
        expect(gateway.streamCalls, isEmpty);
        expect(gateway.completeCalls, isEmpty);
        expect(harness.zoneErrors, isEmpty);
      });
    }
  }
}

Future<Map<String, List<int>>> _memoryBytes(InProcessChatHost harness) async {
  final directory = Directory(harness.memoryDirectory);
  return {
    await for (final entity in directory.list(recursive: true))
      if (entity is File)
        entity.path.substring(directory.path.length): await entity
            .readAsBytes(),
  };
}

File _sessionFile(String directory) =>
    File('$directory/sessions/2026/08/2026-08-11-001.md');

Future<void> _seedLegacyReply(
  Directory directory, {
  required List<String> messages,
  required bool textOnly,
  String userText = _userText,
  String? source = 'llm',
  String? mode = 'model',
  String? fallback,
  String? safety,
}) async {
  final at = DateTime(2026, 8, 11, 22, 30).toUtc();
  final replyAt = at.add(const Duration(minutes: 1));
  final reply = RawSessionTurn.fromJson({
    'requestId': _requestId,
    'speaker': 'qiyu',
    'text': messages.join('\n'),
    if (!textOnly) 'messages': messages,
    'at': replyAt.toIso8601String(),
    'source': ?source,
    'mode': ?mode,
    'fallbackReason': ?fallback,
    'safety': ?safety,
  });
  final session = RawSession(
    id: _sessionId,
    date: '2026-08-11',
    segment: 1,
    createdAt: at,
    updatedAt: replyAt,
    turns: [
      RawSessionTurn.user(requestId: _requestId, text: userText, at: at),
      reply,
    ],
  );
  final file = _sessionFile(directory.path);
  await file.parent.create(recursive: true);
  // 合成旧 marker，绕过新写入过滤；不接触任何真实会话或凭据。
  await file.writeAsString(renderSessionMarkdown(session), flush: true);
}
