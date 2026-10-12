import 'api_client.dart';

/// Checks whether the Snackify backend is running and reachable.
class BackendHealthService {
  BackendHealthService(this._client);

  final ApiClient _client;

  Future<bool> isHealthy() async {
    try {
      final body = await _client.getJson('/api/v1/health');
      return body['status'] == 'ok';
    } on ApiException {
      return false;
    }
  }
}
