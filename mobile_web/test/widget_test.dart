import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snackify/app.dart';

const _phone = Size(390, 844);
const _desktop = Size(1280, 800);

Future<void> _pumpApp(WidgetTester tester, {required Size size, bool apiHealthy = true}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(SnackifyApp(checkBackendHealth: () async => apiHealthy));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the dashboard with a clear sample-data notice', (tester) async {
    await _pumpApp(tester, size: _phone);

    expect(find.widgetWithText(AppBar, 'Dashboard'), findsOneWidget);
    expect(find.textContaining('Sample data only'), findsOneWidget);
    expect(find.text('Dispatch value (confirmed)'), findsOneWidget);
    expect(find.text('Invoiced this week'), findsOneWidget);
    expect(find.text('Payments received this week'), findsOneWidget);
  });

  testWidgets('phone layout uses a drawer and a low-stock list', (tester) async {
    await _pumpApp(tester, size: _phone);

    expect(find.byType(DataTable), findsNothing);
    expect(find.text('Customers'), findsNothing);

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Customers'));
    await tester.pumpAndSettle();

    expect(find.byType(Drawer), findsNothing);
    expect(find.widgetWithText(AppBar, 'Customers'), findsOneWidget);
    expect(find.text('Customers is coming soon'), findsOneWidget);
  });

  testWidgets('wide layout uses a permanent sidebar and a low-stock table', (tester) async {
    await _pumpApp(tester, size: _desktop);

    expect(find.byTooltip('Open navigation menu'), findsNothing);
    expect(find.byType(DataTable), findsOneWidget);

    await tester.tap(find.text('Invoices'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Invoices'), findsOneWidget);
    expect(find.text('Invoices is coming soon'), findsOneWidget);
  });

  testWidgets('shows API online when the backend health check passes', (tester) async {
    await _pumpApp(tester, size: _phone, apiHealthy: true);

    expect(find.text('API online'), findsOneWidget);
  });

  testWidgets('shows API offline when the backend cannot be reached', (tester) async {
    await _pumpApp(tester, size: _phone, apiHealthy: false);

    expect(find.text('API offline'), findsOneWidget);
  });
}
