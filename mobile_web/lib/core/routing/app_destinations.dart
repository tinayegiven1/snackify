import 'package:flutter/material.dart';

import '../../features/auth/domain/app_user.dart';

class AppDestination {
  const AppDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.isVisibleTo,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// Sections a user may not use are not shown at all (the server refuses them anyway).
  final bool Function(AppUser user) isVisibleTo;
}

bool _everyone(AppUser user) => true;
bool _dashboard(AppUser user) => user.can('report.dashboard');
bool _stock(AppUser user) => user.can('stock.view');
bool _catalogue(AppUser user) =>
    user.can('catalogue.manage') || user.can('supplier.manage') || user.can('stock.receive');
bool _orders(AppUser user) => user.can('order.view');
bool _customers(AppUser user) => user.can('customer.view');
bool _dispatches(AppUser user) => user.can('dispatch.view');
bool _invoices(AppUser user) => user.can('invoice.manage');
bool _payments(AppUser user) => user.can('payment.manage');
bool _reports(AppUser user) => user.can('report.stock') || user.can('report.financial');
bool _forecasts(AppUser user) => user.can('forecast.use');
bool _users(AppUser user) => user.can('user.manage');
bool _audit(AppUser user) => user.can('audit.view');

/// Main navigation sections, in menu order.
const appDestinations = <AppDestination>[
  AppDestination(
    label: 'Dashboard',
    icon: Icons.dashboard_outlined,
    selectedIcon: Icons.dashboard,
    isVisibleTo: _dashboard,
  ),
  AppDestination(
    label: 'Products',
    icon: Icons.inventory_2_outlined,
    selectedIcon: Icons.inventory_2,
    isVisibleTo: _everyone,
  ),
  AppDestination(
    label: 'Stock',
    icon: Icons.warehouse_outlined,
    selectedIcon: Icons.warehouse,
    isVisibleTo: _stock,
  ),
  AppDestination(
    label: 'Goods Received',
    icon: Icons.move_to_inbox_outlined,
    selectedIcon: Icons.move_to_inbox,
    isVisibleTo: _stock,
  ),
  AppDestination(
    label: 'Orders',
    icon: Icons.shopping_cart_outlined,
    selectedIcon: Icons.shopping_cart,
    isVisibleTo: _orders,
  ),
  AppDestination(
    label: 'Catalogue',
    icon: Icons.category_outlined,
    selectedIcon: Icons.category,
    isVisibleTo: _catalogue,
  ),
  AppDestination(
    label: 'Customers',
    icon: Icons.people_outline,
    selectedIcon: Icons.people,
    isVisibleTo: _customers,
  ),
  AppDestination(
    label: 'Dispatches',
    icon: Icons.local_shipping_outlined,
    selectedIcon: Icons.local_shipping,
    isVisibleTo: _dispatches,
  ),
  AppDestination(
    label: 'Invoices',
    icon: Icons.receipt_long_outlined,
    selectedIcon: Icons.receipt_long,
    isVisibleTo: _invoices,
  ),
  AppDestination(
    label: 'Payments',
    icon: Icons.payments_outlined,
    selectedIcon: Icons.payments,
    isVisibleTo: _payments,
  ),
  AppDestination(
    label: 'Reports',
    icon: Icons.insights_outlined,
    selectedIcon: Icons.insights,
    isVisibleTo: _reports,
  ),
  AppDestination(
    label: 'Forecasts',
    icon: Icons.trending_up_outlined,
    selectedIcon: Icons.trending_up,
    isVisibleTo: _forecasts,
  ),
  AppDestination(
    label: 'Organisations',
    icon: Icons.business_outlined,
    selectedIcon: Icons.business,
    isVisibleTo: _everyone,
  ),
  AppDestination(
    label: 'Users & Roles',
    icon: Icons.manage_accounts_outlined,
    selectedIcon: Icons.manage_accounts,
    isVisibleTo: _users,
  ),
  AppDestination(
    label: 'Audit Log',
    icon: Icons.history_outlined,
    selectedIcon: Icons.history,
    isVisibleTo: _audit,
  ),
];

/// The sections [user] may use, in menu order.
List<AppDestination> destinationsFor(AppUser user) =>
    appDestinations.where((destination) => destination.isVisibleTo(user)).toList();
