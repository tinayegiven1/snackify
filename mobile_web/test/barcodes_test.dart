import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snackify/core/scanning/manual_barcode_dialog.dart';

import 'helpers/receipt_steps.dart';
import 'helpers/test_app.dart';

const bbqBarcode = '5901234123457';
const cheeseBarcode = '4006381333931';
const chutneyBarcode = '0036000291452';

/// BBQ and Cheese have manufacturer barcodes; Salt has none; Chutney is inactive.
FakeBackend backendForBarcodes(String role) => FakeBackend(role: role)
  ..addProduct('PC-BBQ-S', 'Potato Crisps', 'BBQ', 'Small', '0.50', barcode: bbqBarcode)
  ..addProduct('MP-CH-S', 'Maize Puffs', 'Cheese', 'Small', '0.30', barcode: cheeseBarcode)
  ..addProduct('PC-SA-S', 'Potato Crisps', 'Salt', 'Small', '0.50')
  ..addProduct(
    'PC-CT-S',
    'Potato Crisps',
    'Chutney',
    'Small',
    '0.50',
    barcode: chutneyBarcode,
    isActive: false,
  )
  ..addStock('PC-BBQ-S', 100)
  ..addStock('MP-CH-S', 50)
  ..addCustomer('C0001', 'Avondale Tuckshop')
  ..addSupplier('SUP-01', 'Harare Potato Co-op');

Future<void> tapButton(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> startDispatch(WidgetTester tester) async {
  await openSection(tester, 'Dispatches');
  await tester.tap(find.text('New dispatch'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Choose a customer'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Avondale Tuckshop'));
  await tester.pumpAndSettle();
}

final packsField = find.widgetWithText(TextFormField, 'Packs');

String packsOnLine(WidgetTester tester) =>
    tester.widget<TextFormField>(packsField.first).controller!.text;

void main() {
  testWidgets('scanning asks how many packs, and never adds the same product twice', (
    tester,
  ) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: backendForBarcodes('salesperson'),
    );
    await startDispatch(tester);

    app.scanner.willRead([bbqBarcode]);
    await tapButton(tester, find.text('Scan barcode'));
    expect(find.text('How many packs?'), findsOneWidget);
    expect(find.text('Potato Crisps — BBQ — Small'), findsOneWidget);
    await tester.enterText(packsField.last, '12');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(packsOnLine(tester), '12');

    // The same pack scanned again: the line's quantity is offered for change instead.
    app.scanner.willRead([bbqBarcode]);
    await tapButton(tester, find.text('Scan barcode'));
    expect(find.text('Already on this dispatch'), findsOneWidget);
    expect(tester.widget<TextFormField>(packsField.last).controller!.text, '12');
    await tester.enterText(packsField.last, '20');
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pumpAndSettle();

    expect(find.text('Potato Crisps — BBQ — Small'), findsOneWidget);
    expect(packsOnLine(tester), '20');
    expect(find.text('Total USD 10.00'), findsOneWidget);

    await tapButton(tester, find.text('Save draft'));
    final lines = app.backend.dispatches.single['lines'] as List<Map<String, Object?>>;
    expect(lines, hasLength(1));
    expect(lines.single['quantity'], 20);
  });

  testWidgets('an unknown barcode is explained clearly and can be scanned again', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: backendForBarcodes('salesperson'),
    );
    await startDispatch(tester);

    app.scanner.willRead(['6009876543210', cheeseBarcode]);
    await tapButton(tester, find.text('Scan barcode'));

    expect(find.text('Barcode not found'), findsOneWidget);
    expect(
      find.text(
        'No product has the barcode 6009876543210. Check that you scanned the right pack. '
        'An admin can add the barcode to the product in Products.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Scan again'));
    await tester.pumpAndSettle();
    expect(find.text('Maize Puffs — Cheese — Small'), findsOneWidget);

    // Changing one's mind adds nothing.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(packsField, findsNothing);
    expect(app.scanner.scans, 2);
  });

  testWidgets('inactive products and closed scanners add nothing', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: backendForBarcodes('salesperson'),
    );
    await startDispatch(tester);

    app.scanner.willRead([chutneyBarcode]);
    await tapButton(tester, find.text('Scan barcode'));
    expect(
      find.text('Potato Crisps — Chutney — Small is inactive and cannot be dispatched.'),
      findsOneWidget,
    );
    expect(packsField, findsNothing);

    // The user closes the scanner without scanning anything.
    app.scanner.willRead([null]);
    await tapButton(tester, find.text('Scan barcode'));
    expect(packsField, findsNothing);
    expect(app.backend.requests.where((r) => r.contains('/barcode/')), hasLength(1));
  });

  testWidgets('confirming a dispatch shows every quantity first', (tester) async {
    final backend = backendForBarcodes('storekeeper')
      ..addDraft('C0001', {'PC-BBQ-S': 12, 'MP-CH-S': 5});
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Dispatches');
    await tester.tap(find.text('D000001 · Avondale Tuckshop'));
    await tester.pumpAndSettle();

    await tapButton(tester, find.text('Confirm dispatch'));

    expect(find.text('Check the quantities:'), findsOneWidget);
    expect(find.text('12 × Potato Crisps — BBQ — Small'), findsOneWidget);
    expect(find.text('5 × Maize Puffs — Cheese — Small'), findsOneWidget);
    expect(find.textContaining('17 packs will be taken out of stock'), findsOneWidget);
  });

  testWidgets('receiving stock: scanning a pack chooses the product', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: backendForBarcodes('storekeeper'),
    );
    await openSection(tester, 'Stock');
    await tester.tap(find.text('Receive stock'));
    await tester.pumpAndSettle();

    await tapButton(tester, find.text('Add product'));
    app.scanner.willRead([cheeseBarcode]);
    await tapButton(tester, find.text('Scan barcode'));
    expect(find.text('Maize Puffs — Cheese — Small'), findsOneWidget);

    await fillLine(tester, bought: 24);
    app.documents.willPick([pdfDocument()]);
    await tapButton(tester, find.text('Attach document'));
    await tapButton(tester, find.text('Submit for verification'));
    expect(app.backend.onHand('product-2'), 74);
  });

  testWidgets('scanning in Products finds the product', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: backendForBarcodes('salesperson'),
    );
    await openSection(tester, 'Products');

    app.scanner.willRead([cheeseBarcode]);
    await tester.tap(find.byTooltip('Scan a barcode'));
    await tester.pumpAndSettle();

    expect(find.text('Maize Puffs — Cheese'), findsOneWidget);
    expect(find.text('Potato Crisps — BBQ'), findsNothing);
  });

  testWidgets('admins scan a barcode into a product, or generate one for packs without', (
    tester,
  ) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: backendForBarcodes('admin'));
    await openSection(tester, 'Products');

    // Scanning a pack opens its product for editing.
    app.scanner.willRead([bbqBarcode]);
    await tester.tap(find.byTooltip('Scan a barcode'));
    await tester.pumpAndSettle();
    expect(find.text('Edit product'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Salt has no barcode: generate one.
    await tester.tap(find.text('Potato Crisps — Salt'));
    await tester.pumpAndSettle();
    await tapButton(tester, find.text('No barcode on the pack? Generate one'));
    expect(find.text('2000000000015'), findsOneWidget);
    expect(find.text('Saved. Print labels for it from Stock.'), findsOneWidget);
    expect(find.text('No barcode on the pack? Generate one'), findsNothing);
    expect(app.backend.products[2]['barcode'], '2000000000015');

    // Or fill the barcode by scanning the pack.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add product'));
    await tester.pumpAndSettle();
    app.scanner.willRead(['9780306406157']);
    await tapButton(tester, find.byTooltip('Scan the barcode'));
    expect(find.text('9780306406157'), findsOneWidget);
  });

  testWidgets('storekeepers print barcode labels', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: backendForBarcodes('storekeeper'),
    );
    await openSection(tester, 'Stock');
    await tester.tap(find.text('Potato Crisps — BBQ — Small'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Print barcode labels'));
    await tester.pumpAndSettle();
    expect(find.text('Print barcode labels'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Number of labels'), '30');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Labels already used on the sheet'),
      '24',
    );
    await tester.tap(find.text('Make PDF'));
    await tester.pumpAndSettle();
    expect(find.text('From 0 to 23'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Labels already used on the sheet'),
      '5',
    );
    await tester.tap(find.text('Make PDF'));
    await tester.pumpAndSettle();

    expect(app.sharedPdfs, [('labels-PC-BBQ-S.pdf', '%PDF-1.3 labels PC-BBQ-S count=30 skip=5')]);
  });

  testWidgets('labels need a barcode', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: backendForBarcodes('storekeeper'),
    );
    await openSection(tester, 'Stock');
    await tester.tap(find.text('Potato Crisps — Salt — Small'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Print barcode labels'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make PDF'));
    await tester.pumpAndSettle();
    expect(
      find.text('This product has no barcode yet. An admin can generate one in Products.'),
      findsOneWidget,
    );
    expect(app.sharedPdfs, isEmpty);
  });

  testWidgets('labels are not for salespeople', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: backendForBarcodes('salesperson'));
    await openSection(tester, 'Stock');
    await tester.tap(find.text('Potato Crisps — BBQ — Small'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Print barcode labels'), findsNothing);
  });

  testWidgets('a typed barcode is checked, and spaces are ignored', (tester) async {
    String? result = 'not yet';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await askForBarcode(context),
            child: const Text('Type a barcode'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Type a barcode'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Find product'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the barcode'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), 'abc\$');
    await tester.tap(find.text('Find product'));
    await tester.pumpAndSettle();
    expect(find.text('A barcode has only letters, digits and dashes'), findsOneWidget);

    // A USB scanner types the number and presses Enter.
    await tester.enterText(find.byType(TextFormField), '5 901234 123457');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(result, bbqBarcode);
  });
}
