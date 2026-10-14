import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:snackify/core/network/api_client.dart';
import 'package:snackify/features/auth/data/auth_repository.dart';
import 'package:snackify/features/auth/data/token_store.dart';
import 'package:snackify/features/auth/presentation/auth_controller.dart';

/// Secure storage that fails the way Android's can, e.g. after a reinstall or a backup restore.
class BrokenSecureStorage extends Fake implements FlutterSecureStorage {
  BrokenSecureStorage({this.hang = false});

  final bool hang;
  final deleted = <String>[];

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (hang) return Completer<String?>().future; // never answers
    return Future.error(PlatformException(code: 'Exception', message: 'BAD_DECRYPT'));
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deleted.add(key);
  }
}

/// A token store that fails with something other than a network error.
class ExplodingTokenStore extends MemoryTokenStore {
  @override
  Future<String?> read() => Future.error(StateError('storage plugin crashed'));
}

AuthController controllerWith(TokenStore store) {
  final api = ApiClient(
    baseUrl: 'http://localhost:3000',
    httpClient: MockClient((_) async => http.Response('{}', 500)),
  );
  return AuthController(AuthRepository(api: api, tokenStore: store));
}

void main() {
  test('a saved sign-in that cannot be decrypted is cleared, not fatal', () async {
    final storage = BrokenSecureStorage();

    expect(await SecureTokenStore(storage).read(), isNull);
    expect(storage.deleted, ['snackify_session_token']);
  });

  test('secure storage that never answers is given up on', () async {
    final store = SecureTokenStore(
      BrokenSecureStorage(hang: true),
      const Duration(milliseconds: 50),
    );

    expect(await store.read(), isNull);
  });

  test('any failure while restoring the session leads to the sign-in screen', () async {
    final auth = controllerWith(ExplodingTokenStore());
    var notified = false;
    auth.addListener(() => notified = true);

    await auth.restore();

    expect(auth.status, AuthStatus.signedOut);
    expect(auth.user, isNull);
    expect(notified, isTrue);
  });
}
