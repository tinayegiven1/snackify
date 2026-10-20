import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_app.dart';

Finder field(String label) => find.widgetWithText(TextFormField, label);

/// Taps the button labelled [label] (screen titles often use the same words).
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

Future<void> tickRole(WidgetTester tester, String name) async {
  final box = find.widgetWithText(CheckboxListTile, name);
  await tester.ensureVisible(box);
  await tester.pumpAndSettle();
  await tester.tap(box);
  await tester.pumpAndSettle();
}

FakeBackend adminBackend() => FakeBackend(role: 'admin')
  ..addStaff('chipo.n', 'Chipo Ndlovu', 'accounts', lastSignInAt: '2026-10-12T08:00:00Z')
  ..addStaff('farai.m', 'Farai Mutasa', 'salesperson', isActive: false)
  ..addStaff('rudo.b', 'Rudo Banda', 'subsidiary_manager', organisation: FakeBackend.subsidiaryOne);

void main() {
  testWidgets('admins see every account, with organisation, roles and status', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: adminBackend());
    await openSection(tester, 'Users & Roles');

    expect(find.text('3 active accounts, 1 deactivated'), findsOneWidget);
    expect(find.text('Tendai Moyo (you)'), findsOneWidget);
    expect(find.textContaining('chipo.n · HQ Finance Officer\nHead Office'), findsOneWidget);
    expect(find.textContaining('Last signed in 12 Oct 2026'), findsOneWidget);
    expect(find.textContaining('rudo.b · Subsidiary Manager\nMbare Branch'), findsOneWidget);
    expect(find.text('Deactivated'), findsOneWidget);
  });

  testWidgets('an admin adds Head Office staff with several roles and a first password', (
    tester,
  ) async {
    final backend = adminBackend();
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Users & Roles');
    await tester.tap(find.text('Add staff'));
    await tester.pumpAndSettle();

    // The same rules as the server, checked before sending.
    await tester.enterText(field('Full name'), 'Rudo Chikore');
    await tester.enterText(field('Username'), 'r');
    await tester.enterText(field('Password'), 'short');
    await tester.enterText(field('Password again'), 'different');
    await tapButton(tester, 'Add staff member');
    expect(find.textContaining('Use 3–32 letters'), findsOneWidget);
    expect(find.text('Choose at least one role'), findsOneWidget);
    expect(find.text('Use at least 10 characters'), findsOneWidget);
    expect(find.text('The two passwords differ'), findsOneWidget);
    expect(backend.requests.where((r) => r == 'POST /api/v1/users'), isEmpty);

    // Only Head Office roles are offered for Head Office staff.
    expect(find.text('Subsidiary Manager'), findsNothing);
    await tester.enterText(field('Username'), 'Rudo.Chikore');
    await tickRole(tester, 'HQ Warehouse Officer');
    await tickRole(tester, 'HQ Sales Officer');
    expect(find.text('Choose at least one role'), findsNothing);
    await tester.enterText(field('Password'), 'rudo-first-password');
    await tester.enterText(field('Password again'), 'rudo-first-password');
    await tapButton(tester, 'Add staff member');

    final added = backend.staff.last;
    expect(added['username'], 'rudo.chikore');
    expect((added['roles'] as List).map((r) => (r as Map)['code']), [
      'hq_sales_officer',
      'hq_warehouse_officer',
    ]);
    expect(backend.passwordsSet.last, (added['id'], 'rudo-first-password'));
    expect(find.textContaining('Added Rudo Chikore (Head Office)'), findsOneWidget);
  });

  testWidgets("a subsidiary's staff can only be given subsidiary roles", (tester) async {
    final backend = adminBackend();
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Users & Roles');
    await tester.tap(find.text('Add staff'));
    await tester.pumpAndSettle();

    await tickRole(tester, 'HQ Finance Officer');
    await tester.tap(find.text('Head Office (Head Office)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mbare Branch (Subsidiary)').last);
    await tester.pumpAndSettle();

    // Head Office roles disappear, and the one ticked is dropped.
    expect(find.text('HQ Finance Officer'), findsNothing);
    expect(find.text('Subsidiary Manager'), findsOneWidget);
    await tester.enterText(field('Full name'), 'Nyasha Moyo');
    await tester.enterText(field('Username'), 'nyasha');
    await tickRole(tester, 'Subsidiary Storekeeper');
    await tester.enterText(field('Password'), 'nyasha-password-1');
    await tester.enterText(field('Password again'), 'nyasha-password-1');
    await tapButton(tester, 'Add staff member');

    expect(backend.staff.last['organisation'], containsPair('code', 'SUB-01'));
    expect(
      (backend.staff.last['roles'] as List).single,
      containsPair('code', 'subsidiary_storekeeper'),
    );
  });

  testWidgets('a username that is taken is explained', (tester) async {
    await pumpSnackify(tester, signedIn: true, backend: adminBackend());
    await openSection(tester, 'Users & Roles');
    await tester.tap(find.text('Add staff'));
    await tester.pumpAndSettle();

    await tester.enterText(field('Full name'), 'Chipo Two');
    await tester.enterText(field('Username'), 'chipo.n');
    await tickRole(tester, 'HQ Finance Officer');
    await tester.enterText(field('Password'), 'a-good-password');
    await tester.enterText(field('Password again'), 'a-good-password');
    await tapButton(tester, 'Add staff member');

    expect(find.text('The username "chipo.n" is already taken.'), findsOneWidget);
  });

  testWidgets('an admin changes roles and deactivates an account, after confirming', (
    tester,
  ) async {
    final backend = adminBackend();
    await pumpSnackify(tester, signedIn: true, backend: backend, size: desktopSize);
    await openSection(tester, 'Users & Roles');
    await tester.tap(find.text('Chipo Ndlovu'));
    await tester.pumpAndSettle();

    expect(find.text('Signs in as "chipo.n"'), findsOneWidget);
    await tickRole(tester, 'System Administrator');
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tapButton(tester, 'Save changes');

    expect(find.text('Deactivate Chipo Ndlovu?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.staff[1]['isActive'], isTrue); // nothing sent

    await tapButton(tester, 'Save changes');
    await tester.tap(find.widgetWithText(FilledButton, 'Deactivate'));
    await tester.pumpAndSettle();

    expect((backend.staff[1]['roles'] as List).map((r) => (r as Map)['code']), [
      'hq_finance_officer',
      'system_admin',
    ]);
    expect(backend.staff[1]['isActive'], isFalse);
    expect(
      find.text('Deactivated Chipo Ndlovu. They were signed out and can no longer sign in.'),
      findsOneWidget,
    );
  });

  testWidgets('an admin sets a new password for someone who forgot theirs', (tester) async {
    final backend = adminBackend();
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Users & Roles');
    await tester.tap(find.text('Chipo Ndlovu'));
    await tester.pumpAndSettle();

    await tapButton(tester, 'Set a new password');
    await tester.enterText(field('New password'), 'chipo-new-pass-1');
    await tester.enterText(field('New password again'), 'chipo-new-pass-2');
    await tester.tap(find.text('Set password'));
    await tester.pumpAndSettle();
    expect(find.text('The two passwords differ'), findsOneWidget);

    await tester.enterText(field('New password again'), 'chipo-new-pass-1');
    await tester.tap(find.text('Set password'));
    await tester.pumpAndSettle();

    expect(backend.passwordsSet.last, (backend.staff[1]['id'], 'chipo-new-pass-1'));
    expect(find.textContaining('New password set for Chipo Ndlovu.'), findsOneWidget);
  });

  testWidgets('admins cannot lock themselves out', (tester) async {
    final backend = adminBackend();
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Users & Roles');
    await tester.tap(find.text('Tendai Moyo (you)'));
    await tester.pumpAndSettle();

    expect(find.text('You cannot change your own roles. Ask another admin.'), findsOneWidget);
    for (final box in tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile))) {
      expect(box.onChanged, isNull);
    }
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    expect(find.text('Set a new password'), findsNothing);
    expect(
      find.text('To change your own password, use Change password in the menu.'),
      findsOneWidget,
    );

    // Renaming yourself is fine.
    await tester.enterText(field('Full name'), 'Tendai B. Moyo');
    await tapButton(tester, 'Save changes');
    expect(backend.staff.first['fullName'], 'Tendai B. Moyo');
    expect((backend.staff.first['roles'] as List), hasLength(4));
  });

  testWidgets('only staff managers see Users & Roles', (tester) async {
    final app = await pumpSnackify(
      tester,
      signedIn: true,
      backend: FakeBackend(role: 'storekeeper'),
    );
    expect(await menuSections(tester), isNot(contains('Users & Roles')));
    expect(app.backend.requests.where((r) => r.contains('/users')), isEmpty);
  });

  testWidgets('anyone can change their own password, proving the current one', (tester) async {
    final backend = FakeBackend(role: 'salesperson');
    await pumpSnackify(tester, signedIn: true, backend: backend);
    await openSection(tester, 'Change password');

    await tester.enterText(field('Current password'), 'not my password');
    await tester.enterText(field('New password'), 'my brand new password');
    await tester.enterText(field('New password again'), 'my brand new password');
    await tapButton(tester, 'Change password');
    expect(find.text('Incorrect password'), findsOneWidget);
    expect(backend.passwordsSet, isEmpty);

    await tester.enterText(field('Current password'), testPassword);
    await tester.enterText(field('New password again'), 'my brand new passwrd');
    await tapButton(tester, 'Change password');
    expect(find.text('The two new passwords differ'), findsOneWidget);

    await tester.enterText(field('New password again'), 'my brand new password');
    await tapButton(tester, 'Change password');

    expect(backend.passwordsSet, [(backend.user['id'], 'my brand new password')]);
    expect(find.textContaining('Your password has been changed.'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Dashboard'), findsOneWidget); // still signed in
  });
}
