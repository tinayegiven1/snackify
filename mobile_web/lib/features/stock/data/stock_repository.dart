import '../../../core/network/api_client.dart';
import '../domain/stock_models.dart';

/// Stock on hand, receipts, the stock ledger and adjustments, through the backend.
class StockRepository {
  StockRepository(this._api);

  final ApiClient _api;

  Future<List<StockBalance>> balances({String search = '', bool lowStockOnly = false}) async {
    final query = Uri(
      queryParameters: {
        if (search.trim().isNotEmpty) 'q': search.trim(),
        if (lowStockOnly) 'lowStockOnly': 'true',
      },
    ).query;
    final body = await _api.getJson('/api/v1/stock/balance?$query');
    return (body['balances'] as List)
        .map((item) => StockBalance.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// Receipts between two API dates (inclusive), newest first, with the total quantity.
  Future<({List<StockReceipt> receipts, int totalQuantity})> receipts({
    required String from,
    required String to,
  }) async {
    final query = Uri(queryParameters: {'from': from, 'to': to}).query;
    final body = await _api.getJson('/api/v1/stock/receipts?$query');
    return (
      receipts: (body['receipts'] as List)
          .map((item) => StockReceipt.fromJson(item as Map<String, dynamic>))
          .toList(),
      totalQuantity: body['totalQuantity'] as int,
    );
  }

  /// A product's ledger, newest first.
  Future<List<StockMovement>> movements(String productId) async {
    final query = Uri(queryParameters: {'productId': productId, 'limit': '200'}).query;
    final body = await _api.getJson('/api/v1/stock/movements?$query');
    return (body['movements'] as List)
        .map((item) => StockMovement.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// Records stock received. Returns the receipt and the product's new stock on hand.
  Future<({StockReceipt receipt, int quantityOnHand})> receive(ReceiptInput input) async {
    final body = await _api.postJson('/api/v1/stock/receipts', input.toJson());
    return (
      receipt: StockReceipt.fromJson(body['receipt'] as Map<String, dynamic>),
      quantityOnHand: body['quantityOnHand'] as int,
    );
  }

  /// Changes stock by hand (admins). [type] is "damage" or "adjustment".
  Future<int> adjust({
    required String productId,
    required String type,
    required int quantityDelta,
    required String reason,
  }) async {
    final body = await _api.postJson('/api/v1/stock/adjustments', {
      'productId': productId,
      'type': type,
      'quantityDelta': quantityDelta,
      'reason': reason,
    });
    return body['quantityOnHand'] as int;
  }
}
