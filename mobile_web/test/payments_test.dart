import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snackify/core/formatting/dates.dart';

import 'helpers/test_app.dart';

/// Two products and two customers; tests add invoices and payments as needed.
FakeBackend backendForPayments(String role) => FakeBackend(role: role)
  ..addProduct('PC-BBQ-S', 'Potato Crisps', 'BBQ', 'Small', '0.50')
  ..addProduct('MP-CH-S', 'Maize Puffs', 'Cheese', 'Small', '0.30')
  ..addCustomer('C0001', 'Avondale Tuckshop')
  ..addCustomer('C0002', 'Mabelreign Grocers');

/// Avondale owes INV-000001 (USD 10.00, issued 14 days ago, overdue 7 days) and INV-000002
/// (USD 5.00, issued today).
FakeBackend backendWithInvoices(String role) => backendForPayments(role)
  ..addIssuedInvoice('C0001', {'PC-BBQ-S': 20}, daysAgo: 14)
  ..addIssuedInvoice('C0001', {'PC-BBQ-S': 10});

String daysFromToday(int days) => formatApiDate(toApiDate(today().add(Duration(days: days))));

Future<void> tapButton(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> startPaymentFor(WidgetTester tester, String customerName) async {
  await openSection(tester, 'Payments');
  await tester.tap(find.text('Record payment'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Choose a customer'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(customerName));
  await tester.pumpAndSettle();
}

String allocated(WidgetTester tester, String invoiceId) =>
    tester.widget<TextField>(find.byKey(ValueKey('allocation-$invoiceId'))).controller!.text;

final amountField = find.widgetWithText(TextFormField, 'Amount received');
final saveButton = find.widgetWithText(FilledButton, 'Record payment');

void main() {
  testWidgets('a payment pays the oldest invoices first; the rest is kept as credit', (
    tester,
  ) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: backendWithInvoices('accounts'),
    );
    await startPaymentFor(tester, 'Avondale Tuckshop');

    expect(find.text('USD 10.00 left · overdue 7 days'), findsOneWidget);
    expect(find.text('USD 5.00 left · due ${daysFromToday(7)}'), findsOneWidget);

    await tester.enterText(amountField, '12');
    await tester.pumpAndSettle();
    expect(allocated(tester, 'invoice-1'), '10.00');
    expect(allocated(tester, 'invoice-2'), '2.00');
    expect(find.text('Applied to invoices: USD 12.00 · kept as credit: USD 0.00'), findsOneWidget);

    await tester.enterText(amountField, '20');
    await tester.pumpAndSettle();
    expect(allocated(tester, 'invoice-2'), '5.00');
    expect(find.text('Applied to invoices: USD 15.00 · kept as credit: USD 5.00'), findsOneWidget);

    await tester.tap(find.text('Cash'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile money').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Reference (optional)'),
      'MP261012.1234',
    );
    await tapButton(tester, saveButton);

    // The new payment opens.
    expect(find.text('P000001'), findsOneWidget);
    expect(find.text('USD 20.00'), findsOneWidget);
    expect(
      find.text('Received ${daysFromToday(0)} · Mobile money · ref MP261012.1234'),
      findsOneWidget,
    );
    expect(find.text('INV-000001'), findsOneWidget);
    expect(find.text('Credit left'), findsOneWidget);
    final payment = app.backend.payments.single;
    expect(payment['method'], 'mobile_money');
    expect(payment['idempotencyKey'], isA<String>());
    expect(payment['allocations'], [
      {'invoiceId': 'invoice-1', 'amount': '10.00'},
      {'invoiceId': 'invoice-2', 'amount': '5.00'},
    ]);
  });

  testWidgets('amounts can be changed by hand, and are checked before anything is sent', (
    tester,
  ) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: backendWithInvoices('accounts'),
    );
    await startPaymentFor(tester, 'Avondale Tuckshop');

    await tapButton(tester, saveButton);
    expect(find.text('Enter an amount like 25.00'), findsOneWidget);

    await tester.enterText(amountField, '5');
    await tester.pumpAndSettle();
    expect(allocated(tester, 'invoice-1'), '5.00');

    await tester.enterText(find.byKey(const ValueKey('allocation-invoice-1')), '12');
    await tester.pumpAndSettle();
    expect(find.text('At most USD 10.00'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('allocation-invoice-1')), '3');
    await tester.enterText(find.byKey(const ValueKey('allocation-invoice-2')), '3');
    await tester.pumpAndSettle();
    expect(
      find.text('The invoices add up to USD 6.00, more than the USD 5.00 received.'),
      findsOneWidget,
    );
    await tapButton(tester, saveButton);
    expect(app.backend.requests, isNot(contains('POST /api/v1/payments')));

    // Amounts typed by hand stay put when the amount received changes.
    await tester.enterText(amountField, '8');
    await tester.pumpAndSettle();
    expect(allocated(tester, 'invoice-1'), '3');
    expect(find.text('Applied to invoices: USD 6.00 · kept as credit: USD 2.00'), findsOneWidget);

    await tapButton(tester, saveButton);
    expect(app.backend.payments.single['allocations'], [
      {'invoiceId': 'invoice-1', 'amount': '3.00'},
      {'invoiceId': 'invoice-2', 'amount': '3.00'},
    ]);
  });

  testWidgets('a payment is recorded once, even if the connection drops and it is sent again', (
    tester,
  ) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: backendWithInvoices('accounts'),
    );
    await startPaymentFor(tester, 'Avondale Tuckshop');
    await tester.enterText(amountField, '10');
    await tester.pumpAndSettle();

    // The server records it, but the answer never arrives.
    app.backend.loseNextResponse = true;
    await tapButton(tester, saveButton);
    expect(find.textContaining('Cannot reach the Snackify server'), findsOneWidget);
    expect(app.backend.payments, hasLength(1));

    await tapButton(tester, saveButton);

    expect(find.text('P000001'), findsOneWidget);
    expect(app.backend.payments, hasLength(1));
  });

  testWidgets('balances show who owes what; an account shows open invoices and a statement', (
    tester,
  ) async {
    final backend = backendWithInvoices('accounts')
      ..addConfirmedDispatch('C0001', {'MP-CH-S': 5}) // 1.50, not yet invoiced
      ..addPayment('C0001', '4.00', {'invoice-1': '4.00'})
      ..addPayment('C0002', '2.00'); // paid in advance
    await pumpSnackify(tester, signedIn: true, size: desktopSize, backend: backend);
    await openSection(tester, 'Payments');

    expect(find.text('All customers'), findsOneWidget);
    expect(find.text('USD 10.50'), findsOneWidget); // 12.50 owed by Avondale, less 2.00 credit
    expect(find.text('Avondale Tuckshop (C0001)'), findsOneWidget);
    expect(find.text('Overdue USD 6.00 since ${daysFromToday(-7)}'), findsOneWidget);
    expect(find.text('USD 12.50'), findsOneWidget);
    expect(find.text('Mabelreign Grocers (C0002)'), findsOneWidget);
    expect(find.text('In credit USD 2.00'), findsOneWidget);

    await tester.tap(find.text('Avondale Tuckshop (C0001)'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Avondale Tuckshop'), findsOneWidget);
    expect(find.text('Overdue 7 days (due ${daysFromToday(-7)})'), findsOneWidget);
    expect(find.text('Due ${daysFromToday(7)}'), findsOneWidget);

    final lastWeek = backend.lastWeek;
    await tester.dragUntilVisible(
      find.text('Balance at the end'),
      find.byType(ListView),
      const Offset(0, -300),
    );
    expect(
      find.text('Invoice INV-000001 (${formatApiPeriod(lastWeek.from, lastWeek.to)})'),
      findsOneWidget,
    );
    expect(find.text('Payment P000001 · Cash'), findsOneWidget);
    expect(find.text('${daysFromToday(0)} · balance USD 11.00'), findsOneWidget);
  });

  testWidgets('credit can be applied to an invoice later', (tester) async {
    final backend = backendForPayments('accounts')
      ..addIssuedInvoice('C0001', {'PC-BBQ-S': 6}) // 3.00
      ..addPayment('C0001', '5.00');
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Payments');
    await tester.tap(find.widgetWithText(Tab, 'Payments'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('P000001 · Avondale Tuckshop'));
    await tester.pumpAndSettle();
    expect(find.text('Not applied to any invoice'), findsOneWidget);

    await tapButton(tester, find.text('Allocate credit'));
    expect(find.text('P000001 has USD 5.00 of credit to apply.'), findsOneWidget);
    expect(allocated(tester, 'invoice-1'), '3.00');
    expect(find.text('Credit still left after this: USD 2.00'), findsOneWidget);

    await tapButton(tester, find.text('Apply credit'));

    expect(find.text('INV-000001'), findsOneWidget);
    expect(find.text('USD 2.00'), findsOneWidget); // credit left
    expect(backend.payments.single['allocations'], [
      {'invoiceId': 'invoice-1', 'amount': '3.00'},
    ]);
  });

  testWidgets('only admins void a payment, with a reason; its invoices are owed again', (
    tester,
  ) async {
    final backend = backendWithInvoices('admin')
      ..addPayment('C0001', '4.00', {'invoice-1': '4.00'});
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Payments');
    await tester.tap(find.widgetWithText(Tab, 'Payments'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('P000001 · Avondale Tuckshop'));
    await tester.pumpAndSettle();

    await tapButton(tester, find.text('Void payment'));
    await tester.tap(find.widgetWithText(FilledButton, 'Void payment'));
    await tester.pumpAndSettle();
    expect(find.text('Explain the reason in a few words'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Reason'), 'Cheque bounced');
    await tester.tap(find.widgetWithText(FilledButton, 'Void payment'));
    await tester.pumpAndSettle();

    expect(find.text('Voided'), findsOneWidget);
    expect(
      find.text('Voided by Tendai Moyo: Cheque bounced. It no longer pays any invoice.'),
      findsOneWidget,
    );
    expect(find.text('Void payment'), findsNothing);
    expect(backend.payments.single['status'], 'voided');
  });

  testWidgets('accounts staff cannot void payments', (tester) async {
    final backend = backendWithInvoices('accounts')
      ..addPayment('C0001', '4.00', {'invoice-1': '4.00'});
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Payments');
    await tester.tap(find.widgetWithText(Tab, 'Payments'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('P000001 · Avondale Tuckshop'));
    await tester.pumpAndSettle();

    expect(find.text('USD 4.00'), findsWidgets);
    expect(find.text('Void payment'), findsNothing);
  });

  testWidgets('invoices show what has been paid and whether they are overdue', (tester) async {
    final backend = backendWithInvoices('accounts')
      ..addPayment('C0001', '2.00', {'invoice-2': '2.00'});
    final app = await pumpSnackify(tester, signedIn: true, size: desktopSize, backend: backend);
    await openSection(tester, 'Invoices');

    Finder badgeOn(String title, String badge) => find.descendant(
      of: find.ancestor(of: find.text(title), matching: find.byType(ListTile)),
      matching: find.text(badge),
    );
    expect(badgeOn('INV-000001 · Avondale Tuckshop', 'Overdue'), findsOneWidget);
    expect(badgeOn('INV-000002 · Avondale Tuckshop', 'Part paid'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Overdue'));
    await tester.pumpAndSettle();
    expect(app.backend.requests.last, 'GET /api/v1/invoices?payment=overdue&limit=200');
    expect(find.text('INV-000002 · Avondale Tuckshop'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Unpaid'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('INV-000002 · Avondale Tuckshop'));
    await tester.pumpAndSettle();

    expect(find.text('Due ${daysFromToday(7)}'), findsOneWidget);
    expect(find.text('Part paid'), findsOneWidget);
    expect(find.text('P000001'), findsOneWidget);
    expect(find.text('${daysFromToday(0)} · Cash'), findsOneWidget);
    expect(find.text('USD 3.00'), findsOneWidget); // balance due
  });

  testWidgets('payments are not offered to sales and warehouse staff', (tester) async {
    for (final role in ['salesperson', 'storekeeper']) {
      final app = await pumpSnackify(tester, signedIn: true, backend: backendForPayments(role));

      expect(await menuSections(tester), isNot(contains('Payments')), reason: role);
      expect(
        app.backend.requests.where((r) => r.contains('/payments') || r.contains('/balances')),
        isEmpty,
        reason: role,
      );
    }
  });
}
