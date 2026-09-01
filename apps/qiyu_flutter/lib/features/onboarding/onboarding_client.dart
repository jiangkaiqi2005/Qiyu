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

  Future<void> complete();
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
  Future<void> complete() async {
    final response = await httpClient.post(
      resolve('/api/onboarding/complete'),
      headers: await modifyingHeaders(),
      body: '{}',
    );
    decodeSuccess(response);
  }
}
