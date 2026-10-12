import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_app.dart';

void main() {
  testWidgets('shows the dashboard with a clear sample-data notice', (tester) async {
    await pumpSnackify(tester, signedIn: true);

    expect(find.widgetWithText(AppBar, 'Dashboard'), findsOneWidget);
    expect(find.textContaining('Sample data only'), findsOneWidget);
    expect(find.text('Dispatch value (confirmed)'), findsOneWidget);
    expect(find.text('Invoiced this week'), findsOneWidget);
    expect(find.text('Payments received this week'), findsOneWidget);
  });

  testWidgets('phone layout uses a drawer and a low-stock list', (tester) async {
    await pumpSnackify(tester, signedIn: true);

    expect(find.byType(DataTable), findsNothing);
    expect(find.text('Dispatches'), findsNothing);

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dispatches'));
    await tester.pumpAndSettle();

    expect(find.byType(Drawer), findsNothing);
    expect(find.widgetWithText(AppBar, 'Dispatches'), findsOneWidget);
    expect(find.text('Dispatches is coming soon'), findsOneWidget);
  });

  testWidgets('wide layout uses a permanent sidebar and a low-stock table', (tester) async {
    await pumpSnackify(tester, signedIn: true, size: desktopSize);

    expect(find.byTooltip('Open navigation menu'), findsNothing);
    expect(find.byType(DataTable), findsOneWidget);
    expect(find.text('Tendai Moyo'), findsOneWidget);

    await tester.tap(find.text('Invoices'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Invoices'), findsOneWidget);
    expect(find.text('Invoices is coming soon'), findsOneWidget);
  });

  testWidgets('shows API online when the backend health check passes', (tester) async {
    await pumpSnackify(tester, signedIn: true, apiHealthy: true);

    expect(find.text('API online'), findsOneWidget);
  });

  testWidgets('shows API offline when the backend cannot be reached', (tester) async {
    await pumpSnackify(tester, signedIn: true, apiHealthy: false);

    expect(find.text('API offline'), findsOneWidget);
  });

  testWidgets('login screen fits a small phone without overflowing', (tester) async {
    await pumpSnackify(tester, size: const Size(320, 568));

    expect(find.text('Sign in to Snackify'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // Layout overflows are reported as test failures, so this checks every signed-in screen.
  testWidgets('signed-in screens fit a small phone without overflowing', (tester) async {
    await pumpSnackify(tester, signedIn: true, size: const Size(320, 568));
    expect(find.widgetWithText(AppBar, 'Dashboard'), findsOneWidget);

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    // On a short screen the menu scrolls; "Sign out" must still be reachable.
    final menu = find.descendant(of: find.byType(Drawer), matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.text('Sign out'), 100, scrollable: menu);
    expect(find.text('Sign out'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Customers'), -100, scrollable: menu);
    await tester.tap(find.text('Customers'));
    await tester.pumpAndSettle();
    expect(find.text('No customers yet'), findsOneWidget);
  });
}
