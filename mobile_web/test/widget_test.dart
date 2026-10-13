import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_app.dart';

/// BBQ (12 packs) is below its reorder level of 50; Cheese (40) is above its level of 5.
FakeBackend backendWithLowStock() => FakeBackend()
  ..addProduct('PC-BBQ-S', 'Potato Crisps', 'BBQ', 'Small', '0.50', reorderLevel: 50)
  ..addProduct('MP-CH-S', 'Maize Puffs', 'Cheese', 'Small', '0.30', reorderLevel: 5)
  ..addStock('PC-BBQ-S', 12)
  ..addStock('MP-CH-S', 40);

void main() {
  testWidgets('the dashboard shows today at a glance from the server', (tester) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: backendWithLowStock());

    expect(find.widgetWithText(AppBar, 'Dashboard'), findsOneWidget);
    expect(app.backend.requests, contains('GET /api/v1/reports/dashboard'));
    expect(find.text('Today at a glance'), findsOneWidget);
    expect(find.text('Dispatched today'), findsOneWidget);
    expect(find.text('1 product'), findsOneWidget); // low stock
    // Storekeepers do not see money.
    expect(find.text('Money'), findsNothing);
  });

  testWidgets('phone layout uses a drawer and a low-stock list', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: backendWithLowStock());

    expect(find.byType(DataTable), findsNothing);
    await tester.dragUntilVisible(
      find.text('12 left'),
      find.byType(SingleChildScrollView).first,
      const Offset(0, -300),
    );
    expect(find.text('Potato Crisps — BBQ — Small'), findsOneWidget);
    expect(find.text('Payments'), findsNothing);

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Customers'));
    await tester.pumpAndSettle();

    expect(find.byType(Drawer), findsNothing);
    expect(find.widgetWithText(AppBar, 'Customers'), findsOneWidget);
  });

  testWidgets('wide layout uses a permanent sidebar and a low-stock table', (tester) async {
    await pumpSnackify(tester, signedIn: true, size: desktopSize, backend: backendWithLowStock());

    expect(find.byTooltip('Open navigation menu'), findsNothing);
    expect(find.byType(DataTable), findsOneWidget);
    expect(find.text('Tendai Moyo'), findsOneWidget);

    await tester.tap(find.text('Customers'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Customers'), findsOneWidget);
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
