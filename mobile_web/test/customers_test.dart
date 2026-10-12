import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_app.dart';

FakeBackend backendWithCustomers(String role) {
  return FakeBackend(role: role)
    ..addCustomer('C0001', 'Avondale Tuckshop', phone: '+263 77 123 4567')
    ..addCustomer('C0002', 'Mabelreign Grocers', address: '4 Harare Drive', creditLimit: '500.00')
    ..addCustomer('C0003', 'Closed Kiosk', isActive: false);
}

Future<void> openCustomer(WidgetTester tester, String name) async {
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}

Future<void> saveCustomer(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Save customer'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Save customer'));
  await tester.pumpAndSettle();
}

TextField fieldLabelled(WidgetTester tester, String label) => tester.widget<TextField>(
  find.descendant(of: find.widgetWithText(TextFormField, label), matching: find.byType(TextField)),
);

void main() {
  testWidgets('everyone sees active customers; storekeepers cannot add or edit', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: backendWithCustomers('storekeeper'));
    await openSection(tester, 'Customers');

    expect(find.text('Avondale Tuckshop'), findsOneWidget);
    expect(find.text('Limit USD 500.00'), findsOneWidget);
    expect(find.text('Closed Kiosk'), findsNothing);
    expect(find.text('2 customers'), findsOneWidget);
    expect(find.text('Add customer'), findsNothing);

    await openCustomer(tester, 'Avondale Tuckshop');
    expect(find.text('Edit customer'), findsNothing);
  });

  testWidgets('a salesperson adds a customer and the code is generated', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: backendWithCustomers('salesperson'),
    );
    await openSection(tester, 'Customers');
    await tester.tap(find.text('Add customer'));
    await tester.pumpAndSettle();

    // Credit limits are for accounts staff and admins.
    expect(fieldLabelled(tester, 'Credit limit (optional)').enabled, isFalse);
    expect(find.text('Only accounts staff and admins can change this.'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Customer name'), 'Borrowdale Spar');
    await tester.enterText(find.widgetWithText(TextFormField, 'Phone (optional)'), '0242 300 300');
    await saveCustomer(tester);

    expect(find.text('Saved Borrowdale Spar (C0004)'), findsOneWidget);
    expect(find.text('Borrowdale Spar'), findsOneWidget);
    expect(app.backend.customers.last, containsPair('creditLimit', null));
  });

  testWidgets('the form checks fields before sending anything', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: backendWithCustomers('salesperson'),
    );
    await openSection(tester, 'Customers');
    await tester.tap(find.text('Add customer'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Phone (optional)'), 'call me');
    await saveCustomer(tester);

    expect(find.text('Required'), findsOneWidget);
    expect(find.text('Use digits, spaces, brackets or dashes'), findsOneWidget);
    expect(app.backend.requests, isNot(contains('POST /api/v1/customers')));
  });

  testWidgets('a code already in use is reported on the Code field', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: backendWithCustomers('salesperson'));
    await openSection(tester, 'Customers');
    await tester.tap(find.text('Add customer'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Customer name'), 'Copycat');
    await tester.enterText(find.widgetWithText(TextFormField, 'Customer code (optional)'), 'c0001');
    await saveCustomer(tester);

    expect(find.text('Already used by another customer'), findsOneWidget);
    expect(find.text('Add customer'), findsOneWidget); // still on the form
  });

  testWidgets('accounts staff set a credit limit but cannot change details', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: backendWithCustomers('accounts'));
    await openSection(tester, 'Customers');
    expect(find.text('Add customer'), findsNothing);

    await openCustomer(tester, 'Avondale Tuckshop');
    expect(fieldLabelled(tester, 'Customer name').enabled, isFalse);
    expect(fieldLabelled(tester, 'Credit limit (optional)').enabled, isTrue);
    expect(find.text('Active'), findsNothing); // admins only

    await tester.enterText(find.widgetWithText(TextFormField, 'Credit limit (optional)'), '750');
    await saveCustomer(tester);

    // The fake server, like the real one, refuses any field accounts staff may not change,
    // so a successful save also shows that only the credit limit was sent.
    expect(find.text('Saved Avondale Tuckshop (C0001)'), findsOneWidget);
    expect(find.text('Limit USD 750.00'), findsOneWidget);
  });

  testWidgets('an admin deactivates a customer', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: backendWithCustomers('admin'));
    await openSection(tester, 'Customers');

    await openCustomer(tester, 'Avondale Tuckshop');
    await tester.ensureVisible(find.text('Active'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Active'));
    await saveCustomer(tester);

    expect(find.text('Avondale Tuckshop'), findsNothing);
    expect(find.text('1 customer'), findsOneWidget);

    await tester.tap(find.text('Show inactive'));
    await tester.pumpAndSettle();
    expect(find.text('Avondale Tuckshop'), findsOneWidget);
    expect(find.text('Inactive'), findsNWidgets(2));
  });

  testWidgets('searches by name, code or phone', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: backendWithCustomers('storekeeper'));
    await openSection(tester, 'Customers');

    await tester.enterText(find.byType(TextField).first, 'mabel');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Mabelreign Grocers'), findsOneWidget);
    expect(find.text('Avondale Tuckshop'), findsNothing);

    await tester.enterText(find.byType(TextField).first, '123 4567');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Avondale Tuckshop'), findsOneWidget);
  });

  testWidgets('wide screens show customers as a table', (tester) async {
    await pumpSnackify(
      tester,
      signedIn: true,
      size: desktopSize,
      backend: backendWithCustomers('admin'),
    );
    await openSection(tester, 'Customers');

    expect(find.byType(DataTable), findsOneWidget);
    expect(find.text('C0002'), findsOneWidget);
    expect(find.text('USD 500.00'), findsOneWidget);
  });

  testWidgets('customer screens fit a small phone without overflowing', (tester) async {
    await pumpSnackify(
      tester,
      signedIn: true,
      size: const Size(320, 568),
      backend: backendWithCustomers('admin'),
    );
    await openSection(tester, 'Customers');
    expect(find.text('Avondale Tuckshop'), findsOneWidget);

    await tester.tap(find.text('Add customer'));
    await tester.pumpAndSettle();
    expect(find.text('Save customer'), findsOneWidget);
  });
}
