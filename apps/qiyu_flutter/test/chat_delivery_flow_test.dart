import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/features/chat/local_chat_view_model.dart';
import 'package:qiyu_flutter/features/chat/voice_output_controller.dart';
import 'package:qiyu_flutter/features/chat/voice_player_platform.dart';
import 'package:qiyu_flutter/features/settings/tts_settings_client.dart';

import 'support/host_transport.dart';

void main() {
  for (final discard in [false, true]) {
    test('真实流首段后保持发送；discard=$discard 时后续段归属正确', () async {
      final stream = StreamController<List<int>>();
      final client = MockClient.streaming((request, body) async {
        if (request.url.path == '/api/chat') {
          return http.StreamedResponse(stream.stream, 200);
        }
        final response = request.url.path == '/api/bootstrap'
            ? {'csrfToken': 'csrf-1'}
            : {'sessionId': 'new-session', 'turns': <Object>[]};
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(response))),
          200,
        );
      });
      addTearDown(client.close);
      final model = LocalChatViewModel(
        HttpLocalChatGateway(client: client),
        requestIdFactory: () => 'r1',
        autoStart: false,
      );
      addTearDown(model.dispose);
      final firstCommitted = Completer<void>();
      model.addListener(() {
        if (model.messages.length == 2 && !firstCommitted.isCompleted) {
          firstCommitted.complete();
        }
      });
      final pending = model.send('在吗');
      final firstEvents = [
        _event('accepted', sessionId: 's1'),
        ..._segment('首段'),
      ];
      stream.add(
        utf8.encode('${firstEvents.map(jsonEncode).join('\n')}\n'),
      );
      await firstCommitted.future;
      expect(model.sending, isTrue);
      expect(model.messages.last.text, '首段');
      if (discard) await model.discardSession('s1');
      stream.add(utf8.encode('${_segment('次段').map(jsonEncode).join('\n')}\n'));
      await stream.close();
      final result = await pending;
      expect(
        result.status,
        discard ? ChatSendStatus.staleSession : ChatSendStatus.completed,
      );
      expect(
        model.messages.map((m) => m.text),
        discard ? <String>[] : ['在吗', '首段', '次段'],
      );
      expect(model.streamingText, isEmpty);
    });
  }

  for (final count in [1, 2]) {
    test('真实解析的 $count 段同时用于便捷结果、气泡及各一次朗读', () async {
      final fixture = _Fixture([
        _event('accepted', sessionId: 's1'),
        ..._segment('首段'),
        if (count == 2) ..._segment('次段'),
      ]);
      final exchange = await fixture.gateway.send(requestId: 'r1', text: '在吗');
      expect(exchange.messages, count == 1 ? ['首段'] : ['首段', '次段']);
      expect(exchange.requestId, 'r1');
      expect(exchange.sessionId, 's1');

      final model = fixture.model();
      await model.refreshVoiceOutputStatus();
      expect((await model.send('在吗')).status, ChatSendStatus.completed);
      await Future<void>.delayed(Duration.zero);
      final replies = model.messages.where(
        (m) => m.speaker == LocalChatSpeaker.qiyu,
      );
      expect(replies.map((m) => m.text), exchange.messages);
      expect(replies.map((m) => m.requestId), List.filled(count, 'r1'));
      expect(replies.map((m) => m.deliveryIndex), count == 1 ? [0] : [0, 1]);
      expect(fixture.spoken, [
        {'requestId': 'r1', 'turnIndex': 0, 'sessionId': 's1'},
        if (count == 2) {'requestId': 'r1', 'turnIndex': 1, 'sessionId': 's1'},
      ]);
    });
  }

  final invalidSegments = <String, List<Map<String, Object?>>>{
    '缺少 done': [_message('未完成'), _state()],
    '缺少 state': [_message('未完成'), _event('done')],
    '缺少 message': [_state(), _event('done')],
    '只有 done': [_event('done')],
    '重复 message': [_message('一'), _message('二'), _state(), _event('done')],
    '重复 state': [_message('一'), _state(), _state(), _event('done')],
    'message 后 delta': [
      _message('一'),
      _event('delta', text: '二'),
      _state(),
      _event('done'),
    ],
    '空 message': [
      {'event': 'message', 'requestId': 'r1', 'messages': <String>[]},
      _state(),
      _event('done'),
    ],
    '异请求段': [_message('一')..['requestId'] = 'other', _state(), _event('done')],
    '异会话段': [_message('一')..['sessionId'] = 'other', _state(), _event('done')],
  };
  for (final entry in invalidSegments.entries) {
    test('${entry.key} 在两个入口均不提交或朗读伪完整段', () async {
      final fixture = _Fixture([
        _event('accepted', sessionId: 's1'),
        ...entry.value,
      ]);
      await expectLater(
        fixture.gateway.send(requestId: 'r1', text: '在吗'),
        throwsA(isA<LocalChatGatewayException>()),
      );
      final model = fixture.model();
      await model.refreshVoiceOutputStatus();
      final result = await model.send('在吗');
      expect(result.status, ChatSendStatus.acceptedIncomplete);
      expect(result.requestId, 'r1');
      expect(model.messages.single.text, '在吗');
      expect(model.errorMessage, isNotNull);
      expect(model.streamingText, isEmpty);
      expect(fixture.spoken, isEmpty);
    });
  }

  for (final ending in ['cancelled', 'error', 'EOF', 'duplicate done']) {
    test('首段 done 后 $ending 仅保留和朗读已完成段，迟到段不接纳', () async {
      final fixture = _Fixture([
        _event('accepted', sessionId: 's1'),
        ..._segment('首段'),
        if (ending == 'duplicate done')
          _event('done')
        else ...[
          _event('waiting'),
          _event('delta', text: '半句'),
          _message('未落盘的第二段'),
          _state(),
          if (ending == 'cancelled') _event('cancelled'),
          if (ending == 'error')
            {
              'event': 'error',
              'requestId': 'r1',
              'code': 'chat_failed',
              'text': '连接中断',
              'retryable': true,
            },
        ],
        if (ending != 'EOF') ..._segment('迟到内容'),
      ]);
      final exchange = await fixture.gateway.send(requestId: 'r1', text: '在吗');
      expect(exchange.messages, ['首段']);
      final model = fixture.model();
      await model.refreshVoiceOutputStatus();
      final result = await model.send('在吗');
      await Future<void>.delayed(Duration.zero);
      expect(result.status, ChatSendStatus.completed);
      expect(result.requestId, 'r1');
      expect(model.messages.map((m) => m.text), ['在吗', '首段']);
      expect(model.streamingText, isEmpty);
      expect(model.waiting, isFalse);
      expect(fixture.spoken, [
        {'requestId': 'r1', 'turnIndex': 0, 'sessionId': 's1'},
      ]);
    });
  }
}

Map<String, Object?> _event(String kind, {String? text, String? sessionId}) => {
  'event': kind,
  'requestId': 'r1',
  'text': ?text,
  'sessionId': ?sessionId,
};
Map<String, Object?> _message(String text) => {
  'event': 'message',
  'requestId': 'r1',
  'messages': [text],
};
Map<String, Object?> _state() => {
  'event': 'state',
  'requestId': 'r1',
  'source': 'llm',
};
List<Map<String, Object?>> _segment(String text) => [
  _event('waiting'),
  _event('delta', text: text),
  _message(text),
  _state(),
  _event('done'),
];

final class _Fixture {
  _Fixture(List<Map<String, Object?>> events) {
    client = hostTransportClient(
      (request) => switch (request.url.path) {
        '/api/provider/tts' => hostJsonResponse({
          'configured': true,
          'keySet': true,
          'autoSpeak': true,
        }, 200),
        '/api/chat/speak' => _speech(request),
        _ => http.Response.bytes(
          utf8.encode('${events.map(jsonEncode).join('\n')}\n'),
          200,
        ),
      },
    );
    gateway = HttpLocalChatGateway(client: client);
    addTearDown(client.close);
  }

  late final http.Client client;
  late final HttpLocalChatGateway gateway;
  final spoken = <Object?>[];

  http.Response _speech(http.Request request) {
    spoken.add(jsonDecode(request.body));
    return http.Response.bytes([1, 2, 3], 200);
  }

  LocalChatViewModel model() {
    final output = VoiceOutputController(gateway, playerPlatform: _Player());
    final model = LocalChatViewModel(
      gateway,
      requestIdFactory: () => 'r1',
      autoStart: false,
      ttsSettingsGateway: HttpTtsSettingsGateway(client: client),
      voiceOutput: output,
    );
    addTearDown(model.dispose);
    addTearDown(output.dispose);
    return model;
  }
}

final class _Player implements VoicePlayerPlatform {
  @override
  bool get supported => true;
  @override
  double getInitialVolume() => 1;
  @override
  void saveVolume(double volume) {}
  @override
  Future<VoicePlayback?> play(
    Uint8List bytes, {
    required String mimeType,
    double volume = 1,
  }) async => _Playback();
}

final class _Playback implements VoicePlayback {
  @override
  Future<void> get done async {}
  @override
  void stop() {}
  @override
  void setVolume(double volume) {}
}
