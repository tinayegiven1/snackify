import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:snackify/core/network/api_client.dart';
import 'package:snackify/core/network/backend_health_service.dart';

BackendHealthService _serviceWith(MockClientHandler handler) {
  return BackendHealthService(
    ApiClient(baseUrl: 'http://api.test', httpClient: MockClient(handler)),
  );
}

void main() {
  test('reports healthy when the API returns status ok', () async {
    final service = _serviceWith((request) async {
      expect(request.url.toString(), 'http://api.test/api/v1/health');
      return http.Response(jsonEncode({'status': 'ok'}), 200);
    });

    expect(await service.isHealthy(), isTrue);
  });

  test('reports unhealthy on an error response', () async {
    final service = _serviceWith((request) async {
      return http.Response(
        jsonEncode({
          'error': {'code': 'INTERNAL_ERROR', 'message': 'Something went wrong.'},
        }),
        500,
      );
    });

    expect(await service.isHealthy(), isFalse);
  });

  test('reports unhealthy when the API cannot be reached', () async {
    final service = _serviceWith((request) async {
      throw http.ClientException('Connection refused');
    });

    expect(await service.isHealthy(), isFalse);
  });

  test('reports unhealthy when the response is not JSON', () async {
    final service = _serviceWith((request) async => http.Response('<html>Bad gateway</html>', 502));

    expect(await service.isHealthy(), isFalse);
  });
}
