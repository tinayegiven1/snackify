import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import '../data/auth_repository.dart';
import '../domain/app_user.dart';

enum AuthStatus { restoring, signedOut, signedIn }

/// Tracks who is signed in. The app shows the login screen or the main shell based on [status].
class AuthController extends ChangeNotifier {
  AuthController(this._repository) {
    _repository.onSessionExpired = _handleSessionExpired;
  }

  final AuthRepository _repository;

  AuthStatus _status = AuthStatus.restoring;
  AuthStatus get status => _status;

  AppUser? _user;
  AppUser? get user => _user;

  /// A message for the login screen, e.g. why the user was signed out.
  String? _notice;
  String? get notice => _notice;

  /// Checks for a saved session when the app starts.
  Future<void> restore() async {
    try {
      _user = await _repository.restoreSession();
      _status = _user == null ? AuthStatus.signedOut : AuthStatus.signedIn;
    } on ApiException catch (error) {
      _status = AuthStatus.signedOut;
      _notice = error.isNetworkError
          ? 'Cannot reach the Snackify server, so you need to sign in again.'
          : error.message;
      await _repository.forgetSession();
    }
    notifyListeners();
  }

  /// Throws [ApiException] with a user-friendly message if signing in fails.
  Future<void> signIn(String username, String password) async {
    _user = await _repository.signIn(username, password);
    _status = AuthStatus.signedIn;
    _notice = null;
    notifyListeners();
  }

  Future<void> signOut() async {
    await _repository.signOut();
    _user = null;
    _status = AuthStatus.signedOut;
    _notice = null;
    notifyListeners();
  }

  Future<void> _handleSessionExpired() async {
    if (_status != AuthStatus.signedIn) return;
    await _repository.forgetSession();
    _user = null;
    _status = AuthStatus.signedOut;
    _notice = 'Your session has ended. Please sign in again.';
    notifyListeners();
  }
}
