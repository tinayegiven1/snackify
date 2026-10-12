import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_app.dart';

/// Two products in stock (BBQ 100, Cheese 50) and two customers: Avondale has a credit limit
/// of 10.00, Mabelreign has none.
FakeBackend backendForDispatches(String role) {
  return FakeBackend(role: role)
    ..addProduct('PC-BBQ-S', 'Potato Crisps', 'BBQ', 'Small', '0.50')
    ..addProduct('MP-CH-S', 'Maize Puffs', 'Cheese', 'Small', '0.30')
    ..addStock('PC-BBQ-S', 100)
    ..addStock('MP-CH-S', 50)
    ..addCustomer('C0001', 'Avondale Tuckshop', creditLimit: '10.00')
    ..addCustomer('C0002', 'Mabelreign Grocers');
}

Future<void> openDispatch(WidgetTester tester, String title) async {
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

Future<void> tapButton(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a salesperson creates a draft; it does not touch stock', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: backendForDispatches('salesperson'),
    );
    await openSection(tester, 'Dispatches');
    expect(find.text('No dispatches found'), findsOneWidget);

    await tester.tap(find.text('New dispatch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a customer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mabelreign Grocers'));
    await tester.pumpAndSettle();
    await tapButton(tester, 'Add product');
    await tester.tap(find.text('Potato Crisps — BBQ — Small'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Packs'), '12');
    await tester.pumpAndSettle();
    expect(find.text('Total USD 6.00'), findsOneWidget);

    await tapButton(tester, 'Save draft');

    // The new draft opens, with its number, total and no Confirm button for salespeople.
    expect(find.text('D000001'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('Mabelreign Grocers (C0002)'), findsOneWidget);
    expect(find.text('12 × USD 0.50 · in stock: 100'), findsOneWidget);
    expect(find.text('Confirm dispatch'), findsNothing);
    expect(app.backend.onHand('product-1'), 100);
  });

  testWidgets('the editor asks for a customer and at least one product', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: backendForDispatches('salesperson'),
    );
    await openSection(tester, 'Dispatches');
    await tester.tap(find.text('New dispatch'));
    await tester.pumpAndSettle();

    await tapButton(tester, 'Save draft');

    expect(find.text('Choose a customer'), findsWidgets);
    expect(find.text('Add at least one product'), findsOneWidget);
    expect(app.backend.requests, isNot(contains('POST /api/v1/dispatches')));
  });

  testWidgets('a storekeeper confirms a draft and stock is deducted', (tester) async {
    final backend = backendForDispatches('storekeeper')
      ..addDraft('C0002', {'PC-BBQ-S': 12, 'MP-CH-S': 5});
    final app = await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Dispatches');
    await openDispatch(tester, 'D000001 · Mabelreign Grocers');

    await tapButton(tester, 'Confirm dispatch');
    expect(find.text('Confirm dispatch?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();

    expect(find.text('D000001 confirmed. Stock has been updated.'), findsOneWidget);
    expect(find.text('Confirmed'), findsOneWidget);
    expect(find.text('Confirm dispatch'), findsNothing);
    expect(app.backend.onHand('product-1'), 88);
    expect(app.backend.onHand('product-2'), 45);
  });

  testWidgets('shows a shortage on the draft and the server refusing it', (tester) async {
    final backend = backendForDispatches('storekeeper')..addDraft('C0002', {'PC-BBQ-S': 120});
    final app = await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Dispatches');
    await openDispatch(tester, 'D000001 · Mabelreign Grocers');

    expect(find.text('Not enough stock for: Potato Crisps — BBQ — Small.'), findsOneWidget);

    await tapButton(tester, 'Confirm dispatch');
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();

    expect(
      find.text('Not enough stock for: Potato Crisps — BBQ — Small (need 120, have 100).'),
      findsOneWidget,
    );
    expect(find.text('Draft'), findsOneWidget);
    expect(app.backend.onHand('product-1'), 100);
  });

  testWidgets('warns about the credit limit and allows confirming anyway', (tester) async {
    final backend = backendForDispatches('storekeeper')..addDraft('C0001', {'PC-BBQ-S': 24});
    final app = await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Dispatches');
    await openDispatch(tester, 'D000001 · Avondale Tuckshop');

    expect(
      find.textContaining('Over credit limit: confirming takes the unpaid balance to USD 12.00'),
      findsOneWidget,
    );

    await tapButton(tester, 'Confirm dispatch');
    expect(find.text('Over credit limit'), findsOneWidget);
    await tester.tap(find.text('Confirm anyway'));
    await tester.pumpAndSettle();

    expect(find.text('Confirmed'), findsOneWidget);
    expect(find.text('Confirmed by Tendai Moyo (over the credit limit)'), findsOneWidget);
    expect(app.backend.dispatches.single['confirmedOverCreditLimit'], isTrue);
  });

  testWidgets('going back from the credit warning confirms nothing', (tester) async {
    final backend = backendForDispatches('storekeeper')..addDraft('C0001', {'PC-BBQ-S': 24});
    final app = await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Dispatches');
    await openDispatch(tester, 'D000001 · Avondale Tuckshop');

    await tapButton(tester, 'Confirm dispatch');
    await tester.tap(find.text('Go back'));
    await tester.pumpAndSettle();

    expect(find.text('Draft'), findsOneWidget);
    expect(app.backend.onHand('product-1'), 100);
  });

  testWidgets('a draft can be cancelled with a reason', (tester) async {
    final backend = backendForDispatches('salesperson')..addDraft('C0002', {'PC-BBQ-S': 12});
    final app = await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Dispatches');
    await openDispatch(tester, 'D000001 · Mabelreign Grocers');

    await tapButton(tester, 'Cancel draft');
    await tester.enterText(find.widgetWithText(TextFormField, 'Reason'), 'Customer changed order');
    await tester.tap(find.text('Cancel dispatch'));
    await tester.pumpAndSettle();

    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('Cancelled: Customer changed order'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(app.backend.dispatches.single['status'], 'cancelled');
  });

  testWidgets('an admin reverses a confirmed dispatch and the stock comes back', (tester) async {
    final backend = backendForDispatches('admin')..addDraft('C0002', {'PC-BBQ-S': 12});
    final app = await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Dispatches');
    await openDispatch(tester, 'D000001 · Mabelreign Grocers');
    await tapButton(tester, 'Confirm dispatch');
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();
    expect(app.backend.onHand('product-1'), 88);

    await tapButton(tester, 'Reverse');
    await tester.enterText(find.widgetWithText(TextFormField, 'Reason'), 'Wrong shop');
    await tester.tap(find.text('Reverse and return stock'));
    await tester.pumpAndSettle();

    expect(find.text('Reversed'), findsOneWidget);
    expect(find.text('Reversed: Wrong shop'), findsOneWidget);
    expect(app.backend.onHand('product-1'), 100);
  });

  testWidgets('accounts staff can view dispatches but not create or confirm them', (tester) async {
    final backend = backendForDispatches('accounts')..addDraft('C0002', {'PC-BBQ-S': 12});
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Dispatches');

    expect(find.text('New dispatch'), findsNothing);
    await openDispatch(tester, 'D000001 · Mabelreign Grocers');
    expect(find.text('USD 6.00'), findsNWidgets(2)); // line and total
    expect(find.text('Confirm dispatch'), findsNothing);
    expect(find.text('Edit'), findsNothing);
  });

  testWidgets('filters by status', (tester) async {
    final backend = backendForDispatches('storekeeper')
      ..addDraft('C0002', {'PC-BBQ-S': 1})
      ..addDraft('C0001', {'MP-CH-S': 1});
    backend.dispatches.first['status'] = 'confirmed';
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Dispatches');
    expect(find.textContaining('D00000'), findsNWidgets(2));

    await tester.tap(find.text('Drafts'));
    await tester.pumpAndSettle();
    expect(find.text('D000002 · Avondale Tuckshop'), findsOneWidget);
    expect(find.text('D000001 · Mabelreign Grocers'), findsNothing);
  });

  testWidgets('dispatch screens fit a small phone without overflowing', (tester) async {
    final backend = backendForDispatches('admin')..addDraft('C0001', {'PC-BBQ-S': 24});
    await pumpSnackify(tester, signedIn: true, size: const Size(320, 568), backend: backend);
    await openSection(tester, 'Dispatches');
    await openDispatch(tester, 'D000001 · Avondale Tuckshop');
    expect(find.text('Confirm dispatch'), findsOneWidget);

    await tapButton(tester, 'Edit');
    expect(find.text('Save draft'), findsOneWidget);
  });
}
