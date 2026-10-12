import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/routing/app_destinations.dart';
import '../../core/theme/app_theme.dart';
import '../../features/auth/domain/app_user.dart';
import '../../features/dashboard/presentation/dashboard_screen.dart';
import '../../features/products/presentation/products_screen.dart';
import 'api_status_indicator.dart';
import 'coming_soon_view.dart';
import 'snackify_logo.dart';

/// Screen width at which navigation moves from a drawer (phones) to a permanent sidebar.
const double kWideLayoutBreakpoint = 840;

/// App frame: top bar, navigation, and the selected section.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.user, required this.onSignOut, required this.services});

  final AppUser user;
  final Future<void> Function() onSignOut;
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
      onSignOut: () {
        _scaffoldKey.currentState?.closeDrawer();
        widget.onSignOut();
      },
    );
    final page = switch (destination.label) {
      'Dashboard' => const DashboardScreen(),
      // Only admins manage products (spec section 5); the server enforces this too.
      'Products' => ProductsScreen(
        repository: widget.services.products,
        canEdit: widget.user.role == StaffRole.admin,
      ),
      _ => ComingSoonView(title: destination.label),
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
    required this.onSignOut,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final AppUser user;
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
          leading: const Icon(Icons.logout),
          title: const Text('Sign out'),
          onTap: onSignOut,
        ),
      ],
    );
  }
}
