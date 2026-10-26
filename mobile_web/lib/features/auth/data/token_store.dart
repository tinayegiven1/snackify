import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'browser_session_stub.dart' if (dart.library.js_interop) 'browser_session_web.dart';

/// Keeps the session token between app launches.
abstract interface class TokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> delete();
}

/// The store for this device. A web page opened by a network address over plain http (as on
/// the office Wi-Fi) cannot use the encrypted store, so the token is kept in that browser tab
/// instead: it survives reloading the page and is forgotten when the tab is closed.
TokenStore deviceTokenStore() =>
    kIsWeb && !browserCanEncrypt ? const TabTokenStore() : SecureTokenStore();

/// Android: encrypted with a key in the Android Keystore.
/// Web: the browser's local storage, encrypted with WebCrypto. A browser cannot fully protect
/// it from malicious scripts, which is one reason sessions expire after 12 hours.
class SecureTokenStore implements TokenStore {
  SecureTokenStore([FlutterSecureStorage? storage, this.readTimeout = const Duration(seconds: 5)])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 'snackify_session_token';

  /// How long to wait for the phone's secure storage before giving up.
  final Duration readTimeout;

  /// The saved token, or null. A token that cannot be read (for example because the phone's
  /// encryption key was lost when the app was reinstalled or restored from a backup) is deleted,
  /// so the person simply signs in again instead of the app waiting forever.
  @override
  Future<String?> read() async {
    try {
      return await _storage.read(key: _key).timeout(readTimeout);
    } on Object catch (error) {
      debugPrint('Saved session could not be read, so it is cleared: $error');
      unawaited(_storage.delete(key: _key).catchError((Object _) {}));
      return null;
    }
  }

  @override
  Future<void> write(String token) => _storage.write(key: _key, value: token);

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

/// Web pages that are not "secure" (plain http by a network address): the tab's session
/// storage, cleared when the tab closes.
class TabTokenStore implements TokenStore {
  const TabTokenStore();

  static const _key = 'snackify_session_token';

  @override
  Future<String?> read() async => readTabSession(_key);

  @override
  Future<void> write(String token) async => writeTabSession(_key, token);

  @override
  Future<void> delete() async => deleteTabSession(_key);
}

/// Keeps the token in memory only. Used in tests.
class MemoryTokenStore implements TokenStore {
  MemoryTokenStore([this.token]);

  String? token;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> write(String token) async {
    this.token = token;
  }

  @override
  Future<void> delete() async {
    token = null;
  }
}
