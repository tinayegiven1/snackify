import 'package:flutter/material.dart';

import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/network/api_client.dart';
import '../../../core/scanning/barcode_reader.dart';
import '../../../shared/widgets/message_view.dart';
import '../../customers/data/customers_repository.dart';
import '../../products/data/products_repository.dart';
import '../data/dispatches_repository.dart';
import '../domain/dispatch_models.dart';
import 'dispatch_editor_screen.dart';

/// One dispatch: its lines, totals and history, and the actions the user's role allows.
class DispatchDetailScreen extends StatefulWidget {
  const DispatchDetailScreen({
    super.key,
    required this.dispatchId,
    required this.dispatches,
    required this.customers,
    required this.products,
    required this.permissions,
    required this.readBarcode,
  });

  final String dispatchId;
  final DispatchesRepository dispatches;
  final CustomersRepository customers;
  final ProductsRepository products;
  final DispatchPermissions permissions;
  final BarcodeReader readBarcode;

  @override
  State<DispatchDetailScreen> createState() => _DispatchDetailScreenState();
}

class _DispatchDetailScreenState extends State<DispatchDetailScreen> {
  Dispatch? _dispatch;
  String? _loadError;
  bool _busy = false;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final dispatch = await widget.dispatches.get(widget.dispatchId);
      if (mounted) setState(() => _dispatch = dispatch);
    } on ApiException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    }
  }

  /// Runs an action, showing progress and any error, and updates the screen with the result.
  Future<void> _run(Future<Dispatch> Function() action, String doneMessage) async {
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final updated = await action();
      if (!mounted) return;
      setState(() => _dispatch = updated);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(doneMessage)));
    } on ApiException catch (error) {
      if (mounted) setState(() => _actionError = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(Dispatch dispatch) async {
    final saved = await Navigator.of(context).push<Dispatch>(
      MaterialPageRoute(
        builder: (_) => DispatchEditorScreen(
          dispatches: widget.dispatches,
          customers: widget.customers,
          products: widget.products,
          readBarcode: widget.readBarcode,
          existing: dispatch,
        ),
      ),
    );
    if (saved != null && mounted) setState(() => _dispatch = saved);
  }

  Future<void> _confirm(Dispatch dispatch) async {
    final credit = dispatch.creditCheck;
    final overLimit = credit != null && credit.exceedsLimit;
    final go = await _askToConfirm(
      dispatch,
      overLimitMessage: overLimit
          ? 'Confirming takes ${dispatch.customerName}\'s unpaid balance to '
                '${withCurrency(credit.balanceAfter)}, over their credit limit of '
                '${withCurrency(credit.creditLimit!)}.'
          : null,
    );
    if (go != true) return;

    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      Dispatch confirmed;
      try {
        confirmed = await widget.dispatches.confirm(dispatch.id, acknowledgeCreditLimit: overLimit);
      } on ApiException catch (error) {
        // The balance changed since this screen was loaded: ask again with the server's figures.
        if (error.code != 'CREDIT_LIMIT_EXCEEDED' || !mounted) rethrow;
        final retry = await _askToConfirm(dispatch, overLimitMessage: error.message);
        if (retry != true) return;
        confirmed = await widget.dispatches.confirm(dispatch.id, acknowledgeCreditLimit: true);
      }
      if (!mounted) return;
      setState(() => _dispatch = confirmed);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${dispatch.dispatchNumber} confirmed. Stock has been updated.')),
      );
    } on ApiException catch (error) {
      if (mounted) setState(() => _actionError = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _askToConfirm(Dispatch dispatch, {String? overLimitMessage}) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: overLimitMessage == null ? null : const Icon(Icons.warning_amber_rounded),
        title: Text(overLimitMessage == null ? 'Confirm dispatch?' : 'Over credit limit'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (overLimitMessage == null) ...[
                // Quantities are checked once more before stock is taken out (spec 6.7).
                const Text('Check the quantities:'),
                const SizedBox(height: 8),
                for (final line in dispatch.items)
                  Text(
                    '${line.quantity} × ${line.description}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                const SizedBox(height: 12),
                Text(
                  '${dispatch.totalQuantity} packs will be taken out of stock for '
                  '${dispatch.customerName}. A confirmed dispatch cannot be edited.',
                ),
              ] else
                Text('$overLimitMessage\n\nYou can still confirm; this will be recorded.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Go back'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(overLimitMessage == null ? 'Confirm' : 'Confirm anyway'),
          ),
        ],
      ),
    );
  }

  Future<String?> _askReason(String title, String action) {
    final reason = TextEditingController();
    final formKey = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: reason,
            autofocus: true,
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'Reason',
              border: OutlineInputBorder(),
              counterText: '',
            ),
            validator: (value) =>
                (value ?? '').trim().length < 3 ? 'Explain the reason in a few words' : null,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Go back')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.of(context).pop(reason.text.trim());
              }
            },
            child: Text(action),
          ),
        ],
      ),
    );
  }

  Future<void> _cancel(Dispatch dispatch) async {
    final reason = await _askReason('Cancel ${dispatch.dispatchNumber}?', 'Cancel dispatch');
    if (reason == null) return;
    await _run(
      () => widget.dispatches.cancel(dispatch.id, reason),
      '${dispatch.dispatchNumber} cancelled.',
    );
  }

  Future<void> _reverse(Dispatch dispatch) async {
    final reason = await _askReason(
      'Reverse ${dispatch.dispatchNumber}?',
      'Reverse and return stock',
    );
    if (reason == null) return;
    await _run(
      () => widget.dispatches.reverse(dispatch.id, reason),
      '${dispatch.dispatchNumber} reversed. The stock has been put back.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final dispatch = _dispatch;
    return Scaffold(
      appBar: AppBar(title: Text(dispatch?.dispatchNumber ?? 'Dispatch')),
      body: _loadError != null
          ? MessageView(
              icon: Icons.cloud_off_outlined,
              title: 'Could not load the dispatch',
              message: _loadError!,
              action: RetryButton(onPressed: _load),
            )
          : dispatch == null
          ? const Center(child: CircularProgressIndicator())
          : _buildDetail(dispatch),
    );
  }

  Widget _buildDetail(Dispatch dispatch) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDraft = dispatch.status == DispatchStatus.draft;
    final credit = dispatch.creditCheck;
    final can = widget.permissions;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DispatchStatusBadge(dispatch.status),
                  Text(formatApiDate(dispatch.dispatchDate)),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '${dispatch.customerName} (${dispatch.customerCode})',
                style: theme.textTheme.titleLarge,
              ),
              if (dispatch.notes != null) ...[const SizedBox(height: 4), Text(dispatch.notes!)],
              const SizedBox(height: 16),
              if (isDraft && credit != null && credit.exceedsLimit)
                _Notice(
                  icon: Icons.warning_amber_rounded,
                  color: colorScheme.tertiaryContainer,
                  textColor: colorScheme.onTertiaryContainer,
                  message:
                      'Over credit limit: confirming takes the unpaid balance to '
                      '${withCurrency(credit.balanceAfter)} (limit '
                      '${withCurrency(credit.creditLimit!)}). The unpaid balance is every confirmed '
                      'dispatch less the payments received.',
                ),
              if (isDraft && dispatch.shortLines.isNotEmpty)
                _Notice(
                  icon: Icons.inventory_2_outlined,
                  color: colorScheme.errorContainer,
                  textColor: colorScheme.onErrorContainer,
                  message:
                      'Not enough stock for: '
                      '${dispatch.shortLines.map((l) => l.description).join(', ')}.',
                ),
              Card(
                child: Column(
                  children: [
                    for (final line in dispatch.items)
                      ListTile(
                        title: Text(line.description),
                        subtitle: Text(
                          [
                            '${line.quantity} × ${withCurrency(line.unitPrice)}',
                            if (isDraft) 'in stock: ${line.quantityOnHand}',
                          ].join(' · '),
                          style: isDraft && line.quantity > line.quantityOnHand
                              ? TextStyle(color: colorScheme.error)
                              : null,
                        ),
                        trailing: Text(withCurrency(line.lineTotal)),
                      ),
                    const Divider(height: 1),
                    ListTile(
                      title: Text(
                        'Total: ${dispatch.totalQuantity} packs',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      trailing: Text(
                        withCurrency(dispatch.totalValue),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text('Created by ${dispatch.createdBy}', style: theme.textTheme.bodySmall),
              if (dispatch.confirmedBy != null)
                Text(
                  'Confirmed by ${dispatch.confirmedBy}'
                  '${dispatch.confirmedOverCreditLimit ? ' (over the credit limit)' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
              if (dispatch.cancelReason != null)
                Text('Cancelled: ${dispatch.cancelReason}', style: theme.textTheme.bodySmall),
              if (dispatch.reversalReason != null)
                Text('Reversed: ${dispatch.reversalReason}', style: theme.textTheme.bodySmall),
              if (_actionError != null) ...[
                const SizedBox(height: 16),
                ErrorBanner(message: _actionError!),
              ],
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  if (isDraft && can.canCreate)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _cancel(dispatch),
                      icon: const Icon(Icons.close),
                      label: const Text('Cancel draft'),
                    ),
                  if (isDraft && can.canCreate)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _edit(dispatch),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit'),
                    ),
                  if (isDraft && can.canConfirm)
                    FilledButton.icon(
                      onPressed: _busy ? null : () => _confirm(dispatch),
                      icon: const Icon(Icons.check),
                      label: const Text('Confirm dispatch'),
                    ),
                  if (dispatch.status == DispatchStatus.confirmed && can.canReverse)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _reverse(dispatch),
                      icon: const Icon(Icons.undo),
                      label: const Text('Reverse'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.textColor,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final Color textColor;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(icon, color: textColor),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message, style: TextStyle(color: textColor)),
          ),
        ],
      ),
    );
  }
}

/// A coloured label for a dispatch's status.
class DispatchStatusBadge extends StatelessWidget {
  const DispatchStatusBadge(this.status, {super.key});

  final DispatchStatus status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (status) {
      DispatchStatus.draft => (colorScheme.secondaryContainer, colorScheme.onSecondaryContainer),
      DispatchStatus.confirmed => (Colors.green.shade100, Colors.green.shade900),
      DispatchStatus.cancelled || DispatchStatus.reversed => (
        colorScheme.surfaceContainerHighest,
        colorScheme.onSurfaceVariant,
      ),
    };
    return StatusBadge(status.label, color: background, textColor: foreground);
  }
}
