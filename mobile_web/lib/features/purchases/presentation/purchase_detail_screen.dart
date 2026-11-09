import 'package:flutter/material.dart';

import '../../../core/files/pdf_sharer.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../receipts/domain/receipt_models.dart';
import '../../receipts/presentation/document_preview.dart';
import '../../receipts/presentation/receipt_detail_screen.dart';
import '../../receipts/presentation/receipts_screen.dart' show ReceiptStatusBadge, receivedMessage;
import '../domain/purchase_models.dart';
import 'purchase_editor_screen.dart';
import 'receive_against.dart';
import 'purchase_services.dart';
import 'purchases_screen.dart' show PurchaseStatusPill;

/// One goods-bought list: what was bought, what has arrived and what is still to come, the
/// supplier's documents, the goods-received notes made from it, and what may be done next.
/// Finance and administrators attach documents and verify or reject each one; the warehouse
/// can look at them.
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

  /// Pictures of the attached documents, downloaded for their thumbnails.
  late final _pictures = DocumentPictureCache(
    (documentId) => _services.purchases.document(widget.purchaseId, documentId),
  );

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

  /// Runs an action that returns the updated list, showing [done] when it succeeds.
  Future<void> _run(Future<Purchase> Function() action, String done) async {
    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });
    try {
      final purchase = await action();
      if (!mounted) return;
      setState(() {
        _purchase = purchase;
        _note = done;
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addDocuments(Purchase purchase) async {
    final picked = await _services.receiptServices.pickDocuments();
    for (final document in picked) {
      if (!mounted) return;
      await _run(
        () => _services.purchases.addDocument(purchase.id, document.name, document.bytes),
        'Attached ${document.name}.',
      );
      if (_error != null) return;
    }
  }

  Future<void> _takePhoto(Purchase purchase) async {
    final photo = await _services.receiptServices.takePhoto();
    if (photo == null || !mounted) return;
    await _run(
      () => _services.purchases.addDocument(purchase.id, photo.name, photo.bytes),
      'Attached ${photo.name}.',
    );
  }

  /// A photo opens in the preview; a PDF is downloaded (web) or shared (phones).
  Future<void> _openDocument(Purchase purchase, ReceiptDocument document) async {
    setState(() => _error = null);
    try {
      if (document.isPdf) {
        await _services.receiptServices.sharePdf(
          await _services.purchases.document(purchase.id, document.id),
          document.filename,
        );
        return;
      }
      final bytes =
          _pictures.bytesOf(document.id) ??
          await _services.purchases.document(purchase.id, document.id);
      if (mounted) await showDocumentPreview(context, document.filename, bytes);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Widget _thumbnail(ReceiptDocument document) {
    if (!document.isPdf) _pictures.ensure(document.id, () => mounted ? setState(() {}) : null);
    return DocumentThumbnail(
      isPdf: document.isPdf,
      bytes: _pictures.bytesOf(document.id),
      loading: _pictures.isLoading(document.id),
    );
  }

  Future<void> _review(Purchase purchase, ReceiptDocument document) async {
    final result = await showDialog<_Review>(
      context: context,
      builder: (_) => _ReviewDialog(document: document, currency: purchase.currency),
    );
    if (result == null || !mounted) return;
    final verified = result.status == DocumentStatus.verified;
    await _run(
      () => _services.purchases.reviewDocument(
        purchase.id,
        document.id,
        status: result.status,
        notes: result.notes,
        documentTotal: result.documentTotal,
      ),
      '${document.filename} ${verified ? 'verified' : 'rejected'}.',
    );
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

  /// Opens the goods-received editor filled in with what is still to arrive. The list is fetched
  /// again first: it may have been changed elsewhere (another device or tab) since this screen
  /// loaded, and a changed list has new lines that the note must point at.
  Future<void> _receive(Purchase shown) async {
    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });
    final GoodsReceipt? receipt;
    try {
      receipt = await receiveAgainstPurchase(
        context,
        purchases: _services.purchases,
        receiptServices: _services.receiptServices,
        purchaseId: shown.id,
      );
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
      await _load();
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    final saved = receipt;
    if (saved == null || !mounted) return;
    setState(() {
      _error = null;
      _note = receivedMessage(saved);
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
    final canAddDocuments = _services.canManage && purchase.status == PurchaseStatus.open;

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
                Text('Supplier documents', style: theme.textTheme.titleMedium),
                if (purchase.documentTotalMismatch) ...[
                  const SizedBox(height: 8),
                  ErrorBanner(
                    message:
                        'A verified document\'s total differs from this list\'s total '
                        '(${purchase.currency} ${purchase.total}).',
                  ),
                ],
                if (purchase.documents.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('No documents attached.'),
                  ),
                for (final document in purchase.documents)
                  _DocumentTile(
                    document: document,
                    currency: purchase.currency,
                    thumbnail: _thumbnail(document),
                    onTap: () => _openDocument(purchase, document),
                    showReview: _services.canManage && document.status == DocumentStatus.pending,
                    onReview: _busy ? null : () => _review(purchase, document),
                  ),
                if (canAddDocuments)
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: _busy ? null : () => _addDocuments(purchase),
                        icon: const Icon(Icons.attach_file),
                        label: const Text('Attach document'),
                      ),
                      TextButton.icon(
                        onPressed: _busy ? null : () => _takePhoto(purchase),
                        icon: const Icon(Icons.photo_camera_outlined),
                        label: const Text('Take photo'),
                      ),
                    ],
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

/// One supplier document: its picture, name, size and what the reviewer decided.
class _DocumentTile extends StatelessWidget {
  const _DocumentTile({
    required this.document,
    required this.currency,
    required this.thumbnail,
    required this.onTap,
    required this.showReview,
    required this.onReview,
  });

  final ReceiptDocument document;
  final String currency;
  final Widget thumbnail;
  final VoidCallback onTap;
  final bool showReview;
  final VoidCallback? onReview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = switch (document.status) {
      DocumentStatus.pending => Tone.warn,
      DocumentStatus.verified => Tone.good,
      DocumentStatus.rejected => Tone.bad,
    };
    final details = [
      document.sizeLabel,
      if (document.reviewedBy != null)
        '${document.status.label} by ${document.reviewedBy!.fullName}',
      if (document.documentTotal != null) 'Document total $currency ${document.documentTotal}',
      ?document.reviewNotes,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            thumbnail,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(document.filename, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 4),
                  Pill(document.status.label, tone: tone),
                  const SizedBox(height: 4),
                  Text(details.join('\n'), style: theme.textTheme.bodySmall),
                  if (showReview)
                    TextButton.icon(
                      onPressed: onReview,
                      icon: const Icon(Icons.fact_check_outlined),
                      label: const Text('Review'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the reviewer decided about a document.
typedef _Review = ({DocumentStatus status, String? notes, String? documentTotal});

/// Verifies or rejects one document, with notes (needed to reject) and the total printed on
/// it. Pops with the decision.
class _ReviewDialog extends StatefulWidget {
  const _ReviewDialog({required this.document, required this.currency});

  final ReceiptDocument document;
  final String currency;

  @override
  State<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends State<_ReviewDialog> {
  final _formKey = GlobalKey<FormState>();
  final _notes = TextEditingController();
  final _total = TextEditingController();
  DocumentStatus _status = DocumentStatus.verified;

  @override
  void dispose() {
    _notes.dispose();
    _total.dispose();
    super.dispose();
  }

  void _done() {
    if (!_formKey.currentState!.validate()) return;
    final notes = _notes.text.trim();
    final total = _total.text.trim();
    Navigator.of(context).pop<_Review>((
      status: _status,
      notes: notes.isEmpty ? null : notes,
      documentTotal: total.isEmpty ? null : total,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final rejecting = _status == DocumentStatus.rejected;
    return AlertDialog(
      title: Text('Review ${widget.document.filename}'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<DocumentStatus>(
                  segments: const [
                    ButtonSegment(
                      value: DocumentStatus.verified,
                      label: Text('Verify'),
                      icon: Icon(Icons.check),
                    ),
                    ButtonSegment(
                      value: DocumentStatus.rejected,
                      label: Text('Reject'),
                      icon: Icon(Icons.close),
                    ),
                  ],
                  selected: {_status},
                  onSelectionChanged: (selected) => setState(() => _status = selected.first),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _notes,
                  maxLength: 500,
                  decoration: InputDecoration(
                    labelText: rejecting ? 'Why it is rejected' : 'Notes (optional)',
                    border: const OutlineInputBorder(),
                  ),
                  validator: (value) => rejecting && (value ?? '').trim().length < 3
                      ? 'Say why (at least 3 characters)'
                      : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _total,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Total on the document (optional)',
                    hintText: 'e.g. 57.50',
                    prefixText: '${widget.currency} ',
                    border: const OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final text = (value ?? '').trim();
                    if (text.isEmpty) return null;
                    return RegExp(r'^\d{1,12}(\.\d{1,2})?$').hasMatch(text)
                        ? null
                        : 'Use an amount with up to 2 decimal places';
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _done,
          child: Text(rejecting ? 'Reject document' : 'Verify document'),
        ),
      ],
    );
  }
}
