import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'provider_config.dart';

enum ModelMessageRole { system, user, assistant }

final class ModelMessage {
  const ModelMessage(this.role, this.content);

  final ModelMessageRole role;
  final String content;
}

enum ModelFailureKind {
  dns,
  tls,
  timeout,
  authentication,
  network,
  modelNotFound,
  rateLimited,
  incompatibleResponse,
  contentParsing,
  provider,
}

final class ModelGatewayException implements Exception {
  const ModelGatewayException({required this.kind, required this.message});

  final ModelFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

abstract interface class ModelGateway {
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
  });
}

final class ProviderHttpResponse {
  const ProviderHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

abstract interface class ProviderHttpClient {
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
  });
}

final class DartIoProviderHttpClient implements ProviderHttpClient {
  const DartIoProviderHttpClient();

  @override
  Future<ProviderHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.postUrl(uri).timeout(timeout);
      headers.forEach(request.headers.set);
      request.write(body);
      final response = await request.close().timeout(timeout);
      final responseBody = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      return ProviderHttpResponse(
        statusCode: response.statusCode,
        body: responseBody,
      );
    } finally {
      client.close(force: true);
    }
  }
}

final class ProviderModelGateway implements ModelGateway {
  const ProviderModelGateway(this.httpClient);

  final ProviderHttpClient httpClient;

  @override
  Future<String> complete({
    required ProviderConfig config,
    required String? apiKey,
    required List<ModelMessage> messages,
  }) async {
    config.validate();
    final protocol = _providerProtocol(config.kind);
    if (protocol.requiresApiKey && (apiKey == null || apiKey.trim().isEmpty)) {
      throw const ModelGatewayException(
        kind: ModelFailureKind.authentication,
        message: '还没有保存 API Key。',
      );
    }

    final request = protocol.buildRequest(config, apiKey, messages);
    ProviderHttpResponse response;
    try {
      response = await httpClient.post(
        uri: request.uri,
        headers: request.headers,
        body: jsonEncode(request.body),
        timeout: Duration(seconds: config.timeoutSeconds),
      );
    } on TimeoutException {
      throw const ModelGatewayException(
        kind: ModelFailureKind.timeout,
        message: '连接模型服务超时。',
      );
    } on HandshakeException {
      throw const ModelGatewayException(
        kind: ModelFailureKind.tls,
        message: '模型服务的 TLS 安全连接失败。',
      );
    } on SocketException catch (error) {
      throw _socketFailure(error);
    } on HttpException {
      throw const ModelGatewayException(
        kind: ModelFailureKind.network,
        message: '模型服务连接中断。',
      );
    } on ModelGatewayException {
      rethrow;
    } on Object {
      throw const ModelGatewayException(
        kind: ModelFailureKind.network,
        message: '模型服务暂时不可用。',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _statusFailure(response);
    }
    late Map<String, Object?> payload;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('response is not an object');
      }
      payload = decoded;
    } on Object {
      throw const ModelGatewayException(
        kind: ModelFailureKind.incompatibleResponse,
        message: '模型服务返回了不兼容的响应格式。',
      );
    }
    try {
      final content = protocol.readContent(payload).trim();
      if (content.isEmpty) {
        throw const FormatException('empty content');
      }
      return content;
    } on ModelGatewayException {
      rethrow;
    } on Object {
      throw const ModelGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '模型服务返回的内容无法解析。',
      );
    }
  }
}

typedef _ProviderRequest = ({
  Uri uri,
  Map<String, String> headers,
  Map<String, Object?> body,
});

abstract interface class _ProviderProtocol {
  bool get requiresApiKey;

  _ProviderRequest buildRequest(
    ProviderConfig config,
    String? apiKey,
    List<ModelMessage> messages,
  );

  String readContent(Map<String, Object?> payload);
}

_ProviderProtocol _providerProtocol(ProviderKind kind) => switch (kind) {
  ProviderKind.openAiCompatible => const _OpenAiCompatibleProtocol(),
  ProviderKind.anthropic => const _AnthropicProtocol(),
  ProviderKind.ollama => const _OllamaProtocol(),
};

final class _OpenAiCompatibleProtocol implements _ProviderProtocol {
  const _OpenAiCompatibleProtocol();

  @override
  bool get requiresApiKey => true;

  @override
  _ProviderRequest buildRequest(
    ProviderConfig config,
    String? apiKey,
    List<ModelMessage> messages,
  ) => (
    uri: _appendEndpoint(config.baseUrl, 'chat/completions'),
    headers: {
      'content-type': 'application/json',
      'authorization': 'Bearer ${apiKey!.trim()}',
    },
    body: {
      'model': config.model.trim(),
      'messages': messages.map(_messageJson).toList(),
      'temperature': config.temperature,
      'stream': false,
    },
  );

  @override
  String readContent(Map<String, Object?> payload) {
    final choices = payload['choices']! as List<Object?>;
    final message =
        (choices.first! as Map<String, Object?>)['message']!
            as Map<String, Object?>;
    final content = message['content'];
    if (content is String) {
      return content;
    }
    return (content! as List<Object?>)
        .map((part) => (part! as Map<String, Object?>)['text'] as String? ?? '')
        .join();
  }
}

final class _AnthropicProtocol implements _ProviderProtocol {
  const _AnthropicProtocol();

  @override
  bool get requiresApiKey => true;

  @override
  _ProviderRequest buildRequest(
    ProviderConfig config,
    String? apiKey,
    List<ModelMessage> messages,
  ) => (
    uri: _appendEndpoint(config.baseUrl, 'messages'),
    headers: {
      'content-type': 'application/json',
      'x-api-key': apiKey!.trim(),
      'anthropic-version': '2023-06-01',
    },
    body: {
      'model': config.model.trim(),
      'system': messages
          .where((message) => message.role == ModelMessageRole.system)
          .map((message) => message.content)
          .join('\n'),
      'messages': messages
          .where((message) => message.role != ModelMessageRole.system)
          .map(_messageJson)
          .toList(),
      'temperature': config.temperature,
      'max_tokens': 512,
      'stream': false,
    },
  );

  @override
  String readContent(Map<String, Object?> payload) =>
      (payload['content']! as List<Object?>)
          .map((part) => part! as Map<String, Object?>)
          .where((part) => part['type'] == 'text')
          .map((part) => part['text'] as String? ?? '')
          .join();
}

final class _OllamaProtocol implements _ProviderProtocol {
  const _OllamaProtocol();

  @override
  bool get requiresApiKey => false;

  @override
  _ProviderRequest buildRequest(
    ProviderConfig config,
    String? apiKey,
    List<ModelMessage> messages,
  ) {
    final headers = <String, String>{'content-type': 'application/json'};
    if (apiKey != null && apiKey.trim().isNotEmpty) {
      headers['authorization'] = 'Bearer ${apiKey.trim()}';
    }
    return (
      uri: _appendEndpoint(config.baseUrl, 'api/chat', ollama: true),
      headers: headers,
      body: {
        'model': config.model.trim(),
        'messages': messages.map(_messageJson).toList(),
        'options': {'temperature': config.temperature},
        'stream': false,
      },
    );
  }

  @override
  String readContent(Map<String, Object?> payload) =>
      (payload['message']! as Map<String, Object?>)['content']! as String;
}

Map<String, String> _messageJson(ModelMessage message) => {
  'role': message.role.name,
  'content': message.content,
};

Uri _appendEndpoint(String baseUrl, String suffix, {bool ollama = false}) {
  final base = Uri.parse(baseUrl.trim());
  final normalizedPath = base.path.replaceFirst(RegExp(r'/+$'), '');
  if (normalizedPath.endsWith('/$suffix')) {
    return base.replace(path: normalizedPath);
  }
  if (ollama && normalizedPath.endsWith('/api')) {
    return base.replace(path: '$normalizedPath/chat');
  }
  final path = normalizedPath.isEmpty ? '/$suffix' : '$normalizedPath/$suffix';
  return base.replace(path: path);
}

ModelGatewayException _statusFailure(ProviderHttpResponse response) {
  if (response.statusCode == HttpStatus.unauthorized ||
      response.statusCode == HttpStatus.forbidden) {
    return const ModelGatewayException(
      kind: ModelFailureKind.authentication,
      message: 'API Key 未通过模型服务验证。',
    );
  }
  if (response.statusCode == HttpStatus.tooManyRequests) {
    return const ModelGatewayException(
      kind: ModelFailureKind.rateLimited,
      message: '模型服务请求过于频繁。',
    );
  }
  final lowerBody = response.body.toLowerCase();
  if (lowerBody.contains('model') &&
      (lowerBody.contains('not found') ||
          lowerBody.contains('does not exist') ||
          lowerBody.contains('unknown model') ||
          lowerBody.contains('no such model'))) {
    return const ModelGatewayException(
      kind: ModelFailureKind.modelNotFound,
      message: '模型名称不存在或当前账号不可用。',
    );
  }
  return const ModelGatewayException(
    kind: ModelFailureKind.provider,
    message: '模型服务拒绝了这次请求。',
  );
}

ModelGatewayException _socketFailure(SocketException error) {
  final message = error.message.toLowerCase();
  final code = error.osError?.errorCode;
  if (message.contains('failed host lookup') || code == 11001) {
    return const ModelGatewayException(
      kind: ModelFailureKind.dns,
      message: '找不到模型服务域名。',
    );
  }
  return const ModelGatewayException(
    kind: ModelFailureKind.network,
    message: '无法连接模型服务。',
  );
}
