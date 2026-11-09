import 'dart:typed_data';

import '../../../core/network/api_client.dart';
import '../../receipts/domain/receipt_models.dart' show DocumentStatus;
import '../domain/purchase_models.dart';

/// Goods bought from suppliers (lists to receive against), through the backend.
class PurchasesRepository {
  PurchasesRepository(this._api);

  final ApiClient _api;

  static const _base = '/api/v1/purchases';

  /// Lists the user may see, newest first. [search] matches the number, the supplier's
  /// invoice number and the supplier's name.
  Future<({List<PurchaseSummary> purchases, int total})> list({
    PurchaseFilter? filter,
    String search = '',
    int limit = 100,
  }) async {
    final query = Uri(
      queryParameters: {
        'q': ?(search.trim().isEmpty ? null : search.trim()),
        'status': ?filter?.code,
        'limit': '$limit',
      },
    ).query;
    final body = await _api.getJson('$_base?$query');
    return (
      purchases: [
        for (final item in body['purchases'] as List)
          PurchaseSummary.fromJson(item as Map<String, dynamic>),
      ],
      total: body['total'] as int,
    );
  }

  Future<Purchase> get(String id) => _purchase(_api.getJson('$_base/$id'));

  Future<Purchase> create(PurchaseInput input) => _purchase(_api.postJson(_base, input.toJson()));

  /// Only while no goods-received note was made from it.
  Future<Purchase> update(String id, PurchaseInput input) =>
      _purchase(_api.putJson('$_base/$id', input.toJson()));

  Future<Purchase> cancel(String id, String reason) =>
      _purchase(_api.postJson('$_base/$id/cancel', {'reason': reason}));

  /// Uploads a supplier document (PDF, JPEG or PNG; checked by the server from its content).
  /// Finance and administrators only.
  Future<Purchase> addDocument(String id, String filename, Uint8List bytes) => _purchase(
    _api.postBytes(
      '$_base/$id/attachments?${Uri(queryParameters: {'filename': filename}).query}',
      bytes,
    ),
  );

  /// Verifies or rejects a document (finance and administrators only). Rejecting needs [notes].
  Future<Purchase> reviewDocument(
    String id,
    String documentId, {
    required DocumentStatus status,
    String? notes,
    String? documentTotal,
  }) => _purchase(
    _api.postJson('$_base/$id/attachments/$documentId/review', {
      'status': status.code,
      'notes': ?notes,
      'documentTotal': ?documentTotal,
    }),
  );

  Future<Uint8List> document(String id, String documentId) =>
      _api.getBytes('$_base/$id/attachments/$documentId');

  Future<Uint8List> pdf(String id) => _api.getBytes('$_base/$id/pdf', accept: 'application/pdf');

  Future<Purchase> _purchase(Future<Map<String, dynamic>> request) async =>
      Purchase.fromJson((await request)['purchase'] as Map<String, dynamic>);
}
