import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/routing/app_destinations.dart';
import '../../core/theme/app_theme.dart';
import '../../features/audit/presentation/audit_log_screen.dart';
import '../../features/auth/domain/app_user.dart';
import '../../features/auth/presentation/change_pin_screen.dart';
import '../../features/catalogue/presentation/catalogue_screen.dart';
import '../../features/customers/domain/customer.dart';
import '../../features/customers/presentation/customers_screen.dart';
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
import '../../features/receipts/presentation/receipt_services.dart';
import '../../features/receipts/presentation/receipts_screen.dart';
import '../../features/reports/presentation/reports_screen.dart';
import '../../features/staff/presentation/staff_screen.dart';
import '../../features/stock/presentation/stock_screen.dart';
import 'api_status_indicator.dart';
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
      'Customers' => CustomersScreen(
        repository: services.customers,
        permissions: CustomerPermissions.forUser(user),
      ),
      'Dispatches' => DispatchesScreen(
        dispatches: services.dispatches,
        customers: services.customers,
        products: services.products,
        permissions: DispatchPermissions.forUser(user),
        readBarcode: services.readBarcode,
      ),
      'Invoices' => InvoicesScreen(invoices: services.invoices, sharePdf: services.sharePdf),
      'Payments' => PaymentsScreen(
        payments: services.payments,
        customers: services.customers,
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
        customers: services.customers,
        canManage: user.can('organisation.manage'),
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

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(destination.label),
        actions: [
          ApiStatusIndicator(checkHealth: widget.services.checkBackendHealth),
          const SizedBox(width: 12),
        ],
      ),
      drawer: isWide ? null : Drawer(child: SafeArea(child: navigation)),
      body: isWide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 240, child: navigation),
                const VerticalDivider(width: 1),
                Expanded(child: page),
              ],
            )
          : page,
    );
  }
}

class _NavigationList extends StatelessWidget {
  const _NavigationList({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.user,
    required this.onChangePin,
    required this.onSignOut,
  });

  final List<AppDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final AppUser user;
  final VoidCallback onChangePin;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(
      context,
    ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, color: SnackifyColors.brandBlue);

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
          child: Row(
            children: [
              const SnackifyLogo(size: 40),
              const SizedBox(width: 12),
              Flexible(
                child: Text('Snackify', style: titleStyle, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
        for (var i = 0; i < destinations.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: ListTile(
              // Compact, so all twelve sections fit on a laptop screen without scrolling.
              visualDensity: VisualDensity.compact,
              leading: Icon(
                i == selectedIndex ? destinations[i].selectedIcon : destinations[i].icon,
              ),
              title: Text(destinations[i].label),
              selected: i == selectedIndex,
              onTap: () => onSelected(i),
            ),
          ),
        const Divider(height: 24),
        ListTile(
          leading: CircleAvatar(child: Text(user.initials)),
          title: Text(user.fullName, overflow: TextOverflow.ellipsis),
          subtitle: Text('${user.roleNames}\n${user.organisation.name}'),
          isThreeLine: true,
        ),
        ListTile(
          leading: const Icon(Icons.pin_outlined),
          title: const Text('Change PIN'),
          onTap: onChangePin,
        ),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Sign out'),
          onTap: onSignOut,
        ),
      ],
    );
  }
}
