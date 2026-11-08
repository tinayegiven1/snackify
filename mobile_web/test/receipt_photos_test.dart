import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snackify/core/files/document_picker.dart';
import 'package:snackify/features/receipts/presentation/document_preview.dart';

import 'helpers/receipt_steps.dart';
import 'helpers/test_app.dart';

// Supplier documents photographed with the camera, and picture previews of documents.

const bbq = 'Potato Crisps — BBQ — Small';

FakeBackend storekeeperBackend() => FakeBackend(role: 'storekeeper')
  ..addProduct('PC-BBQ-S', 'Potato Crisps', 'BBQ', 'Small', '0.50')
  ..addStock('PC-BBQ-S', 10)
  ..addSupplier('SUP-01', 'Harare Potato Co-op');

Finder thumbnailOf(String filename) => find.descendant(
  of: find.ancestor(of: find.text(filename), matching: find.byType(ListTile)),
  matching: find.byType(DocumentThumbnail),
);

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

  testWidgets('a storekeeper photographs the invoice, previews it and submits it', (tester) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: storekeeperBackend());
    await openSection(tester, 'Goods Received');
    await press(tester, find.text('Receive stock'));
    await addLine(tester, product: bbq, bought: 100, cost: '0.4250');

    // Cancelling the camera adds nothing.
    await press(tester, find.text('Take photo'));
    expect(find.text('Uploaded when you save'), findsNothing);

    app.documents.willPhotograph(photoDocument());
    await press(tester, find.text('Take photo'));
    expect(find.text('photo-20261108-090000.png'), findsOneWidget);
    final thumbnail = tester.widget<DocumentThumbnail>(thumbnailOf('photo-20261108-090000.png'));
    expect(thumbnail.isPdf, isFalse);
    expect(thumbnail.bytes, photoDocument().bytes);

    await press(tester, find.text('photo-20261108-090000.png'));
    expect(find.byKey(const ValueKey('document-preview-image')), findsOneWidget);
    await tester.tap(find.byTooltip('Close preview'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('document-preview-image')), findsNothing);

    await press(tester, find.text('Submit for verification'));
    final documents = app.backend.grns.single['documents'] as List<Map<String, Object?>>;
    expect(documents.single['mimeType'], 'image/png');
    expect(documents.single['filename'], 'photo-20261108-090000.png');

    // The receipt shows the saved photo's picture (downloaded), and a PDF keeps its icon.
    expect(find.text('Waiting for verification'), findsWidgets);
    await press(
      tester,
      find.ancestor(of: find.textContaining('GRN000001'), matching: find.byType(ListTile)).first,
    );
    final saved = tester.widget<DocumentThumbnail>(thumbnailOf('photo-20261108-090000.png'));
    expect(saved.bytes, photoDocument().bytes);
    await press(tester, find.text('photo-20261108-090000.png'));
    expect(find.byKey(const ValueKey('document-preview-image')), findsOneWidget);
  });

  testWidgets('a PDF is shown with an icon and does not open a picture preview', (tester) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: storekeeperBackend());
    await openSection(tester, 'Goods Received');
    await press(tester, find.text('Receive stock'));
    await addLine(tester, product: bbq, bought: 5);
    app.documents.willPick([pdfDocument()]);
    await press(tester, find.text('Attach document'));

    final thumbnail = tester.widget<DocumentThumbnail>(thumbnailOf('invoice.pdf'));
    expect(thumbnail.isPdf, isTrue);
    await press(tester, find.text('invoice.pdf'));
    expect(find.byKey(const ValueKey('document-preview-image')), findsNothing);
  });
}
