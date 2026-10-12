import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../customers/data/customers_repository.dart';
import '../../customers/presentation/customer_picker.dart';
import '../../products/data/products_repository.dart';
import '../../products/presentation/product_picker.dart';
import '../data/dispatches_repository.dart';
import '../domain/dispatch_models.dart';

/// Creates a draft dispatch, or edits [existing] (which must be a draft). Pops with the saved
/// dispatch. Saving a draft does not touch stock; confirming does.
class DispatchEditorScreen extends StatefulWidget {
  const DispatchEditorScreen({
    super.key,
    required this.dispatches,
    required this.customers,
    required this.products,
    this.existing,
  });

  final DispatchesRepository dispatches;
  final CustomersRepository customers;
  final ProductsRepository products;
  final Dispatch? existing;

  @override
  State<DispatchEditorScreen> createState() => _DispatchEditorScreenState();
}

class _LineEditor {
  _LineEditor(this.productId, this.description, {required String quantity, required String price})
    : quantity = TextEditingController(text: quantity),
      price = TextEditingController(text: price);

  final String productId;
  final String description;
  final TextEditingController quantity;
  final TextEditingController price;

  /// Line total in cents, or null while the quantity or price is not valid yet.
  int? get totalCents {
    final qty = int.tryParse(quantity.text.trim());
    final cents = parseCents(price.text);
    return qty == null || cents == null ? null : qty * cents;
  }

  void dispose() {
    quantity.dispose();
    price.dispose();
  }
}

class _DispatchEditorScreenState extends State<DispatchEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _notes = TextEditingController(text: widget.existing?.notes);
  late String? _customerId = widget.existing?.customerId;
  late String? _customerName = widget.existing == null
      ? null
      : '${widget.existing!.customerName} (${widget.existing!.customerCode})';
  late DateTime _date = widget.existing == null
      ? today()
      : DateTime.parse(widget.existing!.dispatchDate);
  late final List<_LineEditor> _lines = [
    for (final line in widget.existing?.items ?? const <DispatchLine>[])
      _LineEditor(
        line.productId,
        line.description,
        quantity: '${line.quantity}',
        price: line.unitPrice,
      ),
  ];

  bool _saving = false;
  bool _showLineError = false;
  String? _error;
  Map<String, String> _serverErrors = {};

  bool get _isNew => widget.existing == null;

  @override
  void dispose() {
    _notes.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  Future<void> _chooseCustomer() async {
    final customer = await pickCustomer(context, widget.customers);
    if (customer != null) {
      setState(() {
        _customerId = customer.id;
        _customerName = '${customer.name} (${customer.code})';
        _serverErrors = {..._serverErrors}..remove('customerId');
      });
    }
  }

  Future<void> _chooseDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: today().subtract(const Duration(days: 60)),
      lastDate: today().add(const Duration(days: 60)),
      helpText: 'Dispatch date',
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _addProduct() async {
    final product = await pickProduct(context, widget.products);
    if (product == null || !mounted) return;
    if (_lines.any((line) => line.productId == product.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${product.description} is already on this dispatch.')),
      );
      return;
    }
    setState(() {
      _lines.add(
        _LineEditor(product.id, product.description, quantity: '', price: product.defaultPrice),
      );
      _showLineError = false;
    });
  }

  void _removeLine(_LineEditor line) {
    setState(() {
      _lines.remove(line);
      line.dispose();
    });
  }

  Future<void> _save() async {
    setState(() {
      _serverErrors = {};
      _error = null;
      _showLineError = _lines.isEmpty;
    });
    final formValid = _formKey.currentState!.validate();
    if (_saving || !formValid || _lines.isEmpty) return;

    final lines = [
      for (final line in _lines)
        DraftLine(
          productId: line.productId,
          description: line.description,
          quantity: int.parse(line.quantity.text.trim()),
          unitPrice: line.price.text.trim(),
        ),
    ];
    final notes = _notes.text.trim().isEmpty ? null : _notes.text.trim();

    setState(() => _saving = true);
    try {
      final saved = _isNew
          ? await widget.dispatches.createDraft(
              customerId: _customerId!,
              dispatchDate: toApiDate(_date),
              notes: notes,
              lines: lines,
            )
          : await widget.dispatches.updateDraft(
              widget.existing!.id,
              customerId: _customerId!,
              dispatchDate: toApiDate(_date),
              notes: notes,
              lines: lines,
            );
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _serverErrors = error.fieldErrors;
        _error = error.message;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lineTotals = _lines.map((line) => line.totalCents);
    final total = lineTotals.every((cents) => cents != null)
        ? withCurrency(formatCents(lineTotals.fold(0, (sum, cents) => sum + cents!)))
        : '—';

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New dispatch' : 'Edit ${widget.existing!.dispatchNumber}'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null) ...[
                      ErrorBanner(message: _error!),
                      const SizedBox(height: 16),
                    ],
                    FormField<void>(
                      validator: (_) => _customerId == null ? 'Choose a customer' : null,
                      builder: (field) => InkWell(
                        onTap: _saving ? null : _chooseCustomer,
                        child: InputDecorator(
                          isEmpty: _customerName == null,
                          decoration: InputDecoration(
                            labelText: 'Customer',
                            hintText: 'Choose a customer',
                            prefixIcon: const Icon(Icons.storefront_outlined),
                            suffixIcon: const Icon(Icons.arrow_drop_down),
                            border: const OutlineInputBorder(),
                            errorText: field.errorText ?? _serverErrors['customerId'],
                          ),
                          child: _customerName == null ? null : Text(_customerName!),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    InkWell(
                      onTap: _saving ? null : _chooseDate,
                      child: InputDecorator(
                        decoration: InputDecoration(
                          labelText: 'Dispatch date',
                          prefixIcon: const Icon(Icons.event_outlined),
                          border: const OutlineInputBorder(),
                          errorText: _serverErrors['dispatchDate'],
                        ),
                        child: Text(formatApiDate(toApiDate(_date))),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _notes,
                      enabled: !_saving,
                      maxLength: 500,
                      decoration: const InputDecoration(
                        labelText: 'Notes (optional)',
                        hintText: 'e.g. Deliver before noon',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('Products', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final (index, line) in _lines.indexed) _buildLine(index, line),
                    if (_showLineError || _serverErrors.containsKey('items'))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _serverErrors['items'] ?? 'Add at least one product',
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    OutlinedButton.icon(
                      onPressed: _saving ? null : _addProduct,
                      icon: const Icon(Icons.add),
                      label: const Text('Add product'),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Total $total',
                      textAlign: TextAlign.end,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      child: _saving
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Save draft'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Saving a draft does not change stock. Stock is taken out when the '
                      'dispatch is confirmed.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLine(int index, _LineEditor line) {
    final lineTotal = line.totalCents;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(line.description)),
                IconButton(
                  tooltip: 'Remove ${line.description}',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _saving ? null : () => _removeLine(line),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: line.quantity,
                      enabled: !_saving,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: 'Packs',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        errorText: _serverErrors['items.$index.quantity'],
                      ),
                      onChanged: (_) => setState(() {}),
                      validator: (value) {
                        final quantity = int.tryParse((value ?? '').trim());
                        if (quantity == null) return 'Required';
                        if (quantity < 1) return 'At least 1';
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: line.price,
                      enabled: !_saving,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      decoration: InputDecoration(
                        labelText: 'Unit price',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        errorText: _serverErrors['items.$index.unitPrice'],
                      ),
                      onChanged: (_) => setState(() {}),
                      validator: (value) => parseCents(value ?? '') == null ? 'e.g. 0.50' : null,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 8),
              child: Text(
                lineTotal == null ? '' : withCurrency(formatCents(lineTotal)),
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
