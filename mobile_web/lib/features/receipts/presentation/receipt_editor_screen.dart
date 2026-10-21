import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/files/document_picker.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../catalogue/domain/catalogue_models.dart';
import '../../organisations/domain/organisation.dart';
import '../../products/domain/product.dart';
import '../../products/presentation/product_picker.dart';
import '../../products/presentation/scan_product.dart';
import '../domain/receipt_models.dart';
import 'receipt_services.dart';

/// Records a delivery as a goods-received note: whose stock it is, the supplier, each product
/// with what was bought and what arrived, and the supplier's documents. Saved as a draft or
/// submitted for verification. Pops with the saved receipt.
class ReceiptEditorScreen extends StatefulWidget {
  const ReceiptEditorScreen({super.key, required this.services, this.receipt});

  final ReceiptServices services;

  /// A draft to continue; null for a new receipt.
  final GoodsReceipt? receipt;

  @override
  State<ReceiptEditorScreen> createState() => _ReceiptEditorScreenState();
}

/// A line on the form, with how its unit is shown.
class _LineEntry {
  const _LineEntry(this.input, this.unitLabel);

  final ReceiptLineInput input;
  final String unitLabel;
}

class _ReceiptEditorScreenState extends State<ReceiptEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _invoiceNumber = TextEditingController(text: widget.receipt?.supplierInvoiceNumber);
  late final _notes = TextEditingController(text: widget.receipt?.notes);

  late GoodsReceipt? _saved = widget.receipt;
  late String? _ownerId = widget.receipt?.owner.id ?? widget.services.user.organisation.id;
  late String? _warehouseId = widget.receipt?.warehouse.id;
  late String? _supplierId = widget.receipt?.supplier?.id;
  late DateTime _receivedDate = widget.receipt == null
      ? today()
      : DateTime.parse(widget.receipt!.receivedDate);
  late DateTime? _purchaseDate = widget.receipt?.purchaseDate == null
      ? null
      : DateTime.parse(widget.receipt!.purchaseDate!);
  late final List<_LineEntry> _lines = [
    for (final line in widget.receipt?.lines ?? const <ReceiptLine>[])
      _LineEntry(line.toInput(), line.unit.name),
  ];
  final List<PickedDocument> _newDocuments = [];

  List<Organisation>? _organisations;
  List<CatalogueItem>? _warehouses;
  List<CatalogueItem>? _suppliers;
  String? _loadError;

  bool _saving = false;
  String? _error;
  Map<String, String> _serverErrors = {};

  ReceiptServices get _services => widget.services;

  @override
  void initState() {
    super.initState();
    _loadChoices();
  }

  @override
  void dispose() {
    _invoiceNumber.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _loadChoices() async {
    setState(() => _loadError = null);
    try {
      final results = await Future.wait([
        _services.catalogue.list(CatalogueKind.warehouses),
        _services.catalogue.list(CatalogueKind.suppliers),
        if (_services.canChooseOwner) _services.organisations.list(),
      ]);
      if (!mounted) return;
      setState(() {
        _warehouses = results[0] as List<CatalogueItem>;
        _suppliers = results[1] as List<CatalogueItem>;
        if (_services.canChooseOwner) _organisations = results[2] as List<Organisation>;
        _warehouseId ??= _warehouses!.where((w) => w.isDefault).firstOrNull?.id;
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    }
  }

  Future<void> _pickDate({required bool purchase}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: purchase ? (_purchaseDate ?? _receivedDate) : _receivedDate,
      firstDate: today().subtract(const Duration(days: 366)),
      lastDate: purchase ? _receivedDate : today(),
      helpText: purchase ? 'Date of purchase' : 'Date the goods arrived',
    );
    if (picked == null) return;
    setState(() {
      if (purchase) {
        _purchaseDate = picked;
      } else {
        _receivedDate = picked;
        if (_purchaseDate != null && _purchaseDate!.isAfter(picked)) _purchaseDate = null;
      }
    });
  }

  Future<void> _editLine([int? index]) async {
    final entry = await showDialog<_LineEntry>(
      context: context,
      builder: (_) => _LineDialog(
        services: _services,
        initial: index == null ? null : _lines[index],
        receivedDate: _receivedDate,
      ),
    );
    if (entry == null) return;
    setState(() {
      if (index == null) {
        _lines.add(entry);
      } else {
        _lines[index] = entry;
      }
      _serverErrors = {};
    });
  }

  Future<void> _addDocuments() async {
    final picked = await _services.pickDocuments();
    if (picked.isNotEmpty && mounted) setState(() => _newDocuments.addAll(picked));
  }

  /// Asks an authorised user why there is no supplier document; null when they cancel.
  Future<String?> _askNoDocumentReason() {
    final reason = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Submit without a document?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Receipts normally need the supplier invoice or delivery note. '
              'Say why there is none; this is recorded in the audit log.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reason,
              autofocus: true,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Reason', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (reason.text.trim().length >= 3) Navigator.pop(context, reason.text.trim());
            },
            child: const Text('Submit'),
          ),
        ],
      ),
    );
  }

  ReceiptInput _input() => ReceiptInput(
    organisationId: _services.canChooseOwner ? _ownerId : null,
    warehouseId: _warehouseId,
    supplierId: _supplierId,
    supplierInvoiceNumber: _invoiceNumber.text.trim().isEmpty ? null : _invoiceNumber.text.trim(),
    purchaseDate: _purchaseDate == null ? null : toApiDate(_purchaseDate!),
    receivedDate: toApiDate(_receivedDate),
    notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    lines: [for (final line in _lines) line.input],
  );

  Future<void> _save({required bool submit}) async {
    setState(() {
      _serverErrors = {};
      _error = null;
    });
    if (_saving || !_formKey.currentState!.validate()) return;
    if (_lines.isEmpty) {
      setState(() => _error = 'Add at least one product.');
      return;
    }
    final keptDocuments = (_saved?.documents ?? const <ReceiptDocument>[])
        .where((document) => document.status != DocumentStatus.rejected)
        .length;
    String? noDocumentReason;
    if (submit && keptDocuments + _newDocuments.length == 0) {
      if (!_services.canSkipDocument) {
        setState(() => _error = 'Attach the supplier invoice or delivery note before submitting.');
        return;
      }
      noDocumentReason = await _askNoDocumentReason();
      if (noDocumentReason == null) return;
    }

    setState(() => _saving = true);
    try {
      final id = _saved?.id;
      var receipt = id == null
          ? await _services.receipts.create(_input())
          : await _services.receipts.update(id, _input());
      // Saved: a retry after a later failure changes this draft instead of adding another.
      _saved = receipt;
      while (_newDocuments.isNotEmpty) {
        final document = _newDocuments.first;
        receipt = await _services.receipts.addDocument(receipt.id, document.name, document.bytes);
        _saved = receipt;
        setState(() => _newDocuments.removeAt(0));
      }
      if (submit) {
        receipt = await _services.receipts.submit(receipt.id, noDocumentReason: noDocumentReason);
      }
      if (mounted) Navigator.of(context).pop(receipt);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _serverErrors = error.fieldErrors;
        _error = error.fieldErrors.isEmpty
            ? error.message
            : _lineErrors(error.fieldErrors) ?? 'Check the highlighted fields.';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Problems with lines, e.g. "Line 2: This product has no conversion for that unit".
  String? _lineErrors(Map<String, String> errors) {
    final lines = [
      for (final MapEntry(:key, :value) in errors.entries)
        if (RegExp(r'^lines\.(\d+)').firstMatch(key) case final match?)
          'Line ${int.parse(match.group(1)!) + 1}: $value',
    ];
    return lines.isEmpty ? null : lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final saved = _saved;
    return Scaffold(
      appBar: AppBar(
        title: Text(saved == null ? 'Receive stock' : 'Goods received ${saved.grnNumber}'),
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loadError != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load suppliers and warehouses',
        message: _loadError!,
        action: RetryButton(onPressed: _loadChoices),
      );
    }
    final warehouses = _warehouses;
    final suppliers = _suppliers;
    if (warehouses == null || suppliers == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final organisations = _organisations;
    final previousDocuments = _saved?.documents ?? const <ReceiptDocument>[];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null) ...[ErrorBanner(message: _error!), const SizedBox(height: 16)],
                if (organisations != null) ...[
                  DropdownButtonFormField<String>(
                    initialValue: _ownerId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Whose stock is this?',
                      helperText:
                          'Stock for a subsidiary is added to its balance, not the '
                          'Head Office\'s.',
                      helperMaxLines: 2,
                      border: const OutlineInputBorder(),
                      errorText: _serverErrors['organisationId'],
                    ),
                    items: [
                      for (final organisation in organisations)
                        DropdownMenuItem(
                          value: organisation.id,
                          child: Text('${organisation.name} (${organisation.code})'),
                        ),
                    ],
                    onChanged: _saving ? null : (value) => setState(() => _ownerId = value),
                  ),
                  const SizedBox(height: 16),
                ],
                DropdownButtonFormField<String>(
                  initialValue: _supplierId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Supplier',
                    helperText: suppliers.isEmpty ? 'Add suppliers under Catalogue first.' : null,
                    border: const OutlineInputBorder(),
                    errorText: _serverErrors['supplierId'],
                  ),
                  items: [
                    for (final supplier in suppliers)
                      DropdownMenuItem(value: supplier.id, child: Text(supplier.label)),
                  ],
                  onChanged: _saving ? null : (value) => setState(() => _supplierId = value),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _invoiceNumber,
                  enabled: !_saving,
                  maxLength: 60,
                  decoration: InputDecoration(
                    labelText: 'Supplier invoice or receipt number (optional)',
                    border: const OutlineInputBorder(),
                    counterText: '',
                    errorText: _serverErrors['supplierInvoiceNumber'],
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    SizedBox(
                      width: 300,
                      child: _DateField(
                        label: 'Date received',
                        value: _receivedDate,
                        errorText: _serverErrors['receivedDate'],
                        onTap: _saving ? null : () => _pickDate(purchase: false),
                      ),
                    ),
                    SizedBox(
                      width: 300,
                      child: _DateField(
                        label: 'Date purchased (optional)',
                        value: _purchaseDate,
                        errorText: _serverErrors['purchaseDate'],
                        onTap: _saving ? null : () => _pickDate(purchase: true),
                        onClear: _purchaseDate == null || _saving
                            ? null
                            : () => setState(() => _purchaseDate = null),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _warehouseId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Warehouse',
                    border: const OutlineInputBorder(),
                    errorText: _serverErrors['warehouseId'],
                  ),
                  items: [
                    for (final warehouse in warehouses)
                      DropdownMenuItem(value: warehouse.id, child: Text(warehouse.label)),
                  ],
                  onChanged: _saving ? null : (value) => setState(() => _warehouseId = value),
                ),
                const SizedBox(height: 24),
                Text('Products', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final (index, line) in _lines.indexed)
                  _LineCard(
                    entry: line,
                    onEdit: _saving ? null : () => _editLine(index),
                    onRemove: _saving ? null : () => setState(() => _lines.removeAt(index)),
                  ),
                OutlinedButton.icon(
                  onPressed: _saving ? null : () => _editLine(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add product'),
                ),
                const SizedBox(height: 24),
                Text('Supplier documents', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'The invoice or delivery note: PDF or a photo (JPEG, PNG). '
                  'One document can cover every line.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                for (final document in previousDocuments)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      document.isPdf ? Icons.picture_as_pdf_outlined : Icons.image_outlined,
                    ),
                    title: Text(document.filename),
                    subtitle: Text('${document.sizeLabel} · ${document.status.label}'),
                  ),
                for (final (index, document) in _newDocuments.indexed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.upload_file_outlined),
                    title: Text(document.name),
                    subtitle: const Text('Uploaded when you save'),
                    trailing: IconButton(
                      tooltip: 'Remove ${document.name}',
                      icon: const Icon(Icons.close),
                      onPressed: _saving
                          ? null
                          : () => setState(() => _newDocuments.removeAt(index)),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _saving ? null : _addDocuments,
                    icon: const Icon(Icons.attach_file),
                    label: const Text('Attach document'),
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _notes,
                  enabled: !_saving,
                  maxLength: 1000,
                  maxLines: 3,
                  minLines: 1,
                  decoration: InputDecoration(
                    labelText: 'Notes (optional)',
                    border: const OutlineInputBorder(),
                    errorText: _serverErrors['notes'],
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    OutlinedButton(
                      onPressed: _saving ? null : () => _save(submit: false),
                      child: const Text('Save draft'),
                    ),
                    FilledButton(
                      onPressed: _saving ? null : () => _save(submit: true),
                      child: _saving
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Submit for verification'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({required this.entry, required this.onEdit, required this.onRemove});

  final _LineEntry entry;
  final VoidCallback? onEdit;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final line = entry.input;
    final unit = entry.unitLabel.toLowerCase();
    final differs = line.quantityPurchased != line.quantityReceived;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(line.productLabel),
        subtitle: Text(
          [
            'Received ${line.quantityReceived} $unit'
                '${differs ? ' of ${line.quantityPurchased} bought' : ''}',
            'Cost ${line.unitCost} each',
            if (line.batchNumber != null) 'Batch ${line.batchNumber}',
            if (line.expiryDate != null) 'Expires ${formatApiDate(line.expiryDate!)}',
            if (differs) discrepancyReasons[line.discrepancyReason] ?? '',
          ].join(' · '),
        ),
        onTap: onEdit,
        trailing: IconButton(
          tooltip: 'Remove ${line.productLabel}',
          icon: const Icon(Icons.delete_outline),
          onPressed: onRemove,
        ),
      ),
    );
  }
}

/// Adds or changes one product line; pops with the line.
class _LineDialog extends StatefulWidget {
  const _LineDialog({required this.services, required this.initial, required this.receivedDate});

  final ReceiptServices services;
  final _LineEntry? initial;
  final DateTime receivedDate;

  @override
  State<_LineDialog> createState() => _LineDialogState();
}

class _LineDialogState extends State<_LineDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _purchased = TextEditingController(
    text: widget.initial?.input.quantityPurchased.toString(),
  );
  late final _received = TextEditingController(
    text: widget.initial?.input.quantityReceived.toString(),
  );
  late final _unitCost = TextEditingController(text: widget.initial?.input.unitCost);
  late final _batch = TextEditingController(text: widget.initial?.input.batchNumber);
  late String? _expiry = widget.initial?.input.expiryDate;
  late String? _reason = widget.initial?.input.discrepancyReason;
  late String? _unitId = widget.initial?.input.unitId;
  Product? _product;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    final productId = widget.initial?.input.productId;
    if (productId != null) _loadProduct(productId);
  }

  @override
  void dispose() {
    for (final controller in [_purchased, _received, _unitCost, _batch]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadProduct(String id) async {
    try {
      final product = await widget.services.products.get(id);
      if (mounted) setState(() => _product = product);
    } on ApiException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    }
  }

  Future<void> _chooseProduct() async {
    final product = await pickProduct(context, widget.services.products);
    if (product == null || !mounted) return;
    setState(() {
      _product = product;
      _unitId = product.baseUnit.id;
    });
  }

  Future<void> _scanProduct() async {
    final product = await scanForProduct(
      context,
      products: widget.services.products,
      readBarcode: widget.services.readBarcode,
    );
    if (product == null || !mounted) return;
    if (!product.isActive) {
      setState(() => _loadError = '${product.description} is inactive; it cannot be received.');
      return;
    }
    setState(() {
      _product = product;
      _unitId = product.baseUnit.id;
      _loadError = null;
    });
  }

  Future<void> _chooseExpiry() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiry == null
          ? widget.receivedDate.add(const Duration(days: 90))
          : DateTime.parse(_expiry!),
      firstDate: widget.receivedDate,
      lastDate: widget.receivedDate.add(const Duration(days: 3650)),
      helpText: 'Expiry date',
    );
    if (picked != null) setState(() => _expiry = toApiDate(picked));
  }

  int? _quantity(TextEditingController controller) => int.tryParse(controller.text.trim());

  String? _validateQuantity(String? value) {
    final quantity = int.tryParse((value ?? '').trim());
    if (quantity == null) return 'Required';
    if (quantity > 1000000) return 'Must be at most 1,000,000';
    return null;
  }

  void _done() {
    if (!_formKey.currentState!.validate()) return;
    final product = _product!;
    final unit = product.units.firstWhere((unit) => unit.id == _unitId);
    final purchased = _quantity(_purchased)!;
    final received = _quantity(_received)!;
    Navigator.of(context).pop(
      _LineEntry(
        ReceiptLineInput(
          productId: product.id,
          productLabel: '${product.description} (${product.sku})',
          unitId: unit.id,
          quantityPurchased: purchased,
          quantityReceived: received,
          unitCost: _unitCost.text.trim(),
          batchNumber: _batch.text.trim().isEmpty ? null : _batch.text.trim(),
          expiryDate: _expiry,
          discrepancyReason: purchased == received ? null : _reason,
        ),
        unit.name,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final product = _product;
    final differs =
        _quantity(_purchased) != null &&
        _quantity(_received) != null &&
        _quantity(_purchased) != _quantity(_received);
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add product' : 'Change line'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_loadError != null) ...[
                  ErrorBanner(message: _loadError!),
                  const SizedBox(height: 12),
                ],
                FormField<void>(
                  validator: (_) => _product == null ? 'Choose a product' : null,
                  builder: (field) => InkWell(
                    onTap: _chooseProduct,
                    child: InputDecorator(
                      isEmpty: product == null && widget.initial == null,
                      decoration: InputDecoration(
                        labelText: 'Product',
                        prefixIcon: const Icon(Icons.inventory_2_outlined),
                        suffixIcon: const Icon(Icons.arrow_drop_down),
                        border: const OutlineInputBorder(),
                        errorText: field.errorText,
                      ),
                      child: Text(product?.description ?? widget.initial?.input.productLabel ?? ''),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _scanProduct,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan barcode'),
                  ),
                ),
                if (product != null) ...[
                  DropdownButtonFormField<String>(
                    key: ValueKey(product.id),
                    initialValue: _unitId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Unit',
                      helperText: product.conversions.isEmpty
                          ? 'An administrator can add cartons or cases on the product.'
                          : null,
                      helperMaxLines: 2,
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      for (final unit in product.units)
                        DropdownMenuItem(
                          value: unit.id,
                          child: Text(unit.labelFor(product.baseUnit)),
                        ),
                    ],
                    validator: (value) => value == null ? 'Choose a unit' : null,
                    onChanged: (value) => setState(() => _unitId = value),
                  ),
                  const SizedBox(height: 12),
                ],
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _purchased,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: const InputDecoration(
                          labelText: 'Bought',
                          border: OutlineInputBorder(),
                        ),
                        validator: _validateQuantity,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _received,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: const InputDecoration(
                          labelText: 'Received',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          final problem = _validateQuantity(value);
                          if (problem != null) return problem;
                          if (_quantity(_received) == 0 && _quantity(_purchased) == 0) {
                            return 'Enter what was bought or received';
                          }
                          return null;
                        },
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                if (differs) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _reason,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Why the quantities differ',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final MapEntry(:key, :value) in discrepancyReasons.entries)
                        DropdownMenuItem(value: key, child: Text(value)),
                    ],
                    validator: (value) => value == null ? 'Choose a reason' : null,
                    onChanged: (value) => setState(() => _reason = value),
                  ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: _unitCost,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Cost per unit',
                    hintText: 'e.g. 10.20',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) =>
                      RegExp(r'^\d{1,10}(\.\d{1,4})?$').hasMatch((value ?? '').trim())
                      ? null
                      : 'Use an amount with up to 4 decimal places',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _batch,
                  maxLength: 60,
                  decoration: const InputDecoration(
                    labelText: 'Batch (optional)',
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 12),
                _DateField(
                  label: 'Expiry date (optional)',
                  value: _expiry == null ? null : DateTime.parse(_expiry!),
                  onTap: _chooseExpiry,
                  onClear: _expiry == null ? null : () => setState(() => _expiry = null),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: product == null ? null : _done, child: const Text('Done')),
      ],
    );
  }
}

/// A date shown in a field; tapping opens a date picker.
class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
    this.onClear,
    this.errorText,
  });

  final String label;
  final DateTime? value;
  final VoidCallback? onTap;
  final VoidCallback? onClear;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        isEmpty: value == null,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.event_outlined),
          border: const OutlineInputBorder(),
          errorText: errorText,
          enabled: onTap != null,
          suffixIcon: onClear == null
              ? null
              : IconButton(
                  tooltip: 'Clear $label',
                  icon: const Icon(Icons.clear),
                  onPressed: onClear,
                ),
        ),
        child: value == null ? null : Text(formatApiDate(toApiDate(value!))),
      ),
    );
  }
}
