import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:qiyu_local_host/qiyu_local_host.dart';
import 'package:test/test.dart';

void main() {
  group('QwenWsInferenceTtsGateway.runTaskPayload 音色与参数装配', () {
    test('3.1 模型默认音色回落为 qwenTts31DefaultVoice (longanhuan_v3.1)', () {
      final models = [
        'qwen-audio-3.1-tts-flash',
        'qwen-audio-3.1-tts-max',
        'qwen-audio-3.1-tts',
      ];
      for (final model in models) {
        for (final voice in [null, '', '   ']) {
          final config = TtsConfig(
            provider: TtsProviderKind.qwenTts,
            baseUrl: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
            model: model,
            voice: voice,
          );
          final payload = QwenWsInferenceTtsGateway.runTaskPayload(config);
          final parameters = payload['parameters'] as Map<String, Object?>;
          expect(
            parameters['voice'],
            qwenTts31DefaultVoice,
            reason: 'model=$model, voice="$voice"',
          );
          expect(parameters['voice'], 'longanhuan_v3.1');
          expect(parameters['format'], 'wav');
          expect(parameters['sample_rate'], 24000);
          expect(payload['model'], model);
        }
      }
    });

    test('3.0 或非 3.1 模型保持默认音色为 qwenTtsMaasDefaultVoice (longanhuan_v3.6)', () {
      final models = [
        'qwen-audio-3.0-tts-flash',
        'qwen-audio-3.0-tts',
        'cosyvoice-v1',
      ];
      for (final model in models) {
        for (final voice in [null, '', '   ']) {
          final config = TtsConfig(
            provider: TtsProviderKind.qwenTts,
            baseUrl: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
            model: model,
            voice: voice,
          );
          final payload = QwenWsInferenceTtsGateway.runTaskPayload(config);
          final parameters = payload['parameters'] as Map<String, Object?>;
          expect(
            parameters['voice'],
            qwenTtsMaasDefaultVoice,
            reason: 'model=$model, voice="$voice"',
          );
          expect(parameters['voice'], 'longanhuan_v3.6');
          expect(parameters['format'], 'wav');
          expect(parameters['sample_rate'], 24000);
          expect(payload['model'], model);
        }
      }
    });

    test('显式指定音色时原样使用，不被默认音色覆盖', () {
      const customVoices = [
        'longanlingxin_v3.1',
        'longanfengyue_v3.1',
        'xunanchuan_v3.1',
        'yuxiaoyun_v3.1',
        'Cherry',
      ];
      for (final voice in customVoices) {
        final config31 = TtsConfig(
          provider: TtsProviderKind.qwenTts,
          baseUrl: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
          model: 'qwen-audio-3.1-tts-flash',
          voice: voice,
        );
        final payload31 = QwenWsInferenceTtsGateway.runTaskPayload(config31);
        expect(
          (payload31['parameters'] as Map<String, Object?>)['voice'],
          voice,
        );

        final config30 = TtsConfig(
          provider: TtsProviderKind.qwenTts,
          baseUrl: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
          model: 'qwen-audio-3.0-tts-flash',
          voice: voice,
        );
        final payload30 = QwenWsInferenceTtsGateway.runTaskPayload(config30);
        expect(
          (payload30['parameters'] as Map<String, Object?>)['voice'],
          voice,
        );
      }
    });

    test('extraParams 深合并进 parameters 且可覆盖缺省参数', () {
      const config = TtsConfig(
        provider: TtsProviderKind.qwenTts,
        baseUrl: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
        model: 'qwen-audio-3.1-tts-flash',
        extraParams: {
          'instructions': '温柔低语',
          'sample_rate': 16000,
        },
      );
      final payload = QwenWsInferenceTtsGateway.runTaskPayload(config);
      final parameters = payload['parameters'] as Map<String, Object?>;
      expect(parameters['voice'], qwenTts31DefaultVoice);
      expect(parameters['instructions'], '温柔低语');
      expect(parameters['sample_rate'], 16000);
      expect(payload['task_group'], 'audio');
      expect(payload['task'], 'tts');
      expect(payload['function'], 'SpeechSynthesizer');
    });
  });

  group('QwenWsInferenceTtsGateway 端点与参数辅助方法', () {
    test('resolveInferenceUri: 缺路径时补全默认推理路径，已有路径原样保留', () {
      expect(
        QwenWsInferenceTtsGateway.resolveInferenceUri(
          const TtsConfig(
            provider: TtsProviderKind.qwenTts,
            baseUrl: 'wss://dashscope.aliyuncs.com',
            model: 'qwen-audio-3.1-tts-flash',
          ),
        ).toString(),
        'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
      );

      expect(
        QwenWsInferenceTtsGateway.resolveInferenceUri(
          const TtsConfig(
            provider: TtsProviderKind.qwenTts,
            baseUrl: 'wss://dashscope.aliyuncs.com/',
            model: 'qwen-audio-3.1-tts-flash',
          ),
        ).toString(),
        'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
      );

      expect(
        QwenWsInferenceTtsGateway.resolveInferenceUri(
          const TtsConfig(
            provider: TtsProviderKind.qwenTts,
            baseUrl: 'wss://custom.gateway.example.com/custom/path',
            model: 'qwen-audio-3.1-tts-flash',
          ),
        ).toString(),
        'wss://custom.gateway.example.com/custom/path',
      );
    });

    test('negotiatedSampleRate: 缺省 24000，支持 extraParams 覆盖', () {
      expect(
        QwenWsInferenceTtsGateway.negotiatedSampleRate(
          const TtsConfig(
            provider: TtsProviderKind.qwenTts,
            baseUrl: 'wss://dashscope.aliyuncs.com',
            model: 'qwen-audio-3.1-tts-flash',
          ),
        ),
        24000,
      );

      expect(
        QwenWsInferenceTtsGateway.negotiatedSampleRate(
          const TtsConfig(
            provider: TtsProviderKind.qwenTts,
            baseUrl: 'wss://dashscope.aliyuncs.com',
            model: 'qwen-audio-3.1-tts-flash',
            extraParams: {'sample_rate': 16000},
          ),
        ),
        16000,
      );
    });

    test('isDeliverableAudioFormat: wav 和 pcm 放行，mp3 拒绝', () {
      expect(
        QwenWsInferenceTtsGateway.isDeliverableAudioFormat(
          const TtsConfig(
            provider: TtsProviderKind.qwenTts,
            baseUrl: 'wss://dashscope.aliyuncs.com',
            model: 'qwen-audio-3.1-tts-flash',
          ),
        ),
        isTrue,
      );

      expect(
        QwenWsInferenceTtsGateway.isDeliverableAudioFormat(
          const TtsConfig(
            provider: TtsProviderKind.qwenTts,
            baseUrl: 'wss://dashscope.aliyuncs.com',
            model: 'qwen-audio-3.1-tts-flash',
            extraParams: {'format': 'pcm'},
          ),
        ),
        isTrue,
      );

      expect(
        QwenWsInferenceTtsGateway.isDeliverableAudioFormat(
          const TtsConfig(
            provider: TtsProviderKind.qwenTts,
            baseUrl: 'wss://dashscope.aliyuncs.com',
            model: 'qwen-audio-3.1-tts-flash',
            extraParams: {'format': 'mp3'},
          ),
        ),
        isFalse,
      );
    });
  });

  group('QwenWsInferenceTtsGateway 会话链路与默认音色实际外发验证', () {
    test('3.1 模型默认外发 voice 为 longanhuan_v3.1', () async {
      final connector = _ScriptedWsConnector(
        onTextSend: (text, connection) {
          final event = jsonDecode(text) as Map<String, Object?>;
          final header = event['header']! as Map<String, Object?>;
          final action = header['action'] as String;
          switch (action) {
            case 'run-task':
              connection.serverText(
                jsonEncode({
                  'header': {'task_id': 't-1', 'event': 'task-started'},
                  'payload': {},
                }),
              );
            case 'continue-task':
              connection.serverBinary(wrapPcmAsWav(Uint8List.fromList([1, 2]), sampleRate: 24000));
              connection.serverText(
                jsonEncode({
                  'header': {'task_id': 't-1', 'event': 'result-generated'},
                  'payload': {},
                }),
              );
            case 'finish-task':
              connection.serverBinary(wrapPcmAsWav(Uint8List.fromList([3, 4]), sampleRate: 24000));
              connection.serverText(
                jsonEncode({
                  'header': {'task_id': 't-1', 'event': 'task-finished'},
                  'payload': {},
                }),
              );
          }
        },
      );

      final gateway = QwenWsInferenceTtsGateway(connector);
      final audio = await gateway.synthesize(
        config: const TtsConfig(
          provider: TtsProviderKind.qwenTts,
          baseUrl: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
          model: 'qwen-audio-3.1-tts-flash',
        ),
        apiKey: 'sk-dashscope-test',
        text: '晚安。',
      );

      expect(audio, isNotEmpty);
      final sentTexts = connector.connection.sentText;
      expect(sentTexts, isNotEmpty);
      final runTaskJson =
          jsonDecode(sentTexts.first) as Map<String, Object?>;
      final payload = runTaskJson['payload']! as Map<String, Object?>;
      final parameters = payload['parameters']! as Map<String, Object?>;
      expect(parameters['voice'], qwenTts31DefaultVoice);
      expect(parameters['voice'], 'longanhuan_v3.1');
    });

    test('3.0 模型默认外发 voice 为 longanhuan_v3.6', () async {
      final connector = _ScriptedWsConnector(
        onTextSend: (text, connection) {
          final event = jsonDecode(text) as Map<String, Object?>;
          final header = event['header']! as Map<String, Object?>;
          final action = header['action'] as String;
          switch (action) {
            case 'run-task':
              connection.serverText(
                jsonEncode({
                  'header': {'task_id': 't-2', 'event': 'task-started'},
                  'payload': {},
                }),
              );
            case 'continue-task':
              connection.serverBinary(wrapPcmAsWav(Uint8List.fromList([1, 2]), sampleRate: 24000));
            case 'finish-task':
              connection.serverBinary(wrapPcmAsWav(Uint8List.fromList([3, 4]), sampleRate: 24000));
              connection.serverText(
                jsonEncode({
                  'header': {'task_id': 't-2', 'event': 'task-finished'},
                  'payload': {},
                }),
              );
          }
        },
      );

      final gateway = QwenWsInferenceTtsGateway(connector);
      final audio = await gateway.synthesize(
        config: const TtsConfig(
          provider: TtsProviderKind.qwenTts,
          baseUrl: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
          model: 'qwen-audio-3.0-tts-flash',
        ),
        apiKey: 'sk-dashscope-test',
        text: '晚安。',
      );

      expect(audio, isNotEmpty);
      final sentTexts = connector.connection.sentText;
      expect(sentTexts, isNotEmpty);
      final runTaskJson =
          jsonDecode(sentTexts.first) as Map<String, Object?>;
      final payload = runTaskJson['payload']! as Map<String, Object?>;
      final parameters = payload['parameters']! as Map<String, Object?>;
      expect(parameters['voice'], qwenTtsMaasDefaultVoice);
      expect(parameters['voice'], 'longanhuan_v3.6');
    });
  });
}

final class _ScriptedWsConnection implements ProviderWebSocketConnection {
  final _binary = StreamController<List<int>>.broadcast();
  final _text = StreamController<String>.broadcast();
  final List<String> sentText = [];
  final List<List<int>> sentBinary = [];
  bool closed = false;

  void Function(String text, _ScriptedWsConnection connection)? onTextSend;

  @override
  Stream<List<int>> get messages => _binary.stream;

  @override
  Stream<String> get textMessages => _text.stream;

  @override
  void send(List<int> bytes) {
    sentBinary.add(bytes);
  }

  @override
  void sendText(String text) {
    sentText.add(text);
    onTextSend?.call(text, this);
  }

  @override
  Future<void> close() async {
    closed = true;
    await _binary.close();
    await _text.close();
  }

  void serverText(String text) => _text.add(text);
  void serverBinary(List<int> bytes) => _binary.add(bytes);
}

final class _ScriptedWsConnector implements ProviderWebSocketConnector {
  _ScriptedWsConnector({this.onTextSend});

  final void Function(String text, _ScriptedWsConnection connection)? onTextSend;
  late final connection = _ScriptedWsConnection()..onTextSend = onTextSend;
  Uri? lastUri;
  Map<String, String>? lastHeaders;

  @override
  Future<ProviderWebSocketConnection> connect({
    required Uri uri,
    required Map<String, String> headers,
  }) async {
    lastUri = uri;
    lastHeaders = headers;
    return connection;
  }
}
