import 'dart:convert';

import 'package:http/http.dart' as http;

final class OnboardingState {
  const OnboardingState({required this.completed});

  factory OnboardingState.fromJson(Map<String, Object?> json) =>
      OnboardingState(completed: json['completed'] == true);

  final bool completed;
}

final class OnboardingGatewayException implements Exception {
  const OnboardingGatewayException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class OnboardingGateway {
  Future<OnboardingState> read();

  Future<void> complete();
}

final class HttpOnboardingGateway implements OnboardingGateway {
  HttpOnboardingGateway({http.Client? client, Uri? baseUri})
    : _client = client ?? http.Client(),
      _baseUri = baseUri ?? Uri.base;

  final http.Client _client;
  final Uri _baseUri;
  String? _csrfToken;

  @override
  Future<OnboardingState> read() async {
    await _ensureBootstrap();
    final response = await _client.get(_baseUri.resolve('/api/onboarding'));
    return OnboardingState.fromJson(_decodeSuccess(response));
  }

  @override
  Future<void> complete() async {
    await _ensureBootstrap();
    final response = await _client.post(
      _baseUri.resolve('/api/onboarding/complete'),
      headers: {
        'content-type': 'application/json',
        'x-qiyu-csrf': _csrfToken!,
      },
      body: '{}',
    );
    _decodeSuccess(response);
  }

  Future<void> _ensureBootstrap() async {
    if (_csrfToken != null) {
      return;
    }
    final response = await _client.get(_baseUri.resolve('/api/bootstrap'));
    final json = _decodeSuccess(response);
    _csrfToken = json['csrfToken']! as String;
  }
}

Map<String, Object?> _decodeSuccess(http.Response response) {
  Map<String, Object?>? json;
  try {
    json = jsonDecode(response.body) as Map<String, Object?>;
  } on Object {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      throw const OnboardingGatewayException('本机程序返回了无法读取的内容。');
    }
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw OnboardingGatewayException(
      json?['message'] as String? ?? '本机程序暂时不可用，请稍后重试。',
    );
  }
  return json!;
}
