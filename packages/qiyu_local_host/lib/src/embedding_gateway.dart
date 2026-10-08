import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

import 'model_gateway.dart';
import 'markdown_memory_repository.dart' show stderrDiagnostics;
import 'provider_config.dart';

/// embedding 出网异常：kind 与聊天 Provider 出网错误共用同一套分类
/// （域名解析/TLS/超时/鉴权/网络/模型不存在/限流/响应不兼容/解析
/// 失败/服务拒绝/内部错误），文案换成「记忆召回服务」。
final class EmbeddingGatewayException implements Exception {
  const EmbeddingGatewayException({
    required this.kind,
    required this.message,
    this.serviceError,
  });

  final ModelFailureKind kind;
  final String message;
  final ServiceErrorCategory? serviceError;

  @override
  String toString() => message;
}

/// embedding 客户端的公共调用面：服务层（设置、连接测试，及后续票的
/// 索引与查询）只认这个形状，协议分支不出 Provider 层。
abstract interface class EmbeddingClient {
  /// 把一批输入文本各向量化为一条向量。返回条数必须与 [inputs] 一致；
  /// 每条向量非空、长度一致且全为有限数值——零范数（全零）向量对精确
  /// 余弦不可计算，同样视为无效响应。
  Future<List<Float32List>> embed({
    required EmbeddingConfig config,
    required String? apiKey,
    required List<String> inputs,
  });
}

/// embedding 出网预算：Spec 工程默认值——查询时限 10 秒，连接测试同
/// 一口径。不延长文字聊天的 8 秒补气泡窗口（那是交付侧的既有约定）。
const embeddingRequestTimeout = Duration(seconds: 10);

/// OpenAI-compatible `/embeddings` 的 Host 中介客户端。POST 用户地址
/// 拼接的 embeddings 端点（已以 /embeddings 结尾的地址原样使用），Bearer
/// 鉴权，JSON 请求 `{model, input}`。响应按 Spec 工程默认值校验：data
/// 条目数必须等于输入数，每条 embedding 非空、维度一致、全为有限数值
/// 且范数大于零——不合法响应不可进入有效索引，也不可当作连接成功。
final class OpenAiEmbeddingGateway implements EmbeddingClient {
  const OpenAiEmbeddingGateway(this.httpClient);

  final ProviderHttpClient httpClient;

  @override
  Future<List<Float32List>> embed({
    required EmbeddingConfig config,
    required String? apiKey,
    required List<String> inputs,
  }) async {
    config.validate();
    if (inputs.isEmpty) {
      throw const EmbeddingGatewayException(
        kind: ModelFailureKind.internal,
        message: '本机程序内部出错。',
      );
    }
    final key = requireEmbeddingApiKey(apiKey);
    final uri = appendProviderEndpoint(config.baseUrl, 'embeddings');
    // embedding 是新增出网路径：出网前统一过内网校验（与语音服务同一
    // 套判定，文案按本域服务名）。
    if (nonLocalOutboundRefusalReason(uri, serviceLabel: '记忆召回服务')
        case final reason?) {
      throw EmbeddingGatewayException(kind: ModelFailureKind.provider, message: reason);
    }
    final response = await _postEmbeddingText(
      httpClient: httpClient,
      uri: uri,
      headers: {
        'authorization': 'Bearer $key',
        'content-type': 'application/json',
      },
      body: utf8.encode(
        jsonEncode({'model': config.model.trim(), 'input': inputs}),
      ),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw fromEmbeddingModelFailure(
        providerStatusFailure(
          response.statusCode,
          response.body,
          serviceLabel: '记忆召回服务',
        ),
      );
    }
    return _parseEmbeddingResponse(response.body, expectedCount: inputs.length);
  }
}

/// embedding 家族共用的 Key 前置校验：返回 trim 后的 Key。空按未保存
/// 鉴权失败；脏字符按粘贴事故拦截——粘贴进表单的 Key 常带零宽空格/
/// 中文，HTTP 写头遇脏字节会抛未分类异常，必须在出网前拦成人话（与
/// 语音侧 requireSttApiKey 同律）。
String requireEmbeddingApiKey(String? apiKey) {
  final key = apiKey?.trim();
  if (key == null || key.isEmpty) {
    throw const EmbeddingGatewayException(
      kind: ModelFailureKind.authentication,
      message: '还没有保存记忆召回服务的 API Key。',
    );
  }
  if (containsNonVisibleAscii(key)) {
    throw const EmbeddingGatewayException(
      kind: ModelFailureKind.provider,
      message: 'API Key 里混入了中文或看不见的字符，请重新复制粘贴。',
    );
  }
  return key;
}

/// 模型网关失败到 embedding 出网异常的适配（与语音家族的
/// fromSttModelFailure / fromTtsModelFailure 同律）。
EmbeddingGatewayException fromEmbeddingModelFailure(
  ModelGatewayException failure,
) => EmbeddingGatewayException(
  kind: failure.kind,
  message: failure.message,
  serviceError: failure.serviceError,
);

/// embedding HTTP 出网的统一守护：post 调用与响应体读取包进同一套异常
/// 分类阶梯（超时/TLS/Socket/Http/未分类 + 响应读失败），与语音侧
/// postSttText 同构但异常类型与话术各归本域，勿混用。
Future<({int statusCode, String body})> _postEmbeddingText({
  required ProviderHttpClient httpClient,
  required Uri uri,
  required Map<String, String> headers,
  required List<int> body,
}) async {
  final ProviderHttpResponse response;
  try {
    response = await httpClient.post(
      uri: uri,
      headers: headers,
      body: body,
      timeout: embeddingRequestTimeout,
    );
  } on TimeoutException {
    throw const EmbeddingGatewayException(
      kind: ModelFailureKind.timeout,
      message: '连接记忆召回服务超时。',
    );
  } on HandshakeException {
    throw const EmbeddingGatewayException(
      kind: ModelFailureKind.tls,
      message: '记忆召回服务的 TLS 安全连接失败。',
    );
  } on SocketException catch (error) {
    throw fromEmbeddingModelFailure(
      providerSocketFailure(error, serviceLabel: '记忆召回服务'),
    );
  } on HttpException {
    throw const EmbeddingGatewayException(
      kind: ModelFailureKind.network,
      message: '记忆召回服务连接中断。',
    );
  } on Object catch (error) {
    // 只打异常类型不打消息：消息可能嵌着用户输入（Key/地址/模型名）。
    stderrDiagnostics('embedding unclassified exception: ${error.runtimeType}');
    throw const EmbeddingGatewayException(
      kind: ModelFailureKind.internal,
      message: '本机程序内部出错。',
    );
  }
  try {
    return (statusCode: response.statusCode, body: await response.body.join());
  } on TimeoutException {
    throw const EmbeddingGatewayException(
      kind: ModelFailureKind.timeout,
      message: '记忆召回服务响应超时。',
    );
  } on Object {
    throw const EmbeddingGatewayException(
      kind: ModelFailureKind.network,
      message: '记忆召回服务连接中断。',
    );
  }
}

/// OpenAI-compatible embeddings 响应解析与有效性校验。data 按条目自带
/// 的 index 排序（缺 index 字段按出现顺序）；条目数、维度一致性、有限
/// 数值与零范数任一不合法都按内容解析失败给人话——不合法响应不可当
/// 作连接成功，也不可进入有效索引（Spec 工程默认值）。
List<Float32List> _parseEmbeddingResponse(
  String body, {
  required int expectedCount,
}) {
  final List<Object?> data;
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('embedding response must be an object');
    }
    final rawData = decoded['data'];
    if (rawData is! List || rawData.isEmpty) {
      throw const FormatException('embedding data must be a non-empty list');
    }
    data = rawData;
  } on Object {
    throw const EmbeddingGatewayException(
      kind: ModelFailureKind.contentParsing,
      message: '记忆召回服务返回的内容无法解析。',
    );
  }
  if (data.length != expectedCount) {
    throw const EmbeddingGatewayException(
      kind: ModelFailureKind.incompatibleResponse,
      message: '记忆召回服务返回的向量数量与请求不一致。',
    );
  }
  final vectors = List<Float32List>.filled(data.length, Float32List(0));
  var dimension = -1;
  for (var i = 0; i < data.length; i++) {
    final entry = data[i];
    if (entry is! Map<String, Object?>) {
      throw const EmbeddingGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '记忆召回服务返回的内容无法解析。',
      );
    }
    // 条目自带 index 时按它落位：请求多输入时服务可能乱序返回。落位
    // 前校验槽位未被占用——重复 index（或缺带混排撞槽）会让某个输入
    // 没有向量，遗留的空占位绝不能冒充有效向量出仓。
    var slot = i;
    final rawIndex = entry['index'];
    if (rawIndex is int && rawIndex >= 0 && rawIndex < data.length) {
      slot = rawIndex;
    }
    if (vectors[slot].isNotEmpty) {
      throw const EmbeddingGatewayException(
        kind: ModelFailureKind.incompatibleResponse,
        message: '记忆召回服务返回了重复的向量序号。',
      );
    }
    final rawVector = entry['embedding'];
    if (rawVector is! List || rawVector.isEmpty) {
      throw const EmbeddingGatewayException(
        kind: ModelFailureKind.incompatibleResponse,
        message: '记忆召回服务返回的向量格式不兼容。',
      );
    }
    if (dimension == -1) {
      dimension = rawVector.length;
    } else if (rawVector.length != dimension) {
      throw const EmbeddingGatewayException(
        kind: ModelFailureKind.incompatibleResponse,
        message: '记忆召回服务返回的向量维度不一致。',
      );
    }
    final vector = Float32List(rawVector.length);
    var squaredNorm = 0.0;
    for (var j = 0; j < rawVector.length; j++) {
      final value = rawVector[j];
      // int 也是 num：兼容把 0 写成整数的服务；bool 等其余类型无效。
      if (value is! num) {
        throw const EmbeddingGatewayException(
          kind: ModelFailureKind.incompatibleResponse,
          message: '记忆召回服务返回的向量格式不兼容。',
        );
      }
      final double component = value.toDouble();
      if (component.isNaN || component.isInfinite) {
        throw const EmbeddingGatewayException(
          kind: ModelFailureKind.incompatibleResponse,
          message: '记忆召回服务返回的向量含有非有限数值。',
        );
      }
      vector[j] = component;
      squaredNorm += component * component;
    }
    // 零范数向量无法计算余弦：视为无效响应，不当作连接成功。
    if (squaredNorm <= 0) {
      throw const EmbeddingGatewayException(
        kind: ModelFailureKind.incompatibleResponse,
        message: '记忆召回服务返回了无效的零向量。',
      );
    }
    vectors[slot] = vector;
  }
  // 兜底与接口文档同口径：任何槽位仍空着（向量缺失）都不可出仓。
  if (vectors.any((vector) => vector.isEmpty)) {
    throw const EmbeddingGatewayException(
      kind: ModelFailureKind.incompatibleResponse,
      message: '记忆召回服务返回的向量数量与请求不一致。',
    );
  }
  return vectors;
}
