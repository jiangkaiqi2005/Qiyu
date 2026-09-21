import 'dart:convert';
import 'dart:typed_data';

import 'model_gateway.dart';
import 'tts_gateway.dart';

/// 语音合成服务返回音频地址时的下载跳（Spec 实现决策 3/9）：合成响应
/// 不给音频字节、只给一个公网音频地址（千问朗读的 24 小时有效 URL、
/// 自定义通用档的 URL 形态都这样），本通道把地址下载成内存里的完整
/// 音频字节，两个请求合成一个完整文件。ADR 0002 的整段合成语义不变：
/// 音频只在内存流转，Host 不落盘。
///
/// 千问合成与自定义合成网关共用本通道；协议分支不出 Provider 层，调用
/// 面只有一个函数。失败全部落进 TTSGatewayException 的现有分类（服务
/// 拒绝/网络/内容解析/超时/鉴权/限流），话术与既有语音合成失败一致。
Future<Uint8List> downloadSpeechAudioBytes({
  required ProviderBytesHttpClient httpClient,
  required String? url,
}) async {
  final trimmed = url?.trim() ?? '';
  final uri = Uri.tryParse(trimmed);
  // 合成响应里的地址缺失、空串、无法解析或不是 http(s)：按内容解析失败
  // 说人话，不出网。scheme 顺带挡掉 ws/wss——下载是 HTTP GET，语音出网
  // 共用判定放行 ws 是给转写豆包档的，这里不需要。
  if (trimmed.isEmpty ||
      uri == null ||
      !uri.hasAuthority ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw const TtsGatewayException(
      kind: ModelFailureKind.contentParsing,
      message: '语音合成服务没有返回有效的音频地址。',
    );
  }
  // 下载与原始合成请求过同一套内网防护（speechOutboundRefusalReason），
  // 被返回恶意内网地址时不出网。
  ensureTtsOutboundAllowed(uri);
  // 下载请求不发鉴权头：服务端返回的是不带 Key 也能取的公网 OSS 类地址
  // （千问 24 小时有效 URL 即此形态），客户端抽象干脆不提供 headers
  // 形参；超时预算与合成请求同级。
  final response = await guardTtsOutbound(
    () => httpClient.getBytes(uri: uri, timeout: ttsRequestTimeout),
  );
  final bytes = await consumeTtsBytesResponse(response);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    // 错误体是文本 JSON：latin1 保留字节可读性，只用于错误分类。
    throw fromTtsModelFailure(
      providerStatusFailure(
        response.statusCode,
        latin1.decode(bytes, allowInvalid: true),
        serviceLabel: '语音合成服务',
      ),
    );
  }
  if (bytes.isEmpty) {
    throw const TtsGatewayException(
      kind: ModelFailureKind.contentParsing,
      message: '语音合成服务没有返回音频。',
    );
  }
  return bytes;
}
