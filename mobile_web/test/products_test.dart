import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_app.dart';

/// A backend with the sample catalogue (and one inactive product) for [role].
FakeBackend backendWithProducts({String role = 'admin'}) {
  return FakeBackend(role: role)
    ..addProduct('PC-BBQ-S', 'Potato Crisps', 'BBQ', 'Small', '0.50', barcode: '2000000000015')
    ..addProduct('MP-CH-S', 'Maize Puffs', 'Cheese', 'Small', '0.30')
    ..addProduct('PC-OLD-S', 'Potato Crisps', 'Chutney', 'Small', '0.45', isActive: false);
}

Future<void> fillProductForm(
  WidgetTester tester, {
  String name = 'Potato Crisps',
  String flavour = 'Salt & Vinegar',
  String size = 'Large',
  String sku = 'pc-sv-l',
  String price = '1',
}) async {
  Future<void> type(String label, String text) =>
      tester.enterText(find.widgetWithText(TextFormField, label), text);
  await type('Product name', name);
  await type('Flavour', flavour);
  await type('Size', size);
  await type('SKU (product code)', sku);
  await type('Default selling price', price);
}

Future<void> saveForm(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Save product'));
  await tester.tap(find.text('Save product'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows active products to any signed-in role, read-only for non-admins', (
    tester,
  ) async {
    await pumpSnackify(tester, signedIn: true, backend: backendWithProducts(role: 'storekeeper'));
    await openSection(tester, 'Products');

    expect(find.text('Potato Crisps — BBQ'), findsOneWidget);
    expect(find.text('Maize Puffs — Cheese'), findsOneWidget);
    expect(find.text('USD 0.50'), findsOneWidget);
    expect(find.text('2 products'), findsOneWidget);
    expect(find.textContaining('Chutney'), findsNothing); // inactive
    expect(find.text('Add product'), findsNothing);

    await tester.tap(find.text('Potato Crisps — BBQ'));
    await tester.pumpAndSettle();
    expect(find.text('Edit product'), findsNothing);
  });

  testWidgets('shows a helpful message when there are no products', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: FakeBackend(role: 'admin'));
    await openSection(tester, 'Products');

    expect(find.text('No products yet'), findsOneWidget);
    expect(find.text('Add your first product with the Add product button.'), findsOneWidget);
  });

  testWidgets('explains when products cannot be loaded, and can try again', (tester) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: backendWithProducts());
    app.backend.reachable = false;
    await openSection(tester, 'Products');

    expect(find.text('Could not load products'), findsOneWidget);
    app.backend.reachable = true;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('Potato Crisps — BBQ'), findsOneWidget);
  });

  testWidgets('searches as you type, and says when nothing matches', (tester) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: backendWithProducts());
    await openSection(tester, 'Products');

    await tester.enterText(find.byType(TextField).first, 'cheese');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('Maize Puffs — Cheese'), findsOneWidget);
    expect(find.text('Potato Crisps — BBQ'), findsNothing);
    expect(app.backend.requests.last, contains('q=cheese'));

    await tester.enterText(find.byType(TextField).first, 'nothing like this');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('No products match "nothing like this"'), findsOneWidget);
  });

  testWidgets('can include inactive products, marked as inactive', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: backendWithProducts());
    await openSection(tester, 'Products');

    await tester.tap(find.text('Show inactive'));
    await tester.pumpAndSettle();

    expect(find.text('Potato Crisps — Chutney'), findsOneWidget);
    expect(find.text('Inactive'), findsOneWidget);
  });

  testWidgets('an admin adds a product', (tester) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: backendWithProducts());
    await openSection(tester, 'Products');

    await tester.tap(find.text('Add product'));
    await tester.pumpAndSettle();
    await fillProductForm(tester);
    await saveForm(tester);

    expect(find.text('Saved Potato Crisps — Salt & Vinegar — Large'), findsOneWidget);
    expect(find.text('Potato Crisps — Salt & Vinegar'), findsOneWidget);
    expect(find.text('USD 1.00'), findsOneWidget);
    // The SKU is sent in capitals and an empty barcode as "none".
    expect(app.backend.products.last, containsPair('sku', 'PC-SV-L'));
    expect(app.backend.products.last, containsPair('barcode', null));
  });

  testWidgets('the form checks fields before sending anything', (tester) async {
    final app = await pumpSnackify(tester, signedIn: true, backend: backendWithProducts());
    await openSection(tester, 'Products');
    await tester.tap(find.text('Add product'));
    await tester.pumpAndSettle();

    await saveForm(tester);
    expect(find.text('Required'), findsNWidgets(5));

    await fillProductForm(tester, price: '1.505');
    await tester.enterText(find.widgetWithText(TextFormField, 'Barcode (optional)'), '12');
    await saveForm(tester);
    expect(find.text('Use an amount like 0.50 (up to 2 decimal places)'), findsOneWidget);
    expect(find.text('Use 4–48 letters, digits or dashes'), findsOneWidget);

    expect(app.backend.requests, isNot(contains('POST /api/v1/products')));
  });

  testWidgets("shows the server's message on the right field", (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: backendWithProducts());
    await openSection(tester, 'Products');
    await tester.tap(find.text('Add product'));
    await tester.pumpAndSettle();

    await fillProductForm(tester, sku: 'PC-BBQ-S');
    await saveForm(tester);

    expect(find.text('Already used by another product'), findsOneWidget);
    expect(find.text('Add product'), findsOneWidget); // still on the form
  });

  testWidgets('an admin changes a price and deactivates a product', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: backendWithProducts());
    await openSection(tester, 'Products');

    await tester.tap(find.text('Potato Crisps — BBQ'));
    await tester.pumpAndSettle();
    expect(find.text('Edit product'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Default selling price'), '0.55');
    await saveForm(tester);
    expect(find.text('USD 0.55'), findsOneWidget);

    await tester.tap(find.text('Potato Crisps — BBQ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Active'));
    await saveForm(tester);

    expect(find.text('Potato Crisps — BBQ'), findsNothing);
    expect(find.text('1 product'), findsOneWidget);
  });

  testWidgets('wide screens show the catalogue as a table', (tester) async {
    await pumpSnackify(tester, signedIn: true, size: desktopSize, backend: backendWithProducts());
    await openSection(tester, 'Products');

    expect(find.byType(DataTable), findsOneWidget);
    expect(find.text('PC-BBQ-S'), findsOneWidget);
    expect(find.text('2000000000015'), findsOneWidget);
  });

  testWidgets('product screens fit a small phone without overflowing', (tester) async {
    await pumpSnackify(
      tester,
      signedIn: true,
      size: const Size(320, 568),
      backend: backendWithProducts(),
    );
    await openSection(tester, 'Products');
    expect(find.text('Potato Crisps — BBQ'), findsOneWidget);

    await tester.tap(find.text('Add product'));
    await tester.pumpAndSettle();
    expect(find.text('Save product'), findsOneWidget);
  });
}
