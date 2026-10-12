import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import '../domain/app_user.dart';
import 'token_store.dart';

/// Signs staff in and out through the backend, and remembers the session token.
class AuthRepository {
  AuthRepository({required ApiClient api, required TokenStore tokenStore})
    : _api = api,
      _tokenStore = tokenStore;

  final ApiClient _api;
  final TokenStore _tokenStore;

  /// Called when the server rejects the saved session while the app is in use.
  set onSessionExpired(VoidCallback? callback) => _api.onSessionExpired = callback;

  Future<AppUser> signIn(String username, String password) async {
    final body = await _api.postJson('/api/v1/auth/login', {
      'username': username,
      'password': password,
    });
    final token = body['token'] as String;
    await _tokenStore.write(token);
    _api.authToken = token;
    return AppUser.fromJson(body['user'] as Map<String, dynamic>);
  }

  /// Returns the user for a saved session, or null if there is none or it has ended.
  Future<AppUser?> restoreSession() async {
    final token = await _tokenStore.read();
    if (token == null) return null;

    _api.authToken = token;
    try {
      final body = await _api.getJson('/api/v1/auth/me');
      return AppUser.fromJson(body['user'] as Map<String, dynamic>);
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        await forgetSession();
        return null;
      }
      rethrow;
    }
  }

  /// Ends the session on the server (if reachable) and on this device.
  Future<void> signOut() async {
    try {
      await _api.postJson('/api/v1/auth/logout');
    } on ApiException {
      // Still sign out on this device; the server session expires on its own.
    }
    await forgetSession();
  }

  /// Removes the session from this device only.
  Future<void> forgetSession() async {
    _api.authToken = null;
    await _tokenStore.delete();
  }
}
