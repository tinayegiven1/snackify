import '../../../core/network/api_client.dart';
import '../domain/payment_models.dart';

/// Payments and balances through the backend.
class PaymentsRepository {
  PaymentsRepository(this._api);

  final ApiClient _api;

  Future<List<PaymentSummary>> list({String search = '', String? customerId}) async {
    final query = Uri(
      queryParameters: {
        if (search.trim().isNotEmpty) 'q': search.trim(),
        'customerId': ?customerId,
        'limit': '200',
      },
    ).query;
    final body = await _api.getJson('/api/v1/payments?$query');
    return [
      for (final item in body['payments'] as List)
        PaymentSummary.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<Payment> get(String id) async {
    final body = await _api.getJson('/api/v1/payments/$id');
    return Payment.fromJson(body['payment'] as Map<String, dynamic>);
  }

  /// Records a payment and its allocations. [requestId] is chosen once per payment form: if
  /// the same payment is sent again (a double tap, or a retry after a dropped connection), the
  /// server returns the payment it already recorded instead of recording it twice.
  Future<Payment> record({
    required String requestId,
    required String customerId,
    required String paymentDate,
    required String amount,
    required PaymentMethod method,
    required String? reference,
    required String? notes,
    required List<AllocationInput> allocations,
  }) async {
    final body = await _api.postJson('/api/v1/payments', {
      'idempotencyKey': requestId,
      'customerId': customerId,
      'paymentDate': paymentDate,
      'amount': amount,
      'method': method.apiName,
      'reference': reference,
      'notes': notes,
      'allocations': [for (final allocation in allocations) allocation.toJson()],
    });
    return Payment.fromJson(body['payment'] as Map<String, dynamic>);
  }

  /// Applies unallocated credit from a payment to invoices.
  Future<Payment> allocate(String paymentId, List<AllocationInput> allocations) async {
    final body = await _api.postJson('/api/v1/payments/$paymentId/allocations', {
      'allocations': [for (final allocation in allocations) allocation.toJson()],
    });
    return Payment.fromJson(body['payment'] as Map<String, dynamic>);
  }

  /// Admins only.
  Future<Payment> voidPayment(String paymentId, String reason) async {
    final body = await _api.postJson('/api/v1/payments/$paymentId/void', {'reason': reason});
    return Payment.fromJson(body['payment'] as Map<String, dynamic>);
  }

  Future<({List<CustomerBalance> customers, BalanceMeasures totals})> balances() async {
    final body = await _api.getJson('/api/v1/balances');
    return (
      customers: [
        for (final item in body['customers'] as List)
          CustomerBalance.fromJson(item as Map<String, dynamic>),
      ],
      totals: BalanceMeasures.fromJson(body['totals'] as Map<String, dynamic>),
    );
  }

  /// The customer's account; the statement covers the last 90 days unless dates are given.
  Future<CustomerAccount> account(String customerId, {String? from, String? to}) async {
    final query = Uri(queryParameters: {'from': ?from, 'to': ?to}).query;
    final body = await _api.getJson(
      '/api/v1/balances/$customerId${query.isEmpty ? '' : '?$query'}',
    );
    return CustomerAccount.fromJson(body['account'] as Map<String, dynamic>);
  }
}
