import 'package:flutter/material.dart';

// SAMPLE DATA ONLY. Nothing here comes from the database.
// Replace with API data once stock, dispatch, invoice and payment endpoints exist.

class DashboardMetric {
  const DashboardMetric({
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
  });

  final String label;
  final String value;
  final String caption;
  final IconData icon;
}

class LowStockItem {
  const LowStockItem({
    required this.product,
    required this.flavour,
    required this.size,
    required this.onHand,
    required this.reorderLevel,
  });

  final String product;
  final String flavour;
  final String size;
  final int onHand;
  final int reorderLevel;
}

/// Dispatch value, invoiced amount and cash received are deliberately separate measures.
const placeholderMetrics = <DashboardMetric>[
  DashboardMetric(
    label: 'Stock on hand',
    value: '1,240 packs',
    caption: 'All product variations',
    icon: Icons.inventory_2_outlined,
  ),
  DashboardMetric(
    label: 'Received today',
    value: '300 packs',
    caption: '3 stock receipts',
    icon: Icons.move_to_inbox_outlined,
  ),
  DashboardMetric(
    label: 'Dispatches today',
    value: '6',
    caption: '4 confirmed · 2 draft',
    icon: Icons.local_shipping_outlined,
  ),
  DashboardMetric(
    label: 'Dispatch value (confirmed)',
    value: 'USD 482.50',
    caption: 'Today, not yet invoiced',
    icon: Icons.sell_outlined,
  ),
  DashboardMetric(
    label: 'Invoiced this week',
    value: 'USD 1,920.00',
    caption: 'Issued invoices',
    icon: Icons.receipt_long_outlined,
  ),
  DashboardMetric(
    label: 'Payments received this week',
    value: 'USD 1,150.00',
    caption: 'Money actually received',
    icon: Icons.payments_outlined,
  ),
  DashboardMetric(
    label: 'Outstanding balance',
    value: 'USD 2,310.00',
    caption: 'Unpaid invoices, all customers',
    icon: Icons.account_balance_wallet_outlined,
  ),
  DashboardMetric(
    label: 'Low-stock products',
    value: '3',
    caption: 'At or below reorder level',
    icon: Icons.warning_amber_outlined,
  ),
];

const placeholderLowStock = <LowStockItem>[
  LowStockItem(
    product: 'Potato Crisps',
    flavour: 'BBQ',
    size: 'Small',
    onHand: 18,
    reorderLevel: 50,
  ),
  LowStockItem(
    product: 'Potato Crisps',
    flavour: 'Salt & Vinegar',
    size: 'Large',
    onHand: 9,
    reorderLevel: 30,
  ),
  LowStockItem(
    product: 'Maize Puffs',
    flavour: 'Cheese',
    size: 'Small',
    onHand: 22,
    reorderLevel: 40,
  ),
];
