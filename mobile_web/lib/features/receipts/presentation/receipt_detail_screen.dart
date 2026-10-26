import 'package:flutter/material.dart';

import '../../../core/files/pdf_sharer.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../domain/receipt_models.dart';
import 'receipt_editor_screen.dart';
import 'receipt_services.dart';
import 'receipts_screen.dart' show ReceiptStatusBadge, receivedMessage;

/// One goods-received note: its lines and documents, and what may be done next. Reviewers
/// check each document, then verify or reject the receipt; administrators reverse a posted one.
class ReceiptDetailScreen extends StatefulWidget {
  const ReceiptDetailScreen({super.key, required this.services, required this.receiptId});

  final ReceiptServices services;
  final String receiptId;

  @override
  State<ReceiptDetailScreen> createState() => _ReceiptDetailScreenState();
}

class _ReceiptDetailScreenState extends State<ReceiptDetailScreen> {
  GoodsReceipt? _receipt;
  String? _loadError;
  String? _error;

  /// What the last action did, shown at the top (a snackbar would cover the buttons).
  String? _note;
  bool _busy = false;

  ReceiptServices get _services => widget.services;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final receipt = await _services.receipts.get(widget.receiptId);
      if (mounted) setState(() => _receipt = receipt);
    } on ApiException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    }
  }

  /// Runs an action that returns the updated receipt, showing [done] when it succeeds.
  Future<void> _run(Future<GoodsReceipt> Function() action, String done) async {
    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });
    try {
      final receipt = await action();
      if (!mounted) return;
      setState(() {
        _receipt = receipt;
        _note = done;
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askText(String title, String label, {String? message, int minLength = 3}) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (message != null) ...[Text(message), const SizedBox(height: 12)],
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 500,
              decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.length >= minLength || (minLength == 0)) Navigator.pop(context, text);
            },
            child: Text(title.split(' ').first),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(GoodsReceipt receipt) async {
    final saved = await Navigator.of(context).push<GoodsReceipt>(
      MaterialPageRoute(
        builder: (_) => ReceiptEditorScreen(services: _services, receipt: receipt),
      ),
    );
    if (saved != null && mounted) {
      setState(() {
        _receipt = saved;
        _note = receivedMessage(saved);
      });
    }
  }

  Future<void> _addDocuments(GoodsReceipt receipt) async {
    final picked = await _services.pickDocuments();
    for (final document in picked) {
      await _run(
        () => _services.receipts.addDocument(receipt.id, document.name, document.bytes),
        'Attached ${document.name}.',
      );
      if (_error != null) return;
    }
  }

  Future<void> _review(GoodsReceipt receipt, ReceiptDocument document) async {
    final result = await showDialog<_Review>(
      context: context,
      builder: (_) => _ReviewDialog(document: document, receiptTotal: receipt.total),
    );
    if (result == null) return;
    await _run(
      () => _services.receipts.reviewDocument(
        receipt.id,
        document.id,
        status: result.status,
        notes: result.notes,
        documentTotal: result.documentTotal,
      ),
      result.status == DocumentStatus.verified
          ? 'Verified ${document.filename}.'
          : 'Rejected ${document.filename}.',
    );
  }

  Future<void> _verify(GoodsReceipt receipt) async {
    final notes = await _askText(
      'Verify receipt',
      'Notes (optional)',
      message: 'The documents, quantities and costs match what arrived.',
      minLength: 0,
    );
    if (notes == null) return;
    await _run(
      () => _services.receipts.verify(receipt.id, notes: notes.isEmpty ? null : notes),
      'Receipt ${receipt.grnNumber} verified.',
    );
  }

  Future<void> _reject(GoodsReceipt receipt) async {
    final reason = await _askText(
      'Reject receipt',
      'Reason',
      message: receipt.stockAdded
          ? 'Its stock is taken back out of ${receipt.owner.name}\'s balance.'
          : null,
    );
    if (reason == null) return;
    await _run(
      () => _services.receipts.reject(receipt.id, reason),
      'Receipt ${receipt.grnNumber} rejected.',
    );
  }

  Future<void> _reverse(GoodsReceipt receipt) async {
    final reason = await _askText(
      'Reverse receipt',
      'Reason',
      message:
          'Its stock is taken back out of ${receipt.owner.name}\'s balance. The receipt and '
          'its history are kept.',
    );
    if (reason == null) return;
    await _run(
      () => _services.receipts.reverse(receipt.id, reason),
      'Receipt ${receipt.grnNumber} reversed.',
    );
  }

  Future<void> _download(Future<void> Function() action) async {
    setState(() => _error = null);
    try {
      await action();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final receipt = _receipt;
    return Scaffold(
      appBar: AppBar(
        title: Text(receipt == null ? 'Goods received' : 'Goods received ${receipt.grnNumber}'),
        actions: [
          if (receipt != null)
            IconButton(
              tooltip: sharePdfLabel,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              onPressed: () => _download(
                () async => _services.sharePdf(
                  await _services.receipts.pdf(receipt.id),
                  '${receipt.grnNumber}.pdf',
                ),
              ),
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
        title: 'Could not load the receipt',
        message: _loadError!,
        action: RetryButton(onPressed: _load),
      );
    }
    final receipt = _receipt;
    if (receipt == null) return const Center(child: CircularProgressIndicator());
    final theme = Theme.of(context);
    final status = receipt.status;
    final reviewable =
        _services.canVerify &&
        (status == ReceiptStatus.pendingVerification || status == ReceiptStatus.draft);
    final canAddDocuments =
        _services.canReceive &&
        (status == ReceiptStatus.draft || status == ReceiptStatus.pendingVerification);

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
                Row(
                  children: [
                    ReceiptStatusBadge(status),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        receipt.stockAdded
                            ? 'Stock added to ${receipt.owner.name}'
                            : 'No stock added',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _Facts(
                  facts: {
                    'Stock owner': '${receipt.owner.name} (${receipt.owner.code})',
                    'Supplier': ?receipt.supplier?.name,
                    'Supplier invoice': ?receipt.supplierInvoiceNumber,
                    'Received': formatApiDate(receipt.receivedDate),
                    if (receipt.purchaseDate != null)
                      'Purchased': formatApiDate(receipt.purchaseDate!),
                    'Warehouse': receipt.warehouse.name,
                    'Received by': receipt.receivedBy.fullName,
                    if (receipt.verifiedBy != null && status != ReceiptStatus.rejected)
                      'Verified by': receipt.verifiedBy!.fullName,
                    'Verification notes': ?receipt.verificationNotes,
                    'Rejected because': ?receipt.rejectedReason,
                    'Reversed because': ?receipt.reversalReason,
                    'No document because': ?receipt.noDocumentReason,
                    'Notes': ?receipt.notes,
                    'Total': '${receipt.currency} ${receipt.total}',
                  },
                ),
                if (receipt.flags.discrepancies > 0 || receipt.flags.documentTotalMismatch) ...[
                  const SizedBox(height: 12),
                  ErrorBanner(
                    message: [
                      if (receipt.flags.discrepancies > 0)
                        '${receipt.flags.discrepancies} line(s) received differ from what was '
                            'bought.',
                      if (receipt.flags.documentTotalMismatch)
                        'A document\'s total differs from this receipt\'s total.',
                    ].join('\n'),
                  ),
                ],
                const SizedBox(height: 16),
                Text('Products', style: theme.textTheme.titleMedium),
                for (final line in receipt.lines)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${line.productDescription} (${line.productSku})'),
                    subtitle: Text(
                      [
                        'Received ${line.quantityReceived} ${line.unit.name.toLowerCase()}'
                            '${line.quantityPurchased != line.quantityReceived ? ' of ${line.quantityPurchased} bought' : ''}',
                        if (line.baseQuantityReceived != line.quantityReceived)
                          '= ${line.baseQuantityReceived} in stock units',
                        if (line.discrepancyReason != null)
                          discrepancyReasons[line.discrepancyReason] ?? line.discrepancyReason!,
                        if (line.batchNumber != null) 'Batch ${line.batchNumber}',
                        if (line.expiryDate != null) 'Expires ${formatApiDate(line.expiryDate!)}',
                      ].join(' · '),
                    ),
                    trailing: Text(
                      '${line.unitCost} × ${line.quantityPurchased}\n${line.lineTotal}',
                      textAlign: TextAlign.right,
                    ),
                  ),
                const SizedBox(height: 16),
                Text('Supplier documents', style: theme.textTheme.titleMedium),
                if (receipt.documents.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('No documents attached.'),
                  ),
                for (final document in receipt.documents)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      document.isPdf ? Icons.picture_as_pdf_outlined : Icons.image_outlined,
                    ),
                    title: Text(document.filename),
                    subtitle: Text(
                      [
                        '${document.sizeLabel} · ${document.status.label}',
                        if (document.documentTotal != null)
                          'Document total ${receipt.currency} ${document.documentTotal}',
                        ?document.reviewNotes,
                      ].join('\n'),
                    ),
                    isThreeLine: document.reviewNotes != null || document.documentTotal != null,
                    trailing: Wrap(
                      children: [
                        IconButton(
                          tooltip: 'Download ${document.filename}',
                          icon: const Icon(Icons.download_outlined),
                          onPressed: () => _download(
                            () async => _services.sharePdf(
                              await _services.receipts.document(receipt.id, document.id),
                              document.filename,
                            ),
                          ),
                        ),
                        if (reviewable && document.status == DocumentStatus.pending)
                          IconButton(
                            tooltip: 'Review ${document.filename}',
                            icon: const Icon(Icons.fact_check_outlined),
                            onPressed: _busy ? null : () => _review(receipt, document),
                          ),
                      ],
                    ),
                  ),
                if (canAddDocuments)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _busy ? null : () => _addDocuments(receipt),
                      icon: const Icon(Icons.attach_file),
                      label: const Text('Attach document'),
                    ),
                  ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    if (status == ReceiptStatus.draft && _services.canReceive)
                      FilledButton.icon(
                        onPressed: _busy ? null : () => _edit(receipt),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Continue draft'),
                      ),
                    if (status == ReceiptStatus.pendingVerification && _services.canVerify) ...[
                      OutlinedButton(
                        onPressed: _busy ? null : () => _reject(receipt),
                        child: const Text('Reject receipt'),
                      ),
                      FilledButton(
                        onPressed: _busy ? null : () => _verify(receipt),
                        child: const Text('Verify receipt'),
                      ),
                    ],
                    if (status == ReceiptStatus.verified && _services.canReceive)
                      FilledButton(
                        onPressed: _busy
                            ? null
                            : () => _run(
                                () => _services.receipts.post(receipt.id),
                                'Stock added to ${receipt.owner.name}.',
                              ),
                        child: const Text('Post stock'),
                      ),
                    if (status == ReceiptStatus.posted && _services.canReverse)
                      OutlinedButton(
                        onPressed: _busy ? null : () => _reverse(receipt),
                        child: const Text('Reverse receipt'),
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
                SizedBox(width: 150, child: Text(key, style: labelStyle)),
                Expanded(child: Text(value)),
              ],
            ),
          ),
      ],
    );
  }
}

typedef _Review = ({DocumentStatus status, String? notes, String? documentTotal});

/// Verifies or rejects one document (rejection needs a reason).
class _ReviewDialog extends StatefulWidget {
  const _ReviewDialog({required this.document, required this.receiptTotal});

  final ReceiptDocument document;
  final String receiptTotal;

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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Review ${widget.document.filename}'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<DocumentStatus>(
                segments: const [
                  ButtonSegment(value: DocumentStatus.verified, label: Text('Verify')),
                  ButtonSegment(value: DocumentStatus.rejected, label: Text('Reject')),
                ],
                selected: {_status},
                onSelectionChanged: (value) => setState(() => _status = value.first),
              ),
              const SizedBox(height: 12),
              if (_status == DocumentStatus.verified) ...[
                TextFormField(
                  controller: _total,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Total on the document (optional)',
                    helperText: 'This receipt\'s total is ${widget.receiptTotal}.',
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
                const SizedBox(height: 12),
              ],
              TextFormField(
                controller: _notes,
                maxLength: 500,
                decoration: InputDecoration(
                  labelText: _status == DocumentStatus.rejected
                      ? 'Why is it rejected?'
                      : 'Notes (optional)',
                  border: const OutlineInputBorder(),
                ),
                validator: (value) =>
                    _status == DocumentStatus.rejected && (value ?? '').trim().length < 3
                    ? 'Say why the document is rejected'
                    : null,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.pop<_Review>(context, (
              status: _status,
              notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
              documentTotal: _status == DocumentStatus.verified && _total.text.trim().isNotEmpty
                  ? _total.text.trim()
                  : null,
            ));
          },
          child: const Text('Save review'),
        ),
      ],
    );
  }
}
