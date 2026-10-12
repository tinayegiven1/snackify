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

    await signInThroughForm(tester, testUsername, testPassword);

    expect(find.widgetWithText(AppBar, 'Dashboard'), findsOneWidget);
    expect(app.tokenStore.token, isNotNull);
    expect(app.backend.validTokens, contains(app.tokenStore.token));
  });

  testWidgets('shows the server message for a wrong password and stays on login', (tester) async {
    final app = await pumpSnackify(tester);

    await signInThroughForm(tester, testUsername, 'not the password');

    expect(find.text('Incorrect username or password.'), findsOneWidget);
    expect(find.text('Sign in to Snackify'), findsOneWidget);
    expect(app.tokenStore.token, isNull);
  });

  testWidgets('asks for both fields before contacting the server', (tester) async {
    final app = await pumpSnackify(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Enter your username'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);
    expect(app.backend.requests, isNot(contains('POST /api/v1/auth/login')));
  });

  testWidgets('explains when the server cannot be reached', (tester) async {
    final app = await pumpSnackify(tester);
    app.backend.reachable = false;

    await signInThroughForm(tester, testUsername, testPassword);

    expect(
      find.text('Cannot reach the Snackify server. Check your connection and try again.'),
      findsOneWidget,
    );
  });

  testWidgets('can show the password while typing', (tester) async {
    await pumpSnackify(tester);
    TextField passwordField() => tester.widget<TextField>(
      find.descendant(
        of: find.widgetWithText(TextFormField, 'Password'),
        matching: find.byType(TextField),
      ),
    );

    expect(passwordField().obscureText, isTrue);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(passwordField().obscureText, isFalse);
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
    expect(find.text('Storekeeper'), findsOneWidget);

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

    // For example, an admin deactivated the account or reset the password.
    app.backend.validTokens.clear();
    await expectLater(app.api.getJson('/api/v1/auth/me'), throwsA(isA<ApiException>()));
    await tester.pumpAndSettle();

    expect(find.text('Sign in to Snackify'), findsOneWidget);
    expect(find.text('Your session has ended. Please sign in again.'), findsOneWidget);
    expect(app.tokenStore.token, isNull);
  });
}
