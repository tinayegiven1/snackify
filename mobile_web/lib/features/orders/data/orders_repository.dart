import 'dart:math';
import 'dart:typed_data';

import '../../../core/network/api_client.dart';
import '../domain/order_models.dart';

/// A random id (UUID version 4) for a new order. The form keeps the same one while it is
/// open, so pressing a button twice or retrying after a lost connection never creates two
/// orders: the server answers the second request with the first order.
String newIdempotencyKey([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Subsidiary orders, through the backend.
class OrdersRepository {
  OrdersRepository(this._api);

  final ApiClient _api;

  static const _base = '/api/v1/orders';

  Future<({List<OrderSummary> orders, int total})> list({
    OrderStatus? status,
    String? organisationId,
    bool priceExceptionOnly = false,
    String search = '',
    String sort = 'newest',
    int limit = 100,
  }) async {
    final query = Uri(
      queryParameters: {
        'status': ?status?.code,
        'organisationId': ?organisationId,
        if (priceExceptionOnly) 'priceException': 'true',
        if (search.trim().isNotEmpty) 'q': search.trim(),
        'sort': sort,
        'limit': '$limit',
      },
    ).query;
    final body = await _api.getJson('$_base?$query');
    return (
      orders: [
        for (final item in body['orders'] as List)
          OrderSummary.fromJson(item as Map<String, dynamic>),
      ],
      total: body['total'] as int,
    );
  }

  Future<SubsidiaryOrder> get(String id) => _order(_api.getJson('$_base/$id'));

  /// Creates a draft. [idempotencyKey] stays the same for retries of the same order.
  Future<SubsidiaryOrder> create(OrderInput input, String idempotencyKey) =>
      _order(_api.postJson(_base, {...input.toJson(), 'idempotencyKey': idempotencyKey}));

  Future<SubsidiaryOrder> update(String id, OrderInput input) =>
      _order(_api.putJson('$_base/$id', input.toJson()));

  Future<SubsidiaryOrder> submit(String id) => _order(_api.postJson('$_base/$id/submit'));

  Future<SubsidiaryOrder> cancel(String id, String reason) =>
      _order(_api.postJson('$_base/$id/cancel', {'reason': reason}));

  Future<SubsidiaryOrder> startReview(String id) => _order(_api.postJson('$_base/$id/review'));

  /// Sets actual prices: {lineId: price}, with an optional comment for each.
  Future<SubsidiaryOrder> setPrices(
    String id,
    List<({String itemId, String actualUnitPrice, String? comment})> prices,
  ) => _order(
    _api.putJson('$_base/$id/prices', {
      'prices': [
        for (final price in prices)
          {
            'itemId': price.itemId,
            'actualUnitPrice': price.actualUnitPrice,
            'comment': price.comment,
          },
      ],
    }),
  );

  Future<SubsidiaryOrder> approve(String id, {String? comment}) =>
      _order(_api.postJson('$_base/$id/approve', {'comment': ?comment}));

  Future<SubsidiaryOrder> reject(String id, String comment) =>
      _order(_api.postJson('$_base/$id/reject', {'comment': comment}));

  Future<Uint8List> pdf(String id) => _api.getBytes('$_base/$id/pdf', accept: 'application/pdf');

  Future<SubsidiaryOrder> _order(Future<Map<String, dynamic>> request) async =>
      SubsidiaryOrder.fromJson((await request)['order'] as Map<String, dynamic>);
}
