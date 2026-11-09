import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/files/document_picker.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../catalogue/domain/catalogue_models.dart';
import '../../organisations/domain/organisation.dart';
import '../../products/domain/product.dart';
import '../../products/presentation/product_picker.dart';
import '../../products/presentation/scan_product.dart';
import '../../receipts/domain/receipt_models.dart' show ReceiptDocument;
import '../../receipts/presentation/document_preview.dart';
import '../domain/purchase_models.dart';
import 'purchase_services.dart';

/// Records goods bought from a supplier: whose stock it is for, the supplier, the date and
/// each product with its quantity and cost, and the supplier's documents (uploaded once the
/// list is saved). Pops with the saved list.
class PurchaseEditorScreen extends StatefulWidget {
  const PurchaseEditorScreen({super.key, required this.services, this.purchase});

  final PurchaseServices services;

  /// A list to change (only while nothing was received against it); null for a new one.
  final Purchase? purchase;

  @override
  State<PurchaseEditorScreen> createState() => _PurchaseEditorScreenState();
}

class _PurchaseEditorScreenState extends State<PurchaseEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _invoiceNumber = TextEditingController(text: widget.purchase?.supplierInvoiceNumber);
  late final _notes = TextEditingController(text: widget.purchase?.notes);

  late String? _ownerId =
      widget.purchase?.owner.id ?? widget.services.receiptServices.user.organisation.id;
  late String? _supplierId = widget.purchase?.supplier?.id;
  late DateTime _purchaseDate = widget.purchase == null
      ? today()
      : DateTime.parse(widget.purchase!.purchaseDate);

  /// The list as last saved: after a failed upload, saving again changes it instead of
  /// recording another.
  late Purchase? _saved = widget.purchase;

  /// Documents chosen here, uploaded when the list is saved.
  final List<PickedDocument> _newDocuments = [];

  /// Pictures of documents saved earlier, downloaded for their thumbnails.
  late final _pictures = DocumentPictureCache(
    (documentId) => _services.purchases.document(_saved!.id, documentId),
  );

  late final List<PurchaseLineInput> _lines = [
    for (final line in widget.purchase?.lines ?? const <PurchaseLine>[]) line.toInput(),
  ];

  List<Organisation>? _organisations;
  List<CatalogueItem>? _suppliers;
  String? _loadError;

  bool _saving = false;
  String? _error;
  Map<String, String> _serverErrors = {};

  PurchaseServices get _services => widget.services;

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
        _services.receiptServices.catalogue.list(CatalogueKind.suppliers),
        if (_services.canChooseOwner) _services.receiptServices.organisations.list(),
      ]);
      if (!mounted) return;
      setState(() {
        final suppliers = results[0] as List<CatalogueItem>;
        // An inactive supplier already on the list stays choosable.
        _suppliers = [
          for (final supplier in suppliers)
            if (supplier.isActive || supplier.id == _supplierId) supplier,
        ];
        if (_supplierId != null && !_suppliers!.any((s) => s.id == _supplierId)) {
          final current = widget.purchase!.supplier!;
          _suppliers!.add(
            CatalogueItem(
              id: current.id,
              values: {'code': current.code, 'name': current.name},
              isActive: false,
            ),
          );
        }
        if (_services.canChooseOwner) _organisations = results[1] as List<Organisation>;
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _purchaseDate,
      firstDate: DateTime(2000),
      lastDate: today(),
      helpText: 'Date of purchase',
    );
    if (picked != null) setState(() => _purchaseDate = picked);
  }

  Future<void> _editLine([int? index]) async {
    final line = await showDialog<PurchaseLineInput>(
      context: context,
      builder: (_) =>
          _PurchaseLineDialog(services: _services, initial: index == null ? null : _lines[index]),
    );
    if (line == null) return;
    setState(() {
      if (index == null) {
        _lines.add(line);
      } else {
        _lines[index] = line;
      }
      _serverErrors = {};
    });
  }

  Future<void> _addDocuments() async {
    final picked = await _services.receiptServices.pickDocuments();
    if (picked.isNotEmpty && mounted) setState(() => _newDocuments.addAll(picked));
  }

  Future<void> _takePhoto() async {
    final photo = await _services.receiptServices.takePhoto();
    if (photo != null && mounted) setState(() => _newDocuments.add(photo));
  }

  Future<void> _previewSaved(ReceiptDocument document) async {
    try {
      final bytes =
          _pictures.bytesOf(document.id) ??
          await _services.purchases.document(_saved!.id, document.id);
      if (mounted) await showDocumentPreview(context, document.filename, bytes);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Widget _savedThumbnail(ReceiptDocument document) {
    if (!document.isPdf) _pictures.ensure(document.id, () => mounted ? setState(() {}) : null);
    return DocumentThumbnail(
      isPdf: document.isPdf,
      bytes: _pictures.bytesOf(document.id),
      loading: _pictures.isLoading(document.id),
    );
  }

  PurchaseInput _input() => PurchaseInput(
    organisationId: _services.canChooseOwner ? _ownerId : null,
    supplierId: _supplierId,
    supplierInvoiceNumber: _invoiceNumber.text.trim().isEmpty ? null : _invoiceNumber.text.trim(),
    purchaseDate: toApiDate(_purchaseDate),
    notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    lines: _lines,
  );

  Future<void> _save() async {
    setState(() {
      _serverErrors = {};
      _error = null;
    });
    if (_saving || !_formKey.currentState!.validate()) return;
    if (_lines.isEmpty) {
      setState(() => _error = 'Add at least one product.');
      return;
    }
    setState(() => _saving = true);
    try {
      final existing = _saved;
      var saved = existing == null
          ? await _services.purchases.create(_input())
          : await _services.purchases.update(existing.id, _input());
      _saved = saved;
      while (_newDocuments.isNotEmpty) {
        final document = _newDocuments.first;
        saved = await _services.purchases.addDocument(saved.id, document.name, document.bytes);
        _saved = saved;
        if (mounted) setState(() => _newDocuments.removeAt(0));
      }
      if (mounted) Navigator.of(context).pop(saved);
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

  /// Problems with lines, e.g. "Line 2: Must be at least 1".
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
    final purchase = widget.purchase;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          purchase == null ? 'Record goods bought' : 'Goods bought ${purchase.purchaseNumber}',
        ),
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loadError != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load the suppliers',
        message: _loadError!,
        action: RetryButton(onPressed: _loadChoices),
      );
    }
    final suppliers = _suppliers;
    if (suppliers == null) return const Center(child: CircularProgressIndicator());
    final organisations = _organisations;
    final theme = Theme.of(context);
    final totalCents = _lines.fold<int>(0, (sum, line) => sum + line.totalCents);
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
                      helperText: 'Goods bought for a subsidiary are received into its stock.',
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
                DropdownButtonFormField<String?>(
                  initialValue: _supplierId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Supplier (optional)',
                    border: const OutlineInputBorder(),
                    errorText: _serverErrors['supplierId'],
                  ),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('No supplier')),
                    for (final supplier in suppliers)
                      DropdownMenuItem<String?>(value: supplier.id, child: Text(supplier.label)),
                  ],
                  onChanged: _saving ? null : (value) => setState(() => _supplierId = value),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _invoiceNumber,
                  enabled: !_saving,
                  maxLength: 60,
                  decoration: InputDecoration(
                    labelText: 'Supplier invoice number (optional)',
                    border: const OutlineInputBorder(),
                    counterText: '',
                    errorText: _serverErrors['supplierInvoiceNumber'],
                  ),
                ),
                const SizedBox(height: 16),
                InkWell(
                  onTap: _saving ? null : _pickDate,
                  borderRadius: BorderRadius.circular(4),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Date purchased',
                      prefixIcon: const Icon(Icons.event_outlined),
                      border: const OutlineInputBorder(),
                      errorText: _serverErrors['purchaseDate'],
                      enabled: !_saving,
                    ),
                    child: Text(formatApiDate(toApiDate(_purchaseDate))),
                  ),
                ),
                const SizedBox(height: 24),
                Text('Products', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final (index, line) in _lines.indexed)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      title: Text(line.productLabel),
                      subtitle: Text(
                        [
                          '${line.quantity} ${line.unitLabel.toLowerCase()} × ${line.unitCost}',
                          '= ${formatCents(line.totalCents)}',
                          ?line.notes,
                        ].join(' · '),
                      ),
                      onTap: _saving ? null : () => _editLine(index),
                      trailing: IconButton(
                        tooltip: 'Remove ${line.productLabel}',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _saving ? null : () => setState(() => _lines.removeAt(index)),
                      ),
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: _saving ? null : () => _editLine(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add product'),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    'Total ${withCurrency(formatCents(totalCents))}',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 24),
                Text('Supplier documents', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'The supplier invoice or delivery note: PDF or a photo (JPEG, PNG). '
                  'Finance or an administrator checks each one.',
                  style: theme.textTheme.bodySmall,
                ),
                for (final document in previousDocuments)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: _savedThumbnail(document),
                    title: Text(document.filename),
                    subtitle: Text('${document.sizeLabel} · ${document.status.label}'),
                    onTap: document.isPdf ? null : () => _previewSaved(document),
                  ),
                for (final (index, document) in _newDocuments.indexed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: DocumentThumbnail(
                      isPdf: !isPicture(document.bytes),
                      bytes: document.bytes,
                    ),
                    title: Text(document.name),
                    subtitle: const Text('Uploaded when you save'),
                    onTap: isPicture(document.bytes)
                        ? () => showDocumentPreview(context, document.name, document.bytes)
                        : null,
                    trailing: IconButton(
                      tooltip: 'Remove ${document.name}',
                      icon: const Icon(Icons.close),
                      onPressed: _saving
                          ? null
                          : () => setState(() => _newDocuments.removeAt(index)),
                    ),
                  ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: _saving ? null : _addDocuments,
                      icon: const Icon(Icons.attach_file),
                      label: const Text('Attach document'),
                    ),
                    TextButton.icon(
                      onPressed: _saving ? null : _takePhoto,
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Take photo'),
                    ),
                  ],
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
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Save'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Adds or changes one product line; pops with the line.
class _PurchaseLineDialog extends StatefulWidget {
  const _PurchaseLineDialog({required this.services, required this.initial});

  final PurchaseServices services;
  final PurchaseLineInput? initial;

  @override
  State<_PurchaseLineDialog> createState() => _PurchaseLineDialogState();
}

class _PurchaseLineDialogState extends State<_PurchaseLineDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _quantity = TextEditingController(text: widget.initial?.quantity.toString());
  late final _unitCost = TextEditingController(text: widget.initial?.unitCost);
  late final _note = TextEditingController(text: widget.initial?.notes);
  late String? _unitId = widget.initial?.unitId;
  Product? _product;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    final productId = widget.initial?.productId;
    if (productId != null) _loadProduct(productId);
  }

  @override
  void dispose() {
    for (final controller in [_quantity, _unitCost, _note]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadProduct(String id) async {
    try {
      final product = await widget.services.receiptServices.products.get(id);
      if (mounted) setState(() => _product = product);
    } on ApiException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    }
  }

  Future<void> _chooseProduct() async {
    final product = await pickProduct(context, widget.services.receiptServices.products);
    if (product == null || !mounted) return;
    setState(() {
      _product = product;
      _unitId = product.baseUnit.id;
    });
  }

  Future<void> _scanProduct() async {
    final product = await scanForProduct(
      context,
      products: widget.services.receiptServices.products,
      readBarcode: widget.services.receiptServices.readBarcode,
    );
    if (product == null || !mounted) return;
    if (!product.isActive) {
      setState(() => _loadError = '${product.description} is inactive; it cannot be bought.');
      return;
    }
    setState(() {
      _product = product;
      _unitId = product.baseUnit.id;
      _loadError = null;
    });
  }

  void _done() {
    if (!_formKey.currentState!.validate()) return;
    final product = _product!;
    final unit = product.units.firstWhere((unit) => unit.id == _unitId);
    Navigator.of(context).pop(
      PurchaseLineInput(
        productId: product.id,
        productLabel: '${product.description} (${product.sku})',
        unitId: unit.id,
        unitLabel: unit.name,
        quantity: int.parse(_quantity.text.trim()),
        unitCost: _unitCost.text.trim(),
        notes: _note.text.trim().isEmpty ? null : _note.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final product = _product;
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
                      child: Text(product?.description ?? widget.initial?.productLabel ?? ''),
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
                    decoration: const InputDecoration(
                      labelText: 'Unit',
                      border: OutlineInputBorder(),
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
                TextFormField(
                  controller: _quantity,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Quantity',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final quantity = int.tryParse((value ?? '').trim());
                    if (quantity == null) return 'Required';
                    if (quantity < 1) return 'Must be at least 1';
                    if (quantity > 1000000) return 'Must be at most 1,000,000';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _unitCost,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Cost per unit',
                    hintText: 'e.g. 0.4250',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) =>
                      RegExp(r'^\d{1,10}(\.\d{1,4})?$').hasMatch((value ?? '').trim())
                      ? null
                      : 'Use an amount with up to 4 decimal places',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _note,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    labelText: 'Note (optional)',
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
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
