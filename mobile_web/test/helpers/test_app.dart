import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:snackify/app.dart';
import 'package:snackify/core/network/api_client.dart';
import 'package:snackify/features/auth/data/auth_repository.dart';
import 'package:snackify/features/auth/data/token_store.dart';
import 'package:snackify/features/auth/presentation/auth_controller.dart';

const phoneSize = Size(390, 844);
const desktopSize = Size(1280, 800);

const testUsername = 'tendai';
const testPassword = 'correct horse battery';

/// A pretend Snackify backend that follows the real API's rules for signing in and out.
class FakeBackend {
  bool reachable = true;
  final Set<String> validTokens = {};

  /// Every request received, as "METHOD /path".
  final List<String> requests = [];
  int _issued = 0;

  static const user = {
    'id': '7f9c2b1e-0000-4000-8000-000000000001',
    'username': testUsername,
    'fullName': 'Tendai Moyo',
    'role': 'storekeeper',
  };

  /// Creates a valid session token, as the server would on sign-in.
  String issueToken() {
    final token = 'token${++_issued}'.padRight(43, 'x');
    validTokens.add(token);
    return token;
  }

  late final http.Client client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    final route = '${request.method} ${request.url.path}';
    requests.add(route);
    if (!reachable) throw http.ClientException('Connection refused');

    final token = (request.headers['Authorization'] ?? '').replaceFirst('Bearer ', '');
    switch (route) {
      case 'GET /api/v1/health':
        return _json(200, {'status': 'ok'});
      case 'POST /api/v1/auth/login':
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['username'] == testUsername && body['password'] == testPassword) {
          return _json(200, {
            'token': issueToken(),
            'expiresAt': '2026-10-13T00:00:00.000Z',
            'user': user,
          });
        }
        return _error(401, 'INVALID_CREDENTIALS', 'Incorrect username or password.');
      case 'GET /api/v1/auth/me':
        return validTokens.contains(token) ? _json(200, {'user': user}) : _signedOut();
      case 'POST /api/v1/auth/logout':
        return validTokens.remove(token) ? http.Response('', 204) : _signedOut();
    }
    return _error(404, 'NOT_FOUND', 'Not found');
  }

  http.Response _signedOut() =>
      _error(401, 'UNAUTHENTICATED', 'Your session has ended. Please sign in again.');

  http.Response _error(int status, String code, String message) => _json(status, {
    'error': {'code': code, 'message': message},
  });

  http.Response _json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
}

class TestApp {
  TestApp(this.backend, this.api, this.tokenStore, this.auth);

  final FakeBackend backend;
  final ApiClient api;
  final MemoryTokenStore tokenStore;
  final AuthController auth;
}

/// Starts the whole app against [FakeBackend]. With [signedIn], a valid session is
/// already saved on the device, as if the user signed in earlier.
Future<TestApp> pumpSnackify(
  WidgetTester tester, {
  Size size = phoneSize,
  bool signedIn = false,
  String? savedToken,
  bool apiHealthy = true,
  FakeBackend? backend,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final server = backend ?? FakeBackend();
  final api = ApiClient(baseUrl: 'http://api.test', httpClient: server.client);
  final store = MemoryTokenStore(signedIn ? server.issueToken() : savedToken);
  final auth = AuthController(AuthRepository(api: api, tokenStore: store));

  await tester.pumpWidget(SnackifyApp(auth: auth, checkBackendHealth: () async => apiHealthy));
  auth.restore();
  await tester.pumpAndSettle();
  return TestApp(server, api, store, auth);
}

/// Fills in the login form and presses "Sign in".
Future<void> signInThroughForm(WidgetTester tester, String username, String password) async {
  await tester.enterText(find.widgetWithText(TextFormField, 'Username'), username);
  await tester.enterText(find.widgetWithText(TextFormField, 'Password'), password);
  await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
  await tester.pumpAndSettle();
}
