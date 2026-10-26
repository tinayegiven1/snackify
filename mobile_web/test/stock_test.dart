import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snackify/core/formatting/dates.dart';

import 'helpers/receipt_steps.dart';
import 'helpers/test_app.dart';

/// Two products: BBQ crisps with plenty of stock, cheese puffs below their reorder level.
FakeBackend backendWithStock({String role = 'storekeeper'}) {
  return FakeBackend(role: role)
    ..addProduct('PC-BBQ-S', 'Potato Crisps', 'BBQ', 'Small', '0.50', barcode: '2000000000015')
    ..addProduct('MP-CH-S', 'Maize Puffs', 'Cheese', 'Small', '0.30', reorderLevel: 50)
    ..addStock('PC-BBQ-S', 100)
    ..addStock('MP-CH-S', 20)
    ..addSupplier('SUP-01', 'Harare Potato Co-op');
}

Future<void> openReceiveForm(WidgetTester tester) async {
  await tester.tap(find.text('Receive stock'));
  await tester.pumpAndSettle();
}

Future<void> chooseProduct(WidgetTester tester, String description) async {
  await tester.tap(find.text('Choose or scan a product'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(description));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows stock on hand, warning about low stock', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: backendWithStock());
    await openSection(tester, 'Stock');

    expect(find.text('Potato Crisps — BBQ — Small'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    expect(find.text('20'), findsOneWidget);
    expect(find.text('MP-CH-S · reorder at 50'), findsOneWidget);
    expect(find.text('Low stock'), findsNWidgets(2)); // the filter chip and one badge

    await tester.tap(find.widgetWithText(FilterChip, 'Low stock'));
    await tester.pumpAndSettle();
    expect(find.text('Potato Crisps — BBQ — Small'), findsNothing);
    expect(find.text('Maize Puffs — Cheese — Small'), findsOneWidget);
  });

  testWidgets('a storekeeper receives stock with a goods-received note and sees the new total', (
    tester,
  ) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: backendWithStock());
    await openSection(tester, 'Stock');
    expect(find.text('Opening balance'), findsNothing); // administrators only

    await openReceiveForm(tester);
    await addLine(tester, product: 'Maize Puffs — Cheese — Small', bought: 48, batch: 'L2026-10A');
    app.documents.willPick([pdfDocument()]);
    await press(tester, find.text('Attach document'));
    expect(find.text('invoice.pdf'), findsOneWidget);
    await press(tester, find.text('Submit for verification'));

    expect(
      find.text('Submitted GRN000001. Stock added to Head Office; it will be verified by finance.'),
      findsOneWidget,
    );
    expect(find.text('68'), findsOneWidget);
    final grn = app.backend.grns.single;
    expect(grn, containsPair('receivedDate', toApiDate(today())));
    expect((grn['lines'] as List).single, containsPair('batchNumber', 'L2026-10A'));
    expect((grn['documents'] as List).single, containsPair('filename', 'invoice.pdf'));
  });

  testWidgets('the receive form checks fields before sending anything', (tester) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: backendWithStock());
    await openSection(tester, 'Stock');
    await openReceiveForm(tester);

    await press(tester, find.text('Submit for verification'));
    expect(find.text('Add at least one product.'), findsOneWidget);

    await press(tester, find.text('Add product'));
    await press(tester, find.text('Done')); // disabled until a product is chosen
    await tester.tap(find.widgetWithText(InputDecorator, 'Product'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Potato Crisps — BBQ — Small').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Bought'), '24');
    await tester.enterText(find.widgetWithText(TextFormField, 'Received'), '20');
    await tester.enterText(find.widgetWithText(TextFormField, 'Cost per unit'), '0.12345');
    await press(tester, find.text('Done'));
    expect(find.text('Choose a reason'), findsOneWidget);
    expect(find.text('Use an amount with up to 4 decimal places'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // A storekeeper cannot submit without a supplier document.
    await addLine(tester, product: 'Potato Crisps — BBQ — Small', bought: 24);
    await press(tester, find.text('Submit for verification'));
    expect(
      find.text('Attach the supplier invoice or delivery note before submitting.'),
      findsOneWidget,
    );
    expect(app.backend.requests.where((r) => r.startsWith('POST /api/v1/receipts')), isEmpty);
  });

  testWidgets("an admin records an opening balance, and sees the server's reason when refused", (
    tester,
  ) async {
    await pumpSnackify(tester, signedIn: true, backend: backendWithStock(role: 'admin'));
    await openSection(tester, 'Stock');
    await press(tester, find.text('Opening balance'));

    await chooseProduct(tester, 'Potato Crisps — BBQ — Small');
    await tester.enterText(find.widgetWithText(TextFormField, 'Quantity on hand (packs)'), '10');
    await press(tester, find.text('Record opening balance'));

    expect(
      find.text(
        'This product already has stock records. Use a stock adjustment to correct its balance.',
      ),
      findsOneWidget,
    );
    expect(find.text('Record opening balance'), findsOneWidget); // still on the form
  });

  testWidgets('salespeople can view stock but not receive it', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: backendWithStock(role: 'salesperson'));
    await openSection(tester, 'Stock');

    expect(find.text('Potato Crisps — BBQ — Small'), findsOneWidget);
    expect(find.text('Receive stock'), findsNothing);
  });

  testWidgets("lists today's receipts with totals, and the last 7 days", (tester) async {
    final backend = backendWithStock()
      ..addStock(
        'PC-BBQ-S',
        30,
        receivedDate: toApiDate(today().subtract(const Duration(days: 3))),
      );
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Stock');

    await tester.tap(find.text('Receipts'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 receipts · 120 packs'), findsOneWidget);
    expect(find.text('100 × Potato Crisps — BBQ — Small'), findsOneWidget);

    await tester.tap(find.text('Last 7 days'));
    await tester.pumpAndSettle();
    expect(find.textContaining('3 receipts · 150 packs'), findsOneWidget);
    expect(find.text('30 × Potato Crisps — BBQ — Small'), findsOneWidget);
  });

  testWidgets("an admin sees a product's history and records damage", (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: backendWithStock(role: 'admin'));
    await openSection(tester, 'Stock');

    await tester.tap(find.text('Potato Crisps — BBQ — Small'));
    await tester.pumpAndSettle();
    expect(find.text('100 packs'), findsOneWidget);
    expect(find.text('Received  +100'), findsOneWidget);
    expect(find.text('= 100'), findsOneWidget);

    await tester.tap(find.text('Adjust stock'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Packs to remove'), '2');
    await tester.enterText(find.widgetWithText(TextFormField, 'Reason'), 'Packs torn in transit');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Stock updated. In stock now: 98'), findsOneWidget);
    expect(find.text('98 packs'), findsOneWidget);
    expect(find.text('Damaged  -2'), findsOneWidget);
  });

  testWidgets('the adjust dialog will not remove more than is in stock', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: backendWithStock(role: 'admin'),
    );
    await openSection(tester, 'Stock');
    await tester.tap(find.text('Maize Puffs — Cheese — Small'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Adjust stock'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Packs to remove'), '21');
    await tester.enterText(find.widgetWithText(TextFormField, 'Reason'), 'Stock count');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Only 20 in stock'), findsOneWidget);
    expect(app.backend.requests, isNot(contains('POST /api/v1/stock/adjustments')));
  });

  testWidgets('only admins can adjust stock', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: backendWithStock());
    await openSection(tester, 'Stock');
    await tester.tap(find.text('Potato Crisps — BBQ — Small'));
    await tester.pumpAndSettle();

    expect(find.text('Received  +100'), findsOneWidget);
    expect(find.text('Adjust stock'), findsNothing);
  });

  testWidgets('stock screens fit a small phone without overflowing', (tester) async {
    await pumpSnackify(
      tester,
      signedIn: true,
      size: const Size(320, 568),
      backend: backendWithStock(role: 'admin'),
    );
    await openSection(tester, 'Stock');
    expect(find.text('Potato Crisps — BBQ — Small'), findsOneWidget);

    await tester.tap(find.text('Receipts'));
    await tester.pumpAndSettle();

    await openReceiveForm(tester);
    expect(find.text('Submit for verification'), findsOneWidget);
    await addLine(tester, product: 'Potato Crisps — BBQ — Small', bought: 24);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await press(tester, find.text('Opening balance'));
    expect(find.text('Record opening balance'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('On hand'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Potato Crisps — BBQ — Small'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Adjust stock'));
    await tester.pumpAndSettle();
    expect(find.text('Damaged'), findsOneWidget);
  });
}
