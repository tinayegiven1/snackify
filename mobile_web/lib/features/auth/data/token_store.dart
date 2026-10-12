import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keeps the session token between app launches.
abstract interface class TokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> delete();
}

/// Android: encrypted with a key in the Android Keystore.
/// Web: the browser's local storage, encrypted with WebCrypto. A browser cannot fully protect
/// it from malicious scripts, which is one reason sessions expire after 12 hours.
class SecureTokenStore implements TokenStore {
  SecureTokenStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 'snackify_session_token';

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String token) => _storage.write(key: _key, value: token);

  @override
  Future<void> delete() => _storage.delete(key: _key);
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
