import 'dart:typed_data';

import '../../../core/network/api_client.dart';
import '../domain/receipt_models.dart';

/// Goods-received notes and their documents, through the backend.
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

  /// Submits for verification. [noDocumentReason] is only for authorised users.
  Future<GoodsReceipt> submit(String id, {String? noDocumentReason}) =>
      _receipt(_api.postJson('$_base/$id/submit', {'noDocumentReason': ?noDocumentReason}));

  Future<GoodsReceipt> verify(String id, {String? notes}) =>
      _receipt(_api.postJson('$_base/$id/verify', {'notes': ?notes}));

  Future<GoodsReceipt> reject(String id, String reason) =>
      _receipt(_api.postJson('$_base/$id/reject', {'reason': reason}));

  Future<GoodsReceipt> post(String id) => _receipt(_api.postJson('$_base/$id/post'));

  Future<GoodsReceipt> reverse(String id, String reason) =>
      _receipt(_api.postJson('$_base/$id/reverse', {'reason': reason}));

  /// Uploads a supplier document (PDF, JPEG or PNG; checked by the server from its content).
  Future<GoodsReceipt> addDocument(String id, String filename, Uint8List bytes) => _receipt(
    _api.postBytes(
      '$_base/$id/attachments?${Uri(queryParameters: {'filename': filename}).query}',
      bytes,
    ),
  );

  Future<GoodsReceipt> reviewDocument(
    String id,
    String documentId, {
    required DocumentStatus status,
    String? notes,
    String? documentTotal,
  }) => _receipt(
    _api.postJson('$_base/$id/attachments/$documentId/review', {
      'status': status.code,
      'notes': notes,
      'documentTotal': documentTotal,
    }),
  );

  Future<Uint8List> document(String id, String documentId) =>
      _api.getBytes('$_base/$id/attachments/$documentId');

  Future<Uint8List> pdf(String id) => _api.getBytes('$_base/$id/pdf', accept: 'application/pdf');

  Future<GoodsReceipt> _receipt(Future<Map<String, dynamic>> request) async =>
      GoodsReceipt.fromJson((await request)['receipt'] as Map<String, dynamic>);
}
