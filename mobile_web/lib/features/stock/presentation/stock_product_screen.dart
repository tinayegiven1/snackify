import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/formatting/dates.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../data/stock_repository.dart';
import '../domain/stock_models.dart';

/// One product's stock: how much is on hand and every change to it (the ledger).
/// Admins can correct the count or record damage here.
class StockProductScreen extends StatefulWidget {
  const StockProductScreen({
    super.key,
    required this.stock,
    required this.balance,
    required this.canAdjust,
  });

  final StockRepository stock;
  final StockBalance balance;
  final bool canAdjust;

  @override
  State<StockProductScreen> createState() => _StockProductScreenState();
}

class _StockProductScreenState extends State<StockProductScreen> {
  late int _onHand = widget.balance.quantityOnHand;
  bool _loading = true;
  String? _error;
  List<StockMovement>? _movements;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final movements = await widget.stock.movements(widget.balance.product.id);
      if (!mounted) return;
      setState(() {
        _movements = movements;
        if (movements.isNotEmpty) _onHand = movements.first.balanceAfter;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _adjust() async {
    final newBalance = await showDialog<int>(
      context: context,
      builder: (_) => _AdjustStockDialog(
        stock: widget.stock,
        productId: widget.balance.product.id,
        onHand: _onHand,
      ),
    );
    if (newBalance == null || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Stock updated. In stock now: $newBalance')));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final balance = widget.balance;
    final isLow = balance.reorderLevel != null && _onHand <= balance.reorderLevel!;

    return Scaffold(
      appBar: AppBar(title: Text(balance.product.description)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 24,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('In stock', style: theme.textTheme.labelLarge),
                        Text(
                          '$_onHand packs',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: isLow ? theme.colorScheme.error : null,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      balance.reorderLevel == null
                          ? 'No reorder level set'
                          : 'Reorder at ${balance.reorderLevel}${isLow ? ' — low stock' : ''}',
                    ),
                    if (widget.canAdjust)
                      OutlinedButton.icon(
                        onPressed: _adjust,
                        icon: const Icon(Icons.tune),
                        label: const Text('Adjust stock'),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('History', style: theme.textTheme.titleMedium),
          ),
          if (_loading && _movements != null) const LinearProgressIndicator(),
          Expanded(child: _buildHistory()),
        ],
      ),
    );
  }

  Widget _buildHistory() {
    if (_error != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load the history',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    final movements = _movements;
    if (movements == null) return const Center(child: CircularProgressIndicator());
    if (movements.isEmpty) {
      return const MessageView(
        icon: Icons.history,
        title: 'No stock history yet',
        message: 'Receipts, damage and corrections for this product will appear here.',
      );
    }
    final colorScheme = Theme.of(context).colorScheme;
    return ListView.separated(
      itemCount: movements.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final movement = movements[index];
        final adds = movement.quantityDelta > 0;
        return ListTile(
          leading: Icon(
            adds ? Icons.add_circle_outline : Icons.remove_circle_outline,
            color: adds ? Colors.green.shade700 : colorScheme.error,
          ),
          title: Text('${movement.typeLabel}  ${adds ? '+' : ''}${movement.quantityDelta}'),
          subtitle: Text(
            [
              formatApiDate(movement.businessDate),
              'by ${movement.createdBy}',
              if (movement.batchNumber != null) 'Batch ${movement.batchNumber}',
              ?movement.reference,
              ?movement.reason,
            ].join(' · '),
          ),
          trailing: Text('= ${movement.balanceAfter}'),
        );
      },
    );
  }
}

enum _AdjustmentKind { add, remove, damage }

/// Lets an admin correct the count or record damaged stock, with a reason.
/// Pops with the new stock on hand.
class _AdjustStockDialog extends StatefulWidget {
  const _AdjustStockDialog({required this.stock, required this.productId, required this.onHand});

  final StockRepository stock;
  final String productId;
  final int onHand;

  @override
  State<_AdjustStockDialog> createState() => _AdjustStockDialogState();
}

class _AdjustStockDialogState extends State<_AdjustStockDialog> {
  final _formKey = GlobalKey<FormState>();
  final _quantity = TextEditingController();
  final _reason = TextEditingController();
  _AdjustmentKind _kind = _AdjustmentKind.damage;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _quantity.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    final quantity = int.parse(_quantity.text.trim());
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final newBalance = await widget.stock.adjust(
        productId: widget.productId,
        type: _kind == _AdjustmentKind.damage ? 'damage' : 'adjustment',
        quantityDelta: _kind == _AdjustmentKind.add ? quantity : -quantity,
        reason: _reason.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(newBalance);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Adjust stock'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('In stock now: ${widget.onHand} packs'),
              const SizedBox(height: 16),
              SegmentedButton<_AdjustmentKind>(
                segments: const [
                  ButtonSegment(value: _AdjustmentKind.damage, label: Text('Damaged')),
                  ButtonSegment(value: _AdjustmentKind.remove, label: Text('Remove')),
                  ButtonSegment(value: _AdjustmentKind.add, label: Text('Add')),
                ],
                selected: {_kind},
                onSelectionChanged: _saving
                    ? null
                    : (selection) => setState(() => _kind = selection.first),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _quantity,
                enabled: !_saving,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: _kind == _AdjustmentKind.add ? 'Packs to add' : 'Packs to remove',
                  border: const OutlineInputBorder(),
                ),
                validator: (value) {
                  final quantity = int.tryParse((value ?? '').trim());
                  if (quantity == null || quantity < 1) return 'Enter a number of packs';
                  if (_kind != _AdjustmentKind.add && quantity > widget.onHand) {
                    return 'Only ${widget.onHand} in stock';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _reason,
                enabled: !_saving,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: 'Reason',
                  hintText: 'e.g. Packs torn in transit, or stock count found 2 more',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
                validator: (value) =>
                    (value ?? '').trim().length < 3 ? 'Explain the reason in a few words' : null,
              ),
              if (_error != null) ...[const SizedBox(height: 8), ErrorBanner(message: _error!)],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _saving ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
