import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snackify/core/files/pdf_sharer.dart';

import 'helpers/receipt_steps.dart';
import 'helpers/test_app.dart';

// StockFlow Stage 4: goods-received notes, their documents, the catalogue and product units.

const bbq = 'Potato Crisps — BBQ — Small';
const supplier = 'Harare Potato Co-op (SUP-01)';

FakeBackend backendFor(String role) => FakeBackend(role: role)
  ..addProduct('PC-BBQ-S', 'Potato Crisps', 'BBQ', 'Small', '0.50')
  ..addStock('PC-BBQ-S', 10)
  ..addSupplier('SUP-01', 'Harare Potato Co-op');

/// Opens Goods Received and starts a new receipt.
Future<void> startReceipt(WidgetTester tester) async {
  await openSection(tester, 'Goods Received');
  await press(tester, find.text('Receive stock'));
}

/// A submitted receipt for 100 BBQ at 0.4250, with one PDF, added straight to the backend
/// through the storekeeper's screens.
Future<void> submitThroughScreens(WidgetTester tester, TestApp app, {String? owner}) async {
  await startReceipt(tester);
  if (owner != null) await chooseOption(tester, 'Whose stock is this?', owner);
  await chooseOption(tester, 'Supplier', supplier);
  await addLine(tester, product: bbq, bought: 100, cost: '0.4250');
  app.documents.willPick([pdfDocument()]);
  await press(tester, find.text('Attach document'));
  await press(tester, find.text('Submit for verification'));
}

void main() {
  testWidgets('a storekeeper saves a draft, then submits it with the supplier invoice', (
    tester,
  ) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: backendFor('storekeeper'));
    await startReceipt(tester);
    await chooseOption(tester, 'Supplier', supplier);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Supplier invoice or receipt number (optional)'),
      'INV-1042',
    );
    await addLine(
      tester,
      product: bbq,
      bought: 100,
      received: 96,
      reason: 'Shortage',
      cost: '0.4250',
    );
    expect(find.textContaining('Received 96 pack of 100 bought'), findsOneWidget);
    await press(tester, find.text('Save draft'));

    expect(find.text('Saved draft GRN000001.'), findsOneWidget);
    expect(app.backend.onHand('product-1'), 10); // a draft adds nothing

    await tester.tap(find.text('GRN000001 · Harare Potato Co-op'));
    await tester.pumpAndSettle();
    expect(find.text('1 line(s) received differ from what was bought.'), findsOneWidget);
    await press(tester, find.text('Continue draft'));
    app.documents.willPick([pdfDocument('delivery-note.pdf')]);
    await press(tester, find.text('Attach document'));
    await press(tester, find.text('Submit for verification'));

    expect(find.text('Waiting for verification'), findsWidgets);
    expect(app.backend.onHand('product-1'), 106);
    expect(app.backend.grns.single, containsPair('supplierInvoiceNumber', 'INV-1042'));
    // Draft 42.50: 100 bought x 0.4250, whatever arrived.
    expect(find.text('USD 42.50'), findsOneWidget);
  });

  testWidgets('a document the server refuses is reported, and the draft is kept', (tester) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: backendFor('storekeeper'));
    await startReceipt(tester);
    await chooseOption(tester, 'Supplier', supplier);
    await addLine(tester, product: bbq, bought: 5);
    app.documents.willPick([fakePdf()]);
    await press(tester, find.text('Attach document'));
    await press(tester, find.text('Submit for verification'));

    expect(
      find.text('Only PDF, JPEG and PNG documents are accepted (this file is something else).'),
      findsOneWidget,
    );
    expect(app.backend.grns.single['status'], 'DRAFT');
    expect(app.backend.onHand('product-1'), 10);

    // Saving again changes the same draft rather than adding another.
    await press(tester, find.text('Save draft'));
    expect(app.backend.grns, hasLength(1));
  });

  testWidgets('finance reviews each document, sees a total that differs, and verifies', (
    tester,
  ) async {
    final backend = backendFor('storekeeper');
    final storekeeper = await pumpSnackify(tester, signedIn: true, backend: backend);
    await submitThroughScreens(tester, storekeeper);

    final finance = FakeBackend(role: 'accounts')
      ..products.addAll(backend.products)
      ..catalogue['suppliers']!.addAll(backend.catalogue['suppliers']!)
      ..grns.addAll(backend.grns)
      ..movements.addAll(backend.movements);
    final app = await pumpSnackify(tester, signedIn: true, backend: finance);
    await openSection(tester, 'Goods Received');
    expect(find.text('Receive stock'), findsNothing); // finance does not receive goods
    await tester.tap(find.text('GRN000001 · Harare Potato Co-op'));
    await tester.pumpAndSettle();

    await press(tester, find.text('Verify receipt'));
    await tester.tap(find.text('Verify').last);
    await tester.pumpAndSettle();
    expect(
      find.text('Verify or reject every document before verifying the receipt.'),
      findsOneWidget,
    );

    await press(tester, find.byTooltip('Review invoice.pdf'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Total on the document (optional)'),
      '40.00',
    );
    await press(tester, find.text('Save review'));
    expect(find.text('Verified invoice.pdf.'), findsOneWidget);
    expect(find.text("A document's total differs from this receipt's total."), findsOneWidget);

    await press(tester, find.text('Verify receipt'));
    await tester.tap(find.text('Verify').last);
    await tester.pumpAndSettle();
    expect(find.text('Receipt GRN000001 verified.'), findsOneWidget);
    expect(find.text('Posted'), findsOneWidget);
    expect(app.backend.grns.single['status'], 'POSTED');

    await press(tester, find.byTooltip(sharePdfLabel));
    expect(app.sharedPdfs.single.$1, 'GRN000001.pdf');
  });

  testWidgets('a rejected document needs a reason; rejecting the receipt takes its stock out', (
    tester,
  ) async {
    final backend = backendFor('admin');
    final app = await pumpSnackify(tester, signedIn: true, backend: backend);
    await submitThroughScreens(tester, app);
    expect(backend.onHand('product-1'), 110);

    await tester.tap(find.text('GRN000001 · Harare Potato Co-op'));
    await tester.pumpAndSettle();
    await press(tester, find.byTooltip('Review invoice.pdf'));
    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();
    await press(tester, find.text('Save review'));
    expect(find.text('Say why the document is rejected'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Why is it rejected?'), 'Blurry');
    await press(tester, find.text('Save review'));
    expect(find.textContaining('Blurry'), findsOneWidget);

    await press(tester, find.text('Reject receipt'));
    await tester.enterText(find.widgetWithText(TextField, 'Reason'), 'Not our order');
    await tester.tap(find.text('Reject').last);
    await tester.pumpAndSettle();
    expect(find.text('Receipt GRN000001 rejected.'), findsOneWidget);
    expect(find.text('Rejected because'), findsOneWidget);
    expect(backend.onHand('product-1'), 10);
  });

  testWidgets('Head Office receives stock for a subsidiary: only its balance grows', (
    tester,
  ) async {
    final backend = backendFor('storekeeper');
    final app = await pumpSnackify(tester, signedIn: true, backend: backend);
    await submitThroughScreens(tester, app, owner: 'Mbare Branch (SUB-01)');

    expect(
      find.text(
        'Submitted GRN000001. Stock added to Mbare Branch; it will be verified by finance.',
      ),
      findsOneWidget,
    );
    expect(backend.onHand('product-1', 'org-sub-1'), 100);
    expect(backend.onHand('product-1'), 10);

    await openSection(tester, 'Stock');
    expect(find.text('10'), findsOneWidget);
    await chooseOption(tester, 'Whose stock', 'Mbare Branch (SUB-01)');
    expect(find.text('100'), findsOneWidget);
  });

  testWidgets("a subsidiary's staff see their own receipts but do not record them", (tester) async {
    final backend = FakeBackend(role: 'subsidiary_manager')
      ..addProduct('PC-BBQ-S', 'Potato Crisps', 'BBQ', 'Small', '0.50')
      ..addSupplier('SUP-01', 'Harare Potato Co-op');
    for (final owner in ['org-sub-1', 'org-hq']) {
      backend.grns.add({
        'id': 'grn-$owner',
        'grnNumber': owner == 'org-hq' ? 'GRN000001' : 'GRN000002',
        'status': 'POSTED',
        'documents': <Map<String, Object?>>[],
        'postedAt': '2026-10-20T08:00:00Z',
        'verifiedBy': null,
        'verificationNotes': null,
        'rejectedReason': null,
        'reversalReason': null,
        'noDocumentReason': 'Supplier emails it',
        'ownerId': owner,
        'warehouseId': 'warehouse-main',
        'supplierId': 'supplier-1',
        'supplierInvoiceNumber': null,
        'purchaseDate': null,
        'receivedDate': '2026-10-20',
        'notes': null,
        'lines': <Map<String, Object?>>[],
      });
    }
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Goods Received');

    expect(find.textContaining('GRN000002'), findsOneWidget);
    expect(find.textContaining('GRN000001'), findsNothing);
    expect(find.text('Receive stock'), findsNothing);
    expect(await menuSections(tester), isNot(contains('Catalogue')));
  });

  testWidgets('an administrator submits without a document, giving a reason, and reverses it', (
    tester,
  ) async {
    final backend = backendFor('admin');
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await startReceipt(tester);
    await chooseOption(tester, 'Supplier', supplier);
    await addLine(tester, product: bbq, bought: 30);
    await press(tester, find.text('Submit for verification'));
    expect(find.text('Submit without a document?'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Reason'), 'Supplier will email it');
    await tester.tap(find.text('Submit').last);
    await tester.pumpAndSettle();
    expect(backend.grns.single['noDocumentReason'], 'Supplier will email it');

    await tester.tap(find.text('GRN000001 · Harare Potato Co-op'));
    await tester.pumpAndSettle();
    await press(tester, find.text('Verify receipt'));
    await tester.tap(find.text('Verify').last);
    await tester.pumpAndSettle();
    await press(tester, find.text('Reverse receipt'));
    await tester.enterText(find.widgetWithText(TextField, 'Reason'), 'Entered twice');
    await tester.tap(find.text('Reverse').last);
    await tester.pumpAndSettle();

    expect(find.text('Receipt GRN000001 reversed.'), findsOneWidget);
    expect(find.text('No stock added'), findsOneWidget);
    expect(backend.onHand('product-1'), 10);
  });

  testWidgets('a delivery in cartons is added to stock in packs', (tester) async {
    final backend = backendFor('storekeeper')..addConversion('PC-BBQ-S', 'carton', 24);
    final app = await pumpSnackify(tester, signedIn: true, backend: backend);
    await startReceipt(tester);
    await chooseOption(tester, 'Supplier', supplier);
    await addLine(tester, product: bbq, bought: 3, cost: '10.20', unit: 'Carton (24 packs)');
    expect(find.textContaining('Received 3 carton'), findsOneWidget);
    app.documents.willPick([pdfDocument()]);
    await press(tester, find.text('Attach document'));
    await press(tester, find.text('Submit for verification'));

    expect(backend.onHand('product-1'), 82);
    final line = (backend.grns.single['lines'] as List).single as Map;
    expect(line['baseQuantityReceived'], 72);
    expect(line['lineTotal'], '30.60');
  });

  testWidgets('warehouse staff add suppliers; only administrators change categories', (
    tester,
  ) async {
    final backend = backendFor('storekeeper');
    await pumpSnackify(tester, signedIn: true, backend: backend, size: desktopSize);
    await openSection(tester, 'Catalogue');

    await tester.tap(find.text('Add supplier'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Code'), 'sup-02');
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Mutare Maize Mill');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email (optional)'), 'not-an-email');
    await press(tester, find.text('Save'));
    expect(find.text('Use an email address like sales@example.co.zw'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Email (optional)'), '');
    await press(tester, find.text('Save'));
    expect(find.text('Added supplier Mutare Maize Mill (SUP-02).'), findsOneWidget);
    expect(backend.catalogue['suppliers']!.last, containsPair('code', 'SUP-02'));

    await tester.tap(find.text('Categories'));
    await tester.pumpAndSettle();
    expect(find.text('Add category'), findsNothing);
  });

  testWidgets('an administrator gives a product a category and a carton size', (tester) async {
    final backend = backendFor('admin');
    backend.catalogue['categories']!.add({'id': 'category-1', 'name': 'Crisps', 'isActive': true});
    await pumpSnackify(tester, signedIn: true, backend: backend, size: desktopSize);
    await openSection(tester, 'Products');
    await tester.tap(find.text('PC-BBQ-S'));
    await tester.pumpAndSettle();

    await chooseOption(tester, 'Category (optional)', 'Crisps');
    await press(tester, find.text('Add a unit'));
    await chooseOption(tester, 'Unit', 'Carton');
    await tester.enterText(find.widgetWithText(TextFormField, 'packs'), '24');
    await press(tester, find.text('Save product'));

    final product = backend.products.single;
    expect(product['category'], {'id': 'category-1', 'name': 'Crisps'});
    expect(product['conversions'], [
      {
        'unit': {'id': 'unit-carton', 'code': 'carton', 'name': 'Carton'},
        'baseQuantity': 24,
      },
    ]);
    expect(backend.requests, contains('PUT /api/v1/products/product-1/conversions'));
  });
}
