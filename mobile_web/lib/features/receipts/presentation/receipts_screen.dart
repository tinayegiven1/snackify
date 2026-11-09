import 'package:flutter/material.dart';

import '../../../core/formatting/dates.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/message_view.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../purchases/domain/purchase_models.dart';
import '../../purchases/presentation/receive_against.dart';
import '../domain/receipt_models.dart';
import 'receipt_detail_screen.dart';
import 'receipt_editor_screen.dart';
import 'receipt_services.dart';

/// Goods-received notes the user may see (the Head Office: all; a subsidiary: its own),
/// newest first, filtered by status.
class ReceiptsScreen extends StatefulWidget {
  const ReceiptsScreen({super.key, required this.services});

  final ReceiptServices services;

  @override
  State<ReceiptsScreen> createState() => _ReceiptsScreenState();
}

class _ReceiptsScreenState extends State<ReceiptsScreen> {
  ReceiptStatus? _status;
  List<ReceiptSummary>? _receipts;

  /// Goods-bought lists still waiting to arrive, shown first for the warehouse to receive.
  List<PurchaseSummary> _waiting = const [];
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    // Reviewers mostly need what waits for them.
    if (widget.services.canVerify && !widget.services.canReceive) {
      _status = ReceiptStatus.pendingVerification;
    }
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.services.receipts.list(status: _status);
      final waiting = await _loadWaiting();
      if (mounted) {
        setState(() {
          _receipts = result.receipts;
          _waiting = waiting;
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Open goods-bought lists with something still to come (warehouse staff, "All" only).
  Future<List<PurchaseSummary>> _loadWaiting() async {
    final purchases = widget.services.purchases;
    if (purchases == null || !widget.services.canReceive || _status != null) return const [];
    try {
      final result = await purchases.list();
      return [
        for (final purchase in result.purchases)
          if (purchase.status == PurchaseStatus.open &&
              purchase.receivingStatus != ReceivingStatus.received)
            purchase,
      ];
    } on ApiException {
      return const []; // The notes still show; the lists come back on the next load.
    }
  }

  /// Receives against a goods-bought list: choose what arrived, then the note.
  Future<void> _receiveAgainst(PurchaseSummary purchase) async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    try {
      final receipt = await receiveAgainstPurchase(
        context,
        purchases: widget.services.purchases!,
        receiptServices: widget.services,
        purchaseId: purchase.id,
      );
      if (receipt == null || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(receivedMessage(receipt))));
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    }
    _load();
  }

  Future<void> _receive() async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final receipt = await Navigator.of(context).push<GoodsReceipt>(
      MaterialPageRoute(builder: (_) => ReceiptEditorScreen(services: widget.services)),
    );
    if (receipt == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(receivedMessage(receipt))));
    _load();
  }

  Future<void> _open(ReceiptSummary receipt) async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ReceiptDetailScreen(services: widget.services, receiptId: receipt.id),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: widget.services.canReceive
          ? FloatingActionButton.extended(
              heroTag: 'receive-stock',
              onPressed: _receive,
              icon: const Icon(Icons.move_to_inbox_outlined),
              label: const Text('Receive stock'),
            )
          : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                for (final status in <ReceiptStatus?>[null, ...ReceiptStatus.values])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(status?.label ?? 'All'),
                      selected: _status == status,
                      onSelected: (_) {
                        setState(() => _status = status);
                        _load();
                      },
                    ),
                  ),
              ],
            ),
          ),
          if (_loading && _receipts != null) const LinearProgressIndicator(),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  Widget _content() {
    if (_error != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load goods received',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    final receipts = _receipts;
    if (receipts == null) return const Center(child: CircularProgressIndicator());
    if (receipts.isEmpty && _waiting.isEmpty) {
      return MessageView(
        icon: Icons.move_to_inbox_outlined,
        title: 'No goods received',
        message: _status == null
            ? 'Deliveries recorded with "Receive stock" appear here.'
            : 'None are ${_status!.label.toLowerCase()}.',
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 88),
          children: [
            if (_waiting.isNotEmpty) ...[
              _SectionTitle('Waiting to be received'),
              for (final purchase in _waiting)
                _WaitingPurchase(purchase: purchase, onReceive: () => _receiveAgainst(purchase)),
              _SectionTitle(receipts.isEmpty ? 'No goods received yet' : 'Goods received'),
            ],
            for (final receipt in receipts) ...[
              ListTile(
                title: Text(
                  [
                    receipt.grnNumber,
                    ?receipt.supplier?.name,
                    ?receipt.supplierInvoiceNumber,
                  ].join(' · '),
                ),
                subtitle: Text(
                  [
                    '${formatApiDate(receipt.receivedDate)} · ${receipt.owner.name}',
                    '${receipt.currency} ${receipt.total} · ${receipt.lineCount} line(s) · '
                        '${receipt.attachmentCount} document(s)',
                    if (receipt.flags.discrepancies > 0) 'Quantities differ',
                    if (receipt.flags.documentTotalMismatch) 'Document total differs',
                  ].join('\n'),
                ),
                isThreeLine: true,
                trailing: ReceiptStatusBadge(receipt.status),
                onTap: () => _open(receipt),
              ),
              const Divider(height: 1),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

/// A goods-bought list still to arrive, with its Receive button.
class _WaitingPurchase extends StatelessWidget {
  const _WaitingPurchase({required this.purchase, required this.onReceive});

  final PurchaseSummary purchase;
  final VoidCallback onReceive;

  @override
  Widget build(BuildContext context) {
    final partly = purchase.receivingStatus == ReceivingStatus.partlyReceived;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [purchase.purchaseNumber, ?purchase.supplier?.name].join(' · '),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${formatApiDate(purchase.purchaseDate)} · ${purchase.owner.name} · '
                      '${purchase.lineCount} line(s)',
                      style: const TextStyle(color: SnackifyColors.muted, fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    Pill(
                      partly ? 'Partly received' : 'Not received',
                      tone: partly ? Tone.warn : Tone.info,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.tonalIcon(
                onPressed: onReceive,
                icon: const Icon(Icons.move_to_inbox_outlined),
                label: const Text('Receive'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The confirmation shown after saving a receipt.
String receivedMessage(GoodsReceipt receipt) => switch (receipt.status) {
  ReceiptStatus.draft => 'Saved draft ${receipt.grnNumber}.',
  _ when receipt.stockAdded =>
    'Submitted ${receipt.grnNumber}. Stock added to ${receipt.owner.name}; '
        'it will be verified by finance.',
  _ => 'Submitted ${receipt.grnNumber} for verification.',
};

class ReceiptStatusBadge extends StatelessWidget {
  const ReceiptStatusBadge(this.status, {super.key});

  final ReceiptStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return switch (status) {
      ReceiptStatus.posted => StatusBadge(
        status.label,
        color: SnackifyColors.success.withValues(alpha: 0.15),
        textColor: SnackifyColors.success,
      ),
      ReceiptStatus.rejected || ReceiptStatus.reversed => StatusBadge(
        status.label,
        color: colors.errorContainer,
        textColor: colors.onErrorContainer,
      ),
      ReceiptStatus.pendingVerification => StatusBadge(
        status.label,
        color: colors.tertiaryContainer,
        textColor: colors.onTertiaryContainer,
      ),
      _ => StatusBadge(status.label),
    };
  }
}
