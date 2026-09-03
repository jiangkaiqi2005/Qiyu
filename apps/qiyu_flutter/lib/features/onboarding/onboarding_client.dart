import 'dart:convert';

import '../baseline/host_api_gateway.dart';

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

  /// [appellation] 为首见引导收集的称呼；null 表示不带称呼完成引导
  /// （跳过输入），Host 对不带称呼的请求保持向后兼容。
  Future<void> complete({String? appellation});
}

final class HttpOnboardingGateway extends HostApiGateway
    implements OnboardingGateway {
  HttpOnboardingGateway({super.client, super.baseUri});

  @override
  Object errorFor(String message) => OnboardingGatewayException(message);

  @override
  String get unavailableMessage => '本机程序暂时不可用，请稍后重试。';

  @override
  Future<OnboardingState> read() async {
    await ensureBootstrap();
    final response = await httpClient.get(resolve('/api/onboarding'));
    return OnboardingState.fromJson(decodeSuccess(response));
  }

  @override
  Future<void> complete({String? appellation}) async {
    final response = await httpClient.post(
      resolve('/api/onboarding/complete'),
      headers: await modifyingHeaders(),
      body: appellation == null
          ? '{}'
          : jsonEncode({'appellation': appellation}),
    );
    decodeSuccess(response);
  }
}
