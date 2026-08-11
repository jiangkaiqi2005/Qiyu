import 'package:http/http.dart' as http;

abstract interface class HostConnectionProbe {
  Future<bool> isHostAvailable();
}

final class HttpHostConnectionProbe implements HostConnectionProbe {
  HttpHostConnectionProbe({http.Client? client, Uri? healthUri})
    : _client = client ?? http.Client(),
      _healthUri = healthUri ?? Uri.base.resolve('/api/health');

  final http.Client _client;
  final Uri _healthUri;

  @override
  Future<bool> isHostAvailable() async {
    try {
      final response = await _client
          .get(_healthUri)
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } on Object {
      return false;
    }
  }
}
