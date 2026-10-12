import '../../../core/network/api_client.dart';
import '../domain/customer.dart';

/// Reads and changes customers through the backend.
class CustomersRepository {
  CustomersRepository(this._api);

  final ApiClient _api;

  static const pageSize = 200;

  Future<({List<Customer> customers, int total})> list({
    String search = '',
    bool includeInactive = false,
  }) async {
    final query = Uri(
      queryParameters: {
        if (search.trim().isNotEmpty) 'q': search.trim(),
        if (includeInactive) 'includeInactive': 'true',
        'limit': '$pageSize',
      },
    ).query;
    final body = await _api.getJson('/api/v1/customers?$query');
    return (
      customers: (body['customers'] as List)
          .map((item) => Customer.fromJson(item as Map<String, dynamic>))
          .toList(),
      total: body['total'] as int,
    );
  }

  /// [fields] uses the API's names: code, name, phone, address, creditLimit.
  Future<Customer> create(Map<String, Object?> fields) async {
    final body = await _api.postJson('/api/v1/customers', fields);
    return Customer.fromJson(body['customer'] as Map<String, dynamic>);
  }

  /// Sends only [changes]; fields that are left out keep their value.
  Future<Customer> update(String id, Map<String, Object?> changes) async {
    final body = await _api.patchJson('/api/v1/customers/$id', changes);
    return Customer.fromJson(body['customer'] as Map<String, dynamic>);
  }
}
