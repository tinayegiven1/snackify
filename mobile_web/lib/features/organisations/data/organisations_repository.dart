import '../../../core/network/api_client.dart';
import '../domain/organisation.dart';

/// The Head Office and its subsidiaries. Everyone sees the organisations they may access; adding
/// and changing them needs organisation.manage, and changing a credit limit needs
/// organisation.edit_credit_limit (the server checks).
class OrganisationsRepository {
  OrganisationsRepository(this._api);

  final ApiClient _api;

  /// With [subsidiariesOnly], lists just the subsidiaries (the customers that dispatches,
  /// invoices and payments are for).
  Future<List<Organisation>> list({
    bool includeInactive = false,
    bool subsidiariesOnly = false,
  }) async {
    final query = Uri(
      queryParameters: {
        if (includeInactive) 'includeInactive': 'true',
        if (subsidiariesOnly) 'type': 'SUBSIDIARY',
      },
    ).query;
    final body = await _api.getJson('/api/v1/organisations${query.isEmpty ? '' : '?$query'}');
    return (body['organisations'] as List)
        .map((item) => Organisation.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// [fields] uses the API's names: code, name, contactName, contactPhone, contactEmail,
  /// address, billingName, billingAddress, taxNumber, whatsappNumber, creditLimit.
  Future<Organisation> create(Map<String, Object?> fields) async {
    final body = await _api.postJson('/api/v1/organisations', fields);
    return Organisation.fromJson(body['organisation'] as Map<String, dynamic>);
  }

  /// Sends only [changes]; fields that are left out keep their value.
  Future<Organisation> update(String id, Map<String, Object?> changes) async {
    final body = await _api.patchJson('/api/v1/organisations/$id', changes);
    return Organisation.fromJson(body['organisation'] as Map<String, dynamic>);
  }
}
