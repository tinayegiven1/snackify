import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/routing/app_destinations.dart';
import '../../core/theme/app_theme.dart';
import '../../features/audit/presentation/audit_log_screen.dart';
import '../../features/auth/domain/app_user.dart';
import '../../features/auth/presentation/change_pin_screen.dart';
import '../../features/catalogue/presentation/catalogue_screen.dart';
import '../../features/dashboard/presentation/dashboard_screen.dart';
import '../../features/dispatches/domain/dispatch_models.dart';
import '../../features/dispatches/presentation/dispatches_screen.dart';
import '../../features/forecasts/presentation/forecasts_screen.dart';
import '../../features/invoices/presentation/invoices_screen.dart';
import '../../features/orders/presentation/order_services.dart';
import '../../features/orders/presentation/orders_screen.dart';
import '../../features/organisations/presentation/organisations_screen.dart';
import '../../features/payments/presentation/payments_screen.dart';
import '../../features/products/presentation/products_screen.dart';
import '../../features/purchases/presentation/purchase_services.dart';
import '../../features/purchases/presentation/purchases_screen.dart';
import '../../features/receipts/presentation/receipt_services.dart';
import '../../features/receipts/presentation/receipts_screen.dart';
import '../../features/reports/presentation/reports_screen.dart';
import '../../features/staff/presentation/staff_screen.dart';
import '../../features/stock/presentation/stock_screen.dart';
import 'offline_banner.dart';
import 'ui_kit.dart';
import 'snackify_logo.dart';

/// Screen width at which navigation moves from a drawer (phones) to a permanent sidebar.
const double kWideLayoutBreakpoint = 840;

/// App frame: top bar, navigation, and the selected section.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.user,
    required this.onSignOut,
    required this.onChangePin,
    required this.services,
  });

  final AppUser user;
  final Future<void> Function() onSignOut;
  final Future<void> Function(String currentPin, String newPin) onChangePin;
  final AppServices services;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    // Save the main lists on the device while online, so they can be seen offline later.
    widget.services.sync.warmUp();
  }

  /// The section, under the offline banner while the server cannot be reached. When the
  /// connection comes back and the information is refreshed, the section loads again.
  Widget _withConnection(String label, Widget page) {
    final connection = widget.services.connection;
    return ListenableBuilder(
      listenable: connection,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (connection.offline)
            OfflineBanner(connection: connection, onTryNow: widget.services.sync.syncNow),
          Expanded(
            child: KeyedSubtree(key: ValueKey('$label-${connection.refreshes}'), child: page),
          ),
        ],
      ),
    );
  }

  void _onDestinationSelected(int index) {
    setState(() => _selectedIndex = index);
    _scaffoldKey.currentState?.closeDrawer();
  }

  Widget _pageFor(String label) {
    final user = widget.user;
    final services = widget.services;
    final receiptServices = ReceiptServices(
      receipts: services.receipts,
      catalogue: services.catalogue,
      organisations: services.organisations,
      products: services.products,
      user: user,
      pickDocuments: services.pickDocuments,
      takePhoto: services.takePhoto,
      sharePdf: services.sharePdf,
      readBarcode: services.readBarcode,
    );
    return switch (label) {
      'Dashboard' => DashboardScreen(reports: services.reports),
      'Products' => ProductsScreen(
        repository: services.products,
        canEdit: user.can('product.manage'),
        catalogue: services.catalogue,
        readBarcode: services.readBarcode,
      ),
      'Stock' => StockScreen(
        stock: services.stock,
        products: services.products,
        user: user,
        readBarcode: services.readBarcode,
        sharePdf: services.sharePdf,
        receiptServices: receiptServices,
      ),
      'Goods Bought' => PurchasesScreen(
        services: PurchaseServices(purchases: services.purchases, receiptServices: receiptServices),
      ),
      'Goods Received' => ReceiptsScreen(services: receiptServices),
      'Orders' => OrdersScreen(
        services: OrderServices(
          orders: services.orders,
          products: services.products,
          organisations: services.organisations,
          user: user,
          sharePdf: services.sharePdf,
        ),
      ),
      'Catalogue' => CatalogueScreen(repository: services.catalogue, user: user),
      'Dispatches' => DispatchesScreen(
        dispatches: services.dispatches,
        organisations: services.organisations,
        products: services.products,
        permissions: DispatchPermissions.forUser(user),
        readBarcode: services.readBarcode,
      ),
      'Invoices' => InvoicesScreen(invoices: services.invoices, sharePdf: services.sharePdf),
      'Payments' => PaymentsScreen(
        payments: services.payments,
        organisations: services.organisations,
        invoices: services.invoices,
        sharePdf: services.sharePdf,
        canVoid: user.can('payment.void'),
      ),
      'Reports' => ReportsScreen(
        reports: services.reports,
        financial: user.can('report.financial'),
      ),
      'Forecasts' => ForecastsScreen(forecasts: services.forecasts),
      'Organisations' => OrganisationsScreen(
        repository: services.organisations,
        canManage: user.can('organisation.manage'),
        canEditCreditLimit: user.can('organisation.edit_credit_limit'),
      ),
      'Users & Roles' => StaffScreen(
        repository: services.staff,
        organisations: services.organisations,
        currentUser: user,
      ),
      'Audit Log' => AuditLogScreen(repository: services.audit),
      _ => throw StateError('No screen for $label'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint;
    final destinations = destinationsFor(widget.user);
    final selected = _selectedIndex.clamp(0, destinations.length - 1);
    final destination = destinations[selected];
    final navigation = _NavigationList(
      destinations: destinations,
      selectedIndex: selected,
      onSelected: _onDestinationSelected,
      user: widget.user,
      showUser: !isWide,
      onChangePin: () {
        _scaffoldKey.currentState?.closeDrawer();
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => ChangePinScreen(changePin: widget.onChangePin)),
        );
      },
      onSignOut: () {
        _scaffoldKey.currentState?.closeDrawer();
        widget.onSignOut();
      },
    );
    final page = _pageFor(destination.label);

    if (!isWide) {
      return Scaffold(
        key: _scaffoldKey,
        appBar: AppBar(title: Text(destination.label)),
        drawer: Drawer(
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.horizontal(right: Radius.circular(24)),
          ),
          child: _SidebarBackground(child: SafeArea(child: navigation)),
        ),
        body: _withConnection(destination.label, page),
      );
    }

    // Wide screens: a floating blue sidebar, and a header with the page's title, what it is
    // for, the API status and who is signed in.
    return Scaffold(
      key: _scaffoldKey,
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 0, 12),
              child: SizedBox(
                width: 236,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: _SidebarBackground(child: navigation),
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 20, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: PageHeader(
                            title: destination.label,
                            subtitle: destination.description.isEmpty
                                ? null
                                : destination.description,
                          ),
                        ),
                        const SizedBox(width: 12),
                        _UserChip(user: widget.user),
                      ],
                    ),
                  ),
                  Expanded(child: _withConnection(destination.label, page)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The blue of the sidebar and the phone menu.
class _SidebarBackground extends StatelessWidget {
  const _SidebarBackground({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [SnackifyColors.brandBlueLight, SnackifyColors.brandBlue],
        ),
      ),
      child: child,
    );
  }
}

/// Who is signed in, top right on wide screens.
class _UserChip extends StatelessWidget {
  const _UserChip({required this.user});

  final AppUser user;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 200),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                user.fullName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700, color: SnackifyColors.ink),
              ),
              Text(
                user.organisation.name.toUpperCase(),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.6,
                  color: SnackifyColors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Tooltip(
          message: user.roleNames,
          child: CircleAvatar(
            radius: 19,
            backgroundColor: SnackifyColors.brandBlue,
            foregroundColor: Colors.white,
            child: Text(user.initials, style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }
}

class _NavigationList extends StatelessWidget {
  const _NavigationList({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.user,
    required this.showUser,
    required this.onChangePin,
    required this.onSignOut,
  });

  final List<AppDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final AppUser user;

  /// Phones show who is signed in here; wide screens show it in the header.
  final bool showUser;
  final VoidCallback onChangePin;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const SnackifyLogo(size: 32),
              ),
              const SizedBox(width: 12),
              const Flexible(
                child: Text(
                  'Snackify',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (showUser)
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: Colors.white,
                  foregroundColor: SnackifyColors.brandBlue,
                  child: Text(user.initials, style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user.fullName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${user.roleNames}\n${user.organisation.name}',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        for (var i = 0; i < destinations.length; i++)
          _NavItem(
            icon: i == selectedIndex ? destinations[i].selectedIcon : destinations[i].icon,
            label: destinations[i].label,
            selected: i == selectedIndex,
            onTap: () => onSelected(i),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Divider(color: Colors.white.withValues(alpha: 0.2)),
        ),
        _NavItem(icon: Icons.pin_outlined, label: 'Change PIN', onTap: onChangePin),
        _NavItem(icon: Icons.logout, label: 'Sign out', onTap: onSignOut),
      ],
    );
  }
}

/// One menu entry: white on blue, with a soft highlight for the section that is open.
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.white : Colors.white.withValues(alpha: 0.78);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? Colors.white.withValues(alpha: 0.18) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Semantics(
            selected: selected,
            button: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(icon, color: color, size: 21),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: color,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
