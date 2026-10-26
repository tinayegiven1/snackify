import '../../../core/network/api_client.dart';
import '../domain/staff_member.dart';

/// Staff accounts and roles, through the backend (permission user.manage; the server checks).
class StaffRepository {
  StaffRepository(this._api);

  final ApiClient _api;

  /// Everyone the admin may see, active accounts first.
  Future<List<StaffMember>> list() async {
    final body = await _api.getJson('/api/v1/users');
    return (body['users'] as List)
        .map((item) => StaffMember.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// The roles that can be given.
  Future<List<RoleOption>> roles() async {
    final body = await _api.getJson('/api/v1/roles');
    return (body['roles'] as List)
        .map((item) => RoleOption.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<StaffMember> create({
    required String username,
    required String fullName,
    required String organisationId,
    required List<String> roleCodes,
  }) async {
    // New accounts start on the PIN 1234 and choose their own at the first sign-in.
    final body = await _api.postJson('/api/v1/users', {
      'username': username,
      'fullName': fullName,
      'organisationId': organisationId,
      'roleCodes': roleCodes,
    });
    return StaffMember.fromJson(body['user'] as Map<String, dynamic>);
  }

  /// Sends only the given changes. Deactivating or moving someone signs them out everywhere.
  Future<StaffMember> update(
    String id, {
    String? fullName,
    String? organisationId,
    List<String>? roleCodes,
    bool? isActive,
  }) async {
    final body = await _api.patchJson('/api/v1/users/$id', {
      'fullName': ?fullName,
      'organisationId': ?organisationId,
      'roleCodes': ?roleCodes,
      'isActive': ?isActive,
    });
    return StaffMember.fromJson(body['user'] as Map<String, dynamic>);
  }

  /// Puts someone back on the PIN 1234 (they choose a new one at their next sign-in), unlocks
  /// their account and signs them out everywhere.
  Future<void> resetPin(String id) async {
    await _api.postJson('/api/v1/users/$id/reset-pin');
  }
}
