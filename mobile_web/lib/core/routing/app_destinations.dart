import 'package:flutter/material.dart';

import '../../features/auth/domain/app_user.dart';

class AppDestination {
  const AppDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.isVisibleTo,
    this.description = '',
  });

  final String label;

  /// One line under the page title saying what the section is for.
  final String description;
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
    description: 'Today\'s stock, sales and money at a glance.',
    icon: Icons.dashboard_outlined,
    selectedIcon: Icons.dashboard,
    isVisibleTo: _dashboard,
  ),
  AppDestination(
    label: 'Products',
    description: 'Every product you sell: names, sizes, codes and prices.',
    icon: Icons.inventory_2_outlined,
    selectedIcon: Icons.inventory_2,
    isVisibleTo: _everyone,
  ),
  AppDestination(
    label: 'Stock',
    description: 'What is on hand, what is running low and what has run out.',
    icon: Icons.warehouse_outlined,
    selectedIcon: Icons.warehouse,
    isVisibleTo: _stock,
  ),
  AppDestination(
    label: 'Goods Received',
    description: 'Deliveries in, with their supplier documents.',
    icon: Icons.move_to_inbox_outlined,
    selectedIcon: Icons.move_to_inbox,
    isVisibleTo: _stock,
  ),
  AppDestination(
    label: 'Orders',
    description: 'Orders from the subsidiaries and their prices.',
    icon: Icons.shopping_cart_outlined,
    selectedIcon: Icons.shopping_cart,
    isVisibleTo: _orders,
  ),
  AppDestination(
    label: 'Catalogue',
    description: 'Suppliers, categories, warehouses and units.',
    icon: Icons.category_outlined,
    selectedIcon: Icons.category,
    isVisibleTo: _catalogue,
  ),
  AppDestination(
    label: 'Dispatches',
    description: 'Goods sent out to the subsidiaries.',
    icon: Icons.local_shipping_outlined,
    selectedIcon: Icons.local_shipping,
    isVisibleTo: _dispatches,
  ),
  AppDestination(
    label: 'Invoices',
    description: 'Weekly bills for confirmed dispatches.',
    icon: Icons.receipt_long_outlined,
    selectedIcon: Icons.receipt_long,
    isVisibleTo: _invoices,
  ),
  AppDestination(
    label: 'Payments',
    description: 'Money received and what it pays.',
    icon: Icons.payments_outlined,
    selectedIcon: Icons.payments,
    isVisibleTo: _payments,
  ),
  AppDestination(
    label: 'Reports',
    description: 'Sales, products, customers and stock over time.',
    icon: Icons.insights_outlined,
    selectedIcon: Icons.insights,
    isVisibleTo: _reports,
  ),
  AppDestination(
    label: 'Forecasts',
    description: 'Expected demand, to plan production and stock.',
    icon: Icons.trending_up_outlined,
    selectedIcon: Icons.trending_up,
    isVisibleTo: _forecasts,
  ),
  AppDestination(
    label: 'Organisations',
    description: 'The Head Office and its subsidiaries (the customers).',
    icon: Icons.business_outlined,
    selectedIcon: Icons.business,
    isVisibleTo: _everyone,
  ),
  AppDestination(
    label: 'Users & Roles',
    description: 'Staff accounts and what each role may do.',
    icon: Icons.manage_accounts_outlined,
    selectedIcon: Icons.manage_accounts,
    isVisibleTo: _users,
  ),
  AppDestination(
    label: 'Audit Log',
    description: 'Who did what, and when.',
    icon: Icons.history_outlined,
    selectedIcon: Icons.history,
    isVisibleTo: _audit,
  ),
];

/// The sections [user] may use, in menu order.
List<AppDestination> destinationsFor(AppUser user) =>
    appDestinations.where((destination) => destination.isVisibleTo(user)).toList();
