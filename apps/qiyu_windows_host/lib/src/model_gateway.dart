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
  authentication,
  network,
  modelNotFound,
  invalidResponse,
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
    if (config.kind != ProviderKind.ollama &&
        (apiKey == null || apiKey.trim().isEmpty)) {
      throw const ModelGatewayException(
        kind: ModelFailureKind.authentication,
        message: '还没有保存 API Key。',
      );
    }

    final request = _buildRequest(config, apiKey, messages);
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
        kind: ModelFailureKind.network,
        message: '连接模型服务超时。',
      );
    } on SocketException {
      throw const ModelGatewayException(
        kind: ModelFailureKind.network,
        message: '无法连接模型服务。',
      );
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
    try {
      final payload = jsonDecode(response.body) as Map<String, Object?>;
      final content = _readContent(config.kind, payload).trim();
      if (content.isEmpty) {
        throw const FormatException('empty content');
      }
      return content;
    } on ModelGatewayException {
      rethrow;
    } on Object {
      throw const ModelGatewayException(
        kind: ModelFailureKind.invalidResponse,
        message: '模型服务返回了无法读取的内容。',
      );
    }
  }
}

({Uri uri, Map<String, String> headers, Map<String, Object?> body})
_buildRequest(
  ProviderConfig config,
  String? apiKey,
  List<ModelMessage> messages,
) {
  final headers = <String, String>{'content-type': 'application/json'};
  final body = <String, Object?>{
    'model': config.model.trim(),
    'temperature': config.temperature,
    'stream': false,
  };
  switch (config.kind) {
    case ProviderKind.openAiCompatible:
      headers['authorization'] = 'Bearer ${apiKey!.trim()}';
      body['messages'] = messages.map(_messageJson).toList();
    case ProviderKind.anthropic:
      headers
        ..['x-api-key'] = apiKey!.trim()
        ..['anthropic-version'] = '2023-06-01';
      body
        ..['system'] = messages
            .where((message) => message.role == ModelMessageRole.system)
            .map((message) => message.content)
            .join('\n')
        ..['messages'] = messages
            .where((message) => message.role != ModelMessageRole.system)
            .map(_messageJson)
            .toList()
        ..['max_tokens'] = 512;
    case ProviderKind.ollama:
      body
        ..remove('temperature')
        ..['messages'] = messages.map(_messageJson).toList()
        ..['options'] = {'temperature': config.temperature};
      if (apiKey != null && apiKey.trim().isNotEmpty) {
        headers['authorization'] = 'Bearer ${apiKey.trim()}';
      }
  }
  return (uri: _providerEndpoint(config), headers: headers, body: body);
}

Map<String, String> _messageJson(ModelMessage message) => {
  'role': message.role.name,
  'content': message.content,
};

Uri _providerEndpoint(ProviderConfig config) {
  final base = Uri.parse(config.baseUrl.trim());
  final suffix = switch (config.kind) {
    ProviderKind.openAiCompatible => 'chat/completions',
    ProviderKind.anthropic => 'messages',
    ProviderKind.ollama => 'api/chat',
  };
  final normalizedPath = base.path.replaceFirst(RegExp(r'/+$'), '');
  if (normalizedPath.endsWith('/$suffix')) {
    return base.replace(path: normalizedPath);
  }
  if (config.kind == ProviderKind.ollama && normalizedPath.endsWith('/api')) {
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
  final lowerBody = response.body.toLowerCase();
  if (response.statusCode == HttpStatus.notFound ||
      (lowerBody.contains('model') &&
          (lowerBody.contains('not found') ||
              lowerBody.contains('does not exist') ||
              lowerBody.contains('unknown model') ||
              lowerBody.contains('no such model')))) {
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

String _readContent(ProviderKind kind, Map<String, Object?> payload) {
  return switch (kind) {
    ProviderKind.openAiCompatible => _openAiContent(payload),
    ProviderKind.anthropic => _anthropicContent(payload),
    ProviderKind.ollama =>
      (payload['message']! as Map<String, Object?>)['content']! as String,
  };
}

String _openAiContent(Map<String, Object?> payload) {
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

String _anthropicContent(Map<String, Object?> payload) =>
    (payload['content']! as List<Object?>)
        .map((part) => part! as Map<String, Object?>)
        .where((part) => part['type'] == 'text')
        .map((part) => part['text'] as String? ?? '')
        .join();
