import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snackify/core/files/pdf_sharer.dart';
import 'package:snackify/core/formatting/dates.dart';

import 'helpers/receipt_steps.dart';
import 'helpers/test_app.dart';

// Goods bought: finance records what was bought; the warehouse receives against it.

const bbq = 'Potato Crisps — BBQ — Small';
const cheese = 'Potato Crisps — Cheese — Small';

FakeBackend backendFor(String role) => FakeBackend(role: role)
  ..addProduct('PC-BBQ-S', 'Potato Crisps', 'BBQ', 'Small', '0.50')
  ..addProduct('PC-CHS-S', 'Potato Crisps', 'Cheese', 'Small', '0.50')
  ..addSupplier('SUP-01', 'Harare Potato Co-op');

/// GB000001, as finance recorded it: 100 BBQ at 0.4250 and 30 Cheese at 0.50 (USD 57.50).
FakeBackend withPurchase(FakeBackend backend) => backend
  ..purchases.add({
    'id': 'purchase-1',
    'purchaseNumber': 'GB000001',
    'status': 'OPEN',
    'ownerId': 'org-hq',
    'supplierId': 'supplier-1',
    'supplierInvoiceNumber': 'INV-77',
    'purchaseDate': toApiDate(today()),
    'notes': null,
    'createdBy': {'id': 'finance-person', 'fullName': 'Rudo Finance'},
    'cancelledBy': null,
    'cancelledAt': null,
    'cancelReason': null,
    'lines': [
      {
        'id': 'purchase-1-line-1',
        'productId': 'product-1',
        'unitId': 'unit-pack',
        'quantity': 100,
        'unitCost': '0.4250',
        'notes': null,
      },
      {
        'id': 'purchase-1-line-2',
        'productId': 'product-2',
        'unitId': 'unit-pack',
        'quantity': 30,
        'unitCost': '0.50',
        'notes': null,
      },
    ],
  });

/// Another person, signed in with [role], working on the same server data as [backend].
FakeBackend sameDataAs(FakeBackend backend, String role) => FakeBackend(role: role)
  ..products.addAll(backend.products)
  ..catalogue['suppliers']!.addAll(backend.catalogue['suppliers']!)
  ..purchases.addAll(backend.purchases)
  ..grns.addAll(backend.grns)
  ..movements.addAll(backend.movements);

/// Signs in as someone else on the same data, back at the first screen.
Future<FakeBackend> switchPerson(WidgetTester tester, FakeBackend backend, String role) async {
  tester.state<NavigatorState>(find.byType(Navigator).first).popUntil((route) => route.isFirst);
  await tester.pumpAndSettle();
  final other = sameDataAs(backend, role);
  await pumpSnackify(tester, signedIn: true, backend: other);
  return other;
}

/// The list entry of a goods-bought list.
Finder purchaseTile(String number) =>
    find.ancestor(of: find.textContaining(number), matching: find.byType(ListTile)).first;

/// Opens Goods Bought and the list numbered [number].
Future<void> openPurchase(WidgetTester tester, String number) async {
  await openSection(tester, 'Goods Bought');
  await tester.tap(purchaseTile(number));
  await tester.pumpAndSettle();
}

/// Adds a product line to the goods-bought form.
Future<void> addBoughtLine(
  WidgetTester tester, {
  required String product,
  required int quantity,
  required String cost,
}) async {
  await press(tester, find.text('Add product'));
  await tester.tap(find.widgetWithText(InputDecorator, 'Product'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(product).last);
  await tester.pumpAndSettle();
  await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '$quantity');
  await tester.enterText(find.widgetWithText(TextFormField, 'Cost per unit'), cost);
  await press(tester, find.text('Done'));
}

void main() {
  testWidgets('finance records goods bought with two lines, sees the total and prints it', (
    tester,
  ) async {
    final backend = backendFor('accounts');
    final app = await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Goods Bought');
    expect(find.text('No goods bought'), findsOneWidget);
    await press(tester, find.text('Record goods bought'));

    await chooseOption(tester, 'Supplier (optional)', 'Harare Potato Co-op (SUP-01)');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Supplier invoice number (optional)'),
      'INV-77',
    );
    await addBoughtLine(tester, product: bbq, quantity: 100, cost: '0.4250');
    await addBoughtLine(tester, product: cheese, quantity: 30, cost: '0.50');
    expect(find.text('Total USD 57.50'), findsOneWidget);
    await press(tester, find.text('Save'));

    expect(find.text('Saved goods bought GB000001.'), findsOneWidget);
    expect(find.text('USD 57.50'), findsOneWidget);
    expect(find.text('Not received'), findsWidgets);
    final saved = backend.purchases.single;
    expect(saved['supplierId'], 'supplier-1');
    expect(saved['supplierInvoiceNumber'], 'INV-77');
    expect(saved['ownerId'], 'org-hq');
    expect((saved['lines'] as List).first, containsPair('unitCost', '0.4250'));
    // Finance does not receive goods.
    expect(find.text('Receive'), findsNothing);

    await press(tester, find.byTooltip(sharePdfLabel));
    expect(app.sharedPdfs.single.$1, 'GB000001.pdf');
    expect(app.sharedPdfs.single.$2, startsWith('%PDF'));

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.textContaining('GB000001 · Harare Potato Co-op · INV-77'), findsOneWidget);
    expect(find.textContaining('USD 57.50 · 2 line(s)'), findsOneWidget);
  });

  testWidgets('a storekeeper receives against the list, correcting what arrived', (tester) async {
    final backend = withPurchase(backendFor('storekeeper'));
    final app = await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Goods Bought');
    expect(find.text('Record goods bought'), findsNothing);
    await tester.tap(purchaseTile('GB000001'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Cancel goods bought'), findsNothing);

    await press(tester, find.text('Receive'));
    expect(find.text('Receiving against GB000001'), findsOneWidget);
    expect(find.text('$bbq (PC-BBQ-S)'), findsOneWidget);
    expect(find.text('$cheese (PC-CHS-S)'), findsOneWidget);
    expect(
      find.widgetWithText(TextFormField, 'Supplier invoice or receipt number (optional)'),
      findsOneWidget,
    );
    expect(find.text('INV-77'), findsOneWidget);

    // Only 96 BBQ arrived.
    await press(tester, find.text('$bbq (PC-BBQ-S)'));
    await tester.enterText(find.widgetWithText(TextFormField, 'Received'), '96');
    await tester.pumpAndSettle();
    await chooseOption(tester, 'Why the quantities differ', 'Shortage');
    await press(tester, find.text('Done'));
    expect(find.textContaining('Received 96 pack of 100 bought'), findsOneWidget);
    app.documents.willPick([pdfDocument()]);
    await press(tester, find.text('Attach document'));
    await press(tester, find.text('Submit for verification'));

    final grn = backend.grns.single;
    expect(grn['purchaseId'], 'purchase-1');
    expect(grn['supplierId'], 'supplier-1');
    expect(grn['purchaseDate'], toApiDate(today()));
    expect(
      [for (final line in grn['lines'] as List) (line as Map)['purchaseLineId']],
      ['purchase-1-line-1', 'purchase-1-line-2'],
    );
    expect(backend.onHand('product-1'), 96);

    // Back on the list: part has arrived.
    expect(find.textContaining('Submitted GRN000001.'), findsOneWidget);
    expect(find.text('Partly received'), findsWidgets);
    expect(find.text('Bought 100 pack · Received 96 · Outstanding 4'), findsOneWidget);
    expect(find.text('Bought 30 pack · Received 30 · Outstanding 0'), findsOneWidget);

    // The note made from it opens, and names the list.
    await press(tester, find.text('GRN000001'));
    expect(find.text('Goods bought'), findsOneWidget);
    expect(find.text('GB000001'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: purchaseTile('GB000001'), matching: find.text('Partly received')),
      findsOneWidget,
    );

    // Receiving again offers only what is still to come.
    await tester.tap(purchaseTile('GB000001'));
    await tester.pumpAndSettle();
    await press(tester, find.text('Receive'));
    expect(find.text('$bbq (PC-BBQ-S)'), findsOneWidget);
    expect(find.text('$cheese (PC-CHS-S)'), findsNothing);
    expect(find.textContaining('Received 4 pack'), findsOneWidget);
  });

  testWidgets('once goods are received, finance can no longer change or cancel the list', (
    tester,
  ) async {
    final backend = withPurchase(backendFor('storekeeper'));
    final app = await pumpSnackify(tester, signedIn: true, backend: backend);
    await openPurchase(tester, 'GB000001');
    await press(tester, find.text('Receive'));
    app.documents.willPick([pdfDocument()]);
    await press(tester, find.text('Attach document'));
    await press(tester, find.text('Submit for verification'));
    expect(find.text('Received'), findsWidgets);

    final finance = await switchPerson(tester, backend, 'accounts');
    await openPurchase(tester, 'GB000001');
    expect(find.text('Bought 100 pack · Received 100 · Outstanding 0'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Cancel goods bought'), findsNothing);
    expect(find.text('Receive'), findsNothing);
    expect(find.text('GRN000001'), findsOneWidget);
    expect(finance.purchases.single['status'], 'OPEN');
  });

  testWidgets('finance cancels a list nothing was received against, giving a reason', (
    tester,
  ) async {
    final backend = withPurchase(backendFor('accounts'));
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openPurchase(tester, 'GB000001');
    expect(find.text('Edit'), findsOneWidget);

    await press(tester, find.text('Cancel goods bought'));
    await tester.enterText(find.widgetWithText(TextField, 'Reason'), 'Supplier could not deliver');
    await tester.tap(find.text('Cancel list'));
    await tester.pumpAndSettle();

    expect(find.text('Goods bought GB000001 cancelled.'), findsOneWidget);
    expect(find.text('Cancelled because'), findsOneWidget);
    expect(find.text('Supplier could not deliver'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Cancel goods bought'), findsNothing);
    expect(backend.purchases.single['status'], 'CANCELLED');

    await tester.pageBack();
    await tester.pumpAndSettle();
    await press(tester, find.widgetWithText(ChoiceChip, 'Not received'));
    expect(find.textContaining('GB000001'), findsNothing);
    await press(tester, find.widgetWithText(ChoiceChip, 'Cancelled'));
    expect(find.textContaining('GB000001'), findsOneWidget);
    expect(backend.requests.last, contains('status=CANCELLED'));
  });

  testWidgets('finance changes a list before anything arrives', (tester) async {
    final backend = withPurchase(backendFor('accounts'));
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openPurchase(tester, 'GB000001');
    await press(tester, find.text('Edit'));
    await press(tester, find.text('$cheese (PC-CHS-S)'));
    await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '40');
    await press(tester, find.text('Done'));
    expect(find.text('Total USD 62.50'), findsOneWidget);
    await press(tester, find.text('Save'));

    expect(find.text('Saved goods bought GB000001.'), findsOneWidget);
    expect(find.text('USD 62.50'), findsOneWidget);
    expect(backend.requests, contains('PUT /api/v1/purchases/purchase-1'));
  });

  testWidgets('Goods Bought is for finance, warehouse staff and administrators only', (
    tester,
  ) async {
    await pumpSnackify(tester, signedIn: true, backend: backendFor('salesperson'));
    expect(await menuSections(tester), isNot(contains('Goods Bought')));

    final sections = await (() async {
      await pumpSnackify(tester, signedIn: true, backend: backendFor('storekeeper'));
      return menuSections(tester);
    })();
    expect(sections.indexOf('Goods Bought'), sections.indexOf('Goods Received') - 1);
  });
}
