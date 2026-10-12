import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:snackify/app.dart';
import 'package:snackify/core/app_services.dart';
import 'package:snackify/core/network/api_client.dart';
import 'package:snackify/features/auth/data/auth_repository.dart';
import 'package:snackify/features/auth/data/token_store.dart';
import 'package:snackify/features/auth/presentation/auth_controller.dart';
import 'package:snackify/features/products/data/products_repository.dart';

const phoneSize = Size(390, 844);
const desktopSize = Size(1280, 800);

const testUsername = 'tendai';
const testPassword = 'correct horse battery';

/// A pretend Snackify backend that follows the real API's rules for signing in and out,
/// and for viewing and changing products (only admins may change them).
class FakeBackend {
  FakeBackend({this.role = 'storekeeper'});

  /// The signed-in user's role.
  final String role;

  bool reachable = true;
  final Set<String> validTokens = {};
  final List<Map<String, Object?>> products = [];

  /// Every request received, as "METHOD /path" (plus "?query" when there is one).
  final List<String> requests = [];
  int _issued = 0;

  Map<String, Object?> get user => {
    'id': '7f9c2b1e-0000-4000-8000-000000000001',
    'username': testUsername,
    'fullName': 'Tendai Moyo',
    'role': role,
  };

  /// Creates a valid session token, as the server would on sign-in.
  String issueToken() {
    final token = 'token${++_issued}'.padRight(43, 'x');
    validTokens.add(token);
    return token;
  }

  /// Adds a product directly, as if it already existed on the server.
  void addProduct(
    String sku,
    String name,
    String flavour,
    String size,
    String price, {
    String? barcode,
    bool isActive = true,
  }) {
    products.add({
      'id': 'product-${products.length + 1}',
      'sku': sku,
      'name': name,
      'flavour': flavour,
      'size': size,
      'barcode': barcode,
      'defaultPrice': price,
      'isActive': isActive,
    });
  }

  late final http.Client client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    final route = '${request.method} $path';
    requests.add(request.url.hasQuery ? '$route?${request.url.query}' : route);
    if (!reachable) throw http.ClientException('Connection refused');

    final token = (request.headers['Authorization'] ?? '').replaceFirst('Bearer ', '');
    if (route == 'GET /api/v1/health') return _json(200, {'status': 'ok'});
    if (route == 'POST /api/v1/auth/login') return _login(request);
    if (!validTokens.contains(token)) return _signedOut();

    if (route == 'GET /api/v1/auth/me') return _json(200, {'user': user});
    if (route == 'POST /api/v1/auth/logout') {
      validTokens.remove(token);
      return http.Response('', 204);
    }
    if (route == 'GET /api/v1/products') return _listProducts(request.url.queryParameters);
    if (path.startsWith('/api/v1/products') && request.method != 'GET') {
      if (role != 'admin') {
        return _error(403, 'FORBIDDEN', 'Your role does not allow this action.');
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return request.method == 'POST' ? _createProduct(body) : _updateProduct(path, body);
    }
    return _error(404, 'NOT_FOUND', 'Not found');
  }

  http.Response _login(http.Request request) {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (body['username'] == testUsername && body['password'] == testPassword) {
      return _json(200, {
        'token': issueToken(),
        'expiresAt': '2026-10-13T00:00:00.000Z',
        'user': user,
      });
    }
    return _error(401, 'INVALID_CREDENTIALS', 'Incorrect username or password.');
  }

  http.Response _listProducts(Map<String, String> query) {
    final q = (query['q'] ?? '').toLowerCase();
    final matches =
        products
            .where((p) => query['includeInactive'] == 'true' || p['isActive'] == true)
            .where(
              (p) =>
                  q.isEmpty ||
                  p['barcode'] == q ||
                  [
                    'sku',
                    'name',
                    'flavour',
                    'size',
                  ].any((field) => (p[field] as String).toLowerCase().contains(q)),
            )
            .toList()
          ..sort((a, b) => '${a['name']}${a['flavour']}'.compareTo('${b['name']}${b['flavour']}'));
    return _json(200, {'products': matches, 'total': matches.length});
  }

  http.Response _createProduct(Map<String, dynamic> body) {
    if (products.any((p) => p['sku'] == body['sku'])) return _skuTaken(body['sku']);
    addProduct(
      body['sku'] as String,
      body['name'] as String,
      body['flavour'] as String,
      body['size'] as String,
      double.parse(body['defaultPrice'] as String).toStringAsFixed(2),
      barcode: body['barcode'] as String?,
    );
    return _json(201, {'product': products.last});
  }

  http.Response _updateProduct(String path, Map<String, dynamic> body) {
    final product = products.firstWhere((p) => path.endsWith('/${p['id']}'));
    if (products.any((p) => p != product && p['sku'] == body['sku'])) {
      return _skuTaken(body['sku']);
    }
    product.addAll(body);
    product['defaultPrice'] = double.parse(body['defaultPrice'] as String).toStringAsFixed(2);
    return _json(200, {'product': product});
  }

  http.Response _skuTaken(Object? sku) => _json(409, {
    'error': {
      'code': 'SKU_TAKEN',
      'message': 'Another product already uses the SKU "$sku".',
      'details': [
        {'field': 'sku', 'message': 'Already used by another product'},
      ],
    },
  });

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
  final services = AppServices(
    checkBackendHealth: () async => apiHealthy,
    products: ProductsRepository(api),
  );

  await tester.pumpWidget(SnackifyApp(auth: auth, services: services));
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

/// Opens a section from the menu (drawer on phones, sidebar on wide screens).
Future<void> openSection(WidgetTester tester, String label) async {
  final menuButton = find.byTooltip('Open navigation menu');
  if (menuButton.evaluate().isNotEmpty) {
    await tester.tap(menuButton);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}
