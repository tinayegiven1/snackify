import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snackify/core/formatting/dates.dart';

import 'helpers/test_app.dart';

String day(int offset) => toApiDate(today().add(Duration(days: offset)));

Map<String, Object?> horizon(
  int days,
  String status, {
  double? predicted,
  int? lower,
  int? upper,
  int historyDays = 56,
  int? reorder,
}) => {
  'horizonDays': days,
  'status': status,
  'predicted': predicted,
  'lower': lower,
  'upper': upper,
  'historyDays': historyDays,
  'weeksUsed': status == 'ok' ? 8 : 0,
  'suggestedReorder': reorder,
};

Map<String, Object?> productForecast(
  String id,
  String description,
  Map<String, Object?> week,
  Map<String, Object?> month, {
  int onHand = 15,
  int safetyStock = 15,
  double? mae,
  List<Map<String, Object?>> recent = const [],
}) => {
  'product': {'id': id, 'sku': id.toUpperCase(), 'description': description},
  'onHand': onHand,
  'safetyStock': safetyStock,
  'week': week,
  'month': month,
  'accuracy': {'mae': mae, 'weeksCompared': recent.length, 'needed': 3, 'recent': recent},
};

/// A run as the server returns it: BBQ forecast, Cheese too new, Salt never dispatched.
Map<String, Object?> sampleRun() => {
  'run': {
    'id': 'run-1',
    'forecastStart': day(0),
    'method': 'weekday-average',
    'createdAt': '${day(0)}T06:15:00Z',
    'createdBy': 'Test storekeeper',
  },
  'products': [
    productForecast(
      'pc-bbq-s',
      'Potato Crisps — BBQ — Small',
      horizon(7, 'ok', predicted: 10, lower: 8, upper: 12, reorder: 10),
      horizon(30, 'ok', predicted: 50, lower: 40, upper: 60, reorder: 50),
      mae: 1.3,
      recent: [
        {'forecastStart': day(-14), 'predicted': 10, 'actual': 10},
        {'forecastStart': day(-21), 'predicted': 12, 'actual': 10},
        {'forecastStart': day(-28), 'predicted': 8, 'actual': 10},
      ],
    ),
    productForecast(
      'pc-sv-s',
      'Potato Crisps — Salt & Vinegar — Small',
      horizon(7, 'ok', predicted: 4.4, lower: 4, upper: 4, reorder: 0),
      horizon(30, 'ok', predicted: 19, lower: 19, upper: 19, reorder: 0),
      onHand: 200,
      recent: [
        {'forecastStart': day(-7), 'predicted': 4, 'actual': 6},
      ],
    ),
    productForecast(
      'mp-ch-s',
      'Maize Puffs — Cheese — Small',
      horizon(7, 'insufficient_history', historyDays: 10),
      horizon(30, 'insufficient_history', historyDays: 10),
    ),
    productForecast(
      'pc-sa-s',
      'Potato Crisps — Salt — Small',
      horizon(7, 'no_history', historyDays: 0),
      horizon(30, 'no_history', historyDays: 0),
    ),
  ],
};

void main() {
  testWidgets('a forecast is made on request and labelled as an estimate', (tester) async {
    final backend = FakeBackend(role: 'storekeeper')..forecastAfterRun = sampleRun();
    final app = await pumpSnackify(tester, signedIn: true, size: desktopSize, backend: backend);
    await openSection(tester, 'Forecasts');

    expect(find.text('No forecast has been made yet.'), findsOneWidget);
    expect(find.textContaining('Estimates, not guaranteed sales.'), findsOneWidget);

    await tester.tap(find.text('Make the first forecast'));
    await tester.pumpAndSettle();

    expect(app.backend.forecastRuns, 1);
    expect(
      find.textContaining('by Test storekeeper, from ${formatApiDate(day(0))}.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Next 7 days: about 10 packs (8\u2060–\u206012)\nNext 30 days: about 50 packs (40\u2060–\u206060)',
      ),
      findsOneWidget,
    );
    expect(find.text('Receive 10'), findsOneWidget);
    // A single likely number is shown without a range; enough stock is said plainly.
    expect(find.text('Next 7 days: about 4 packs\nNext 30 days: about 19 packs'), findsOneWidget);
    expect(find.text('Enough stock'), findsOneWidget);
    // Too little history is said honestly, without a number.
    expect(
      find.text(
        'Next 7 days: not enough history yet (10 days of dispatches; needs 28)\n'
        'Next 30 days: not enough history yet (10 days of dispatches; needs 28)',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('never dispatched, so nothing to forecast from'), findsOneWidget);
    expect(find.text('Make a new forecast'), findsOneWidget);
  });

  testWidgets("a product's forecast explains restocking and accuracy", (tester) async {
    final backend = FakeBackend(role: 'accounts')..forecastAnswer = sampleRun();
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Forecasts');

    await tester.tap(find.text('Potato Crisps — BBQ — Small'));
    await tester.pumpAndSettle();

    expect(find.text('About 10 packs, probably between 8 and 12.'), findsOneWidget);
    expect(find.text('About 50 packs, probably between 40 and 60.'), findsOneWidget);
    expect(find.text('On hand now: 15 packs'), findsOneWidget);
    expect(
      find.text(
        'Receive 10 packs to cover the next 7 days (forecast 10 + safety stock 15 − on hand 15).',
      ),
      findsOneWidget,
    );
    await tester.dragUntilVisible(
      find.text('forecast 8 · actual 10'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    expect(
      find.text(
        'Weekly forecasts were 1.3 packs off on average (mean absolute error over the last 3 '
        'weeks).',
      ),
      findsOneWidget,
    );
    expect(find.text('Week from ${formatApiDate(day(-14))}'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Potato Crisps — Salt & Vinegar — Small'));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('Shown once 3 forecast weeks have passed (1 so far).'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    expect(
      find.text(
        'Enough stock for the next 7 days (forecast 4.4, rounded up to 5 + safety stock 15 − on hand 200).',
      ),
      findsOneWidget,
    );
  });

  testWidgets('admins set safety stock on the product', (tester) async {
    final backend = FakeBackend(role: 'admin')
      ..addProduct('PC-BBQ-S', 'Potato Crisps', 'BBQ', 'Small', '0.50');
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Products');
    await tester.tap(find.text('Potato Crisps — BBQ'));
    await tester.pumpAndSettle();

    final field = find.widgetWithText(TextFormField, 'Safety stock (packs)');
    await tester.ensureVisible(field);
    await tester.enterText(field, '24');
    await tester.ensureVisible(find.text('Save product'));
    await tester.tap(find.text('Save product'));
    await tester.pumpAndSettle();

    expect(backend.products.single['safetyStock'], 24);
  });

  testWidgets('salespeople are told forecasts are for managers', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: FakeBackend(role: 'salesperson'),
    );
    await openSection(tester, 'Forecasts');

    expect(find.text('Forecasts are for managers'), findsOneWidget);
    expect(app.backend.requests.where((r) => r.contains('/forecasts')), isEmpty);
  });

  testWidgets('forecasts that cannot be loaded can be tried again', (tester) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: FakeBackend(role: 'admin'));
    app.backend.reachable = false;
    await openSection(tester, 'Forecasts');
    expect(find.text('Could not load forecasts'), findsOneWidget);

    app.backend.reachable = true;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('No forecast has been made yet.'), findsOneWidget);
  });
}
