import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snackify/core/network/api_client.dart';

import 'helpers/test_app.dart';

void main() {
  testWidgets('shows the login screen when nobody is signed in', (tester) async {
    await pumpSnackify(tester);

    expect(find.text('Sign in to Snackify'), findsOneWidget);
    expect(find.text('Dashboard'), findsNothing);
  });

  testWidgets('signs in and opens the dashboard, remembering the session', (tester) async {
    final app = await pumpSnackify(tester);

    await signInThroughForm(tester, testUsername, testPin);

    expect(find.widgetWithText(AppBar, 'Dashboard'), findsOneWidget);
    expect(app.tokenStore.token, isNotNull);
    expect(app.backend.validTokens, contains(app.tokenStore.token));
  });

  testWidgets('shows the server message for a wrong PIN and stays on login', (tester) async {
    final app = await pumpSnackify(tester);

    await signInThroughForm(tester, testUsername, '9999');

    expect(find.text('Incorrect username or PIN.'), findsOneWidget);
    expect(find.text('Sign in to Snackify'), findsOneWidget);
    expect(app.tokenStore.token, isNull);
  });

  testWidgets('asks for both fields before contacting the server', (tester) async {
    final app = await pumpSnackify(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Enter your username'), findsOneWidget);
    expect(find.text('Enter your PIN'), findsOneWidget);
    expect(app.backend.requests, isNot(contains('POST /api/v1/auth/login')));
  });

  testWidgets('explains when the server cannot be reached', (tester) async {
    final app = await pumpSnackify(tester);
    app.backend.reachable = false;

    await signInThroughForm(tester, testUsername, testPin);

    expect(
      find.text('Cannot reach the Snackify server. Check your connection and try again.'),
      findsOneWidget,
    );
  });

  testWidgets('takes digits only for the PIN, hidden unless shown', (tester) async {
    await pumpSnackify(tester);
    TextField pinField() => tester.widget<TextField>(
      find.descendant(
        of: find.widgetWithText(TextFormField, 'PIN'),
        matching: find.byType(TextField),
      ),
    );

    await tester.enterText(find.widgetWithText(TextFormField, 'PIN'), '48a2b6');
    expect(pinField().controller!.text, '4826');
    expect(pinField().keyboardType, TextInputType.number);
    expect(pinField().obscureText, isTrue);
    await tester.tap(find.byTooltip('Show PIN'));
    await tester.pump();
    expect(pinField().obscureText, isFalse);
  });

  testWidgets('the first sign-in with 1234 asks for a new PIN before anything else', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..pin = '1234'
      ..mustChangePin = true;
    final app = await pumpSnackify(tester, backend: backend);

    await signInThroughForm(tester, testUsername, '1234');
    expect(find.text('Choose your PIN'), findsOneWidget);
    expect(find.text('Dashboard'), findsNothing);

    Finder pinBox(String label) => find.widgetWithText(TextFormField, label);
    await tester.enterText(pinBox('New PIN'), '1111');
    await tester.enterText(pinBox('New PIN again'), '1111');
    await tester.tap(find.text('Save my PIN'));
    await tester.pumpAndSettle();
    expect(find.text('Too easy to guess: avoid 1234, 0000, 4321 and the like'), findsOneWidget);

    await tester.enterText(pinBox('New PIN'), '5830');
    await tester.enterText(pinBox('New PIN again'), '5830');
    await tester.tap(find.text('Save my PIN'));
    await tester.pumpAndSettle();

    expect(backend.pinsSet, [(backend.user['id'], '5830')]);
    expect(find.widgetWithText(AppBar, 'Dashboard'), findsOneWidget);
    expect(app.backend.requests, contains('POST /api/v1/auth/change-pin'));
  });

  testWidgets('a saved session still on the starting PIN opens on "Choose your PIN"', (
    tester,
  ) async {
    final backend = FakeBackend()..mustChangePin = true;
    await pumpSnackify(tester, signedIn: true, backend: backend);

    expect(find.text('Choose your PIN'), findsOneWidget);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to Snackify'), findsOneWidget);
  });

  testWidgets('opens straight to the dashboard when a saved session is still valid', (
    tester,
  ) async {
    final app = await pumpSnackify(tester, signedIn: true);

    expect(find.widgetWithText(AppBar, 'Dashboard'), findsOneWidget);
    expect(app.backend.requests, contains('GET /api/v1/auth/me'));
  });

  testWidgets('forgets a saved session the server no longer accepts', (tester) async {
    final app = await pumpSnackify(tester, savedToken: 'expired'.padRight(43, 'x'));

    expect(find.text('Sign in to Snackify'), findsOneWidget);
    expect(app.tokenStore.token, isNull);
  });

  testWidgets('shows who is signed in, and signs out', (tester) async {
    final app = await pumpSnackify(tester, signedIn: true);

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.text('Tendai Moyo'), findsOneWidget);
    // Their roles and organisation.
    expect(find.text('HQ Warehouse Officer\nHead Office'), findsOneWidget);

    // The menu scrolls on a small phone.
    await tester.ensureVisible(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(find.text('Sign in to Snackify'), findsOneWidget);
    expect(app.tokenStore.token, isNull);
    expect(app.backend.requests, contains('POST /api/v1/auth/logout'));
    expect(app.backend.validTokens, isEmpty);
  });

  testWidgets('returns to login with an explanation when the session ends during use', (
    tester,
  ) async {
    final app = await pumpSnackify(tester, signedIn: true);

    // For example, an admin deactivated the account or reset the PIN.
    app.backend.validTokens.clear();
    await expectLater(app.api.getJson('/api/v1/auth/me'), throwsA(isA<ApiException>()));
    await tester.pumpAndSettle();

    expect(find.text('Sign in to Snackify'), findsOneWidget);
    expect(find.text('Your session has ended. Please sign in again.'), findsOneWidget);
    expect(app.tokenStore.token, isNull);
  });
}
