import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:snackify/app.dart';
import 'package:snackify/core/app_services.dart';
import 'package:snackify/core/formatting/dates.dart';
import 'package:snackify/core/formatting/money.dart';
import 'package:snackify/core/network/api_client.dart';
import 'package:snackify/features/auth/data/auth_repository.dart';
import 'package:snackify/features/auth/data/token_store.dart';
import 'package:snackify/features/auth/presentation/auth_controller.dart';
import 'package:snackify/features/customers/data/customers_repository.dart';
import 'package:snackify/features/dispatches/data/dispatches_repository.dart';
import 'package:snackify/features/invoices/data/invoices_repository.dart';
import 'package:snackify/features/payments/data/payments_repository.dart';
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

  /// Dispatches, oldest first. Lines are stored as {productId, quantity, unitPrice}.
  final List<Map<String, Object?>> dispatches = [];

  /// Adds a draft dispatch directly, e.g. addDraft('C0001', {'PC-BBQ-S': 12}).
  Map<String, Object?> addDraft(String customerCode, Map<String, int> quantities) {
    final dispatch = <String, Object?>{
      'id': 'dispatch-${dispatches.length + 1}',
      'dispatchNumber': 'D${(dispatches.length + 1).toString().padLeft(6, '0')}',
      'status': 'draft',
      'dispatchDate': toApiDate(today()),
      'notes': null,
      'customerId': customers.firstWhere((c) => c['code'] == customerCode)['id'],
      'lines': [
        for (final MapEntry(key: sku, value: quantity) in quantities.entries)
          {
            'productId': products.firstWhere((p) => p['sku'] == sku)['id'],
            'quantity': quantity,
            'unitPrice': products.firstWhere((p) => p['sku'] == sku)['defaultPrice'],
          },
      ],
      'confirmedOverCreditLimit': false,
      'confirmedBy': null,
      'cancelReason': null,
      'reversalReason': null,
    };
    dispatches.add(dispatch);
    return dispatch;
  }

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

  /// When set, the next request is carried out but its response never arrives, like a
  /// connection that drops just after the server has acted.
  bool loseNextResponse = false;

  Future<http.Response> _handle(http.Request request) async {
    final response = await _route(request);
    if (loseNextResponse) {
      loseNextResponse = false;
      throw http.ClientException('Connection reset');
    }
    return response;
  }

  Future<http.Response> _route(http.Request request) async {
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
    if (path.startsWith('/api/v1/dispatches')) return _dispatches(request);
    if (path.startsWith('/api/v1/invoices')) return _invoices(request);
    if (path.startsWith('/api/v1/payments')) return _payments(request);
    if (path.startsWith('/api/v1/balances')) return _balances(request);
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

  int _lineCents(Map<String, Object?> line) =>
      (line['quantity'] as int) * parseCents(line['unitPrice'] as String)!;

  int _totalCents(Map<String, Object?> dispatch) =>
      (dispatch['lines'] as List<Map<String, Object?>>).fold(0, (sum, l) => sum + _lineCents(l));

  /// Unpaid balance: every confirmed dispatch (no payments exist yet).
  int _balanceCents(Object? customerId) => dispatches
      .where((d) => d['customerId'] == customerId && d['status'] == 'confirmed')
      .fold(0, (sum, d) => sum + _totalCents(d));

  Map<String, Object?> _dispatchJson(Map<String, Object?> d) {
    final customer = customers.firstWhere((c) => c['id'] == d['customerId']);
    final lines = d['lines'] as List<Map<String, Object?>>;
    final total = _totalCents(d);
    final limit = customer['creditLimit'] as String?;
    final before = _balanceCents(customer['id']);
    return {
      ...d,
      'customer': {
        'id': customer['id'],
        'code': customer['code'],
        'name': customer['name'],
        'creditLimit': limit,
      },
      'items': [
        for (final line in lines)
          {
            'id': 'line-${line['productId']}',
            'product': _summary(products.firstWhere((p) => p['id'] == line['productId'])),
            'quantity': line['quantity'],
            'unitPrice': line['unitPrice'],
            'lineTotal': formatCents(_lineCents(line)),
            'quantityOnHand': onHand(line['productId']),
          },
      ],
      'totalQuantity': lines.fold<int>(0, (sum, l) => sum + (l['quantity'] as int)),
      'totalValue': formatCents(total),
      'createdBy': {'id': 'user-1', 'fullName': 'Tendai Moyo'},
      'creditCheck': d['status'] != 'draft'
          ? null
          : {
              'creditLimit': limit,
              'balanceBefore': formatCents(before),
              'dispatchTotal': formatCents(total),
              'balanceAfter': formatCents(before + total),
              'exceedsLimit': limit != null && before + total > parseCents(limit)!,
            },
    };
  }

  http.Response _dispatches(http.Request request) {
    final forbidden = _error(403, 'FORBIDDEN', 'Your role does not allow this action.');
    final segments = request.url.pathSegments; // api, v1, dispatches, [id], [action]
    final id = segments.length > 3 ? segments[3] : null;
    final action = segments.length > 4 ? segments[4] : null;
    final dispatch = id == null ? null : dispatches.firstWhere((d) => d['id'] == id);
    final body = request.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;
    final canCreate = role != 'accounts';
    final canConfirm = role == 'admin' || role == 'storekeeper';

    if (request.method == 'GET' && dispatch == null) {
      final status = request.url.queryParameters['status'];
      final matching = dispatches.reversed
          .where((d) => status == null || d['status'] == status)
          .map(_dispatchJson)
          .toList();
      return _json(200, {'dispatches': matching, 'total': matching.length});
    }
    if (request.method == 'GET') return _json(200, {'dispatch': _dispatchJson(dispatch!)});

    if (action == null) {
      // Create (POST) or replace (PUT) a draft.
      if (!canCreate) return forbidden;
      if (dispatch != null && dispatch['status'] != 'draft') {
        return _error(409, 'DISPATCH_NOT_DRAFT', 'This dispatch can no longer be changed.');
      }
      final target =
          dispatch ??
          <String, Object?>{
            'id': 'dispatch-${dispatches.length + 1}',
            'dispatchNumber': 'D${(dispatches.length + 1).toString().padLeft(6, '0')}',
            'status': 'draft',
            'confirmedOverCreditLimit': false,
            'confirmedBy': null,
            'cancelReason': null,
            'reversalReason': null,
          };
      target.addAll({
        'customerId': body['customerId'],
        'dispatchDate': body['dispatchDate'],
        'notes': body['notes'],
        'lines': [
          for (final item in body['items'] as List)
            {
              'productId': item['productId'],
              'quantity': item['quantity'],
              'unitPrice': item['unitPrice'],
            },
        ],
      });
      if (dispatch == null) dispatches.add(target);
      return _json(dispatch == null ? 201 : 200, {'dispatch': _dispatchJson(target)});
    }

    final d = dispatch!;
    final lines = d['lines'] as List<Map<String, Object?>>;
    switch (action) {
      case 'confirm':
        if (!canConfirm) return forbidden;
        if (d['status'] == 'confirmed') {
          return _json(200, {'dispatch': _dispatchJson(d), 'alreadyConfirmed': true});
        }
        final short = lines.where((l) => (l['quantity'] as int) > onHand(l['productId']));
        if (short.isNotEmpty) {
          final line = short.first;
          final product = products.firstWhere((p) => p['id'] == line['productId']);
          return _error(
            409,
            'INSUFFICIENT_STOCK',
            'Not enough stock for: ${product['name']} — ${product['flavour']} — '
                '${product['size']} (need ${line['quantity']}, have ${onHand(line['productId'])}).',
          );
        }
        final check = _dispatchJson(d)['creditCheck'] as Map<String, Object?>;
        final overLimit = check['exceedsLimit'] == true;
        if (overLimit && body['acknowledgeCreditLimit'] != true) {
          return _error(
            409,
            'CREDIT_LIMIT_EXCEEDED',
            'This dispatch would take the unpaid balance to ${check['balanceAfter']}, '
                'over the credit limit of ${check['creditLimit']}.',
          );
        }
        for (final line in lines) {
          _addMovement(
            line['productId'],
            'dispatch',
            -(line['quantity'] as int),
            d['dispatchDate'] as String,
            reference: d['dispatchNumber'] as String,
          );
        }
        d.addAll({
          'status': 'confirmed',
          'confirmedOverCreditLimit': overLimit,
          'confirmedBy': {'id': 'user-1', 'fullName': 'Tendai Moyo'},
        });
        return _json(200, {'dispatch': _dispatchJson(d), 'alreadyConfirmed': false});

      case 'cancel':
        if (!canCreate) return forbidden;
        d.addAll({'status': 'cancelled', 'cancelReason': body['reason']});
        return _json(200, {'dispatch': _dispatchJson(d)});

      case 'reverse':
        if (role != 'admin') return forbidden;
        if (_billedLineIds.any((lineId) => lineId.startsWith('${d['id']}#'))) {
          return _error(
            409,
            'DISPATCH_INVOICED',
            'This dispatch is on a draft invoice. Void the draft invoice first, then reverse it.',
          );
        }
        for (final line in lines) {
          _addMovement(
            line['productId'],
            'reversal',
            line['quantity'] as int,
            toApiDate(today()),
            reference: d['dispatchNumber'] as String,
            reason: body['reason'] as String?,
          );
        }
        d.addAll({'status': 'reversed', 'reversalReason': body['reason']});
        return _json(200, {'dispatch': _dispatchJson(d)});
    }
    return _error(404, 'NOT_FOUND', 'Not found');
  }

  // ------------------------------------------------------------------ Invoices

  /// Invoices, oldest first.
  final List<Map<String, Object?>> invoices = [];
  int _invoiceNumbers = 0;

  /// The last complete Monday-to-Sunday week, the server's default billing period.
  ({String from, String to}) get lastWeek {
    final monday = today().subtract(Duration(days: today().weekday - 1));
    return (
      from: toApiDate(monday.subtract(const Duration(days: 7))),
      to: toApiDate(monday.subtract(const Duration(days: 1))),
    );
  }

  /// Adds a confirmed dispatch, dated on the Tuesday of [lastWeek] unless [date] is given.
  /// Stock is not touched.
  Map<String, Object?> addConfirmedDispatch(
    String customerCode,
    Map<String, int> quantities, {
    String? date,
  }) => addDraft(customerCode, quantities)
    ..addAll({
      'status': 'confirmed',
      'dispatchDate': date ?? toApiDate(DateTime.parse(lastWeek.from).add(const Duration(days: 1))),
      'confirmedBy': {'id': 'user-1', 'fullName': 'Tendai Moyo'},
    });

  /// Every dispatch line already on a draft or issued invoice (voided drafts hold none).
  Set<String> get _billedLineIds => {
    for (final invoice in invoices)
      for (final line in invoice['lines'] as List<Map<String, Object?>>)
        line['dispatchItemId'] as String,
  };

  List<Map<String, Object?>> _eligibleLines(Object? customerId, String from, String to) {
    final billed = _billedLineIds;
    return [
      for (final d in dispatches)
        if (d['customerId'] == customerId &&
            d['status'] == 'confirmed' &&
            (d['dispatchDate'] as String).compareTo(from) >= 0 &&
            (d['dispatchDate'] as String).compareTo(to) <= 0)
          for (final (index, line) in (d['lines'] as List<Map<String, Object?>>).indexed)
            if (!billed.contains('${d['id']}#$index')) _invoiceLine(d, index, line),
    ];
  }

  Map<String, Object?> _invoiceLine(Map<String, Object?> d, int index, Map<String, Object?> line) {
    final product = products.firstWhere((p) => p['id'] == line['productId']);
    return {
      'dispatchItemId': '${d['id']}#$index',
      'dispatchNumber': d['dispatchNumber'],
      'dispatchDate': d['dispatchDate'],
      'product': {
        'id': product['id'],
        'sku': product['sku'],
        'description': '${product['name']} — ${product['flavour']} — ${product['size']}',
      },
      'quantity': line['quantity'],
      'unitPrice': line['unitPrice'],
      'lineTotal': formatCents(_lineCents(line)),
    };
  }

  String _sumOf(List<Map<String, Object?>> lines) =>
      formatCents(lines.fold(0, (sum, l) => sum + parseCents(l['lineTotal'] as String)!));

  Map<String, Object?> _customerJson(Object? id) {
    final c = customers.firstWhere((c) => c['id'] == id);
    return {
      'id': c['id'],
      'code': c['code'],
      'name': c['name'],
      'phone': c['phone'],
      'address': c['address'],
    };
  }

  Map<String, Object?> _invoiceJson(Map<String, Object?> v) {
    final total = v['total'] as String;
    final paid = _paidCents(v['id']);
    final issued = v['status'] == 'issued';
    final owed = v['status'] == 'voided' ? 0 : parseCents(total)! - paid;
    final paymentStatus = !issued
        ? null
        : owed == 0
        ? 'paid'
        : paid > 0
        ? 'part_paid'
        : 'unpaid';
    return {
      'id': v['id'],
      'invoiceNumber': v['invoiceNumber'],
      'status': v['status'],
      'customer': v['customerSnapshot'] ?? _customerJson(v['customerId']),
      'periodFrom': v['periodFrom'],
      'periodTo': v['periodTo'],
      'issueDate': v['issueDate'],
      'currency': 'USD',
      'lines': v['lines'],
      'subtotal': total,
      'total': total,
      'dueDate': v['dueDate'],
      'amountPaid': formatCents(paid),
      'balanceDue': formatCents(owed),
      'paymentStatus': paymentStatus,
      'overdue': issued && owed > 0 && (v['dueDate'] as String).compareTo(toApiDate(today())) < 0,
      'payments': [
        for (final p in payments)
          if (p['status'] == 'recorded')
            for (final a in p['allocations'] as List<Map<String, Object?>>)
              if (a['invoiceId'] == v['id'])
                {
                  'paymentId': p['id'],
                  'paymentNumber': p['paymentNumber'],
                  'paymentDate': p['paymentDate'],
                  'method': p['method'],
                  'amount': a['amount'],
                },
      ],
      'createdBy': 'Tendai Moyo',
      'issuedBy': v['status'] == 'issued' ? 'Tendai Moyo' : null,
      'voidReason': v['voidReason'],
    };
  }

  Map<String, Object?> _invoiceSummaryJson(Map<String, Object?> v) {
    final json = _invoiceJson(v);
    final customer = json['customer'] as Map<String, Object?>;
    return {
      ...json,
      'customer': {'id': customer['id'], 'code': customer['code'], 'name': customer['name']},
      'lineCount': (v['lines'] as List).length,
    };
  }

  Map<String, Object?>? _createInvoice(Object? customerId, String from, String to) {
    final lines = _eligibleLines(customerId, from, to);
    if (lines.isEmpty) return null;
    final invoice = <String, Object?>{
      'id': 'invoice-${invoices.length + 1}',
      'invoiceNumber': null,
      'status': 'draft',
      'customerId': customerId,
      'periodFrom': from,
      'periodTo': to,
      'issueDate': null,
      'lines': lines,
      'total': _sumOf(lines),
      'voidReason': null,
    };
    invoices.add(invoice);
    return invoice;
  }

  http.Response _invoices(http.Request request) {
    if (role != 'admin' && role != 'accounts') {
      return _error(403, 'FORBIDDEN', 'Your role does not allow this action.');
    }
    final segments = request.url.pathSegments; // api, v1, invoices, [id or word], [action]
    final id = segments.length > 3 ? segments[3] : null;
    final action = segments.length > 4 ? segments[4] : null;
    final query = request.url.queryParameters;
    final body = request.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;
    final input = request.method == 'GET' ? query : body;
    final from = input['from'] as String? ?? lastWeek.from;
    final to = input['to'] as String? ?? (input['from'] as String? ?? lastWeek.to);

    switch ((request.method, id)) {
      case ('GET', null):
        final status = query['status'];
        final payment = query['payment'];
        final search = (query['q'] ?? '').toLowerCase();
        final matching = invoices.reversed
            .where((v) => status == null || v['status'] == status)
            .map(_invoiceSummaryJson)
            .where(
              (v) =>
                  payment == null ||
                  (v['status'] == 'issued' &&
                      v['balanceDue'] != '0.00' &&
                      (payment == 'unpaid' || v['overdue'] == true)),
            )
            .where((v) {
              final name = (v['customer'] as Map<String, Object?>)['name'] as String;
              return search.isEmpty ||
                  '${v['invoiceNumber'] ?? ''}'.toLowerCase().contains(search) ||
                  name.toLowerCase().contains(search);
            })
            .toList();
        return _json(200, {'invoices': matching, 'total': matching.length});
      case ('GET', 'unbilled'):
        final unbilled = <Map<String, Object?>>[];
        for (final c in customers) {
          final lines = _eligibleLines(c['id'], from, to);
          if (lines.isEmpty) continue;
          unbilled.add({
            'customer': {'id': c['id'], 'code': c['code'], 'name': c['name']},
            'dispatchCount': lines.map((l) => l['dispatchNumber']).toSet().length,
            'lineCount': lines.length,
            'subtotal': _sumOf(lines),
          });
        }
        return _json(200, {'from': from, 'to': to, 'customers': unbilled});
      case ('GET', 'preview'):
        final lines = _eligibleLines(query['customerId'], from, to);
        return _json(200, {
          'preview': {
            'customer': _customerJson(query['customerId']),
            'periodFrom': from,
            'periodTo': to,
            'currency': 'USD',
            'lines': lines,
            'subtotal': _sumOf(lines),
          },
        });
      case ('POST', null):
        final invoice = _createInvoice(body['customerId'], from, to);
        if (invoice == null) {
          return _error(
            409,
            'NOTHING_TO_INVOICE',
            'This customer has no confirmed, unbilled dispatches in that period.',
          );
        }
        return _json(201, {'invoice': _invoiceJson(invoice)});
      case ('POST', 'generate'):
        final created = <Map<String, Object?>>[];
        for (final c in customers) {
          final invoice = _createInvoice(c['id'], from, to);
          if (invoice != null) created.add(_invoiceJson(invoice));
        }
        return _json(201, {'from': from, 'to': to, 'invoices': created});
    }

    final invoice = invoices.firstWhere((v) => v['id'] == id);
    switch ((request.method, action)) {
      case ('GET', null):
        return _json(200, {'invoice': _invoiceJson(invoice)});
      case ('GET', 'pdf'):
        return http.Response.bytes(
          utf8.encode('%PDF-1.3 ${invoice['invoiceNumber'] ?? 'draft'}'),
          200,
          headers: {'content-type': 'application/pdf'},
        );
      case ('POST', 'issue'):
        if (invoice['status'] == 'draft') {
          invoice.addAll({
            'status': 'issued',
            'invoiceNumber': 'INV-${(++_invoiceNumbers).toString().padLeft(6, '0')}',
            'issueDate': toApiDate(today()),
            'dueDate': toApiDate(today().add(const Duration(days: 7))),
            'customerSnapshot': _customerJson(invoice['customerId']),
          });
        }
        return _json(200, {'invoice': _invoiceJson(invoice)});
      case ('POST', 'void'):
        if (invoice['status'] == 'issued') {
          return _error(
            409,
            'INVOICE_ISSUED',
            'An issued invoice cannot be voided. Corrections will be made with credit notes.',
          );
        }
        invoice.addAll({
          'status': 'voided',
          'voidReason': body['reason'],
          'lines': <Map<String, Object?>>[],
        });
        return _json(200, {'invoice': _invoiceJson(invoice)});
    }
    return _error(404, 'NOT_FOUND', 'Not found');
  }

  // ------------------------------------------------------------------ Payments and balances

  /// Payments, oldest first. Allocations are stored as {invoiceId, amount}.
  final List<Map<String, Object?>> payments = [];

  /// Adds an issued invoice for a new confirmed dispatch, issued [daysAgo] days ago and due
  /// seven days after that.
  Map<String, Object?> addIssuedInvoice(
    String customerCode,
    Map<String, int> quantities, {
    int daysAgo = 0,
  }) {
    final dispatch = addConfirmedDispatch(customerCode, quantities);
    final lines = [
      for (final (index, line) in (dispatch['lines'] as List<Map<String, Object?>>).indexed)
        _invoiceLine(dispatch, index, line),
    ];
    final issued = today().subtract(Duration(days: daysAgo));
    final invoice = <String, Object?>{
      'id': 'invoice-${invoices.length + 1}',
      'invoiceNumber': 'INV-${(++_invoiceNumbers).toString().padLeft(6, '0')}',
      'status': 'issued',
      'customerId': dispatch['customerId'],
      'periodFrom': lastWeek.from,
      'periodTo': lastWeek.to,
      'issueDate': toApiDate(issued),
      'dueDate': toApiDate(issued.add(const Duration(days: 7))),
      'customerSnapshot': _customerJson(dispatch['customerId']),
      'lines': lines,
      'total': _sumOf(lines),
      'voidReason': null,
    };
    invoices.add(invoice);
    return invoice;
  }

  /// Adds a recorded payment directly, e.g. addPayment('C0001', '5.00', {'invoice-1': '2.00'}).
  Map<String, Object?> addPayment(
    String customerCode,
    String amount, [
    Map<String, String> allocations = const {},
  ]) {
    final payment = <String, Object?>{
      'id': 'payment-${payments.length + 1}',
      'paymentNumber': 'P${(payments.length + 1).toString().padLeft(6, '0')}',
      'status': 'recorded',
      'customerId': customers.firstWhere((c) => c['code'] == customerCode)['id'],
      'paymentDate': toApiDate(today()),
      'amount': amount,
      'method': 'cash',
      'reference': null,
      'notes': null,
      'idempotencyKey': null,
      'allocations': [
        for (final MapEntry(key: invoiceId, value: cents) in allocations.entries)
          <String, Object?>{'invoiceId': invoiceId, 'amount': cents},
      ],
      'voidReason': null,
    };
    payments.add(payment);
    return payment;
  }

  /// What has been paid on an invoice by payments that are not voided.
  int _paidCents(Object? invoiceId) => payments
      .where((p) => p['status'] == 'recorded')
      .expand((p) => p['allocations'] as List<Map<String, Object?>>)
      .where((a) => a['invoiceId'] == invoiceId)
      .fold(0, (sum, a) => sum + parseCents(a['amount'] as String)!);

  int _allocatedCents(Map<String, Object?> payment) => (payment['allocations'] as List)
      .cast<Map<String, Object?>>()
      .fold(0, (sum, a) => sum + parseCents(a['amount'] as String)!);

  Map<String, Object?> _paymentJson(Map<String, Object?> p) {
    final customer = customers.firstWhere((c) => c['id'] == p['customerId']);
    final allocated = _allocatedCents(p);
    return {
      ...p,
      'customer': {'id': customer['id'], 'code': customer['code'], 'name': customer['name']},
      'currency': 'USD',
      'allocations': [
        for (final a in p['allocations'] as List<Map<String, Object?>>)
          {
            'invoiceId': a['invoiceId'],
            'invoiceNumber': invoices.firstWhere((v) => v['id'] == a['invoiceId'])['invoiceNumber'],
            'amount': a['amount'],
          },
      ],
      'allocatedAmount': formatCents(allocated),
      'unallocatedAmount': p['status'] == 'voided'
          ? '0.00'
          : formatCents(parseCents(p['amount'] as String)! - allocated),
      'recordedBy': 'Tendai Moyo',
      'voidedBy': p['status'] == 'voided' ? 'Tendai Moyo' : null,
    };
  }

  /// Checks and adds allocations to a payment, as the server does. Returns an error response.
  http.Response? _allocate(Map<String, Object?> payment, List<dynamic> allocations) {
    var requested = 0;
    for (final item in allocations.cast<Map<String, dynamic>>()) {
      final invoice = invoices.firstWhere((v) => v['id'] == item['invoiceId']);
      final owed = parseCents(invoice['total'] as String)! - _paidCents(invoice['id']);
      final cents = parseCents(item['amount'] as String)!;
      if (invoice['status'] != 'issued' || invoice['customerId'] != payment['customerId']) {
        return _error(409, 'INVOICE_NOT_ISSUED', 'Only issued invoices can be paid.');
      }
      if (cents > owed) {
        return _error(
          409,
          'ALLOCATION_EXCEEDS_BALANCE',
          'Invoice ${invoice['invoiceNumber']} has only USD ${formatCents(owed)} left to pay.',
        );
      }
      requested += cents;
    }
    final available = parseCents(payment['amount'] as String)! - _allocatedCents(payment);
    if (requested > available) {
      return _error(
        409,
        'ALLOCATION_EXCEEDS_PAYMENT',
        'Only USD ${formatCents(available)} of payment ${payment['paymentNumber']} is left to '
            'allocate.',
      );
    }
    (payment['allocations'] as List<Map<String, Object?>>).addAll([
      for (final item in allocations.cast<Map<String, dynamic>>())
        {'invoiceId': item['invoiceId'], 'amount': item['amount']},
    ]);
    return null;
  }

  http.Response _payments(http.Request request) {
    if (role != 'admin' && role != 'accounts') {
      return _error(403, 'FORBIDDEN', 'Your role does not allow this action.');
    }
    final segments = request.url.pathSegments; // api, v1, payments, [id], [action]
    final id = segments.length > 3 ? segments[3] : null;
    final action = segments.length > 4 ? segments[4] : null;
    final body = request.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;

    if (request.method == 'GET' && id == null) {
      final search = (request.url.queryParameters['q'] ?? '').toLowerCase();
      final matching = payments.reversed
          .map(_paymentJson)
          .where(
            (p) =>
                search.isEmpty ||
                '${p['paymentNumber']} ${p['reference'] ?? ''} ${(p['customer'] as Map)['name']}'
                    .toLowerCase()
                    .contains(search),
          )
          .toList();
      return _json(200, {'payments': matching, 'total': matching.length});
    }
    if (request.method == 'POST' && id == null) {
      final key = body['idempotencyKey'];
      final repeat = payments.where((p) => key != null && p['idempotencyKey'] == key);
      if (repeat.isNotEmpty) {
        return _json(200, {'payment': _paymentJson(repeat.first), 'duplicate': true});
      }
      final payment = <String, Object?>{
        'id': 'payment-${payments.length + 1}',
        'paymentNumber': 'P${(payments.length + 1).toString().padLeft(6, '0')}',
        'status': 'recorded',
        'customerId': body['customerId'],
        'paymentDate': body['paymentDate'],
        'amount': body['amount'],
        'method': body['method'],
        'reference': body['reference'],
        'notes': body['notes'],
        'idempotencyKey': key,
        'allocations': <Map<String, Object?>>[],
        'voidReason': null,
      };
      final refused = _allocate(payment, body['allocations'] as List? ?? const []);
      if (refused != null) return refused;
      payments.add(payment);
      return _json(201, {'payment': _paymentJson(payment), 'duplicate': false});
    }

    final payment = payments.firstWhere((p) => p['id'] == id);
    switch ((request.method, action)) {
      case ('GET', null):
        return _json(200, {'payment': _paymentJson(payment)});
      case ('POST', 'allocations'):
        if (payment['status'] == 'voided') {
          return _error(409, 'PAYMENT_VOIDED', 'This payment was voided and cannot be allocated.');
        }
        final refused = _allocate(payment, body['allocations'] as List);
        return refused ?? _json(200, {'payment': _paymentJson(payment)});
      case ('POST', 'void'):
        if (role != 'admin') {
          return _error(403, 'FORBIDDEN', 'Your role does not allow this action.');
        }
        payment.addAll({'status': 'voided', 'voidReason': body['reason']});
        return _json(200, {'payment': _paymentJson(payment)});
    }
    return _error(404, 'NOT_FOUND', 'Not found');
  }

  Map<String, Object?> _balanceOf(Map<String, Object?> customer) {
    final todayText = toApiDate(today());
    final issued = invoices.where(
      (v) => v['customerId'] == customer['id'] && v['status'] == 'issued',
    );
    final billedLines = {
      for (final v in issued)
        for (final line in v['lines'] as List<Map<String, Object?>>) line['dispatchItemId'],
    };
    var notInvoiced = 0;
    for (final d in dispatches) {
      if (d['customerId'] != customer['id'] || d['status'] != 'confirmed') continue;
      for (final (index, line) in (d['lines'] as List<Map<String, Object?>>).indexed) {
        if (!billedLines.contains('${d['id']}#$index')) notInvoiced += _lineCents(line);
      }
    }
    var unpaid = 0;
    var overdue = 0;
    String? oldest;
    for (final v in issued) {
      final owed = parseCents(v['total'] as String)! - _paidCents(v['id']);
      unpaid += owed;
      final due = v['dueDate'] as String;
      if (owed > 0 && due.compareTo(todayText) < 0) {
        overdue += owed;
        if (oldest == null || due.compareTo(oldest) < 0) oldest = due;
      }
    }
    final credit = payments
        .where((p) => p['customerId'] == customer['id'] && p['status'] == 'recorded')
        .fold(0, (sum, p) => sum + parseCents(p['amount'] as String)! - _allocatedCents(p));
    final balance = notInvoiced + unpaid - credit;
    return {
      'customer': {
        'id': customer['id'],
        'code': customer['code'],
        'name': customer['name'],
        'creditLimit': customer['creditLimit'],
      },
      'notYetInvoiced': formatCents(notInvoiced),
      'invoicedUnpaid': formatCents(unpaid),
      'overdue': formatCents(overdue),
      'unallocatedCredit': formatCents(credit),
      'balance': balance < 0 ? '-${formatCents(-balance)}' : formatCents(balance),
      'oldestOverdueDueDate': oldest,
      'active':
          dispatches.any((d) => d['customerId'] == customer['id'] && d['status'] == 'confirmed') ||
          payments.any((p) => p['customerId'] == customer['id']),
    };
  }

  http.Response _balances(http.Request request) {
    if (role != 'admin' && role != 'accounts') {
      return _error(403, 'FORBIDDEN', 'Your role does not allow this action.');
    }
    final segments = request.url.pathSegments; // api, v1, balances, [customerId]
    if (segments.length == 3) {
      final balances = [
        for (final c in customers)
          if (_balanceOf(c) case final b when b['active'] == true) b..remove('active'),
      ];
      int cents(Map<String, Object?> b, String key) {
        final text = b[key] as String;
        return text.startsWith('-') ? -parseCents(text.substring(1))! : parseCents(text)!;
      }

      balances.sort((a, b) => cents(b, 'overdue').compareTo(cents(a, 'overdue')));
      String total(String key) {
        final sum = balances.fold(0, (s, b) => s + cents(b, key));
        return sum < 0 ? '-${formatCents(-sum)}' : formatCents(sum);
      }

      return _json(200, {
        'currency': 'USD',
        'customers': balances,
        'totals': {
          for (final key in [
            'notYetInvoiced',
            'invoicedUnpaid',
            'overdue',
            'unallocatedCredit',
            'balance',
          ])
            key: total(key),
        },
      });
    }

    final customer = customers.firstWhere((c) => c['id'] == segments[3]);
    final query = request.url.queryParameters;
    final to = query['to'] ?? toApiDate(today());
    final from = query['from'] ?? toApiDate(DateTime.parse(to).subtract(const Duration(days: 89)));
    final summary = _balanceOf(customer)..remove('active');
    final issued = invoices
        .where((v) => v['customerId'] == customer['id'] && v['status'] == 'issued')
        .toList();
    final recorded = payments
        .where((p) => p['customerId'] == customer['id'] && p['status'] == 'recorded')
        .toList();

    var running = 0;
    for (final v in issued) {
      if ((v['issueDate'] as String).compareTo(from) < 0) {
        running += parseCents(v['total'] as String)!;
      }
    }
    for (final p in recorded) {
      if ((p['paymentDate'] as String).compareTo(from) < 0) {
        running -= parseCents(p['amount'] as String)!;
      }
    }
    String signed(int cents) => cents < 0 ? '-${formatCents(-cents)}' : formatCents(cents);
    final opening = signed(running);
    bool inPeriod(String date) => date.compareTo(from) >= 0 && date.compareTo(to) <= 0;
    final events = [
      for (final v in issued)
        if (inPeriod(v['issueDate'] as String))
          {
            'date': v['issueDate'],
            'type': 'invoice',
            'id': v['id'],
            'reference': v['invoiceNumber'],
            'periodFrom': v['periodFrom'],
            'periodTo': v['periodTo'],
            'method': null,
            'paymentReference': null,
            'debit': v['total'],
            'credit': null,
          },
      for (final p in recorded)
        if (inPeriod(p['paymentDate'] as String))
          {
            'date': p['paymentDate'],
            'type': 'payment',
            'id': p['id'],
            'reference': p['paymentNumber'],
            'periodFrom': null,
            'periodTo': null,
            'method': p['method'],
            'paymentReference': p['reference'],
            'debit': null,
            'credit': p['amount'],
          },
    ]..sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));
    final entries = [
      for (final e in events)
        {
          ...e,
          'balance': signed(
            running +=
                parseCents((e['debit'] ?? '0.00') as String)! -
                parseCents((e['credit'] ?? '0.00') as String)!,
          ),
        },
    ];

    final todayDate = today();
    return _json(200, {
      'account': {
        'customer': {
          'id': customer['id'],
          'code': customer['code'],
          'name': customer['name'],
          'phone': customer['phone'],
          'address': customer['address'],
          'creditLimit': customer['creditLimit'],
        },
        'currency': 'USD',
        'summary': summary..remove('customer'),
        'openInvoices': [
          for (final v
              in issued..sort((a, b) => (a['dueDate'] as String).compareTo(b['dueDate'] as String)))
            if (parseCents(v['total'] as String)! - _paidCents(v['id']) case final owed
                when owed > 0)
              {
                'id': v['id'],
                'invoiceNumber': v['invoiceNumber'],
                'issueDate': v['issueDate'],
                'dueDate': v['dueDate'],
                'total': v['total'],
                'amountPaid': formatCents(_paidCents(v['id'])),
                'balanceDue': formatCents(owed),
                'overdue': DateTime.parse(v['dueDate'] as String).isBefore(todayDate),
                'daysOverdue': DateTime.parse(v['dueDate'] as String).isBefore(todayDate)
                    ? todayDate.difference(DateTime.parse(v['dueDate'] as String)).inDays
                    : 0,
              },
        ],
        'creditPayments': [
          for (final p in recorded)
            if (parseCents(p['amount'] as String)! - _allocatedCents(p) case final left
                when left > 0)
              {
                'id': p['id'],
                'paymentNumber': p['paymentNumber'],
                'paymentDate': p['paymentDate'],
                'amount': p['amount'],
                'unallocatedAmount': formatCents(left),
              },
        ],
        'statement': {
          'from': from,
          'to': to,
          'openingBalance': opening,
          'entries': entries,
          'closingBalance': signed(running),
        },
      },
    });
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
  TestApp(this.backend, this.api, this.tokenStore, this.auth, this.sharedPdfs);

  final FakeBackend backend;
  final ApiClient api;
  final MemoryTokenStore tokenStore;
  final AuthController auth;

  /// PDFs handed to the device to share or download, as (file name, contents).
  final List<(String, String)> sharedPdfs;
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
  final sharedPdfs = <(String, String)>[];
  final services = AppServices(
    checkBackendHealth: () async => apiHealthy,
    products: ProductsRepository(api),
    stock: StockRepository(api),
    customers: CustomersRepository(api),
    dispatches: DispatchesRepository(api),
    invoices: InvoicesRepository(api),
    payments: PaymentsRepository(api),
    sharePdf: (bytes, filename) async => sharedPdfs.add((filename, utf8.decode(bytes))),
  );

  await tester.pumpWidget(SnackifyApp(auth: auth, services: services));
  auth.restore();
  await tester.pumpAndSettle();
  return TestApp(server, api, store, auth, sharedPdfs);
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
