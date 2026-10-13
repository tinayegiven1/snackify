import 'package:flutter/material.dart';

class AppDestination {
  const AppDestination({required this.label, required this.icon, required this.selectedIcon});

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Main navigation sections.
const appDestinations = <AppDestination>[
  AppDestination(label: 'Dashboard', icon: Icons.dashboard_outlined, selectedIcon: Icons.dashboard),
  AppDestination(
    label: 'Products',
    icon: Icons.inventory_2_outlined,
    selectedIcon: Icons.inventory_2,
  ),
  AppDestination(label: 'Stock', icon: Icons.warehouse_outlined, selectedIcon: Icons.warehouse),
  AppDestination(label: 'Customers', icon: Icons.people_outline, selectedIcon: Icons.people),
  AppDestination(
    label: 'Dispatches',
    icon: Icons.local_shipping_outlined,
    selectedIcon: Icons.local_shipping,
  ),
  AppDestination(
    label: 'Invoices',
    icon: Icons.receipt_long_outlined,
    selectedIcon: Icons.receipt_long,
  ),
  AppDestination(label: 'Payments', icon: Icons.payments_outlined, selectedIcon: Icons.payments),
  AppDestination(label: 'Reports', icon: Icons.insights_outlined, selectedIcon: Icons.insights),
  AppDestination(
    label: 'Forecasts',
    icon: Icons.trending_up_outlined,
    selectedIcon: Icons.trending_up,
  ),
];
