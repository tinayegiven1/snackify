import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snackify/core/formatting/dates.dart';

import 'helpers/test_app.dart';

/// Two products and two customers, with confirmed dispatches last week:
/// Avondale 12 BBQ + 5 Cheese (USD 7.50) and Mabelreign 4 BBQ (USD 2.00).
/// Also a cancelled dispatch, a draft, and one from the week before, none of which are billed.
FakeBackend backendForInvoices(String role) {
  final backend = FakeBackend(role: role)
    ..addProduct('PC-BBQ-S', 'Potato Crisps', 'BBQ', 'Small', '0.50')
    ..addProduct('MP-CH-S', 'Maize Puffs', 'Cheese', 'Small', '0.30')
    ..addCustomer(
      'C0001',
      'Avondale Tuckshop',
      phone: '+263 00 000 0001',
      address: '1 Example Road',
    )
    ..addCustomer('C0002', 'Mabelreign Grocers');
  backend
    ..addConfirmedDispatch('C0001', {'PC-BBQ-S': 12, 'MP-CH-S': 5})
    ..addConfirmedDispatch('C0002', {'PC-BBQ-S': 4})
    ..addConfirmedDispatch('C0002', {'MP-CH-S': 9})['status'] = 'cancelled';
  backend.addDraft('C0001', {'PC-BBQ-S': 1});
  backend.addConfirmedDispatch('C0001', {
    'PC-BBQ-S': 2,
  }, date: toApiDate(DateTime.parse(backend.lastWeek.from).subtract(const Duration(days: 3))));
  return backend;
}

String get lastWeekLabel {
  final backend = FakeBackend();
  return formatApiPeriod(backend.lastWeek.from, backend.lastWeek.to);
}

Future<void> tapButton(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> openWeeklyInvoicing(WidgetTester tester) async {
  await openSection(tester, 'Invoices');
  await tester.tap(find.text('Weekly invoicing'));
  await tester.pumpAndSettle();
}

/// From the weekly screen: preview Avondale, create its draft, which then opens.
Future<void> createAvondaleDraft(WidgetTester tester) async {
  await tester.tap(find.text('Avondale Tuckshop (C0001)'));
  await tester.pumpAndSettle();
  await tapButton(tester, 'Create draft invoice');
}

void main() {
  testWidgets('the weekly run lists who still needs invoicing and creates all the drafts', (
    tester,
  ) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: backendForInvoices('accounts'));
    await openSection(tester, 'Invoices');
    expect(find.text('No invoices found'), findsOneWidget);

    await tester.tap(find.text('Weekly invoicing'));
    await tester.pumpAndSettle();

    // Last complete week by default; only confirmed dispatches from that week count.
    expect(find.text(lastWeekLabel), findsOneWidget);
    expect(find.text('Avondale Tuckshop (C0001)'), findsOneWidget);
    expect(find.text('1 dispatch · 2 lines'), findsOneWidget);
    expect(find.text('USD 7.50'), findsOneWidget);
    expect(find.text('Mabelreign Grocers (C0002)'), findsOneWidget);
    expect(find.text('USD 2.00'), findsOneWidget);

    await tapButton(tester, 'Create draft invoices for all 2 customers');
    expect(find.text('Create 2 draft invoices?'), findsOneWidget);
    await tester.tap(find.text('Create drafts'));
    await tester.pumpAndSettle();

    // Back on the list, showing the new drafts.
    expect(find.text('Created 2 draft invoices. Check each one, then issue it.'), findsOneWidget);
    expect(find.text('Draft · Avondale Tuckshop'), findsOneWidget);
    expect(find.text('Draft · Mabelreign Grocers'), findsOneWidget);
    expect(app.backend.invoices, hasLength(2));
  });

  testWidgets('a preview saves nothing; the draft is then checked and issued', (tester) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: backendForInvoices('accounts'));
    await openWeeklyInvoicing(tester);

    await tester.tap(find.text('Avondale Tuckshop (C0001)'));
    await tester.pumpAndSettle();

    // The preview: customer details, period and every line, with nothing saved yet.
    final tuesday = formatApiDate(
      toApiDate(DateTime.parse(app.backend.lastWeek.from).add(const Duration(days: 1))),
    );
    expect(find.text('Invoice preview'), findsOneWidget);
    expect(find.text('1 Example Road'), findsOneWidget);
    expect(find.text('Period: $lastWeekLabel'), findsOneWidget);
    expect(find.text('Potato Crisps — BBQ — Small'), findsOneWidget);
    expect(find.text('D000001 · $tuesday · 12 × USD 0.50'), findsOneWidget);
    expect(find.text('USD 6.00'), findsOneWidget);
    expect(find.text('D000001 · $tuesday · 5 × USD 0.30'), findsOneWidget);
    expect(find.text('USD 7.50'), findsOneWidget);
    expect(app.backend.invoices, isEmpty);

    await tapButton(tester, 'Create draft invoice');

    expect(find.text('Draft invoice'), findsOneWidget);
    expect(find.text('Not issued yet'), findsOneWidget);
    expect(find.text('Balance due'), findsOneWidget);
    expect(find.text('USD 7.50'), findsNWidgets(3)); // subtotal, total, balance due

    // Changing one's mind issues nothing.
    await tapButton(tester, 'Issue invoice');
    await tester.tap(find.text('Go back'));
    await tester.pumpAndSettle();
    expect(find.text('Not issued yet'), findsOneWidget);
    expect(app.backend.requests.where((r) => r.endsWith('/issue')), isEmpty);

    await tapButton(tester, 'Issue invoice');
    expect(find.text('Issue this invoice?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Issue'));
    await tester.pumpAndSettle();

    expect(find.text('INV-000001'), findsOneWidget);
    expect(find.text('Issued ${formatApiDate(toApiDate(today()))}'), findsOneWidget);
    expect(find.textContaining('Issued: this invoice is final'), findsOneWidget);
    expect(find.text('Issue invoice'), findsNothing);
    expect(find.text('Void draft'), findsNothing);

    // Back on the weekly screen, only Mabelreign is left to invoice.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Avondale Tuckshop (C0001)'), findsNothing);
    expect(find.text('Mabelreign Grocers (C0002)'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('INV-000001 · Avondale Tuckshop'), findsOneWidget);
  });

  testWidgets('voiding a draft needs a reason and frees its dispatches', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: backendForInvoices('accounts'));
    await openWeeklyInvoicing(tester);
    await createAvondaleDraft(tester);

    await tapButton(tester, 'Void draft');
    await tester.tap(find.widgetWithText(FilledButton, 'Void draft'));
    await tester.pumpAndSettle();
    expect(find.text('Explain the reason in a few words'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Reason'), 'Wrong prices');
    await tester.tap(find.widgetWithText(FilledButton, 'Void draft'));
    await tester.pumpAndSettle();

    expect(find.text('Voided'), findsOneWidget);
    expect(
      find.text('Voided: Wrong prices. Its dispatches can be invoiced again.'),
      findsOneWidget,
    );
    expect(find.text('USD 0.00'), findsNWidgets(2)); // amount paid, balance due
    expect(find.text('Issue invoice'), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Avondale Tuckshop (C0001)'), findsOneWidget);
  });

  testWidgets('the PDF is handed to the device, named after the invoice number', (tester) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: backendForInvoices('admin'));
    await openWeeklyInvoicing(tester);
    await createAvondaleDraft(tester);

    await tapButton(tester, 'Share PDF');
    expect(app.sharedPdfs, [('draft-C0001-${app.backend.lastWeek.from}.pdf', '%PDF-1.3 draft')]);

    await tapButton(tester, 'Issue invoice');
    await tester.tap(find.widgetWithText(FilledButton, 'Issue'));
    await tester.pumpAndSettle();
    await tapButton(tester, 'Share PDF');

    expect(app.sharedPdfs.last, ('INV-000001.pdf', '%PDF-1.3 INV-000001'));
    expect(app.backend.requests, contains('GET /api/v1/invoices/invoice-1/pdf'));
  });

  testWidgets('a draft someone else just created is reported, and the preview refreshes', (
    tester,
  ) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: backendForInvoices('accounts'));
    await openWeeklyInvoicing(tester);
    await tester.tap(find.text('Avondale Tuckshop (C0001)'));
    await tester.pumpAndSettle();

    // Another member of staff invoices Avondale while this preview is open.
    await app.api.postJson('/api/v1/invoices', {'customerId': 'customer-1'});

    await tapButton(tester, 'Create draft invoice');
    expect(
      find.text('This customer has no confirmed, unbilled dispatches in that period.'),
      findsOneWidget,
    );
    expect(app.backend.invoices, hasLength(1));

    await tapButton(tester, 'Refresh preview');
    expect(find.textContaining('Nothing to invoice'), findsOneWidget);
    expect(find.text('Create draft invoice'), findsNothing);
  });

  testWidgets('another week can be chosen', (tester) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: backendForInvoices('accounts'));
    await openWeeklyInvoicing(tester);

    await tester.tap(find.byTooltip('Previous week'));
    await tester.pumpAndSettle();

    final weekBefore = (
      from: toApiDate(DateTime.parse(app.backend.lastWeek.from).subtract(const Duration(days: 7))),
      to: toApiDate(DateTime.parse(app.backend.lastWeek.to).subtract(const Duration(days: 7))),
    );
    expect(find.text(formatApiPeriod(weekBefore.from, weekBefore.to)), findsOneWidget);
    expect(
      app.backend.requests,
      contains('GET /api/v1/invoices/unbilled?from=${weekBefore.from}&to=${weekBefore.to}'),
    );
    expect(find.text('Avondale Tuckshop (C0001)'), findsOneWidget);
    expect(find.text('1 dispatch · 1 line'), findsOneWidget);
    expect(find.text('Mabelreign Grocers (C0002)'), findsNothing);
  });

  testWidgets('the list can be filtered and searched', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      size: desktopSize,
      backend: backendForInvoices('accounts'),
    );
    await openWeeklyInvoicing(tester);
    await tapButton(tester, 'Create draft invoices for all 2 customers');
    await tester.tap(find.text('Create drafts'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'mabel');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('Draft · Mabelreign Grocers'), findsOneWidget);
    expect(find.text('Draft · Avondale Tuckshop'), findsNothing);
    expect(app.backend.requests.last, 'GET /api/v1/invoices?q=mabel&limit=200');

    await tester.tap(find.text('Issued'));
    await tester.pumpAndSettle();
    expect(find.text('No invoices found'), findsOneWidget);
  });

  testWidgets('invoices are not offered to sales and warehouse staff', (tester) async {
    for (final role in ['salesperson', 'storekeeper']) {
      final app = await pumpSnackify(tester, signedIn: true, backend: backendForInvoices(role));

      final sections = await menuSections(tester);
      expect(sections, containsAll(['Products', 'Dispatches']), reason: role);
      expect(sections, isNot(contains('Invoices')), reason: role);
      expect(app.backend.requests.where((r) => r.contains('/invoices')), isEmpty, reason: role);
    }
  });

  testWidgets('a server that cannot be reached is explained, with a way to try again', (
    tester,
  ) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: backendForInvoices('accounts'));
    app.backend.reachable = false;
    await openSection(tester, 'Invoices');

    expect(find.text('Could not load invoices'), findsOneWidget);

    app.backend.reachable = true;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('No invoices found'), findsOneWidget);
  });
}
