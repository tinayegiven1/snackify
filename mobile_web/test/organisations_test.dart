import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_app.dart';

Finder field(String label) => find.widgetWithText(TextFormField, label);

Future<void> tapButton(WidgetTester tester, String label) async {
  final button = find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
  );
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets("a subsidiary's staff see only what is theirs to use", (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: FakeBackend(role: 'subsidiary_manager'),
    );

    final sections = await menuSections(tester);
    expect(sections.sublist(0, sections.indexOf('Change PIN')), [
      'Products',
      'Stock',
      'Goods Received',
      'Orders',
      'Organisations',
      'Tendai Moyo',
    ]);
    // They start on their own stock, not the Head Office's dashboard.
    expect(find.widgetWithText(AppBar, 'Products'), findsOneWidget);
    expect(app.backend.requests.where((r) => r.contains('/reports')), isEmpty);

    await openSection(tester, 'Organisations');
    expect(find.text('Mbare Branch'), findsOneWidget);
    expect(find.text('Head Office'), findsNothing);
    expect(find.text('Add subsidiary'), findsNothing);
  });

  testWidgets('Head Office staff see every organisation; only admins change them', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: FakeBackend(role: 'accounts'));
    await openSection(tester, 'Organisations');

    expect(find.text('Head Office'), findsOneWidget);
    expect(find.text('Mbare Branch'), findsOneWidget);
    expect(find.text('Add subsidiary'), findsNothing);

    await tester.tap(find.text('Mbare Branch'));
    await tester.pumpAndSettle();
    expect(find.text('Save changes'), findsNothing);
  });

  testWidgets('an admin adds a subsidiary, which brings its customer record', (tester) async {
    final backend = FakeBackend(role: 'admin');
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Organisations');
    await tester.tap(find.text('Add subsidiary'));
    await tester.pumpAndSettle();

    await tapButton(tester, 'Add subsidiary');
    expect(find.text('Required'), findsOneWidget);
    expect(find.text('Use 2–20 letters, digits, dashes or underscores'), findsOneWidget);

    await tester.enterText(field('Name'), 'Bulawayo Branch');
    await tester.enterText(field('Code'), 'bul-01');
    await tester.enterText(field('Email (optional)'), 'not an email');
    await tapButton(tester, 'Add subsidiary');
    expect(find.text('Use an email address like orders@example.co.zw'), findsOneWidget);

    await tester.enterText(field('Email (optional)'), 'orders@bulawayo.example');
    await tester.enterText(field('Phone (optional)'), '+263 00 222 3333');
    await tapButton(tester, 'Add subsidiary');

    expect(backend.organisations.last, containsPair('code', 'BUL-01'));
    expect(backend.organisations.last, containsPair('contactEmail', 'orders@bulawayo.example'));
    expect(backend.customers.last, containsPair('code', 'BUL-01'));
    expect(
      find.text('Added Bulawayo Branch (BUL-01). Add its staff under Users & Roles.'),
      findsOneWidget,
    );
  });

  testWidgets('deactivating a subsidiary is confirmed first', (tester) async {
    final backend = FakeBackend(role: 'admin');
    await pumpSnackify(tester, signedIn: true, backend: backend, size: desktopSize);
    await openSection(tester, 'Organisations');
    await tester.tap(find.text('Mbare Branch'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tapButton(tester, 'Save changes');
    expect(find.text('Deactivate Mbare Branch?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Deactivate'));
    await tester.pumpAndSettle();

    expect(backend.organisations[1]['isActive'], isFalse);
    expect(find.text('Deactivated Mbare Branch. Its staff can no longer sign in.'), findsOneWidget);
  });

  testWidgets('the Head Office has no Active switch', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: FakeBackend(role: 'admin'));
    await openSection(tester, 'Organisations');
    await tester.tap(find.text('Head Office'));
    await tester.pumpAndSettle();
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('the audit log lists who did what, and filters by kind', (tester) async {
    final backend = FakeBackend(role: 'admin')
      ..auditEntries.addAll([
        {
          'id': 'a2',
          'occurredAt': '2026-10-20T09:15:00Z',
          'action': 'user.roles_changed',
          'actor': {'id': 'u1', 'fullName': 'Tendai Moyo'},
          'organisation': {'id': 'org-hq', 'code': 'HQ'},
          'entityType': 'user',
          'entityId': 'u2',
          'details': {
            'from': ['hq_sales_officer'],
            'to': ['system_admin'],
          },
          'ipAddress': '192.0.2.10',
        },
        {
          'id': 'a1',
          'occurredAt': '2026-10-20T08:00:00Z',
          'action': 'auth.login_failed',
          'actor': null,
          'organisation': null,
          'entityType': null,
          'entityId': null,
          'details': {'username': 'nobody', 'reason': 'unknown_username'},
          'ipAddress': '192.0.2.99',
        },
      ]);
    await pumpSnackify(tester, signedIn: true, backend: backend, size: desktopSize);
    await openSection(tester, 'Audit Log');

    expect(find.text('User roles changed'), findsOneWidget);
    expect(find.textContaining('Tendai Moyo · HQ · 192.0.2.10'), findsOneWidget);
    expect(find.text('Auth login failed'), findsOneWidget);
    expect(find.textContaining('Unknown or system · 192.0.2.99'), findsOneWidget);
    expect(find.text('2 entries'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Sign-ins'));
    await tester.pumpAndSettle();
    expect(find.text('User roles changed'), findsNothing);
    expect(find.text('Auth login failed'), findsOneWidget);
    expect(backend.requests.last, contains('action=auth'));
  });
}
