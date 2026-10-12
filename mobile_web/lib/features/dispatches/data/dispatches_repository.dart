import '../../../core/network/api_client.dart';
import '../domain/dispatch_models.dart';

/// Dispatches through the backend: drafts, confirming, cancelling and reversing.
class DispatchesRepository {
  DispatchesRepository(this._api);

  final ApiClient _api;

  Future<({List<DispatchSummary> dispatches, int total})> list({
    DispatchStatus? status,
    String search = '',
  }) async {
    final query = Uri(
      queryParameters: {
        'status': ?status?.name,
        if (search.trim().isNotEmpty) 'q': search.trim(),
        'limit': '200',
      },
    ).query;
    final body = await _api.getJson('/api/v1/dispatches?$query');
    return (
      dispatches: (body['dispatches'] as List)
          .map((item) => DispatchSummary.fromJson(item as Map<String, dynamic>))
          .toList(),
      total: body['total'] as int,
    );
  }

  Future<Dispatch> get(String id) async {
    final body = await _api.getJson('/api/v1/dispatches/$id');
    return Dispatch.fromJson(body['dispatch'] as Map<String, dynamic>);
  }

  Map<String, Object?> _draftJson({
    required String customerId,
    required String dispatchDate,
    required String? notes,
    required List<DraftLine> lines,
  }) => {
    'customerId': customerId,
    'dispatchDate': dispatchDate,
    'notes': notes,
    'items': [for (final line in lines) line.toJson()],
  };

  Future<Dispatch> createDraft({
    required String customerId,
    required String dispatchDate,
    required String? notes,
    required List<DraftLine> lines,
  }) async {
    final body = await _api.postJson(
      '/api/v1/dispatches',
      _draftJson(customerId: customerId, dispatchDate: dispatchDate, notes: notes, lines: lines),
    );
    return Dispatch.fromJson(body['dispatch'] as Map<String, dynamic>);
  }

  Future<Dispatch> updateDraft(
    String id, {
    required String customerId,
    required String dispatchDate,
    required String? notes,
    required List<DraftLine> lines,
  }) async {
    final body = await _api.putJson(
      '/api/v1/dispatches/$id',
      _draftJson(customerId: customerId, dispatchDate: dispatchDate, notes: notes, lines: lines),
    );
    return Dispatch.fromJson(body['dispatch'] as Map<String, dynamic>);
  }

  /// Throws [ApiException] with code CREDIT_LIMIT_EXCEEDED when the customer would go over
  /// their limit and [acknowledgeCreditLimit] is false.
  Future<Dispatch> confirm(String id, {bool acknowledgeCreditLimit = false}) async {
    final body = await _api.postJson('/api/v1/dispatches/$id/confirm', {
      'acknowledgeCreditLimit': acknowledgeCreditLimit,
    });
    return Dispatch.fromJson(body['dispatch'] as Map<String, dynamic>);
  }

  Future<Dispatch> cancel(String id, String reason) async {
    final body = await _api.postJson('/api/v1/dispatches/$id/cancel', {'reason': reason});
    return Dispatch.fromJson(body['dispatch'] as Map<String, dynamic>);
  }

  Future<Dispatch> reverse(String id, String reason) async {
    final body = await _api.postJson('/api/v1/dispatches/$id/reverse', {'reason': reason});
    return Dispatch.fromJson(body['dispatch'] as Map<String, dynamic>);
  }
}
