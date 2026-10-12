import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:snackify/app.dart';
import 'package:snackify/core/app_services.dart';
import 'package:snackify/core/formatting/dates.dart';
import 'package:snackify/core/network/api_client.dart';
import 'package:snackify/features/auth/data/auth_repository.dart';
import 'package:snackify/features/auth/data/token_store.dart';
import 'package:snackify/features/auth/presentation/auth_controller.dart';
import 'package:snackify/features/customers/data/customers_repository.dart';
import 'package:snackify/features/products/data/products_repository.dart';
import 'package:snackify/features/stock/data/stock_repository.dart';

const phoneSize = Size(390, 844);
const desktopSize = Size(1280, 800);

const testUsername = 'tendai';
const testPassword = 'correct horse battery';

/// A pretend Snackify backend that follows the real API's rules for signing in and out,
/// products (only admins may change them) and stock (storekeepers and admins receive stock;
/// only admins record opening balances and adjustments; stock never goes below zero).
class FakeBackend {
  FakeBackend({this.role = 'storekeeper'});

  /// The signed-in user's role.
  final String role;

  bool reachable = true;
  final Set<String> validTokens = {};
  final List<Map<String, Object?>> products = [];
  final List<Map<String, Object?>> receipts = [];
  final List<Map<String, Object?>> customers = [];

  /// Adds a customer directly, as if it already existed on the server.
  void addCustomer(
    String code,
    String name, {
    String? phone,
    String? address,
    String? creditLimit,
    bool isActive = true,
  }) {
    customers.add({
      'id': 'customer-${customers.length + 1}',
      'code': code,
      'name': name,
      'phone': phone,
      'address': address,
      'creditLimit': creditLimit,
      'isActive': isActive,
    });
  }

  /// The stock ledger, oldest first.
  final List<Map<String, Object?>> movements = [];

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
    int? reorderLevel,
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
      'reorderLevel': reorderLevel,
      'isActive': isActive,
    });
  }

  /// Records stock already received for the product with [sku].
  void addStock(String sku, int quantity, {String? receivedDate}) {
    final product = products.firstWhere((p) => p['sku'] == sku);
    _recordReceipt(product, {
      'quantity': quantity,
      'receivedDate': receivedDate ?? toApiDate(today()),
    });
  }

  int onHand(Object? productId) => movements
      .where((m) => m['productId'] == productId)
      .fold(0, (sum, m) => sum + (m['quantityDelta'] as int));

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
    if (path.startsWith('/api/v1/stock')) return _stock(request);
    if (path.startsWith('/api/v1/customers')) return _customers(request);
    return _error(404, 'NOT_FOUND', 'Not found');
  }

  Map<String, Object?> _summary(Map<String, Object?> product) => {
    for (final key in ['id', 'sku', 'name', 'flavour', 'size']) key: product[key],
  };

  Map<String, Object?> _recordReceipt(Map<String, Object?> product, Map<String, dynamic> body) {
    final receipt = <String, Object?>{
      'id': 'receipt-${receipts.length + 1}',
      'product': _summary(product),
      'quantity': body['quantity'],
      'receivedDate': body['receivedDate'],
      'batchNumber': body['batchNumber'],
      'expiryDate': body['expiryDate'],
      'supplierReference': body['supplierReference'],
      'isOpeningBalance': body['isOpeningBalance'] ?? false,
      'receivedBy': {'id': 'user-1', 'fullName': 'Tendai Moyo'},
    };
    receipts.add(receipt);
    _addMovement(
      product['id'],
      receipt['isOpeningBalance'] == true ? 'opening_balance' : 'receipt',
      body['quantity'] as int,
      body['receivedDate'] as String,
      reference: body['supplierReference'] as String?,
    );
    return receipt;
  }

  void _addMovement(
    Object? productId,
    String type,
    int delta,
    String date, {
    String? reference,
    String? reason,
  }) {
    movements.add({
      'id': 'movement-${movements.length + 1}',
      'productId': productId,
      'type': type,
      'quantityDelta': delta,
      'businessDate': date,
      'reference': reference,
      'reason': reason,
      'batchNumber': null,
      'createdBy': {'id': 'user-1', 'fullName': 'Tendai Moyo'},
      'balanceAfter': onHand(productId) + delta,
    });
  }

  http.Response _stock(http.Request request) {
    final query = request.url.queryParameters;
    final route = '${request.method} ${request.url.path}';
    final forbidden = _error(403, 'FORBIDDEN', 'Your role does not allow this action.');

    switch (route) {
      case 'GET /api/v1/stock/balance':
        final q = (query['q'] ?? '').toLowerCase();
        final balances = [
          for (final p in products.where((p) => p['isActive'] == true))
            {
              'product': {..._summary(p), 'isActive': true},
              'quantityOnHand': onHand(p['id']),
              'reorderLevel': p['reorderLevel'],
              'isLowStock':
                  p['reorderLevel'] != null && onHand(p['id']) <= (p['reorderLevel'] as int),
            },
        ];
        return _json(200, {
          'balances': balances
              .where((b) => q.isEmpty || '${b['product']}'.toLowerCase().contains(q))
              .where((b) => query['lowStockOnly'] != 'true' || b['isLowStock'] == true)
              .toList(),
        });

      case 'GET /api/v1/stock/receipts':
        final matching = receipts.reversed.where((r) {
          final date = r['receivedDate'] as String;
          return date.compareTo(query['from']!) >= 0 && date.compareTo(query['to']!) <= 0;
        }).toList();
        return _json(200, {
          'from': query['from'],
          'to': query['to'],
          'receipts': matching,
          'totalQuantity': matching.fold<int>(0, (sum, r) => sum + (r['quantity'] as int)),
        });

      case 'GET /api/v1/stock/movements':
        final history = movements.reversed
            .where((m) => m['productId'] == query['productId'])
            .toList();
        return _json(200, {
          'movements': [
            for (final m in history)
              {...m, 'product': _summary(products.firstWhere((p) => p['id'] == m['productId']))},
          ],
          'total': history.length,
        });

      case 'POST /api/v1/stock/receipts':
        if (role != 'admin' && role != 'storekeeper') return forbidden;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final product = products.firstWhere((p) => p['id'] == body['productId']);
        if (body['isOpeningBalance'] == true) {
          if (role != 'admin') return forbidden;
          if (movements.any((m) => m['productId'] == product['id'])) {
            return _error(
              409,
              'OPENING_BALANCE_NOT_ALLOWED',
              'This product already has stock records. Use a stock adjustment to correct its '
                  'balance.',
            );
          }
        }
        final receipt = _recordReceipt(product, body);
        return _json(201, {'receipt': receipt, 'quantityOnHand': onHand(product['id'])});

      case 'POST /api/v1/stock/adjustments':
        if (role != 'admin') return forbidden;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final delta = body['quantityDelta'] as int;
        final before = onHand(body['productId']);
        if (before + delta < 0) {
          return _error(
            409,
            'INSUFFICIENT_STOCK',
            'Only $before in stock, so ${-delta} cannot be removed.',
          );
        }
        _addMovement(
          body['productId'],
          body['type'] as String,
          delta,
          toApiDate(today()),
          reason: body['reason'] as String?,
        );
        return _json(201, {'movement': movements.last, 'quantityOnHand': before + delta});
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

  /// Who may change which customer fields, as on the real server.
  static const _customerFieldRoles = {
    'code': ['admin', 'salesperson'],
    'name': ['admin', 'salesperson'],
    'phone': ['admin', 'salesperson'],
    'address': ['admin', 'salesperson'],
    'creditLimit': ['admin', 'accounts'],
    'isActive': ['admin'],
  };

  http.Response _customers(http.Request request) {
    final forbidden = _error(403, 'FORBIDDEN', 'Your role does not allow this action.');
    if (request.method == 'GET') {
      final query = request.url.queryParameters;
      final q = (query['q'] ?? '').toLowerCase();
      final matches =
          customers
              .where((c) => query['includeInactive'] == 'true' || c['isActive'] == true)
              .where(
                (c) =>
                    q.isEmpty ||
                    [
                      'code',
                      'name',
                      'phone',
                    ].any((field) => '${c[field] ?? ''}'.toLowerCase().contains(q)),
              )
              .toList()
            ..sort(
              (a, b) => (a['name'] as String).toLowerCase().compareTo(
                (b['name'] as String).toLowerCase(),
              ),
            );
      return _json(200, {'customers': matches, 'total': matches.length});
    }

    final body = jsonDecode(request.body) as Map<String, dynamic>;
    for (final field in body.keys) {
      if (body[field] != null || request.method == 'PATCH') {
        if (!(_customerFieldRoles[field] ?? const []).contains(role)) return forbidden;
      }
    }
    final code = (body['code'] as String?)?.toUpperCase();
    if (code != null &&
        customers.any((c) => c['code'] == code && !request.url.path.endsWith('/${c['id']}'))) {
      return _json(409, {
        'error': {
          'code': 'CUSTOMER_CODE_TAKEN',
          'message': 'Another customer already uses the code "$code".',
          'details': [
            {'field': 'code', 'message': 'Already used by another customer'},
          ],
        },
      });
    }

    if (request.method == 'POST') {
      addCustomer(
        code ?? 'C${(customers.length + 1).toString().padLeft(4, '0')}',
        body['name'] as String,
        phone: body['phone'] as String?,
        address: body['address'] as String?,
        creditLimit: body['creditLimit'] == null
            ? null
            : double.parse(body['creditLimit'] as String).toStringAsFixed(2),
      );
      return _json(201, {'customer': customers.last});
    }

    final customer = customers.firstWhere((c) => request.url.path.endsWith('/${c['id']}'));
    customer.addAll({...body, 'code': ?code});
    if (body['creditLimit'] != null) {
      customer['creditLimit'] = double.parse(body['creditLimit'] as String).toStringAsFixed(2);
    }
    return _json(200, {'customer': customer});
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
    stock: StockRepository(api),
    customers: CustomersRepository(api),
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
