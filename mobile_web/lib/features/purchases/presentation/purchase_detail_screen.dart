import 'package:flutter/material.dart';

import '../../../core/files/pdf_sharer.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../receipts/domain/receipt_models.dart';
import '../../receipts/presentation/receipt_detail_screen.dart';
import '../../receipts/presentation/receipt_editor_screen.dart';
import '../../receipts/presentation/receipts_screen.dart' show ReceiptStatusBadge, receivedMessage;
import '../domain/purchase_models.dart';
import 'purchase_editor_screen.dart';
import 'purchase_services.dart';
import 'purchases_screen.dart' show PurchaseStatusPill;

/// One goods-bought list: what was bought, what has arrived and what is still to come, the
/// goods-received notes made from it, and what may be done next.
class PurchaseDetailScreen extends StatefulWidget {
  const PurchaseDetailScreen({
    super.key,
    required this.services,
    required this.purchaseId,
    this.note,
  });

  final PurchaseServices services;
  final String purchaseId;

  /// Shown at the top when the screen opens, e.g. after saving.
  final String? note;

  @override
  State<PurchaseDetailScreen> createState() => _PurchaseDetailScreenState();
}

class _PurchaseDetailScreenState extends State<PurchaseDetailScreen> {
  Purchase? _purchase;
  String? _loadError;
  String? _error;
  late String? _note = widget.note;
  bool _busy = false;

  PurchaseServices get _services => widget.services;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final purchase = await _services.purchases.get(widget.purchaseId);
      if (mounted) setState(() => _purchase = purchase);
    } on ApiException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    }
  }

  Future<void> _download(Purchase purchase) async {
    setState(() => _error = null);
    try {
      await _services.receiptServices.sharePdf(
        await _services.purchases.pdf(purchase.id),
        '${purchase.purchaseNumber}.pdf',
      );
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _edit(Purchase purchase) async {
    final saved = await Navigator.of(context).push<Purchase>(
      MaterialPageRoute(
        builder: (_) => PurchaseEditorScreen(services: _services, purchase: purchase),
      ),
    );
    if (saved != null && mounted) {
      setState(() {
        _purchase = saved;
        _error = null;
        _note = 'Saved goods bought ${saved.purchaseNumber}.';
      });
    }
  }

  Future<void> _cancel(Purchase purchase) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel goods bought'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${purchase.purchaseNumber} can no longer be received against.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Reason', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Keep it')),
          FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.length >= 3) Navigator.pop(context, text);
            },
            child: const Text('Cancel list'),
          ),
        ],
      ),
    );
    if (reason == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });
    try {
      final cancelled = await _services.purchases.cancel(purchase.id, reason);
      if (!mounted) return;
      setState(() {
        _purchase = cancelled;
        _note = 'Goods bought ${purchase.purchaseNumber} cancelled.';
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opens the goods-received editor filled in with what is still to arrive.
  Future<void> _receive(Purchase purchase) async {
    final receipt = await Navigator.of(context).push<GoodsReceipt>(
      MaterialPageRoute(
        builder: (_) => ReceiptEditorScreen(
          services: _services.receiptServices,
          prefill: purchase.toReceiptPrefill(),
        ),
      ),
    );
    if (receipt == null || !mounted) return;
    setState(() {
      _error = null;
      _note = receivedMessage(receipt);
    });
    await _load();
  }

  Future<void> _openReceipt(PurchaseReceipt receipt) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            ReceiptDetailScreen(services: _services.receiptServices, receiptId: receipt.id),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final purchase = _purchase;
    return Scaffold(
      appBar: AppBar(
        title: Text(purchase == null ? 'Goods bought' : 'Goods bought ${purchase.purchaseNumber}'),
        actions: [
          if (purchase != null)
            IconButton(
              tooltip: sharePdfLabel,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              onPressed: () => _download(purchase),
            ),
        ],
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loadError != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load the goods bought',
        message: _loadError!,
        action: RetryButton(onPressed: _load),
      );
    }
    final purchase = _purchase;
    if (purchase == null) return const Center(child: CircularProgressIndicator());
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (_error != null) ...[ErrorBanner(message: _error!), const SizedBox(height: 12)],
                if (_note != null) ...[SuccessBanner(message: _note!), const SizedBox(height: 12)],
                Align(alignment: Alignment.centerLeft, child: PurchaseStatusPill(purchase)),
                const SizedBox(height: 12),
                _Facts(
                  facts: {
                    'Number': purchase.purchaseNumber,
                    'Status': purchase.status.label,
                    if (!purchase.isCancelled) 'Receiving': purchase.receivingStatus.label,
                    'Supplier': ?purchase.supplier?.name,
                    'Supplier invoice': ?purchase.supplierInvoiceNumber,
                    'Purchased': formatApiDate(purchase.purchaseDate),
                    'For': '${purchase.owner.name} (${purchase.owner.code})',
                    'Entered by': purchase.createdBy.fullName,
                    'Notes': ?purchase.notes,
                    if (purchase.cancelledBy != null)
                      'Cancelled by': purchase.cancelledBy!.fullName,
                    'Cancelled because': ?purchase.cancelReason,
                    'Total': '${purchase.currency} ${purchase.total}',
                  },
                ),
                const SizedBox(height: 16),
                Text('Products', style: theme.textTheme.titleMedium),
                for (final line in purchase.lines)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(line.productLabel),
                    subtitle: Text(
                      [
                        'Bought ${line.quantity} ${line.unit.name.toLowerCase()} · '
                            'Received ${line.quantityReceived} · '
                            'Outstanding ${line.quantityOutstanding}',
                        ?line.notes,
                      ].join('\n'),
                    ),
                    isThreeLine: line.notes != null,
                    trailing: Text(
                      '${line.unitCost} × ${line.quantity}\n${line.lineTotal}',
                      textAlign: TextAlign.right,
                    ),
                  ),
                const SizedBox(height: 16),
                Text('Goods received against it', style: theme.textTheme.titleMedium),
                if (purchase.receipts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('Nothing received yet.'),
                  ),
                for (final receipt in purchase.receipts)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.move_to_inbox_outlined),
                    title: Text(receipt.grnNumber),
                    subtitle: Text('Received ${formatApiDate(receipt.receivedDate)}'),
                    trailing: ReceiptStatusBadge(receipt.status),
                    onTap: () => _openReceipt(receipt),
                  ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    if (purchase.canCancel && _services.canManage)
                      OutlinedButton(
                        onPressed: _busy ? null : () => _cancel(purchase),
                        child: const Text('Cancel goods bought'),
                      ),
                    if (purchase.canChange && _services.canManage)
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => _edit(purchase),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Edit'),
                      ),
                    if (purchase.canReceive && _services.canReceive)
                      FilledButton.icon(
                        onPressed: _busy ? null : () => _receive(purchase),
                        icon: const Icon(Icons.move_to_inbox_outlined),
                        label: const Text('Receive'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Facts extends StatelessWidget {
  const _Facts({required this.facts});

  final Map<String, String> facts;

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final MapEntry(:key, :value) in facts.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 130, child: Text(key, style: labelStyle)),
                Expanded(child: Text(value)),
              ],
            ),
          ),
      ],
    );
  }
}
