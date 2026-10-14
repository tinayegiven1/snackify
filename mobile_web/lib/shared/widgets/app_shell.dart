import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/routing/app_destinations.dart';
import '../../core/theme/app_theme.dart';
import '../../features/auth/domain/app_user.dart';
import '../../features/auth/presentation/change_password_screen.dart';
import '../../features/customers/domain/customer.dart';
import '../../features/customers/presentation/customers_screen.dart';
import '../../features/dashboard/presentation/dashboard_screen.dart';
import '../../features/dispatches/domain/dispatch_models.dart';
import '../../features/dispatches/presentation/dispatches_screen.dart';
import '../../features/forecasts/domain/forecast_models.dart';
import '../../features/forecasts/presentation/forecasts_screen.dart';
import '../../features/invoices/domain/invoice_models.dart';
import '../../features/invoices/presentation/invoices_screen.dart';
import '../../features/payments/domain/payment_models.dart';
import '../../features/payments/presentation/payments_screen.dart';
import '../../features/products/presentation/products_screen.dart';
import '../../features/reports/domain/report_models.dart';
import '../../features/reports/presentation/reports_screen.dart';
import '../../features/staff/presentation/staff_screen.dart';
import '../../features/stock/presentation/stock_screen.dart';
import 'api_status_indicator.dart';
import 'message_view.dart';
import 'snackify_logo.dart';

/// Screen width at which navigation moves from a drawer (phones) to a permanent sidebar.
const double kWideLayoutBreakpoint = 840;

/// App frame: top bar, navigation, and the selected section.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.user,
    required this.onSignOut,
    required this.onChangePassword,
    required this.services,
  });

  final AppUser user;
  final Future<void> Function() onSignOut;
  final Future<void> Function(String currentPassword, String newPassword) onChangePassword;
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

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint;
    final destination = appDestinations[_selectedIndex];
    final navigation = _NavigationList(
      selectedIndex: _selectedIndex,
      onSelected: _onDestinationSelected,
      user: widget.user,
      onChangePassword: () {
        _scaffoldKey.currentState?.closeDrawer();
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ChangePasswordScreen(changePassword: widget.onChangePassword),
          ),
        );
      },
      onSignOut: () {
        _scaffoldKey.currentState?.closeDrawer();
        widget.onSignOut();
      },
    );
    final page = switch (destination.label) {
      'Dashboard' => DashboardScreen(reports: widget.services.reports),
      // Only admins manage products (spec section 5); the server enforces this too.
      'Products' => ProductsScreen(
        repository: widget.services.products,
        canEdit: widget.user.role == StaffRole.admin,
        readBarcode: widget.services.readBarcode,
      ),
      'Stock' => StockScreen(
        stock: widget.services.stock,
        products: widget.services.products,
        user: widget.user,
        readBarcode: widget.services.readBarcode,
        sharePdf: widget.services.sharePdf,
      ),
      'Customers' => CustomersScreen(
        repository: widget.services.customers,
        permissions: CustomerPermissions.forRole(widget.user.role),
      ),
      'Dispatches' => DispatchesScreen(
        dispatches: widget.services.dispatches,
        customers: widget.services.customers,
        products: widget.services.products,
        permissions: DispatchPermissions.forRole(widget.user.role),
        readBarcode: widget.services.readBarcode,
      ),
      'Invoices' when canUseInvoices(widget.user.role) => InvoicesScreen(
        invoices: widget.services.invoices,
        sharePdf: widget.services.sharePdf,
      ),
      'Invoices' => const MessageView(
        icon: Icons.lock_outline,
        title: 'Invoices are for accounts staff',
        message: 'Ask an administrator or a member of the accounts team for invoice details.',
      ),
      'Payments' when canUsePayments(widget.user.role) => PaymentsScreen(
        payments: widget.services.payments,
        customers: widget.services.customers,
        invoices: widget.services.invoices,
        sharePdf: widget.services.sharePdf,
        canVoid: canVoidPayments(widget.user.role),
      ),
      'Payments' => const MessageView(
        icon: Icons.lock_outline,
        title: 'Payments are for accounts staff',
        message: 'Ask an administrator or a member of the accounts team about payments.',
      ),
      'Reports' when canSeeStockReports(widget.user.role) => ReportsScreen(
        reports: widget.services.reports,
        financial: canSeeFinancialReports(widget.user.role),
      ),
      'Reports' => const MessageView(
        icon: Icons.lock_outline,
        title: 'Reports are for managers',
        message: 'Admins, accounts staff and storekeepers can open reports.',
      ),
      'Forecasts' when canUseForecasts(widget.user.role) => ForecastsScreen(
        forecasts: widget.services.forecasts,
      ),
      'Forecasts' => const MessageView(
        icon: Icons.lock_outline,
        title: 'Forecasts are for managers',
        message: 'Admins, accounts staff and storekeepers can see forecasts.',
      ),
      // Staff accounts are for admins only; the server enforces this too.
      'Staff' when widget.user.role == StaffRole.admin => StaffScreen(
        repository: widget.services.staff,
        currentUserId: widget.user.id,
      ),
      'Staff' => const MessageView(
        icon: Icons.lock_outline,
        title: 'Staff accounts are managed by admins',
        message:
            'Ask an administrator to add staff or reset a password. To change your own '
            'password, use Change password in the menu.',
      ),
      _ => throw StateError('No screen for ${destination.label}'),
    };

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
    required this.selectedIndex,
    required this.onSelected,
    required this.user,
    required this.onChangePassword,
    required this.onSignOut,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final AppUser user;
  final VoidCallback onChangePassword;
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
        for (var i = 0; i < appDestinations.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: ListTile(
              leading: Icon(
                i == selectedIndex ? appDestinations[i].selectedIcon : appDestinations[i].icon,
              ),
              title: Text(appDestinations[i].label),
              selected: i == selectedIndex,
              onTap: () => onSelected(i),
            ),
          ),
        const Divider(height: 24),
        ListTile(
          leading: CircleAvatar(child: Text(user.initials)),
          title: Text(user.fullName, overflow: TextOverflow.ellipsis),
          subtitle: Text(user.role.label),
        ),
        ListTile(
          leading: const Icon(Icons.password),
          title: const Text('Change password'),
          onTap: onChangePassword,
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
