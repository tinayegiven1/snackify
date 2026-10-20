import '../../../core/network/api_client.dart';
import '../domain/organisation.dart';

/// The Head Office and its subsidiaries. Everyone sees the organisations they may access; adding
/// and changing them needs organisation.manage (the server checks).
class OrganisationsRepository {
  OrganisationsRepository(this._api);

  final ApiClient _api;

  Future<List<Organisation>> list({bool includeInactive = false}) async {
    final body = await _api.getJson(
      '/api/v1/organisations${includeInactive ? '?includeInactive=true' : ''}',
    );
    return (body['organisations'] as List)
        .map((item) => Organisation.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// [fields] uses the API's names: code, name, contactName, contactPhone, contactEmail,
  /// address, billingName, billingAddress, taxNumber, existingCustomerId.
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
