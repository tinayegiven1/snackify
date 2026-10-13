import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snackify/core/formatting/dates.dart';

import 'helpers/test_app.dart';

String day(int offset) => toApiDate(today().add(Duration(days: offset)));

Map<String, Object?> measures(
  int dispatches,
  int packs,
  String sales,
  String invoiced,
  String paid,
) => {
  'dispatches': dispatches,
  'packs': packs,
  'salesValue': sales,
  'invoiced': invoiced,
  'paymentsReceived': paid,
};

/// Three days of sales, as the server would report them.
Map<String, Object?> salesAnswer(String groupBy) => {
  'from': day(-2),
  'to': day(0),
  'groupBy': groupBy,
  'currency': 'USD',
  'totals': measures(4, 45, '19.80', '13.50', '7.50'),
  'periods': [
    {'start': day(-2), 'end': day(-2), ...measures(1, 20, '10.00', '0.00', '4.00')},
    {'start': day(-1), 'end': day(-1), ...measures(0, 0, '0.00', '10.00', '0.00')},
    {'start': day(0), 'end': day(0), ...measures(3, 25, '9.80', '3.50', '3.50')},
  ],
};

Future<void> openReports(WidgetTester tester) => openSection(tester, 'Reports');

void main() {
  testWidgets('admins and accounts staff see money on the dashboard, each figure labelled', (
    tester,
  ) async {
    final backend = FakeBackend(role: 'accounts')
      ..reportAnswers['dashboard'] = {
        'dashboard': {
          'today': day(0),
          'dispatchesToday': {'dispatches': 3, 'packs': 25, 'salesValue': '9.80'},
          'dispatchesThisWeek': {'dispatches': 4, 'packs': 45, 'salesValue': '19.80'},
          'receivedToday': {'receipts': 1, 'packs': 48},
          'lowStock': {'count': 0, 'products': <Object>[]},
          'expiring': {
            'withinDays': 30,
            'count': 1,
            'batches': [
              {
                'product': {
                  'id': 'p1',
                  'sku': 'MP-CH-S',
                  'description': 'Maize Puffs — Cheese — Small',
                },
                'batchNumber': 'SOON',
                'receivedDate': day(-10),
                'expiryDate': day(3),
                'daysToExpiry': 3,
                'estimatedPacksLeft': 5,
              },
            ],
          },
          'money': {
            'currency': 'USD',
            'salesThisMonth': '19.80',
            'invoicedThisMonth': '13.50',
            'paymentsThisMonth': '7.50',
            'owedByCustomers': '12.30',
            'overdue': '6.00',
          },
          'trend': [
            for (var i = 13; i >= 0; i--)
              {'date': day(-i), 'packs': i == 0 ? 25 : 0, 'salesValue': i == 0 ? '9.80' : '0.00'},
          ],
        },
      };
    await pumpSnackify(tester, signedIn: true, size: desktopSize, backend: backend);

    expect(find.text('25 packs'), findsOneWidget);
    expect(find.text('3 confirmed dispatches · USD 9.80'), findsOneWidget);
    expect(find.text('48 packs'), findsOneWidget);
    expect(find.text('1 delivery'), findsOneWidget);
    expect(find.text('Money'), findsOneWidget);
    expect(find.text('Sales value this month'), findsOneWidget);
    expect(find.text('Invoiced this month'), findsOneWidget);
    expect(find.text('Payments received this month'), findsOneWidget);
    expect(find.text('USD 12.30'), findsOneWidget);
    expect(find.text('Owed by customers now'), findsOneWidget);
    expect(find.text('Sales value, last 14 days'), findsOneWidget);

    // The expiring batch, with the estimate explained.
    await tester.dragUntilVisible(
      find.text('about 5 left'),
      find.byType(SingleChildScrollView).first,
      const Offset(0, -300),
    );
    expect(find.text('Batch SOON · expires ${formatApiDate(day(3))} (in 3 days)'), findsOneWidget);
    expect(find.textContaining('the oldest stock is assumed to go first'), findsOneWidget);
  });

  testWidgets('the sales report shows separate measures, a chart and the same numbers as a table', (
    tester,
  ) async {
    final backend = FakeBackend(role: 'accounts')..reportAnswers['sales'] = salesAnswer('day');
    final app = await pumpSnackify(tester, signedIn: true, size: desktopSize, backend: backend);
    await openReports(tester);

    expect(app.backend.requests.last, startsWith('GET /api/v1/reports/sales?from='));
    expect(app.backend.requests.last, endsWith('&groupBy=day'));
    for (final label in ['Sales value', 'Packs dispatched', 'Invoiced', 'Payments received']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(find.text('USD 19.80'), findsOneWidget);
    expect(find.text('4 confirmed dispatches'), findsOneWidget);

    // One column per day, each with its exact value in a tooltip.
    expect(find.byKey(const ValueKey('bar-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('bar-2')), findsOneWidget);
    expect(find.byTooltip('${formatApiDate(day(-2))}: USD 10.00, 20 packs'), findsOneWidget);

    // The table.
    await tester.dragUntilVisible(
      find.byType(DataTable),
      find.byType(Scrollable).last,
      const Offset(0, -300),
    );
    expect(find.text('USD 9.80'), findsWidgets);

    // Grouping by week asks the server again.
    await tester.dragUntilVisible(
      find.text('By week'),
      find.byType(Scrollable).last,
      const Offset(0, 300),
    );
    await tester.tap(find.text('By week'));
    await tester.pumpAndSettle();
    expect(app.backend.requests.last, endsWith('&groupBy=week'));
  });

  testWidgets('the period can be changed', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      size: desktopSize,
      backend: FakeBackend(role: 'admin'),
    );
    await openReports(tester);

    await tester.tap(find.text('Last 30 days'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('This month').last);
    await tester.pumpAndSettle();

    final firstOfMonth = toApiDate(DateTime(today().year, today().month));
    expect(app.backend.requests.last, contains('from=$firstOfMonth&to=${day(0)}'));
    expect(find.text(formatApiPeriod(firstOfMonth, day(0))), findsOneWidget);
  });

  testWidgets('best sellers can be ranked by value or packs', (tester) async {
    final backend = FakeBackend(role: 'accounts')
      ..reportAnswers['products'] = {
        'products': [
          {
            'product': {
              'id': 'p1',
              'sku': 'PC-BBQ-S',
              'description': 'Potato Crisps — BBQ — Small',
            },
            'dispatches': 3,
            'packs': 30,
            'salesValue': '15.30',
          },
          {
            'product': {
              'id': 'p2',
              'sku': 'MP-CH-S',
              'description': 'Maize Puffs — Cheese — Small',
            },
            'dispatches': 2,
            'packs': 15,
            'salesValue': '4.50',
          },
        ],
        'totals': {'packs': 45, 'salesValue': '19.80'},
      };
    final app = await pumpSnackify(tester, signedIn: true, size: desktopSize, backend: backend);
    await openReports(tester);
    await tester.tap(find.widgetWithText(Tab, 'Products'));
    await tester.pumpAndSettle();

    expect(find.text('Potato Crisps — BBQ — Small'), findsOneWidget);
    expect(find.text('30 packs · 3 dispatches · PC-BBQ-S'), findsOneWidget);
    expect(find.text('USD 15.30'), findsOneWidget);
    expect(app.backend.requests.last, endsWith('&sortBy=value'));

    await tester.tap(find.text('By packs'));
    await tester.pumpAndSettle();
    expect(app.backend.requests.last, endsWith('&sortBy=packs'));
  });

  testWidgets('customer summaries say who is in credit', (tester) async {
    final backend = FakeBackend(role: 'accounts')
      ..reportAnswers['customers'] = {
        'customers': [
          {
            'customer': {'id': 'c1', 'code': 'C0001', 'name': 'Avondale Tuckshop'},
            'dispatches': 2,
            'packs': 30,
            'salesValue': '13.00',
            'invoiced': '10.00',
            'paymentsReceived': '4.00',
            'balanceNow': '9.00',
          },
          {
            'customer': {'id': 'c2', 'code': 'C0002', 'name': 'Mabelreign Grocers'},
            'dispatches': 0,
            'packs': 0,
            'salesValue': '0.00',
            'invoiced': '0.00',
            'paymentsReceived': '2.00',
            'balanceNow': '-2.00',
          },
        ],
      };
    await pumpSnackify(tester, signedIn: true, size: desktopSize, backend: backend);
    await openReports(tester);
    await tester.tap(find.widgetWithText(Tab, 'Customers'));
    await tester.pumpAndSettle();

    expect(
      find.text('30 packs · invoiced USD 10.00 · paid USD 4.00 · owes now USD 9.00'),
      findsOneWidget,
    );
    expect(
      find.text('0 packs · invoiced USD 0.00 · paid USD 2.00 · in credit USD 2.00'),
      findsOneWidget,
    );
  });

  testWidgets('storekeepers see the stock report only', (tester) async {
    final backend = FakeBackend(role: 'storekeeper')
      ..reportAnswers['stock-received'] = {
        'products': [
          {
            'product': {
              'id': 'p1',
              'sku': 'PC-BBQ-S',
              'description': 'Potato Crisps — BBQ — Small',
            },
            'receipts': 2,
            'packs': 36,
          },
        ],
        'totals': {'receipts': 2, 'packs': 36},
      };
    final app = await pumpSnackify(tester, signedIn: true, size: desktopSize, backend: backend);
    await openReports(tester);

    expect(find.widgetWithText(Tab, 'Sales'), findsNothing);
    expect(find.text('Potato Crisps — BBQ — Small'), findsOneWidget);
    expect(find.text('36 packs'), findsOneWidget);
    expect(find.textContaining('2 deliveries, 36 packs'), findsOneWidget);
    expect(find.text('Nothing expires in the next 30 days.'), findsOneWidget);

    await tester.tap(find.text('60 days'));
    await tester.pumpAndSettle();
    expect(app.backend.requests.last, 'GET /api/v1/reports/expiring?days=60');
    expect(app.backend.requests.where((r) => r.contains('/reports/sales')), isEmpty);
  });

  testWidgets('salespeople are told reports are for managers', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: FakeBackend(role: 'salesperson'),
    );
    await openReports(tester);

    expect(find.text('Reports are for managers'), findsOneWidget);
    expect(
      app.backend.requests.where((r) => r.contains('/reports/') && !r.contains('dashboard')),
      isEmpty,
    );
  });

  testWidgets('a report that cannot be loaded can be tried again', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      size: desktopSize,
      backend: FakeBackend(role: 'admin'),
    );
    app.backend.reachable = false;
    await openReports(tester);
    expect(find.text('Could not load the sales report'), findsOneWidget);

    app.backend.reachable = true;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Sales value by day'), findsOneWidget);
  });

  testWidgets('reports and the money dashboard fit a phone screen', (tester) async {
    final backend = FakeBackend(role: 'admin')..reportAnswers['sales'] = salesAnswer('day');
    await pumpSnackify(tester, signedIn: true, backend: backend);
    expect(find.text('Money'), findsOneWidget);

    await openReports(tester);
    for (final tab in ['Products', 'Customers', 'Stock', 'Sales']) {
      await tester.tap(find.widgetWithText(Tab, tab));
      await tester.pumpAndSettle();
    }
    await tester.dragUntilVisible(
      find.text('Figures by day'),
      find.byType(Scrollable).last,
      const Offset(0, -300),
    );
    // On a phone the figures are a list rather than a table.
    expect(find.byType(DataTable), findsNothing);
    expect(find.text('20 packs · invoiced USD 0.00 · paid USD 4.00'), findsOneWidget);
  });
}
