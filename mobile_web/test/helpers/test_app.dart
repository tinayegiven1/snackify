import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:snackify/app.dart';
import 'package:snackify/core/app_services.dart';
import 'package:snackify/core/files/document_picker.dart';
import 'package:snackify/core/formatting/dates.dart';
import 'package:snackify/core/formatting/money.dart';
import 'package:snackify/core/network/api_client.dart';
import 'package:snackify/features/auth/data/auth_repository.dart';
import 'package:snackify/features/auth/data/token_store.dart';
import 'package:snackify/features/auth/presentation/auth_controller.dart';
import 'package:snackify/features/audit/data/audit_repository.dart';
import 'package:snackify/features/catalogue/data/catalogue_repository.dart';
import 'package:snackify/features/customers/data/customers_repository.dart';
import 'package:snackify/features/dispatches/data/dispatches_repository.dart';
import 'package:snackify/features/forecasts/data/forecasts_repository.dart';
import 'package:snackify/features/invoices/data/invoices_repository.dart';
import 'package:snackify/features/orders/data/orders_repository.dart';
import 'package:snackify/features/organisations/data/organisations_repository.dart';
import 'package:snackify/features/payments/data/payments_repository.dart';
import 'package:snackify/features/products/data/products_repository.dart';
import 'package:snackify/features/receipts/data/receipts_repository.dart';
import 'package:snackify/features/reports/data/reports_repository.dart';
import 'package:snackify/features/staff/data/staff_repository.dart';
import 'package:snackify/features/staff/domain/staff_member.dart' show checkNewPin;
import 'package:snackify/features/stock/data/stock_repository.dart';

const phoneSize = Size(390, 844);
const desktopSize = Size(1280, 800);

const testUsername = 'tendai';

/// The test user's PIN (their own, not the starting PIN 1234).
const testPin = '4826';

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

  /// Staff accounts as the server lists them. The signed-in user is always the first.
  late final List<Map<String, Object?>> staff = [
    {
      for (final key in ['id', 'username', 'fullName', 'organisation', 'roles']) key: user[key],
      'isActive': true,
      'lastSignInAt': '2026-10-13T06:30:00Z',
    },
  ];

  /// The Head Office and subsidiaries, as the server lists them.
  final List<Map<String, Object?>> organisations = [
    {...headOffice, 'isActive': true, 'customerId': null},
    {...subsidiaryOne, 'isActive': true, 'contactPhone': '+263 00 100 0001', 'customerId': null},
  ];

  /// Audit log entries, newest first, as the server returns them.
  final List<Map<String, Object?>> auditEntries = [];

  /// The signed-in user's current PIN, and whether it is still the starting PIN.
  String pin = testPin;
  bool mustChangePin = false;

  /// PINs chosen through the API: (account id, new PIN).
  final List<(String, String)> pinsSet = [];

  /// Accounts an admin put back on the starting PIN.
  final List<String> pinResets = [];

  /// Adds a staff account directly, as if it already existed on the server. [role] is an old
  /// role name or a role code.
  Map<String, Object?> addStaff(
    String username,
    String fullName,
    String role, {
    Map<String, Object?> organisation = headOffice,
    bool isActive = true,
    String? lastSignInAt,
  }) {
    final member = <String, Object?>{
      'id': 'user-${staff.length + 1}',
      'username': username,
      'fullName': fullName,
      'organisation': organisation,
      'roles': _rolesJson(legacyRoles[role] ?? [role]),
      'isActive': isActive,
      'lastSignInAt': lastSignInAt,
    };
    staff.add(member);
    return member;
  }

  /// Every request received, as "METHOD /path" (plus "?query" when there is one).
  final List<String> requests = [];
  int _issued = 0;

  /// What each role may do: the same rows as the real database (migrations 20261020090000000,
  /// 20261021090000000 and 20261021110000000).
  static const rolePermissions = <String, List<String>>{
    'system_admin': [
      'order.view',
      'catalogue.manage',
      'supplier.manage',
      'receipt.no_document',
      'receipt.reverse',
      'organisation.manage',
      'user.manage',
      'role.manage',
      'audit.view',
      'product.manage',
      'stock.view',
      'stock.opening_balance',
      'stock.adjust',
      'customer.view',
      'customer.edit_details',
      'customer.change_active',
      'dispatch.view',
      'dispatch.reverse',
      'payment.void',
      'report.dashboard',
    ],
    'hq_warehouse_officer': [
      'supplier.manage',
      'label.print',
      'stock.view',
      'stock.receive',
      'customer.view',
      'dispatch.view',
      'dispatch.draft',
      'dispatch.confirm',
      'report.dashboard',
      'report.stock',
      'forecast.use',
    ],
    'hq_finance_officer': [
      'order.view',
      'order.price',
      'order.approve',
      'price.exception.approve',
      'receipt.verify',
      'stock.view',
      'customer.view',
      'customer.edit_credit_limit',
      'dispatch.view',
      'invoice.manage',
      'payment.manage',
      'report.dashboard',
      'report.financial',
      'report.stock',
      'forecast.use',
    ],
    'hq_sales_officer': [
      'order.view',
      'stock.view',
      'customer.view',
      'customer.edit_details',
      'dispatch.view',
      'dispatch.draft',
      'report.dashboard',
    ],
    'subsidiary_manager': ['stock.view', 'order.view', 'order.create'],
    'subsidiary_storekeeper': ['stock.view'],
  };

  static const roleNames = <String, String>{
    'system_admin': 'System Administrator',
    'hq_warehouse_officer': 'HQ Warehouse Officer',
    'hq_finance_officer': 'HQ Finance Officer',
    'hq_sales_officer': 'HQ Sales Officer',
    'subsidiary_manager': 'Subsidiary Manager',
    'subsidiary_storekeeper': 'Subsidiary Storekeeper',
  };

  /// The old single roles most tests use, and the roles they became (decision D2).
  static const legacyRoles = <String, List<String>>{
    'admin': ['hq_finance_officer', 'hq_sales_officer', 'hq_warehouse_officer', 'system_admin'],
    'storekeeper': ['hq_warehouse_officer'],
    'accounts': ['hq_finance_officer'],
    'salesperson': ['hq_sales_officer'],
  };

  /// The signed-in user's roles: [role] is an old role name or one role code.
  List<String> get roleCodes => legacyRoles[role] ?? [role];

  Set<String> get permissions => {for (final code in roleCodes) ...?rolePermissions[code]};

  bool can(String permission) => permissions.contains(permission);

  static const headOffice = {'id': 'org-hq', 'code': 'HQ', 'name': 'Head Office', 'type': 'HQ'};
  static const subsidiaryOne = {
    'id': 'org-sub-1',
    'code': 'SUB-01',
    'name': 'Mbare Branch',
    'type': 'SUBSIDIARY',
  };

  Map<String, Object?> get organisation =>
      role.startsWith('subsidiary') ? subsidiaryOne : headOffice;

  static List<Map<String, Object?>> _rolesJson(List<String> codes) => [
    for (final code in [...codes]..sort()) {'code': code, 'name': roleNames[code]},
  ];

  Map<String, Object?> get user => {
    'id': '7f9c2b1e-0000-4000-8000-000000000001',
    'username': testUsername,
    'fullName': 'Tendai Moyo',
    'organisation': organisation,
    'roles': _rolesJson(roleCodes),
    'permissions': permissions.toList()..sort(),
    'mustChangePin': mustChangePin,
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
      'description': null,
      'category': null,
      'baseUnit': packUnit,
      'conversions': <Map<String, Object?>>[],
    });
  }

  static const packUnit = {'id': 'unit-pack', 'code': 'pack', 'name': 'Pack'};

  /// Suppliers, categories, warehouses and units, as the catalogue API lists them.
  final Map<String, List<Map<String, Object?>>> catalogue = {
    'suppliers': [],
    'categories': [],
    'warehouses': [
      {
        'id': 'warehouse-main',
        'code': 'HQ-MAIN',
        'name': 'Head Office main warehouse',
        'address': null,
        'isActive': true,
        'isDefault': true,
      },
    ],
    'units': [
      {'id': 'unit-carton', 'code': 'carton', 'name': 'Carton', 'isActive': true},
      {'id': 'unit-case', 'code': 'case', 'name': 'Case', 'isActive': true},
      {...packUnit, 'isActive': true},
    ],
  };

  /// Adds a supplier directly, as if it already existed on the server.
  void addSupplier(String code, String name) => catalogue['suppliers']!.add({
    'id': 'supplier-${catalogue['suppliers']!.length + 1}',
    'code': code,
    'name': name,
    'contactName': null,
    'phone': null,
    'email': null,
    'address': null,
    'isActive': true,
  });

  /// Says that one [unitCode] of the product with [sku] holds [baseQuantity] packs.
  void addConversion(String sku, String unitCode, int baseQuantity) {
    final product = products.firstWhere((p) => p['sku'] == sku);
    final unit = catalogue['units']!.firstWhere((u) => u['code'] == unitCode);
    (product['conversions'] as List<Map<String, Object?>>).add({
      'unit': {
        for (final key in ['id', 'code', 'name']) key: unit[key],
      },
      'baseQuantity': baseQuantity,
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

  int onHand(Object? productId, [String owner = 'org-hq']) => movements
      .where((m) => m['productId'] == productId && (m['owner'] ?? 'org-hq') == owner)
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
    if (route == 'POST /api/v1/auth/change-pin') return _changePin(request);
    // Like the real server: an account on the starting PIN may only choose its own.
    if (mustChangePin && route != 'GET /api/v1/auth/me' && route != 'POST /api/v1/auth/logout') {
      return _error(403, 'PIN_CHANGE_REQUIRED', 'Choose your own PIN first.');
    }
    if (path.startsWith('/api/v1/users')) return _users(request);
    if (path.startsWith('/api/v1/organisations')) return _organisations(request);
    if (route == 'GET /api/v1/roles') return _roles();
    if (route == 'GET /api/v1/audit-logs') return _audit(request);
    if (route == 'GET /api/v1/products') return _listProducts(request.url.queryParameters);
    if (RegExp(r'^/api/v1/(suppliers|categories|warehouses|units)').hasMatch(path)) {
      return _catalogue(request);
    }
    if (path.startsWith('/api/v1/receipts')) return _receipts(request);
    if (path.startsWith('/api/v1/orders')) return _orders(request);
    if (request.method == 'GET' && RegExp(r'^/api/v1/products/[^/]+$').hasMatch(path)) {
      final product = products.where((p) => path.endsWith('/${p['id']}')).firstOrNull;
      return product == null
          ? _error(404, 'PRODUCT_NOT_FOUND', 'No product has that id.')
          : _json(200, {'product': product});
    }
    if (request.method == 'PUT' && path.endsWith('/conversions')) {
      if (!can('product.manage')) {
        return _error(403, 'FORBIDDEN', 'Your role does not allow this action.');
      }
      final product = products.firstWhere((p) => path.contains('/${p['id']}/'));
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      product['conversions'] = [
        for (final conversion in body['conversions'] as List)
          {
            'unit': {
              for (final key in ['id', 'code', 'name'])
                key: catalogue['units']!.firstWhere(
                  (u) => u['id'] == (conversion as Map)['unitId'],
                )[key],
            },
            'baseQuantity': (conversion as Map)['baseQuantity'],
          },
      ];
      return _json(200, {'product': product});
    }
    if (path.startsWith('/api/v1/products/barcode/') ||
        path.endsWith('/barcode') ||
        path.endsWith('/labels')) {
      return _barcodes(request);
    }
    if (path.startsWith('/api/v1/products') && request.method != 'GET') {
      if (!can('product.manage')) {
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
    if (path.startsWith('/api/v1/reports')) return _reports(request);
    if (path.startsWith('/api/v1/forecasts')) return _forecasts(request);
    return _error(404, 'NOT_FOUND', 'Not found');
  }

  /// Like the real server: proving the current PIN is required, and the new one must follow
  /// the PIN rules and differ from it.
  http.Response _changePin(http.Request request) {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final current = body['currentPin'] as String;
    final next = body['newPin'] as String;
    if (current != pin) return _fieldError('currentPin', 'Incorrect PIN');
    if (checkNewPin(next) case final problem?) return _fieldError('newPin', problem);
    if (next == current) return _fieldError('newPin', 'Must be different from the current PIN');
    pin = next;
    mustChangePin = false;
    pinsSet.add((user['id'] as String, next));
    return _json(200, {'user': user});
  }

  http.Response get _forbidden => _error(403, 'FORBIDDEN', 'Your role does not allow this action.');

  Map<String, Object?>? _organisationById(Object? id) =>
      organisations.where((o) => o['id'] == id).firstOrNull;

  /// Roles must suit the organisation: subsidiary roles for a subsidiary's staff only.
  http.Response? _checkRoles(List<String> codes, Map<String, Object?> organisation) {
    final forSubsidiary = organisation['type'] == 'SUBSIDIARY';
    final wrong = codes.where((code) => code.startsWith('subsidiary') != forSubsidiary);
    if (wrong.isEmpty) return null;
    final whose = forSubsidiary ? 'Head Office staff' : "a subsidiary's staff";
    return _fieldError('roleCodes', '${wrong.join(', ')} is for $whose');
  }

  static Map<String, Object?> _organisationRef(Map<String, Object?> organisation) => {
    for (final key in ['id', 'code', 'name', 'type']) key: organisation[key],
  };

  /// Staff accounts (user.manage). Admins cannot change their own roles or organisation, or
  /// deactivate themselves, nor reset their own PIN here. Roles must suit the organisation.
  http.Response _users(http.Request request) {
    if (!can('user.manage')) return _forbidden;
    final segments = request.url.pathSegments; // api, v1, users, [id], [reset-pin]
    final body = request.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;

    if (segments.length == 3) {
      if (request.method == 'GET') return _json(200, {'users': staff});
      final username = body['username'] as String;
      if (staff.any((member) => member['username'] == username)) {
        return _error(409, 'USERNAME_TAKEN', 'The username "$username" is already taken.');
      }
      final organisation = _organisationById(body['organisationId']);
      if (organisation == null) return _fieldError('organisationId', 'No organisation has that id');
      final codes = [for (final code in body['roleCodes'] as List) code as String];
      if (_checkRoles(codes, organisation) case final problem?) return problem;
      final added = addStaff(
        username,
        body['fullName'] as String,
        codes.first,
        organisation: _organisationRef(organisation),
      )..['roles'] = _rolesJson(codes);
      return _json(201, {'user': added});
    }

    final member = staff.where((m) => m['id'] == segments[3]).firstOrNull;
    if (member == null) return _error(404, 'USER_NOT_FOUND', 'No staff account has that id.');
    final isSelf = member['id'] == user['id'];

    if (segments.length == 5 && segments[4] == 'reset-pin') {
      if (isSelf) return _error(409, 'USE_CHANGE_PIN', 'Use change-pin for your own account.');
      pinResets.add(member['id'] as String);
      return _json(200, {'pin': '1234', 'mustChangePin': true});
    }

    final currentCodes = [
      for (final role in member['roles'] as List) (role as Map)['code'] as String,
    ]..sort();
    final newCodes = body.containsKey('roleCodes')
        ? ([for (final code in body['roleCodes'] as List) code as String]..sort())
        : currentCodes;
    final currentOrganisation = member['organisation'] as Map<String, Object?>;
    final changesOwnAccess =
        newCodes.join() != currentCodes.join() ||
        (body.containsKey('organisationId') &&
            body['organisationId'] != currentOrganisation['id']) ||
        body['isActive'] == false;
    if (isSelf && changesOwnAccess) {
      return _error(
        409,
        'CANNOT_CHANGE_OWN_ACCESS',
        'You cannot change your own roles or organisation, or deactivate your own account. '
            'Ask another admin.',
      );
    }
    final organisation = _organisationById(body['organisationId'] ?? currentOrganisation['id']);
    if (organisation == null) return _fieldError('organisationId', 'No organisation has that id');
    if (_checkRoles(newCodes, organisation) case final problem?) return problem;
    member['roles'] = _rolesJson(newCodes);
    member['organisation'] = _organisationRef(organisation);
    for (final key in ['fullName', 'isActive']) {
      if (body.containsKey(key)) member[key] = body[key];
    }
    return _json(200, {'user': member});
  }

  http.Response _roles() {
    if (!can('user.manage') && !can('role.manage')) return _forbidden;
    return _json(200, {
      'roles': [
        for (final code in rolePermissions.keys)
          {
            'code': code,
            'name': roleNames[code],
            'description': 'What a ${roleNames[code]} does.',
            'organisationType': code.startsWith('subsidiary') ? 'SUBSIDIARY' : 'HQ',
            'permissions': rolePermissions[code],
          },
      ],
      'permissions': <Object>[],
    });
  }

  http.Response _audit(http.Request request) {
    if (!can('audit.view')) return _forbidden;
    final query = request.url.queryParameters;
    final action = query['action'] ?? '';
    final matching = [
      for (final entry in auditEntries)
        if (action.isEmpty || (entry['action'] as String).startsWith('$action.')) entry,
    ];
    final offset = int.parse(query['offset'] ?? '0');
    final limit = int.parse(query['limit'] ?? '50');
    return _json(200, {
      'entries': matching.skip(offset).take(limit).toList(),
      'total': matching.length,
    });
  }

  /// Organisations: everyone sees those they may access (Head Office staff all, a subsidiary's
  /// staff their own); adding and changing needs organisation.manage.
  http.Response _organisations(http.Request request) {
    final segments = request.url.pathSegments; // api, v1, organisations, [id]
    final own = organisation;
    final visible = [
      for (final candidate in organisations)
        if (own['type'] == 'HQ' || candidate['id'] == own['id']) candidate,
    ];
    if (request.method == 'GET') {
      final includeInactive = request.url.queryParameters['includeInactive'] == 'true';
      return _json(200, {
        'organisations': [
          for (final candidate in visible)
            if (includeInactive || candidate['isActive'] == true) candidate,
        ],
      });
    }
    if (!can('organisation.manage')) return _forbidden;
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (segments.length == 3) {
      final code = (body['code'] as String).toUpperCase();
      if (organisations.any((o) => o['code'] == code)) {
        return _json(409, {
          'error': {
            'code': 'ORGANISATION_CODE_TAKEN',
            'message': 'The code "$code" is already used.',
            'details': [
              {'field': 'code', 'message': 'Already used by another organisation'},
            ],
          },
        });
      }
      final id = 'org-${organisations.length + 1}';
      String customerId;
      if (body['existingCustomerId'] case final String existing) {
        customerId = existing;
        customers.firstWhere((c) => c['id'] == existing)['organisationId'] = id;
      } else {
        addCustomer(code, body['name'] as String, phone: body['contactPhone'] as String?);
        customers.last['organisationId'] = id;
        customerId = customers.last['id'] as String;
      }
      final created = <String, Object?>{
        ...body,
        'id': id,
        'code': code,
        'type': 'SUBSIDIARY',
        'isActive': true,
        'customerId': customerId,
      }..remove('existingCustomerId');
      organisations.add(created);
      return _json(201, {'organisation': created});
    }
    final target = visible.where((o) => o['id'] == segments[3]).firstOrNull;
    if (target == null) {
      return _error(404, 'ORGANISATION_NOT_FOUND', 'No organisation has that id.');
    }
    if (target['type'] == 'HQ' && body['isActive'] == false) {
      return _error(409, 'HEAD_OFFICE_ALWAYS_ACTIVE', 'The Head Office cannot be deactivated');
    }
    target.addAll(body);
    return _json(200, {'organisation': target});
  }

  http.Response _fieldError(String field, String message) => _json(400, {
    'error': {
      'code': 'VALIDATION_ERROR',
      'message': 'Some fields are missing or invalid.',
      'details': [
        {'field': field, 'message': message},
      ],
    },
  });

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
        final owner = query['organisationId'] ?? organisation['id'] as String;
        final balances = [
          for (final p in products.where((p) => p['isActive'] == true))
            {
              'product': {..._summary(p), 'isActive': true},
              'quantityOnHand': onHand(p['id'], owner),
              'reorderLevel': p['reorderLevel'],
              'isLowStock':
                  p['reorderLevel'] != null && onHand(p['id'], owner) <= (p['reorderLevel'] as int),
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
        if (!can('stock.receive') && !can('stock.opening_balance')) return forbidden;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final product = products.firstWhere((p) => p['id'] == body['productId']);
        // Since StockFlow Stage 4 deliveries need a goods-received note.
        if (body['isOpeningBalance'] != true) {
          return _error(
            409,
            'USE_GOODS_RECEIVED_NOTE',
            'Record deliveries with a goods-received note.',
          );
        }
        {
          if (!can('stock.opening_balance')) return forbidden;
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
        if (!can('stock.adjust')) return forbidden;
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

  // ------------------------------------------------------------------ Catalogue

  static const _cataloguePermissions = {
    'suppliers': 'supplier.manage',
    'categories': 'catalogue.manage',
    'warehouses': 'catalogue.manage',
    'units': 'catalogue.manage',
  };

  http.Response _catalogue(http.Request request) {
    final segments = request.url.pathSegments;
    final kind = segments[2];
    final items = catalogue[kind]!;
    if (request.method == 'GET') {
      final all = request.url.queryParameters['includeInactive'] == 'true';
      final listed = items.where((item) => all || item['isActive'] == true).toList()
        ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
      return _json(200, {'items': listed});
    }
    if (!can(_cataloguePermissions[kind]!)) {
      return _error(403, 'FORBIDDEN', 'Your role does not allow this action.');
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (body['code'] case final String code) {
      body['code'] = kind == 'units' ? code.toLowerCase() : code.toUpperCase();
    }
    final current = segments.length > 3
        ? items.firstWhere((item) => item['id'] == segments[3])
        : null;
    final duplicate = items.any(
      (item) =>
          item != current &&
          ((body['code'] != null && item['code'] == body['code']) ||
              (kind == 'categories' &&
                  (item['name'] as String).toLowerCase() ==
                      (body['name'] as String?)?.toLowerCase())),
    );
    if (duplicate) {
      final field = kind == 'categories' ? 'name' : 'code';
      return _json(409, {
        'error': {
          'code': 'ALREADY_EXISTS',
          'message': 'Another entry already uses that.',
          'details': [
            {
              'field': field,
              'message':
                  'Already used by another ${kind == 'categories' ? 'category' : kind.substring(0, kind.length - 1)}',
            },
          ],
        },
      });
    }
    if (current == null) {
      final item = <String, Object?>{
        'id': '${kind.substring(0, kind.length - 1)}-${items.length + 1}',
        ...body,
        'isActive': true,
      };
      items.add(item);
      return _json(201, {'item': item});
    }
    if (current['isDefault'] == true && body['isActive'] == false) {
      return _error(409, 'DEFAULT_WAREHOUSE_ACTIVE', 'The default warehouse stays active.');
    }
    current.addAll(body);
    return _json(200, {'item': current});
  }

  // ------------------------------------------------------------------ Goods received

  /// Goods-received notes as the server stores them, oldest first. Lines keep productId and
  /// unitId; documents keep their bytes.
  final List<Map<String, Object?>> grns = [];

  /// When false, stock waits for verification (RECEIPT_STOCK_AVAILABLE_BEFORE_VERIFICATION).
  bool stockBeforeVerification = true;

  static const _person = {'id': '7f9c2b1e-0000-4000-8000-000000000001', 'fullName': 'Tendai Moyo'};

  Map<String, Object?> _ref(Map<String, Object?> item) => {
    for (final key in ['id', 'code', 'name']) key: item[key],
  };

  String _lineTotal(int quantity, String unitCost) {
    // Exact enough for test amounts: hundredths of a cent, then rounded half up to cents.
    final parts = unitCost.split('.');
    final tenThousandths =
        int.parse(parts[0]) * 10000 +
        int.parse((parts.length > 1 ? parts[1] : '').padRight(4, '0'));
    final cents = (quantity * tenThousandths + 50) ~/ 100;
    return formatCents(cents);
  }

  Map<String, Object?> _grnJson(Map<String, Object?> grn) {
    final lines = grn['lines'] as List<Map<String, Object?>>;
    final documents = grn['documents'] as List<Map<String, Object?>>;
    final totalCents = lines.fold<int>(0, (sum, l) => sum + parseCents(l['lineTotal'] as String)!);
    final total = formatCents(totalCents);
    final status = grn['status'] as String;
    return {
      for (final MapEntry(:key, :value) in grn.entries)
        if (key != 'documents') key: value,
      'owner': _ref(organisations.firstWhere((o) => o['id'] == grn['ownerId'])),
      'warehouse': _ref(catalogue['warehouses']!.firstWhere((w) => w['id'] == grn['warehouseId'])),
      'supplier': grn['supplierId'] == null
          ? null
          : _ref(catalogue['suppliers']!.firstWhere((x) => x['id'] == grn['supplierId'])),
      'currency': 'USD',
      'total': total,
      'lineCount': lines.length,
      'attachmentCount': documents.length,
      'stockAdded': grn['postedAt'] != null && status != 'REJECTED' && status != 'REVERSED',
      'flags': {
        'discrepancies': lines.where((l) => l['discrepancyReason'] != null).length,
        'documentTotalMismatch': documents.any(
          (d) =>
              d['verificationStatus'] != 'REJECTED' &&
              d['documentTotal'] != null &&
              parseCents(d['documentTotal'] as String) != totalCents,
        ),
        'documentsPending': documents.where((d) => d['verificationStatus'] == 'PENDING').length,
      },
      'receivedBy': _person,
      'lines': [
        for (final (index, line) in lines.indexed)
          {
            ...line,
            'id': '${grn['id']}-line-${index + 1}',
            'lineNumber': index + 1,
            'product': () {
              final p = products.firstWhere((p) => p['id'] == line['productId']);
              return {
                'id': p['id'],
                'sku': p['sku'],
                'description': '${p['name']} — ${p['flavour']} — ${p['size']}',
              };
            }(),
            'unit': _ref(catalogue['units']!.firstWhere((u) => u['id'] == line['unitId'])),
          },
      ],
      'attachments': [
        for (final d in documents) {...d}..remove('bytes'),
      ],
    };
  }

  /// The receipt's stock goes in (or, with [sign] -1, comes back out) for its owner.
  void _moveGrnStock(Map<String, Object?> grn, int sign, String type) {
    for (final line in grn['lines'] as List<Map<String, Object?>>) {
      final quantity = line['baseQuantityReceived'] as int;
      if (quantity == 0) continue;
      _addMovement(
        line['productId'],
        type,
        sign * quantity,
        toApiDate(today()),
        reference: grn['grnNumber'] as String,
      );
      movements.last['owner'] = grn['ownerId'];
    }
  }

  http.Response _receipts(http.Request request) {
    final forbidden = _error(403, 'FORBIDDEN', 'Your role does not allow this action.');
    final notFound = _error(404, 'RECEIPT_NOT_FOUND', 'No goods-received note has that id.');
    final segments = request.url.pathSegments; // api, v1, receipts, id?, action?, ...
    final visible = grns.where(
      (g) => organisation['type'] == 'HQ' || g['ownerId'] == organisation['id'],
    );
    Map<String, Object?>? grn;
    if (segments.length > 3) {
      grn = visible.where((g) => g['id'] == segments[3]).firstOrNull;
      if (grn == null) return notFound;
    }
    final action = segments.length > 4 ? segments[4] : null;
    final route = '${request.method} ${action ?? (grn == null ? '' : ':id')}';
    String wrongStatus(String what) =>
        'This goods-received note is ${(grn!['status'] as String).toLowerCase().replaceAll('_', ' ')}, so it cannot be $what.';

    switch (route) {
      case 'GET ':
        final status = request.url.queryParameters['status'];
        final listed = visible
            .where((g) => status == null || g['status'] == status)
            .toList()
            .reversed
            .map(_grnJson)
            .toList();
        return _json(200, {'receipts': listed, 'total': listed.length});
      case 'GET :id':
        return _json(200, {'receipt': _grnJson(grn!)});
      case 'GET pdf':
        return http.Response.bytes(
          utf8.encode('%PDF-1.4 goods received note ${grn!['grnNumber']}'),
          200,
          headers: {'content-type': 'application/pdf'},
        );
      case 'GET attachments':
        final document = (grn!['documents'] as List<Map<String, Object?>>).firstWhere(
          (d) => d['id'] == segments[5],
        );
        return http.Response.bytes(document['bytes'] as List<int>, 200);
      case 'POST ' || 'PUT :id':
        if (!can('stock.receive')) return forbidden;
        if (grn != null && grn['status'] != 'DRAFT') {
          return _error(409, 'RECEIPT_WRONG_STATUS', wrongStatus('changed'));
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final lines = <Map<String, Object?>>[];
        for (final (index, line) in (body['lines'] as List).cast<Map<String, dynamic>>().indexed) {
          final product = products.firstWhere((p) => p['id'] == line['productId']);
          final unitId = line['unitId'] as String;
          final perUnit = unitId == (product['baseUnit'] as Map)['id']
              ? 1
              : (product['conversions'] as List<Map<String, Object?>>)
                        .where((c) => (c['unit'] as Map)['id'] == unitId)
                        .firstOrNull?['baseQuantity']
                    as int?;
          if (perUnit == null) {
            return _fieldError(
              'lines.$index.unitId',
              'This product has no conversion for that unit',
            );
          }
          lines.add({
            'productId': product['id'],
            'unitId': unitId,
            'quantityPurchased': line['quantityPurchased'],
            'quantityReceived': line['quantityReceived'],
            'baseQuantityReceived': (line['quantityReceived'] as int) * perUnit,
            'unitCost': line['unitCost'],
            'lineTotal': _lineTotal(line['quantityPurchased'] as int, line['unitCost'] as String),
            'batchNumber': line['batchNumber'],
            'expiryDate': line['expiryDate'],
            'discrepancyReason': line['discrepancyReason'],
            'notes': line['notes'],
          });
        }
        final fields = <String, Object?>{
          'ownerId': body['organisationId'] ?? organisation['id'],
          'warehouseId': body['warehouseId'] ?? 'warehouse-main',
          'supplierId': body['supplierId'],
          'supplierInvoiceNumber': body['supplierInvoiceNumber'],
          'purchaseDate': body['purchaseDate'],
          'receivedDate': body['receivedDate'],
          'notes': body['notes'],
          'lines': lines,
        };
        if (grn == null) {
          grn = {
            'id': 'grn-${grns.length + 1}',
            'grnNumber': 'GRN${(grns.length + 1).toString().padLeft(6, '0')}',
            'status': 'DRAFT',
            'documents': <Map<String, Object?>>[],
            'postedAt': null,
            'verifiedBy': null,
            'verificationNotes': null,
            'rejectedReason': null,
            'reversalReason': null,
            'noDocumentReason': null,
            ...fields,
          };
          grns.add(grn);
          return _json(201, {'receipt': _grnJson(grn)});
        }
        grn.addAll(fields);
        return _json(200, {'receipt': _grnJson(grn)});
      case 'POST attachments' when segments.length == 5:
        if (!can('stock.receive')) return forbidden;
        if (grn!['status'] != 'DRAFT' && grn['status'] != 'PENDING_VERIFICATION') {
          return _error(409, 'RECEIPT_WRONG_STATUS', wrongStatus('given more documents'));
        }
        final bytes = request.bodyBytes;
        final filename = request.url.queryParameters['filename']!;
        final String? type =
            bytes.length >= 5 && utf8.decode(bytes.sublist(0, 5), allowMalformed: true) == '%PDF-'
            ? 'application/pdf'
            : bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff
            ? 'image/jpeg'
            : bytes.length >= 4 && bytes[0] == 0x89 && bytes[1] == 0x50
            ? 'image/png'
            : null;
        if (type == null) {
          return _error(
            415,
            'UNSUPPORTED_DOCUMENT',
            'Only PDF, JPEG and PNG documents are accepted (this file is something else).',
          );
        }
        final documents = grn['documents'] as List<Map<String, Object?>>;
        documents.add({
          'id': '${grn['id']}-doc-${documents.length + 1}',
          'filename': filename,
          'mimeType': type,
          'sizeBytes': bytes.length,
          'uploadedBy': _person,
          'uploadedAt': '2026-10-20T08:00:00Z',
          'verificationStatus': 'PENDING',
          'reviewedBy': null,
          'reviewedAt': null,
          'reviewNotes': null,
          'documentTotal': null,
          'bytes': bytes,
        });
        return _json(201, {'receipt': _grnJson(grn)});
      case 'POST attachments':
        if (!can('receipt.verify')) return forbidden;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final document = (grn!['documents'] as List<Map<String, Object?>>).firstWhere(
          (d) => d['id'] == segments[5],
        );
        if (document['verificationStatus'] != 'PENDING') {
          return _error(
            409,
            'DOCUMENT_ALREADY_REVIEWED',
            'This document has already been reviewed.',
          );
        }
        document
          ..['verificationStatus'] = body['status']
          ..['reviewNotes'] = body['notes']
          ..['documentTotal'] = body['documentTotal']
          ..['reviewedBy'] = _person;
        return _json(200, {'receipt': _grnJson(grn)});
      case 'POST submit':
        if (!can('stock.receive')) return forbidden;
        if (grn!['status'] != 'DRAFT') {
          return _error(409, 'RECEIPT_WRONG_STATUS', wrongStatus('submitted'));
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final documents = (grn['documents'] as List<Map<String, Object?>>).where(
          (d) => d['verificationStatus'] != 'REJECTED',
        );
        if (documents.isEmpty) {
          if (body['noDocumentReason'] == null) {
            return _error(
              409,
              'DOCUMENT_REQUIRED',
              'Attach the supplier invoice or delivery note before submitting.',
            );
          }
          if (!can('receipt.no_document')) return forbidden;
          grn['noDocumentReason'] = body['noDocumentReason'];
        }
        grn['status'] = 'PENDING_VERIFICATION';
        if (stockBeforeVerification) {
          _moveGrnStock(grn, 1, 'receipt');
          grn['postedAt'] = '2026-10-20T08:00:00Z';
        }
        return _json(200, {'receipt': _grnJson(grn)});
      case 'POST verify':
        if (!can('receipt.verify')) return forbidden;
        if (grn!['status'] != 'PENDING_VERIFICATION') {
          return _error(409, 'RECEIPT_WRONG_STATUS', wrongStatus('verified'));
        }
        final documents = grn['documents'] as List<Map<String, Object?>>;
        if (documents.any((d) => d['verificationStatus'] == 'PENDING')) {
          return _error(
            409,
            'DOCUMENTS_NOT_REVIEWED',
            'Verify or reject every document before verifying the receipt.',
          );
        }
        if (!documents.any((d) => d['verificationStatus'] == 'VERIFIED') &&
            grn['noDocumentReason'] == null) {
          return _error(409, 'NO_VERIFIED_DOCUMENT', 'No document has been verified.');
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        grn
          ..['status'] = grn['postedAt'] == null ? 'VERIFIED' : 'POSTED'
          ..['verifiedBy'] = _person
          ..['verificationNotes'] = body['notes'];
        return _json(200, {'receipt': _grnJson(grn)});
      case 'POST post':
        if (!can('stock.receive')) return forbidden;
        if (grn!['status'] != 'VERIFIED') {
          return _error(409, 'RECEIPT_WRONG_STATUS', wrongStatus('posted'));
        }
        _moveGrnStock(grn, 1, 'receipt');
        grn
          ..['status'] = 'POSTED'
          ..['postedAt'] = '2026-10-20T09:00:00Z';
        return _json(200, {'receipt': _grnJson(grn)});
      case 'POST reject':
        if (!can('receipt.verify')) return forbidden;
        if (grn!['status'] != 'PENDING_VERIFICATION') {
          return _error(409, 'RECEIPT_WRONG_STATUS', wrongStatus('rejected'));
        }
        if (grn['postedAt'] != null) _moveGrnStock(grn, -1, 'reversal');
        grn
          ..['status'] = 'REJECTED'
          ..['rejectedReason'] = (jsonDecode(request.body) as Map)['reason'];
        return _json(200, {'receipt': _grnJson(grn)});
      case 'POST reverse':
        if (!can('receipt.reverse')) return forbidden;
        if (grn!['status'] != 'POSTED') {
          return _error(409, 'RECEIPT_WRONG_STATUS', wrongStatus('reversed'));
        }
        _moveGrnStock(grn, -1, 'reversal');
        grn
          ..['status'] = 'REVERSED'
          ..['reversalReason'] = (jsonDecode(request.body) as Map)['reason'];
        return _json(200, {'receipt': _grnJson(grn)});
    }
    return _error(404, 'NOT_FOUND', 'Not found');
  }

  // ------------------------------------------------------------------ Orders

  /// Subsidiary orders as the server stores them, oldest first.
  final List<Map<String, Object?>> subsidiaryOrders = [];

  /// When false, approval needs enough Head Office stock (ORDERS_ALLOW_BACKORDERS).
  bool allowBackorders = true;

  /// Adds an order directly, e.g. addOrder('org-sub-1', {'PC-BBQ-S': (10, '0.50', '0.55')}).
  Map<String, Object?> addOrder(
    String organisationId,
    Map<String, (int, String, String)> lines, {
    String status = 'SUBMITTED',
  }) {
    final order = <String, Object?>{
      'id': 'order-${subsidiaryOrders.length + 1}',
      'orderNumber': 'ORD${(subsidiaryOrders.length + 1).toString().padLeft(6, '0')}',
      'status': status,
      'organisationId': organisationId,
      'orderDate': toApiDate(today()),
      'requiredDate': null,
      'notes': null,
      'idempotencyKey': 'seeded-${subsidiaryOrders.length}',
      'requestedBy': _person,
      'submittedBy': status == 'DRAFT' ? null : _person,
      'decidedBy': null,
      'decisionComment': null,
      'priceExceptionApproved': false,
      'cancelReason': null,
      'lines': [
        for (final MapEntry(key: sku, value: (quantity, expected, maximum)) in lines.entries)
          <String, Object?>{
            'productId': products.firstWhere((p) => p['sku'] == sku)['id'],
            'unitId': 'unit-pack',
            'requestedQuantity': quantity,
            'expectedUnitPrice': expected,
            'maximumUnitPrice': maximum,
            'actualUnitPrice': null,
            'notes': null,
          },
      ],
      'history': <Map<String, Object?>>[
        _orderHistory(null, 'DRAFT', null),
        if (status != 'DRAFT') _orderHistory('DRAFT', status, null),
      ],
      'changes': <Map<String, Object?>>[],
    };
    subsidiaryOrders.add(order);
    return order;
  }

  Map<String, Object?> _orderHistory(String? from, String to, String? comment) => {
    'fromStatus': from,
    'toStatus': to,
    'changedBy': _person,
    'changedAt': '2026-10-21T08:00:00Z',
    'comment': comment,
  };

  String _times(int quantity, String? price) =>
      price == null ? '' : formatCents(quantity * parseCents(price)!);

  Map<String, Object?> _orderJson(Map<String, Object?> order) {
    final lines = order['lines'] as List<Map<String, Object?>>;
    int sum(String field) => lines.fold(
      0,
      (total, l) => total + (l['requestedQuantity'] as int) * parseCents(l[field] as String)!,
    );
    final priced = lines.isNotEmpty && lines.every((l) => l['actualUnitPrice'] != null);
    bool exception(Map<String, Object?> l) =>
        l['actualUnitPrice'] != null &&
        parseCents(l['actualUnitPrice'] as String)! > parseCents(l['maximumUnitPrice'] as String)!;
    final headOffice = organisation['type'] == 'HQ';
    return {
      for (final MapEntry(:key, :value) in order.entries)
        if (!['organisationId', 'lines', 'idempotencyKey'].contains(key)) key: value,
      'organisation': _ref(organisations.firstWhere((o) => o['id'] == order['organisationId'])),
      'currency': 'USD',
      'lineCount': lines.length,
      'expectedTotal': formatCents(sum('expectedUnitPrice')),
      'maximumTotal': formatCents(sum('maximumUnitPrice')),
      'actualTotal': priced ? formatCents(sum('actualUnitPrice')) : null,
      'priceException': lines.any(exception),
      'lines': [
        for (final (index, l) in lines.indexed)
          {
            'id': '${order['id']}-line-${index + 1}',
            'lineNumber': index + 1,
            'product': () {
              final p = products.firstWhere((p) => p['id'] == l['productId']);
              return {
                'id': p['id'],
                'sku': p['sku'],
                'description': '${p['name']} — ${p['flavour']} — ${p['size']}',
              };
            }(),
            'unit': _ref(catalogue['units']!.firstWhere((u) => u['id'] == l['unitId'])),
            'requestedQuantity': l['requestedQuantity'],
            'baseQuantity': l['requestedQuantity'],
            'expectedUnitPrice': l['expectedUnitPrice'],
            'maximumUnitPrice': l['maximumUnitPrice'],
            'actualUnitPrice': l['actualUnitPrice'],
            'expectedLineTotal': _times(
              l['requestedQuantity'] as int,
              l['expectedUnitPrice'] as String,
            ),
            'maximumLineTotal': _times(
              l['requestedQuantity'] as int,
              l['maximumUnitPrice'] as String,
            ),
            'actualLineTotal': l['actualUnitPrice'] == null
                ? null
                : _times(l['requestedQuantity'] as int, l['actualUnitPrice'] as String),
            'priceException': exception(l),
            'notes': l['notes'],
            if (headOffice) 'hqAvailable': onHand(l['productId']),
          },
      ],
    };
  }

  http.Response _orders(http.Request request) {
    final forbidden = _error(403, 'FORBIDDEN', 'Your role does not allow this action.');
    if (!can('order.view')) return forbidden;
    final notFound = _error(404, 'ORDER_NOT_FOUND', 'No order has that id.');
    final segments = request.url.pathSegments; // api, v1, orders, id?, action?
    final headOffice = organisation['type'] == 'HQ';
    final visible = subsidiaryOrders.where(
      (o) => headOffice || o['organisationId'] == organisation['id'],
    );
    Map<String, Object?>? order;
    if (segments.length > 3) {
      order = visible.where((o) => o['id'] == segments[3]).firstOrNull;
      if (order == null) return notFound;
    }
    final action = segments.length > 4 ? segments[4] : null;
    final route = '${request.method} ${action ?? (order == null ? '' : ':id')}';
    final body = request.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;
    http.Response wrong(String what) => _error(
      409,
      'ORDER_WRONG_STATUS',
      'This order is ${(order!['status'] as String).toLowerCase()}, so it cannot be $what.',
    );
    http.Response ok(Map<String, Object?> o, [Map<String, Object?> extra = const {}]) =>
        _json(200, {'order': _orderJson(o), ...extra});
    void move(String to, String? comment) {
      final from = order!['status'] as String;
      order['status'] = to;
      (order['history'] as List<Map<String, Object?>>).add(_orderHistory(from, to, comment));
    }

    List<Map<String, Object?>> linesFrom(Map<String, dynamic> body) => [
      for (final l in (body['lines'] as List).cast<Map<String, dynamic>>())
        {
          'productId': l['productId'],
          'unitId': l['unitId'],
          'requestedQuantity': l['requestedQuantity'],
          'expectedUnitPrice': l['expectedUnitPrice'],
          'maximumUnitPrice': l['maximumUnitPrice'],
          'actualUnitPrice': null,
          'notes': l['notes'],
        },
    ];

    switch (route) {
      case 'GET ':
        final q = request.url.queryParameters;
        final listed = visible
            .map(_orderJson)
            .where((o) => q['status'] == null || o['status'] == q['status'])
            .where(
              (o) =>
                  q['organisationId'] == null ||
                  (o['organisation'] as Map)['id'] == q['organisationId'],
            )
            .where((o) => q['priceException'] != 'true' || o['priceException'] == true)
            .where((o) => (o['orderNumber'] as String).contains((q['q'] ?? '').toUpperCase()))
            .toList()
            .reversed
            .toList();
        return _json(200, {'orders': listed, 'total': listed.length});
      case 'GET :id':
        return ok(order!);
      case 'GET pdf':
        return http.Response.bytes(
          utf8.encode('%PDF-1.4 order sheet ${order!['orderNumber']}'),
          200,
          headers: {'content-type': 'application/pdf'},
        );
      case 'POST ':
        if (!can('order.create')) return forbidden;
        final replay = subsidiaryOrders
            .where((o) => o['idempotencyKey'] == body['idempotencyKey'])
            .firstOrNull;
        if (replay != null) return ok(replay, {'replayed': true});
        final created = addOrder(
          headOffice ? body['organisationId'] as String : organisation['id'] as String,
          const {},
          status: 'DRAFT',
        );
        created
          ..['idempotencyKey'] = body['idempotencyKey']
          ..['requiredDate'] = body['requiredDate']
          ..['notes'] = body['notes']
          ..['lines'] = linesFrom(body);
        return _json(201, {'order': _orderJson(created), 'replayed': false});
      case 'PUT :id':
        if (!can('order.create')) return forbidden;
        if (order!['status'] != 'DRAFT') return wrong('changed');
        order
          ..['requiredDate'] = body['requiredDate']
          ..['notes'] = body['notes']
          ..['lines'] = linesFrom(body);
        return ok(order);
      case 'POST submit':
        if (!can('order.create')) return forbidden;
        if (order!['status'] == 'SUBMITTED') return ok(order, {'alreadySubmitted': true});
        if (order['status'] != 'DRAFT') return wrong('submitted');
        order['submittedBy'] = _person;
        move('SUBMITTED', null);
        return ok(order, {'alreadySubmitted': false});
      case 'POST cancel':
        if (!can('order.create')) return forbidden;
        if (order!['status'] != 'DRAFT' && order['status'] != 'SUBMITTED') {
          return wrong('cancelled');
        }
        order['cancelReason'] = body['reason'];
        move('CANCELLED', body['reason'] as String?);
        return ok(order);
      case 'POST review':
        if (!can('order.price') || !headOffice) return forbidden;
        if (order!['status'] != 'SUBMITTED') return wrong('taken into review');
        move('UNDER_REVIEW', null);
        return ok(order);
      case 'PUT prices':
        if (!can('order.price') || !headOffice) return forbidden;
        if (order!['status'] != 'SUBMITTED' && order['status'] != 'UNDER_REVIEW') {
          return wrong('priced');
        }
        if (order['status'] == 'SUBMITTED') move('UNDER_REVIEW', null);
        final lines = order['lines'] as List<Map<String, Object?>>;
        for (final price in (body['prices'] as List).cast<Map<String, dynamic>>()) {
          final index = int.parse((price['itemId'] as String).split('-line-').last) - 1;
          final old = lines[index]['actualUnitPrice'];
          lines[index]['actualUnitPrice'] = price['actualUnitPrice'];
          (order['changes'] as List<Map<String, Object?>>).add({
            'lineNumber': index + 1,
            'field': 'actual_unit_price',
            'oldValue': old,
            'newValue': price['actualUnitPrice'],
            'changedBy': _person,
            'changedAt': '2026-10-21T09:00:00Z',
            'comment': price['comment'],
          });
        }
        return ok(order);
      case 'POST approve':
        if (!can('order.approve') || !headOffice) return forbidden;
        if (order!['status'] != 'UNDER_REVIEW') return wrong('approved');
        final json = _orderJson(order);
        if (json['actualTotal'] == null) {
          return _error(409, 'PRICES_MISSING', 'Set the actual price of every line first.');
        }
        if (json['priceException'] == true) {
          if (!can('price.exception.approve')) {
            return _error(403, 'PRICE_EXCEPTION_NOT_ALLOWED', 'Not allowed to approve this price.');
          }
          if (body['comment'] == null) {
            return _fieldError('comment', 'Explain why the price above the maximum is approved');
          }
        }
        order
          ..['decidedBy'] = _person
          ..['decisionComment'] = body['comment']
          ..['priceExceptionApproved'] = json['priceException'];
        move('APPROVED', body['comment'] as String?);
        return ok(order);
      case 'POST reject':
        if (!can('order.approve') || !headOffice) return forbidden;
        if (order!['status'] != 'SUBMITTED' && order['status'] != 'UNDER_REVIEW') {
          return wrong('rejected');
        }
        order
          ..['decidedBy'] = _person
          ..['decisionComment'] = body['comment'];
        move('REJECTED', body['comment'] as String?);
        return ok(order);
    }
    return _error(404, 'NOT_FOUND', 'Not found');
  }

  http.Response _login(http.Request request) {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (body['username'] == testUsername && body['pin'] == pin) {
      return _json(200, {
        'token': issueToken(),
        'expiresAt': '2026-10-13T00:00:00.000Z',
        'user': user,
      });
    }
    return _error(401, 'INVALID_CREDENTIALS', 'Incorrect username or PIN.');
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
    if (body.containsKey('categoryId')) {
      final category = catalogue['categories']!
          .where((c) => c['id'] == body['categoryId'])
          .firstOrNull;
      product['category'] = category == null
          ? null
          : {'id': category['id'], 'name': category['name']};
    }
    return _json(200, {'product': product});
  }

  /// Which permission changes which customer field, as on the real server.
  static const _customerFieldPermissions = {
    'code': 'customer.edit_details',
    'name': 'customer.edit_details',
    'phone': 'customer.edit_details',
    'address': 'customer.edit_details',
    'creditLimit': 'customer.edit_credit_limit',
    'isActive': 'customer.change_active',
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
        if (!can(_customerFieldPermissions[field] ?? '-')) return forbidden;
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
    final canCreate = can('dispatch.draft');
    final canConfirm = can('dispatch.confirm');

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
        if (!can('dispatch.reverse')) return forbidden;
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
    if (!can('invoice.manage')) {
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
    if (!can('payment.manage')) {
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
        if (!can('payment.void')) {
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
    if (!can('payment.manage')) {
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

  // ------------------------------------------------------------------ Barcodes

  int _internalBarcodes = 0;

  /// Snackify's own EAN-13 number n: 20, ten digits, and the check digit.
  static String internalBarcode(int n) {
    final body = '20${n.toString().padLeft(10, '0')}';
    var sum = 0;
    for (var i = 0; i < 12; i++) {
      sum += int.parse(body[i]) * (i.isEven ? 1 : 3);
    }
    return '$body${(10 - sum % 10) % 10}';
  }

  http.Response _barcodes(http.Request request) {
    final segments = request.url.pathSegments; // api, v1, products, (barcode, code) | (id, action)
    if (segments[3] == 'barcode') {
      final code = segments[4].replaceAll(RegExp(r'\s+'), '');
      final matches = products.where((p) => p['barcode'] == code);
      if (matches.isEmpty) {
        return _error(404, 'BARCODE_NOT_FOUND', 'No product has the barcode $code.');
      }
      return _json(200, {'product': matches.first});
    }

    final product = products.firstWhere((p) => p['id'] == segments[3]);
    if (segments[4] == 'barcode') {
      if (!can('product.manage')) {
        return _error(403, 'FORBIDDEN', 'Your role does not allow this action.');
      }
      if (product['barcode'] != null) {
        return _error(
          409,
          'PRODUCT_HAS_BARCODE',
          'This product already has the barcode ${product['barcode']}.',
        );
      }
      product['barcode'] = internalBarcode(++_internalBarcodes);
      return _json(200, {'product': product});
    }

    // Labels.
    if (!can('label.print')) {
      return _error(403, 'FORBIDDEN', 'Your role does not allow this action.');
    }
    if (product['barcode'] == null) {
      return _error(
        409,
        'PRODUCT_HAS_NO_BARCODE',
        'This product has no barcode yet. An admin can generate one in Products.',
      );
    }
    final query = request.url.queryParameters;
    return http.Response.bytes(
      utf8.encode(
        '%PDF-1.3 labels ${product['sku']} count=${query['count']} skip=${query['skip']}',
      ),
      200,
      headers: {'content-type': 'application/pdf'},
    );
  }

  // ------------------------------------------------------------------ Reports

  /// Canned answers by report name (dashboard, sales, products, customers, stock-received,
  /// expiring). Reports without one answer as empty; the dashboard is built from the fake's own
  /// products. The real calculations are tested against PostgreSQL in the backend.
  final Map<String, Map<String, Object?>> reportAnswers = {};

  http.Response _reports(http.Request request) {
    final name = request.url.pathSegments[3];
    final money = can('report.financial');
    final allowed = switch (name) {
      'dashboard' => can('report.dashboard'),
      'stock-received' || 'expiring' => can('report.stock'),
      _ => money,
    };
    if (!allowed) return _error(403, 'FORBIDDEN', 'Your role does not allow this action.');
    if (reportAnswers[name] case final answer?) return _json(200, answer);

    final query = request.url.queryParameters;
    final range = {
      'from': query['from'] ?? toApiDate(today().subtract(const Duration(days: 29))),
      'to': query['to'] ?? toApiDate(today()),
    };
    return _json(200, switch (name) {
      'dashboard' => {'dashboard': _dashboard(money)},
      'sales' => {
        ...range,
        'groupBy': query['groupBy'] ?? 'day',
        'currency': 'USD',
        'totals': {
          'dispatches': 0,
          'packs': 0,
          'salesValue': '0.00',
          'invoiced': '0.00',
          'paymentsReceived': '0.00',
        },
        'periods': <Object>[],
      },
      'products' => {
        ...range,
        'currency': 'USD',
        'products': <Object>[],
        'totals': {'packs': 0, 'salesValue': '0.00'},
      },
      'customers' => {...range, 'currency': 'USD', 'customers': <Object>[]},
      'stock-received' => {
        ...range,
        'products': <Object>[],
        'totals': {'receipts': 0, 'packs': 0},
      },
      _ => {
        'today': toApiDate(today()),
        'withinDays': int.parse(query['days'] ?? '30'),
        'batches': <Object>[],
      },
    });
  }

  Map<String, Object?> _dashboard(bool money) {
    final low = [
      for (final p in products)
        if (p['isActive'] == true &&
            p['reorderLevel'] != null &&
            onHand(p['id']) <= (p['reorderLevel'] as int))
          {
            'product': {
              'id': p['id'],
              'sku': p['sku'],
              'description': '${p['name']} — ${p['flavour']} — ${p['size']}',
            },
            'quantityOnHand': onHand(p['id']),
            'reorderLevel': p['reorderLevel'],
          },
    ];
    final none = {'dispatches': 0, 'packs': 0, 'salesValue': money ? '0.00' : null};
    return {
      'today': toApiDate(today()),
      'dispatchesToday': none,
      'dispatchesThisWeek': none,
      'receivedToday': {'receipts': 0, 'packs': 0},
      'lowStock': {'count': low.length, 'products': low},
      'expiring': {'withinDays': 30, 'count': 0, 'batches': <Object>[]},
      'money': money
          ? {
              'currency': 'USD',
              'salesThisMonth': '0.00',
              'invoicedThisMonth': '0.00',
              'paymentsThisMonth': '0.00',
              'owedByCustomers': '0.00',
              'overdue': '0.00',
            }
          : null,
      'trend': [
        for (var i = 13; i >= 0; i--)
          {
            'date': toApiDate(today().subtract(Duration(days: i))),
            'packs': 0,
            'salesValue': money ? '0.00' : null,
          },
      ],
    };
  }

  // ------------------------------------------------------------------ Forecasts

  /// What GET /forecasts answers. Making a forecast replaces it with [forecastAfterRun] (or an
  /// empty run). The forecasting itself is tested against PostgreSQL in the backend.
  Map<String, Object?> forecastAnswer = {'run': null, 'products': <Object>[]};
  Map<String, Object?>? forecastAfterRun;
  int forecastRuns = 0;

  http.Response _forecasts(http.Request request) {
    if (!can('forecast.use')) {
      return _error(403, 'FORBIDDEN', 'Your role does not allow this action.');
    }
    if (request.method == 'POST') {
      forecastRuns++;
      forecastAnswer =
          forecastAfterRun ??
          {
            'run': {
              'id': 'run-$forecastRuns',
              'forecastStart': toApiDate(today()),
              'method': 'weekday-average',
              'createdAt': DateTime.now().toUtc().toIso8601String(),
              'createdBy': 'Tendai Moyo',
            },
            'products': <Object>[],
          };
      return _json(201, {'forecast': forecastAnswer});
    }
    return _json(200, {'forecast': forecastAnswer});
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
  TestApp(
    this.backend,
    this.api,
    this.tokenStore,
    this.auth,
    this.sharedPdfs,
    this.scanner,
    this.documents,
  );

  final FakeBackend backend;
  final ApiClient api;
  final MemoryTokenStore tokenStore;
  final AuthController auth;

  /// PDFs handed to the device to share or download, as (file name, contents).
  final List<(String, String)> sharedPdfs;

  /// The pretend barcode scanner the app uses.
  final FakeScanner scanner;

  /// The pretend file chooser for supplier documents.
  final FakeDocumentPicker documents;
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
  final scanner = FakeScanner();
  final documents = FakeDocumentPicker();
  final services = AppServices(
    checkBackendHealth: () async => apiHealthy,
    products: ProductsRepository(api),
    stock: StockRepository(api),
    customers: CustomersRepository(api),
    dispatches: DispatchesRepository(api),
    invoices: InvoicesRepository(api),
    payments: PaymentsRepository(api),
    reports: ReportsRepository(api),
    forecasts: ForecastsRepository(api),
    staff: StaffRepository(api),
    organisations: OrganisationsRepository(api),
    audit: AuditRepository(api),
    receipts: ReceiptsRepository(api),
    catalogue: CatalogueRepository(api),
    orders: OrdersRepository(api),
    sharePdf: (bytes, filename) async =>
        sharedPdfs.add((filename, utf8.decode(bytes, allowMalformed: true))),
    readBarcode: scanner.read,
    pickDocuments: documents.pick,
  );

  await tester.pumpWidget(SnackifyApp(auth: auth, services: services));
  auth.restore();
  await tester.pumpAndSettle();
  return TestApp(server, api, store, auth, sharedPdfs, scanner, documents);
}

/// Fills in the login form and presses "Sign in".
Future<void> signInThroughForm(WidgetTester tester, String username, String pin) async {
  await tester.enterText(find.widgetWithText(TextFormField, 'Username'), username);
  await tester.enterText(find.widgetWithText(TextFormField, 'PIN'), pin);
  await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
  await tester.pumpAndSettle();
}

/// Opens a section from the menu (drawer on phones, sidebar on wide screens).
Future<void> openSection(WidgetTester tester, String label) async {
  final menuButton = find.byTooltip('Open navigation menu');
  final onPhone = menuButton.evaluate().isNotEmpty;
  if (onPhone) {
    await tester.tap(menuButton);
    await tester.pumpAndSettle();
  }
  // The menu scrolls, and builds entries only as they come into view.
  await tester.scrollUntilVisible(
    find.text(label),
    80,
    scrollable: find
        .descendant(
          of: find.byType(onPhone ? Drawer : ListView).first,
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).first);
  await tester.pumpAndSettle();
}

/// The sections listed in the menu (drawer on phones, sidebar on wide screens).
Future<List<String>> menuSections(WidgetTester tester) async {
  final menuButton = find.byTooltip('Open navigation menu');
  final onPhone = menuButton.evaluate().isNotEmpty;
  if (onPhone) {
    await tester.tap(menuButton);
    await tester.pumpAndSettle();
  }
  final tiles = find.descendant(
    of: find.byType(onPhone ? Drawer : ListView).first,
    matching: find.byType(ListTile),
  );
  final labels = [
    for (final tile in tester.widgetList<ListTile>(tiles))
      if (tile.title case Text(:final data?)) data,
  ];
  if (onPhone) {
    Navigator.of(tester.element(find.byType(Drawer))).pop();
    await tester.pumpAndSettle();
  }
  return labels;
}

/// Stands in for the camera: each scan returns the next queued barcode, or null (as when the
/// user closes the scanner) once the queue is empty.
class FakeScanner {
  final List<String?> queue = [];
  int scans = 0;

  /// Queues barcodes for the next scans; a null entry is a scan the user cancels.
  void willRead(List<String?> barcodes) => queue.addAll(barcodes);

  Future<String?> read(BuildContext context) async {
    scans++;
    return queue.isEmpty ? null : queue.removeAt(0);
  }
}

/// Stands in for the device's file chooser: each use returns the next queued files (none,
/// as when the user cancels, once the queue is empty).
class FakeDocumentPicker {
  final List<List<PickedDocument>> queue = [];

  void willPick(List<PickedDocument> documents) => queue.add(documents);

  Future<List<PickedDocument>> pick() async => queue.isEmpty ? [] : queue.removeAt(0);
}
