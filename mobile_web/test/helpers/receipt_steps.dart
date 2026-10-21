import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snackify/core/files/document_picker.dart';

/// Steps for the goods-received screens, shared by the stock, barcode and receipt tests.

/// A small file the server accepts as a PDF (it checks the first bytes).
PickedDocument pdfDocument([String name = 'invoice.pdf']) =>
    (name: name, bytes: utf8.encode('%PDF-1.4 supplier invoice'));

/// A program renamed to look like a PDF.
PickedDocument fakePdf([String name = 'invoice.pdf']) =>
    (name: name, bytes: utf8.encode('MZ this program cannot be run'));

/// Scrolls [finder] into view, then taps it.
Future<void> press(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Picks [option] in the dropdown labelled [label].
Future<void> chooseOption(WidgetTester tester, String label, String option) async {
  final field = find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is DropdownButtonFormField),
  );
  await press(tester, field.first);
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

/// Adds a product line through the line dialog. [product] is the product's description;
/// [unit] the unit's label (default: the base unit).
Future<void> addLine(
  WidgetTester tester, {
  required String product,
  required int bought,
  int? received,
  String cost = '0.25',
  String? unit,
  String? reason,
  String? batch,
}) async {
  await press(tester, find.text('Add product'));
  await tester.tap(find.widgetWithText(InputDecorator, 'Product'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(product).last);
  await tester.pumpAndSettle();
  await fillLine(
    tester,
    bought: bought,
    received: received,
    cost: cost,
    unit: unit,
    reason: reason,
    batch: batch,
  );
}

/// Fills in the open line dialog (after the product is chosen) and presses Done.
Future<void> fillLine(
  WidgetTester tester, {
  required int bought,
  int? received,
  String cost = '0.25',
  String? unit,
  String? reason,
  String? batch,
}) async {
  if (unit != null) await chooseOption(tester, 'Unit', unit);
  await tester.enterText(find.widgetWithText(TextFormField, 'Bought'), '$bought');
  await tester.enterText(find.widgetWithText(TextFormField, 'Received'), '${received ?? bought}');
  await tester.pumpAndSettle();
  if (reason != null) await chooseOption(tester, 'Why the quantities differ', reason);
  await tester.enterText(find.widgetWithText(TextFormField, 'Cost per unit'), cost);
  if (batch != null) {
    await tester.enterText(find.widgetWithText(TextFormField, 'Batch (optional)'), batch);
  }
  await press(tester, find.text('Done'));
}
