import 'dart:typed_data';

import '../../../core/network/api_client.dart';
import '../domain/receipt_models.dart';

/// Goods-received notes, through the backend. Supplier documents are attached to goods-bought
/// lists; older notes' documents can still be downloaded.
class ReceiptsRepository {
  ReceiptsRepository(this._api);

  final ApiClient _api;

  static const _base = '/api/v1/receipts';

  /// Receipts the user may see, newest first.
  Future<({List<ReceiptSummary> receipts, int total})> list({
    ReceiptStatus? status,
    int limit = 100,
  }) async {
    final query = Uri(queryParameters: {'status': ?status?.code, 'limit': '$limit'}).query;
    final body = await _api.getJson('$_base?$query');
    return (
      receipts: [
        for (final item in body['receipts'] as List)
          ReceiptSummary.fromJson(item as Map<String, dynamic>),
      ],
      total: body['total'] as int,
    );
  }

  Future<GoodsReceipt> get(String id) => _receipt(_api.getJson('$_base/$id'));

  Future<GoodsReceipt> create(ReceiptInput input) => _receipt(_api.postJson(_base, input.toJson()));

  Future<GoodsReceipt> update(String id, ReceiptInput input) =>
      _receipt(_api.putJson('$_base/$id', input.toJson()));

  /// Submits for verification.
  Future<GoodsReceipt> submit(String id) => _receipt(_api.postJson('$_base/$id/submit'));

  Future<GoodsReceipt> verify(String id, {String? notes}) =>
      _receipt(_api.postJson('$_base/$id/verify', {'notes': ?notes}));

  Future<GoodsReceipt> reject(String id, String reason) =>
      _receipt(_api.postJson('$_base/$id/reject', {'reason': reason}));

  Future<GoodsReceipt> post(String id) => _receipt(_api.postJson('$_base/$id/post'));

  /// Sends an approved note to its subsidiary on WhatsApp again.
  Future<GoodsReceipt> sendWhatsApp(String id) => _receipt(_api.postJson('$_base/$id/whatsapp'));

  Future<GoodsReceipt> reverse(String id, String reason) =>
      _receipt(_api.postJson('$_base/$id/reverse', {'reason': reason}));

  /// A document attached before documents moved to the goods-bought list.
  Future<Uint8List> document(String id, String documentId) =>
      _api.getBytes('$_base/$id/attachments/$documentId');

  Future<Uint8List> pdf(String id) => _api.getBytes('$_base/$id/pdf', accept: 'application/pdf');

  Future<GoodsReceipt> _receipt(Future<Map<String, dynamic>> request) async =>
      GoodsReceipt.fromJson((await request)['receipt'] as Map<String, dynamic>);
}
