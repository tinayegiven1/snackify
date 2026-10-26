import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snackify/core/files/pdf_sharer.dart';

import 'helpers/receipt_steps.dart';
import 'helpers/test_app.dart';

// StockFlow Stage 5: subsidiary orders, Head Office review and price exceptions.

const bbq = 'Potato Crisps — BBQ — Small';

FakeBackend backendFor(String role) => FakeBackend(role: role)
  ..addProduct('PC-BBQ-S', 'Potato Crisps', 'BBQ', 'Small', '0.50')
  ..addProduct('MP-CH-S', 'Maize Puffs', 'Cheese', 'Small', '0.30')
  ..addStock('PC-BBQ-S', 100);

/// Adds a line through the order's line dialog.
Future<void> addOrderLine(
  WidgetTester tester, {
  required String product,
  required int quantity,
  String? expected,
  String? maximum,
}) async {
  await press(tester, find.text('Add product'));
  await tester.tap(find.widgetWithText(InputDecorator, 'Product'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(product).last);
  await tester.pumpAndSettle();
  await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '$quantity');
  if (expected != null) {
    await tester.enterText(find.widgetWithText(TextFormField, 'Expected price each'), expected);
  }
  if (maximum != null) {
    await tester.enterText(find.widgetWithText(TextFormField, 'Maximum price each'), maximum);
  }
  await press(tester, find.text('Done'));
}

/// Opens the order from the list.
Future<void> openOrder(WidgetTester tester, String number) async {
  await tester.tap(find.textContaining(number).first);
  await tester.pumpAndSettle();
}

/// Answers the open confirmation dialog, typing [comment] first when given.
Future<void> confirmWith(WidgetTester tester, String button, {String? comment}) async {
  if (comment != null) {
    await tester.enterText(
      find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextFormField)),
      comment,
    );
  }
  await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(button)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a subsidiary manager orders with expected and maximum prices, and submits', (
    tester,
  ) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: backendFor('subsidiary_manager'),
    );
    await openSection(tester, 'Orders');
    await press(tester, find.text('New order'));

    // The product's price is suggested; the maximum may not be below the expected price.
    await press(tester, find.text('Add product'));
    await tester.tap(find.widgetWithText(InputDecorator, 'Product'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(bbq).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '3');
    await tester.enterText(find.widgetWithText(TextFormField, 'Expected price each'), '0.10');
    await tester.enterText(find.widgetWithText(TextFormField, 'Maximum price each'), '0.09');
    await press(tester, find.text('Done'));
    expect(find.text('At least the expected price'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Maximum price each'), '0.15');
    await press(tester, find.text('Done'));

    expect(find.text('Expected total USD 0.30 · maximum USD 0.45'), findsOneWidget);
    await press(tester, find.text('Submit order'));
    expect(find.text('Submit order?'), findsOneWidget);
    await confirmWith(tester, 'Submit');

    expect(find.text('Submitted ORD000001 to the Head Office.'), findsOneWidget);
    final order = app.backend.subsidiaryOrders.single;
    expect(order['status'], 'SUBMITTED');
    expect(order['organisationId'], 'org-sub-1'); // always the user's own subsidiary
    expect(order['idempotencyKey'], matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(app.backend.requests.where((r) => r == 'POST /api/v1/orders'), hasLength(1));
  });

  testWidgets('a lost response and a second press still make one order', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: backendFor('subsidiary_manager'),
    );
    await openSection(tester, 'Orders');
    await press(tester, find.text('New order'));
    await addOrderLine(tester, product: bbq, quantity: 5);

    app.backend.loseNextResponse = true;
    await press(tester, find.text('Save draft'));
    expect(find.textContaining('Cannot reach the Snackify server'), findsOneWidget);
    await press(tester, find.text('Save draft'));

    expect(find.text('Saved draft ORD000001.'), findsOneWidget);
    expect(app.backend.subsidiaryOrders, hasLength(1));
    expect(app.backend.requests.where((r) => r == 'POST /api/v1/orders'), hasLength(2));
  });

  testWidgets('the subsidiary cancels a submitted order with a reason', (tester) async {
    final backend = backendFor('subsidiary_manager')
      ..addOrder('org-sub-1', {'PC-BBQ-S': (10, '0.50', '0.55')});
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Orders');
    await openOrder(tester, 'ORD000001');
    expect(find.text('Set actual prices'), findsNothing); // the Head Office's job

    await press(tester, find.text('Cancel order'));
    await confirmWith(tester, 'Cancel order');
    expect(find.text('Explain in a few words'), findsOneWidget);
    await confirmWith(tester, 'Cancel order', comment: 'Ordered twice');

    expect(find.text('Cancelled ORD000001.'), findsOneWidget);
    expect(find.text('Cancelled: Ordered twice'), findsOneWidget);
    expect(backend.subsidiaryOrders.single['status'], 'CANCELLED');
  });

  testWidgets('a subsidiary sees only its own orders', (tester) async {
    final backend = backendFor('subsidiary_manager')
      ..organisations.add({
        'id': 'org-sub-2',
        'code': 'SUB-02',
        'name': 'Glen View Branch',
        'type': 'SUBSIDIARY',
        'isActive': true,
        'customerId': null,
      })
      ..addOrder('org-sub-1', {'PC-BBQ-S': (10, '0.50', '0.55')})
      ..addOrder('org-sub-2', {'PC-BBQ-S': (20, '0.50', '0.55')});
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Orders');

    expect(find.textContaining('ORD000001 · Mbare Branch'), findsOneWidget);
    expect(find.textContaining('ORD000002'), findsNothing);
    expect(find.text('Price exceptions'), findsNothing); // Head Office filters only
  });

  testWidgets('finance sets an actual price above the maximum and approves it with a reason', (
    tester,
  ) async {
    final backend = backendFor('accounts')
      ..addOrder('org-sub-1', {'PC-BBQ-S': (10, '0.50', '0.55')});
    final app = await pumpSnackify(tester, signedIn: true, backend: backend, size: desktopSize);
    await openSection(tester, 'Orders');
    // The review queue starts with submitted orders.
    expect(find.widgetWithText(ChoiceChip, 'Submitted'), findsOneWidget);
    await openOrder(tester, 'ORD000001');
    expect(find.text('Head Office has 100 in stock (needs 10).'), findsOneWidget);
    expect(find.text('Actual: not set'), findsOneWidget);

    await press(tester, find.text('Set actual prices'));
    await tester.enterText(find.widgetWithText(TextFormField, 'Actual price each (USD)'), '0.60');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Comment on the change (optional)'),
      'Supplier price rise',
    );
    await press(tester, find.text('Save prices'));

    expect(find.text('Actual prices saved.'), findsOneWidget);
    expect(find.text('Actual USD 0.60 = USD 6.00'), findsOneWidget);
    expect(find.text('Above maximum'), findsOneWidget);
    expect(find.text('Line 1: actual price set to 0.60'), findsOneWidget);
    expect(find.text('Under review (was submitted)'), findsOneWidget);

    await press(tester, find.text('Approve'));
    expect(find.textContaining('price exception: say why'), findsOneWidget);
    await confirmWith(tester, 'Approve');
    expect(find.text('Explain in a few words'), findsOneWidget);
    await confirmWith(tester, 'Approve', comment: 'Agreed with the branch by phone');

    expect(find.text('Approved ORD000001.'), findsOneWidget);
    expect(
      find.text('A price above the maximum was approved as a price exception.'),
      findsOneWidget,
    );
    expect(backend.subsidiaryOrders.single['status'], 'APPROVED');

    await press(tester, find.byTooltip(sharePdfLabel));
    expect(app.sharedPdfs.single.$1, 'ORD000001.pdf');
  });

  testWidgets('finance rejects an order with a reason the subsidiary can read', (tester) async {
    final backend = backendFor('accounts')
      ..addOrder('org-sub-1', {'PC-BBQ-S': (10, '0.50', '0.55')});
    await pumpSnackify(tester, signedIn: true, backend: backend, size: desktopSize);
    await openSection(tester, 'Orders');
    await openOrder(tester, 'ORD000001');

    await press(tester, find.text('Reject'));
    await confirmWith(tester, 'Reject', comment: 'Out of season');
    expect(find.text('Rejected ORD000001.'), findsOneWidget);
    expect(find.text('Rejected by Tendai Moyo: Out of season'), findsOneWidget);
    expect(find.text('Approve'), findsNothing);
  });

  testWidgets('sales staff can follow orders but not decide them', (tester) async {
    final backend = backendFor('salesperson')
      ..addOrder('org-sub-1', {'PC-BBQ-S': (10, '0.50', '0.55')});
    await pumpSnackify(tester, signedIn: true, backend: backend, size: desktopSize);
    await openSection(tester, 'Orders');
    expect(find.text('New order'), findsNothing);
    await openOrder(tester, 'ORD000001');
    for (final action in ['Set actual prices', 'Approve', 'Reject', 'Start review']) {
      expect(find.text(action), findsNothing, reason: action);
    }
  });
}
