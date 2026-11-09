import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snackify/core/files/document_picker.dart';
import 'package:snackify/core/formatting/dates.dart';
import 'package:snackify/features/receipts/presentation/document_preview.dart';

import 'helpers/receipt_steps.dart';
import 'helpers/test_app.dart';

// Supplier documents on goods bought: finance attaches them (files or camera photos), previews
// them, and verifies or rejects each one; the warehouse can only look at them.

const bbq = 'Potato Crisps — BBQ — Small';
const photoName = 'photo-20261108-090000.png';

FakeBackend backendFor(String role) => FakeBackend(role: role)
  ..addProduct('PC-BBQ-S', 'Potato Crisps', 'BBQ', 'Small', '0.50')
  ..addSupplier('SUP-01', 'Harare Potato Co-op');

/// A stored document as the server keeps it.
Map<String, Object?> storedDocument(String id, PickedDocument document, String mimeType) => {
  'id': id,
  'filename': document.name,
  'mimeType': mimeType,
  'sizeBytes': document.bytes.length,
  'uploadedBy': {'id': 'finance-person', 'fullName': 'Rudo Finance'},
  'uploadedAt': '2026-11-09T08:30:00Z',
  'verificationStatus': 'PENDING',
  'reviewedBy': null,
  'reviewedAt': null,
  'reviewNotes': null,
  'documentTotal': null,
  'bytes': document.bytes,
};

/// GB000001: 100 BBQ at 0.4250 (USD 42.50), with [documents] attached.
FakeBackend withPurchase(FakeBackend backend, {List<Map<String, Object?>>? documents}) =>
    backend
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
        'documents': documents ?? <Map<String, Object?>>[],
        'lines': [
          {
            'id': 'purchase-1-line-1',
            'productId': 'product-1',
            'unitId': 'unit-pack',
            'quantity': 100,
            'unitCost': '0.4250',
            'notes': null,
          },
        ],
      });

/// The thumbnail at the start of a document's row (on the form or the list's page).
Finder thumbnailOf(String filename) => find.descendant(
  of: find.ancestor(of: find.text(filename), matching: find.byType(InkWell)).first,
  matching: find.byType(DocumentThumbnail),
);

Finder get previewImage => find.byKey(const ValueKey('document-preview-image'));

Future<void> closePreview(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Close preview'));
  await tester.pumpAndSettle();
}

Future<void> openPurchase(WidgetTester tester, String number) async {
  await openSection(tester, 'Goods Bought');
  await tester.tap(
    find.ancestor(of: find.textContaining(number), matching: find.byType(ListTile)).first,
  );
  await tester.pumpAndSettle();
}

/// Reviews the first document still to check: verifies it, or rejects it with [reason].
Future<void> review(
  WidgetTester tester, {
  String? reason,
  String? total,
  bool reject = false,
}) async {
  await press(tester, find.text('Review').first);
  if (reject) {
    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();
  }
  if (reason != null) {
    await tester.enterText(find.widgetWithText(TextFormField, 'Why it is rejected'), reason);
  }
  if (total != null) {
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Total on the document (optional)'),
      total,
    );
  }
  await tester.tap(find.text(reject ? 'Reject document' : 'Verify document'));
  await tester.pumpAndSettle();
}

void main() {
  test('photos are named by the time taken and their real type', () {
    final time = DateTime(2026, 11, 8, 9, 5, 3);
    expect(photoFileName(time, photoDocument().bytes), 'photo-20261108-090503.png');
    expect(
      photoFileName(time, Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])),
      'photo-20261108-090503.jpg',
    );
    expect(isPicture(pdfDocument().bytes), isFalse);
  });

  testWidgets('finance attaches a PDF and a photo to a new list, and previews the photo', (
    tester,
  ) async {
    final backend = backendFor('accounts');
    final app = await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Goods Bought');
    await press(tester, find.text('Record goods bought'));
    await press(tester, find.text('Add product'));
    await tester.tap(find.widgetWithText(InputDecorator, 'Product'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(bbq).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '100');
    await tester.enterText(find.widgetWithText(TextFormField, 'Cost per unit'), '0.4250');
    await press(tester, find.text('Done'));

    // Cancelling the camera adds nothing.
    await press(tester, find.text('Take photo'));
    expect(find.text('Uploaded when you save'), findsNothing);

    app.documents.willPhotograph(photoDocument());
    await press(tester, find.text('Take photo'));
    app.documents.willPick([pdfDocument()]);
    await press(tester, find.text('Attach document'));
    expect(find.text('Uploaded when you save'), findsNWidgets(2));
    final picked = tester.widget<DocumentThumbnail>(thumbnailOf(photoName));
    expect(picked.isPdf, isFalse);
    expect(picked.bytes, photoDocument().bytes);
    expect(tester.widget<DocumentThumbnail>(thumbnailOf('invoice.pdf')).isPdf, isTrue);

    await press(tester, find.text(photoName));
    expect(previewImage, findsOneWidget);
    await closePreview(tester);
    expect(previewImage, findsNothing);
    // A PDF has no picture preview.
    await press(tester, find.text('invoice.pdf'));
    expect(previewImage, findsNothing);

    await press(tester, find.text('Save'));
    expect(find.text('Saved goods bought GB000001.'), findsOneWidget);
    final documents = backend.purchases.single['documents'] as List<Map<String, Object?>>;
    expect([for (final d in documents) d['filename']], [photoName, 'invoice.pdf']);
    expect([for (final d in documents) d['mimeType']], ['image/png', 'application/pdf']);
    expect(backend.purchases, hasLength(1));

    // The list's page shows the saved photo's picture (downloaded) and opens it.
    expect(find.text('Supplier documents'), findsOneWidget);
    expect(find.text('Not reviewed'), findsNWidgets(2));
    expect(tester.widget<DocumentThumbnail>(thumbnailOf(photoName)).bytes, photoDocument().bytes);
    await press(tester, find.text(photoName));
    expect(previewImage, findsOneWidget);
    await closePreview(tester);
    // A PDF is downloaded or shared instead.
    await press(tester, find.text('invoice.pdf'));
    expect(app.sharedPdfs.single.$1, 'invoice.pdf');

    // The Goods Bought list says documents are waiting to be checked.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Documents to check'), findsOneWidget);
  });

  testWidgets('finance verifies one document with its total and rejects another with a reason', (
    tester,
  ) async {
    final backend = withPurchase(
      backendFor('accounts'),
      documents: [
        storedDocument('purchase-1-doc-1', photoDocument(), 'image/png'),
        storedDocument('purchase-1-doc-2', pdfDocument(), 'application/pdf'),
      ],
    );
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openPurchase(tester, 'GB000001');
    expect(find.text('Review'), findsNWidgets(2));

    // The total on the photo differs from the list's USD 42.50.
    await review(tester, total: '40.00');
    expect(find.text('$photoName verified.'), findsOneWidget);
    expect(find.textContaining('Verified by Tendai Moyo'), findsOneWidget);
    expect(find.textContaining('Document total USD 40.00'), findsOneWidget);
    expect(find.textContaining("A verified document's total differs"), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);

    // Rejecting needs a reason.
    await review(tester, reject: true);
    expect(find.text('Say why (at least 3 characters)'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Why it is rejected'),
      'Wrong supplier',
    );
    await tester.tap(find.text('Reject document'));
    await tester.pumpAndSettle();
    expect(find.text('invoice.pdf rejected.'), findsOneWidget);
    expect(find.textContaining('Rejected by Tendai Moyo'), findsOneWidget);
    expect(find.textContaining('Wrong supplier'), findsOneWidget);
    expect(find.text('Review'), findsNothing);

    final documents = backend.purchases.single['documents'] as List<Map<String, Object?>>;
    expect(documents.first, containsPair('verificationStatus', 'VERIFIED'));
    expect(documents.first, containsPair('documentTotal', '40.00'));
    expect(documents.last, containsPair('verificationStatus', 'REJECTED'));
    expect(documents.last, containsPair('reviewNotes', 'Wrong supplier'));

    // Every document reviewed: the list shows no document pill.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Documents to check'), findsNothing);
    expect(find.text('No document'), findsNothing);
  });

  testWidgets('a matching total raises no warning; a list without documents says so', (
    tester,
  ) async {
    final backend = withPurchase(
      backendFor('accounts'),
      documents: [storedDocument('purchase-1-doc-1', pdfDocument(), 'application/pdf')],
    );
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openPurchase(tester, 'GB000001');
    await review(tester, total: '42.5');
    expect(find.text('invoice.pdf verified.'), findsOneWidget);
    expect(find.textContaining("A verified document's total differs"), findsNothing);

    backend.purchases.single['documents'] = <Map<String, Object?>>[];
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('No document'), findsOneWidget);
  });

  testWidgets('a storekeeper sees the documents but cannot attach or review them', (tester) async {
    final backend = withPurchase(
      backendFor('storekeeper'),
      documents: [storedDocument('purchase-1-doc-1', photoDocument(), 'image/png')],
    );
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Goods Bought');
    expect(find.text('Documents to check'), findsOneWidget);
    await press(tester, find.textContaining('GB000001'));

    expect(find.text(photoName), findsOneWidget);
    expect(find.text('Not reviewed'), findsOneWidget);
    expect(find.text('Attach document'), findsNothing);
    expect(find.text('Take photo'), findsNothing);
    expect(find.text('Review'), findsNothing);
    await press(tester, find.text(photoName));
    expect(previewImage, findsOneWidget);
    await closePreview(tester);

    // Receiving against the list asks for no document either.
    await press(tester, find.text('Receive'));
    expect(find.text('Attach document'), findsNothing);
    expect(find.text('Take photo'), findsNothing);
  });

  testWidgets('a document the server refuses is reported, and the saved list is kept', (
    tester,
  ) async {
    final backend = backendFor('accounts');
    final app = await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Goods Bought');
    await press(tester, find.text('Record goods bought'));
    await press(tester, find.text('Add product'));
    await tester.tap(find.widgetWithText(InputDecorator, 'Product'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(bbq).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '5');
    await tester.enterText(find.widgetWithText(TextFormField, 'Cost per unit'), '0.50');
    await press(tester, find.text('Done'));
    app.documents.willPick([fakePdf()]);
    await press(tester, find.text('Attach document'));
    await press(tester, find.text('Save'));

    expect(
      find.text('Only PDF, JPEG and PNG documents are accepted (this file is something else).'),
      findsOneWidget,
    );
    expect(backend.purchases, hasLength(1));

    // Without the bad file, saving again changes the same list rather than adding another.
    await press(tester, find.byTooltip('Remove invoice.pdf'));
    await press(tester, find.text('Save'));
    expect(find.text('Saved goods bought GB000001.'), findsOneWidget);
    expect(backend.purchases, hasLength(1));
    expect(backend.requests, contains('PUT /api/v1/purchases/purchase-1'));
  });

  testWidgets('goods-received notes no longer take documents', (tester) async {
    final backend = withPurchase(backendFor('storekeeper'));
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openPurchase(tester, 'GB000001');
    await press(tester, find.text('Receive'));
    await press(tester, find.text('Submit for verification'));
    expect(backend.grns.single['status'], 'PENDING_VERIFICATION');
    expect(backend.grns.single['documents'], isEmpty);
  });
}
