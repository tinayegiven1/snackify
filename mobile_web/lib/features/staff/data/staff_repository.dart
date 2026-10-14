import '../../../core/network/api_client.dart';
import '../../auth/domain/app_user.dart';
import '../domain/staff_member.dart';

/// Staff accounts, through the backend. Admins only (the server checks).
class StaffRepository {
  StaffRepository(this._api);

  final ApiClient _api;

  /// Everyone, active accounts first.
  Future<List<StaffMember>> list() async {
    final body = await _api.getJson('/api/v1/users');
    return (body['users'] as List)
        .map((item) => StaffMember.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<StaffMember> create({
    required String username,
    required String fullName,
    required StaffRole role,
    required String password,
  }) async {
    final body = await _api.postJson('/api/v1/users', {
      'username': username,
      'fullName': fullName,
      'role': role.name,
      'password': password,
    });
    return StaffMember.fromJson(body['user'] as Map<String, dynamic>);
  }

  /// Sends only the given changes. Deactivating signs the person out everywhere.
  Future<StaffMember> update(String id, {String? fullName, StaffRole? role, bool? isActive}) async {
    final body = await _api.patchJson('/api/v1/users/$id', {
      'fullName': ?fullName,
      'role': ?role?.name,
      'isActive': ?isActive,
    });
    return StaffMember.fromJson(body['user'] as Map<String, dynamic>);
  }

  /// Gives someone else a new password and signs them out everywhere.
  Future<void> resetPassword(String id, String newPassword) async {
    await _api.postJson('/api/v1/users/$id/reset-password', {'newPassword': newPassword});
  }
}
