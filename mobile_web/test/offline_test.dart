import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snackify/core/network/api_client.dart';
import 'package:snackify/core/network/response_cache.dart';
import 'package:snackify/core/network/sync_service.dart';
import 'package:snackify/features/auth/data/auth_repository.dart';
import 'package:snackify/features/auth/data/token_store.dart';

import 'helpers/test_app.dart';

// Offline: the phone shows what it last saw, and says that changes need a connection.

/// An API on [backend], keeping copies in memory.
ApiClient apiOn(FakeBackend backend, {String? token}) =>
    ApiClient(baseUrl: 'http://api.test', httpClient: backend.client, cache: MemoryResponseCache())
      ..authToken = token;

void main() {
  group('the API client', () {
    test('answers with the saved copy when the server cannot be reached', () async {
      final backend = FakeBackend()
        ..addProduct('PC-BBQ-S', 'Potato Crisps', 'BBQ', 'Small', '0.50');
      final api = apiOn(backend, token: backend.issueToken());

      final online = await api.getJson('/api/v1/products?limit=200');
      expect(api.connection.offline, isFalse);

      backend.offline = true;
      final offline = await api.getJson('/api/v1/products?limit=200');
      expect(offline, online);
      expect(api.connection.offline, isTrue);
      expect(api.connection.showingFrom, isNotNull);

      // Something never fetched before cannot be shown.
      await expectLater(
        api.getJson('/api/v1/organisations'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.isNetworkError, 'network error', isTrue)
              .having((e) => e.message, 'message', contains('has not been saved on this device')),
        ),
      );
      // Changes are refused plainly.
      await expectLater(
        api.postJson('/api/v1/purchases', {}),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            'Cannot reach the Snackify server. Check your connection and try again.',
          ),
        ),
      );
      // Whether the server is up is never answered from a copy.
      await expectLater(api.getJson('/api/v1/health'), throwsA(isA<ApiException>()));

      backend.offline = false;
      await api.getJson('/api/v1/health');
      expect(api.connection.offline, isFalse);
      expect(api.connection.showingFrom, isNull);
    });

    test('never hides real answers from the server behind a copy', () async {
      final backend = FakeBackend();
      final api = apiOn(backend, token: backend.issueToken());
      await api.getJson('/api/v1/products?limit=200');
      // Signed out on the server: the 401 comes through, not yesterday's list.
      api.authToken = 'not-a-valid-token-xxxxxxxxxxxxxxxxxxxxxxxxxx';
      await expectLater(
        api.getJson('/api/v1/products?limit=200'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)),
      );
    });
  });

  group('signing in and out', () {
    test('a saved session opens offline, from the copy saved last time', () async {
      final backend = FakeBackend();
      final token = backend.issueToken();
      final api = apiOn(backend);
      final store = MemoryTokenStore(token);
      final repository = AuthRepository(api: api, tokenStore: store);
      expect((await repository.restoreSession())?.fullName, 'Tendai Moyo');

      backend.offline = true;
      expect((await repository.restoreSession())?.fullName, 'Tendai Moyo');
    });

    test('each sign-in and every sign-out wipes what was saved', () async {
      final backend = FakeBackend();
      final api = apiOn(backend);
      final repository = AuthRepository(api: api, tokenStore: MemoryTokenStore());
      await repository.signIn(testUsername, testPin);
      await api.getJson('/api/v1/organisations');
      expect(await api.cache!.read('/api/v1/organisations'), isNotNull);

      await repository.signOut();
      expect(await api.cache!.read('/api/v1/organisations'), isNull);

      await repository.signIn(testUsername, testPin);
      await api.getJson('/api/v1/organisations');
      await repository.signIn(testUsername, testPin); // someone else signs in on this phone
      expect(await api.cache!.read('/api/v1/organisations'), isNull);
    });
  });

  test('copies saved on the phone survive a restart and can be wiped', () async {
    final folder = await Directory.systemTemp.createTemp('snackify-offline-');
    addTearDown(() => folder.delete(recursive: true));
    final cache = FileResponseCache(baseFolder: () async => folder);
    final body = jsonEncode({'products': <Object>[], 'total': 0});
    await cache.write('/api/v1/products?limit=200', body);

    final afterRestart = FileResponseCache(baseFolder: () async => folder);
    final copy = await afterRestart.read('/api/v1/products?limit=200');
    expect(copy?.body, body);
    expect(await afterRestart.read('/api/v1/organisations'), isNull);

    await afterRestart.clear();
    expect(
      await FileResponseCache(baseFolder: () async => folder).read('/api/v1/products?limit=200'),
      isNull,
    );
  });

  test('while offline it keeps checking, and catches up once the server is back', () async {
    final backend = FakeBackend();
    final api = apiOn(backend, token: backend.issueToken());
    var refreshed = 0;
    final sync = SyncService(
      api: api,
      checkHealth: () async {
        try {
          return (await api.getJson('/api/v1/health'))['status'] == 'ok';
        } on ApiException {
          return false;
        }
      },
      refreshers: [() async => refreshed++],
      retryEvery: const Duration(milliseconds: 20),
    );
    addTearDown(sync.dispose);

    backend.offline = true;
    await expectLater(api.getJson('/api/v1/organisations'), throwsA(isA<ApiException>()));
    expect(api.connection.offline, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(refreshed, 0); // still unreachable

    backend.offline = false;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(api.connection.offline, isFalse);
    expect(refreshed, greaterThan(0));
    expect(api.connection.refreshes, 1);
  });

  testWidgets('offline, the app shows what it saved, says so, and catches up when back', (
    tester,
  ) async {
    final backend = FakeBackend(role: 'storekeeper')
      ..addProduct('PC-BBQ-S', 'Potato Crisps', 'BBQ', 'Small', '0.50')
      ..addStock('PC-BBQ-S', 40);
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Stock');
    expect(find.text('Potato Crisps — BBQ — Small'), findsOneWidget);

    // The connection drops, then stock changes on the server meanwhile.
    backend.offline = true;
    await openSection(tester, 'Products');
    expect(find.textContaining('Offline. Showing information from'), findsOneWidget);
    expect(find.textContaining('Changes need a connection.'), findsOneWidget);
    expect(find.text('Potato Crisps — BBQ'), findsOneWidget); // saved when the app opened

    // A section never opened while online has nothing to show yet.
    await openSection(tester, 'Goods Received');
    expect(find.textContaining('has not been saved on this device yet'), findsOneWidget);

    // Back online: "Try now" catches up and the banner goes.
    backend
      ..offline = false
      ..addStock('PC-BBQ-S', 10);
    await tester.tap(find.text('Try now'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Offline.'), findsNothing);
    await openSection(tester, 'Stock');
    expect(find.text('50'), findsOneWidget);
  });
}
