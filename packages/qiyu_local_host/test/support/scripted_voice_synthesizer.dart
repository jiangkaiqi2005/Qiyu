import 'dart:async';
import 'dart:typed_data';

import 'package:qiyu_local_host/qiyu_local_host.dart';

/// 流式合成网关的脚本化假件（票二）：按**句子文本**应答（不按调用
/// 顺序——在途合成并发完成，调用顺序本就无关；交付顺序由分句层按句
/// 序保证，测试据此断言）。同时实现整段接口（朗读路由/连接测试用），
/// 请求序列留档供断言（分句边界即合成请求边界）。经
/// `TtsSettingsService` 注入进程内 Host——分句层走的是真实服务层
/// （配置加载、Key 归一、文本校验）。
final class ScriptedTtsGateway
    implements TtsSynthesisGateway, TtsStreamSynthesisGateway {
  ScriptedTtsGateway({
    this.replies = const {},
    this.defaultReply = const ScriptedVoiceChunks([
      [1],
    ]),
  });

  /// 句子文本 → 应答脚本。
  final Map<String, ScriptedVoiceReply> replies;
  final ScriptedVoiceReply defaultReply;
  final List<String> requests = [];

  @override
  Future<List<int>> synthesize({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) async => Uint8List.fromList(const [9, 9, 9]);

  @override
  Stream<VoiceAudioChunk> synthesizeStream({
    required TtsConfig config,
    required String? apiKey,
    required String text,
  }) {
    requests.add(text);
    return switch (replies[text] ?? defaultReply) {
      ScriptedVoiceChunks(:final chunks) => Stream.fromIterable([
        for (final chunk in chunks)
          VoiceAudioChunk(bytes: Uint8List.fromList(chunk), sampleRate: 24000),
      ]),
      // E1：整响应当一块（容器块，不带采样率）。
      ScriptedVoiceWhole(:final bytes) => Stream.fromIterable([
        VoiceAudioChunk(
          bytes: Uint8List.fromList(bytes),
          mimeType: voiceWholeContainerMime,
        ),
      ]),
      ScriptedVoiceFailure() => Stream.error(
        const TtsGatewayException(
          kind: ModelFailureKind.provider,
          message: '语音合成服务拒绝了这次请求。',
        ),
      ),
      ScriptedVoiceGated(:final gate) => _gated(gate),
    };
  }

  /// 挂在 [gate] 上不吐块：停止信号用例用来把合成停在在途状态。
  static Stream<VoiceAudioChunk> _gated(Future<void> gate) async* {
    await gate;
    yield VoiceAudioChunk(
      bytes: Uint8List.fromList(const [1]),
      sampleRate: 24000,
    );
  }
}

/// 语音合成脚本条目。
sealed class ScriptedVoiceReply {
  const ScriptedVoiceReply();
}

/// 按序吐出若干 PCM 块（每块一个 `List<int>`）。
final class ScriptedVoiceChunks extends ScriptedVoiceReply {
  const ScriptedVoiceChunks(this.chunks);

  final List<List<int>> chunks;
}

/// E1：整响应当一块（拿不到音频块的档位按句子级顺序播）。
final class ScriptedVoiceWhole extends ScriptedVoiceReply {
  const ScriptedVoiceWhole(this.bytes);

  final List<int> bytes;
}

/// 合成失败（D1：一句失败即本段语音结束）。
final class ScriptedVoiceFailure extends ScriptedVoiceReply {
  const ScriptedVoiceFailure();
}

/// 等待 [gate] 完成才吐块：把合成停在在途状态（停止信号用例）。
final class ScriptedVoiceGated extends ScriptedVoiceReply {
  const ScriptedVoiceGated(this.gate);

  final Future<void> gate;
}
