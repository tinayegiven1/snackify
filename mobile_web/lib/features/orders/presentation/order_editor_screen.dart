import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../organisations/domain/organisation.dart';
import '../../products/domain/product.dart';
import '../../products/presentation/product_picker.dart';
import '../data/orders_repository.dart';
import '../domain/order_models.dart';
import 'order_services.dart';

/// Creates or changes a draft order: each product with the quantity, the price the subsidiary
/// expects and the most it will pay. Saved as a draft or submitted to the Head Office. Pops
/// with the saved order.
class OrderEditorScreen extends StatefulWidget {
  const OrderEditorScreen({super.key, required this.services, this.order});

  final OrderServices services;

  /// A draft to continue; null for a new order.
  final SubsidiaryOrder? order;

  @override
  State<OrderEditorScreen> createState() => _OrderEditorScreenState();
}

class _OrderEditorScreenState extends State<OrderEditorScreen> {
  late final _notes = TextEditingController(text: widget.order?.notes);
  late SubsidiaryOrder? _saved = widget.order;
  late DateTime? _requiredDate = widget.order?.requiredDate == null
      ? null
      : DateTime.parse(widget.order!.requiredDate!);
  late final List<OrderLineInput> _lines = [
    for (final line in widget.order?.lines ?? const <OrderLine>[]) line.toInput(),
  ];

  /// Kept while the form is open: a retry of the same order never creates a second one.
  final String _idempotencyKey = newIdempotencyKey();

  /// Head Office staff ordering for a subsidiary choose it (subsidiaries order for themselves).
  String? _organisationId;
  List<Organisation>? _subsidiaries;

  bool _saving = false;
  String? _error;

  OrderServices get _services => widget.services;

  @override
  void initState() {
    super.initState();
    if (_services.seesAll && widget.order == null) _loadSubsidiaries();
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _loadSubsidiaries() async {
    try {
      final organisations = await _services.organisations.list();
      if (!mounted) return;
      setState(() => _subsidiaries = organisations.where((o) => !o.isHeadOffice).toList());
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _pickRequiredDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _requiredDate ?? today().add(const Duration(days: 7)),
      firstDate: today(),
      lastDate: today().add(const Duration(days: 366)),
      helpText: 'Needed by',
    );
    if (picked != null) setState(() => _requiredDate = picked);
  }

  Future<void> _editLine([int? index]) async {
    final line = await showDialog<OrderLineInput>(
      context: context,
      builder: (_) =>
          _LineDialog(services: _services, initial: index == null ? null : _lines[index]),
    );
    if (line == null) return;
    setState(() {
      if (index == null) {
        _lines.add(line);
      } else {
        _lines[index] = line;
      }
    });
  }

  int _cents(String Function(OrderLineInput line) price) =>
      _lines.fold(0, (sum, line) => sum + line.requestedQuantity * (parseCents(price(line)) ?? 0));

  Future<bool> _confirmSubmit() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Submit order?'),
          content: const Text(
            'The Head Office will review it and set the actual prices. You can cancel it until '
            'the review starts, but not change it.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Submit'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _save({required bool submit}) async {
    setState(() => _error = null);
    if (_saving) return;
    if (_lines.isEmpty) {
      setState(() => _error = 'Add at least one product.');
      return;
    }
    if (_services.seesAll && _saved == null && _organisationId == null) {
      setState(() => _error = 'Choose the subsidiary that orders.');
      return;
    }
    if (submit && !await _confirmSubmit()) return;

    final input = OrderInput(
      organisationId: _saved == null ? _organisationId : null,
      requiredDate: _requiredDate == null ? null : toApiDate(_requiredDate!),
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      lines: _lines,
    );
    setState(() => _saving = true);
    try {
      final id = _saved?.id;
      var order = id == null
          ? await _services.orders.create(input, _idempotencyKey)
          : await _services.orders.update(id, input);
      _saved = order;
      if (submit) order = await _services.orders.submit(order.id);
      if (mounted) Navigator.of(context).pop(order);
    } on ApiException catch (error) {
      if (!mounted) return;
      final lines = [
        for (final MapEntry(:key, :value) in error.fieldErrors.entries)
          if (RegExp(r'^lines\.(\d+)').firstMatch(key) case final match?)
            'Line ${int.parse(match.group(1)!) + 1}: $value'
          else
            value,
      ];
      setState(() => _error = lines.isEmpty ? error.message : lines.join('\n'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = _saved;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(saved == null ? 'New order' : 'Order ${saved.orderNumber}')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null) ...[
                    ErrorBanner(message: _error!),
                    const SizedBox(height: 16),
                  ],
                  if (_subsidiaries case final subsidiaries? when saved == null) ...[
                    DropdownButtonFormField<String>(
                      initialValue: _organisationId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Ordering subsidiary',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final subsidiary in subsidiaries)
                          DropdownMenuItem(
                            value: subsidiary.id,
                            child: Text('${subsidiary.name} (${subsidiary.code})'),
                          ),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) => setState(() => _organisationId = value),
                    ),
                    const SizedBox(height: 16),
                  ],
                  InkWell(
                    onTap: _saving ? null : _pickRequiredDate,
                    child: InputDecorator(
                      isEmpty: _requiredDate == null,
                      decoration: InputDecoration(
                        labelText: 'Needed by (optional)',
                        prefixIcon: const Icon(Icons.event_outlined),
                        border: const OutlineInputBorder(),
                        suffixIcon: _requiredDate == null
                            ? null
                            : IconButton(
                                tooltip: 'Clear the date',
                                icon: const Icon(Icons.clear),
                                onPressed: () => setState(() => _requiredDate = null),
                              ),
                      ),
                      child: _requiredDate == null
                          ? null
                          : Text(formatApiDate(toApiDate(_requiredDate!))),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text('Products', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'For each product: what you expect to pay, and the most you will accept. '
                    'The Head Office sets the actual price.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  for (final (index, line) in _lines.indexed)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        title: Text(line.productLabel),
                        subtitle: Text(
                          '${line.requestedQuantity} ${line.unitLabel.toLowerCase()} · '
                          'expected ${line.expectedUnitPrice} · at most ${line.maximumUnitPrice} each',
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
                  if (_lines.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Expected total ${withCurrency(formatCents(_cents((l) => l.expectedUnitPrice)))} · '
                      'maximum ${withCurrency(formatCents(_cents((l) => l.maximumUnitPrice)))}',
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      'The server works the totals out again when you save.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextField(
                    controller: _notes,
                    enabled: !_saving,
                    maxLength: 1000,
                    maxLines: 3,
                    minLines: 1,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                      border: OutlineInputBorder(),
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
                            : const Text('Submit order'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final _priceFormat = RegExp(r'^\d{1,10}(\.\d{1,2})?$');

/// Adds or changes one line; pops with it.
class _LineDialog extends StatefulWidget {
  const _LineDialog({required this.services, required this.initial});

  final OrderServices services;
  final OrderLineInput? initial;

  @override
  State<_LineDialog> createState() => _LineDialogState();
}

class _LineDialogState extends State<_LineDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _quantity = TextEditingController(text: widget.initial?.requestedQuantity.toString());
  late final _expected = TextEditingController(text: widget.initial?.expectedUnitPrice);
  late final _maximum = TextEditingController(text: widget.initial?.maximumUnitPrice);
  late String? _unitId = widget.initial?.unitId;
  Product? _product;

  @override
  void initState() {
    super.initState();
    final productId = widget.initial?.productId;
    if (productId != null) {
      widget.services.products.get(productId).then((product) {
        if (mounted) setState(() => _product = product);
      }, onError: (Object _) {});
    }
  }

  @override
  void dispose() {
    for (final controller in [_quantity, _expected, _maximum]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// The product's default price for one [unit] (e.g. a carton of 24 packs), as a suggestion.
  String _suggestedPrice(Product product, ProductUnit unit) {
    final cents = parseCents(product.defaultPrice) ?? 0;
    return formatCents(cents * unit.baseQuantity);
  }

  void _useUnit(Product product, String unitId) {
    final unit = product.units.firstWhere((unit) => unit.id == unitId);
    setState(() {
      _unitId = unitId;
      _expected.text = _suggestedPrice(product, unit);
      _maximum.text = _expected.text;
    });
  }

  Future<void> _chooseProduct() async {
    final product = await pickProduct(context, widget.services.products);
    if (product == null || !mounted) return;
    setState(() => _product = product);
    _useUnit(product, product.baseUnit.id);
  }

  String? _validatePrice(String? value) =>
      _priceFormat.hasMatch((value ?? '').trim()) ? null : 'Use an amount like 0.50';

  void _done() {
    if (!_formKey.currentState!.validate()) return;
    final product = _product!;
    final unit = product.units.firstWhere((unit) => unit.id == _unitId);
    Navigator.of(context).pop(
      OrderLineInput(
        productId: product.id,
        productLabel: '${product.description} (${product.sku})',
        unitId: unit.id,
        unitLabel: unit.name,
        requestedQuantity: int.parse(_quantity.text.trim()),
        expectedUnitPrice: _expected.text.trim(),
        maximumUnitPrice: _maximum.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final product = _product;
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add product' : 'Change line'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InkWell(
                  onTap: _chooseProduct,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Product',
                      prefixIcon: Icon(Icons.inventory_2_outlined),
                      suffixIcon: Icon(Icons.arrow_drop_down),
                      border: OutlineInputBorder(),
                    ),
                    child: Text(product?.description ?? widget.initial?.productLabel ?? ''),
                  ),
                ),
                const SizedBox(height: 12),
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
                    onChanged: (value) {
                      if (value != null) _useUnit(product, value);
                    },
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
                    if (quantity == null || quantity < 1) return 'At least 1';
                    if (quantity > 1000000) return 'At most 1,000,000';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _expected,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Expected price each',
                    border: OutlineInputBorder(),
                  ),
                  validator: _validatePrice,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _maximum,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Maximum price each',
                    helperText: 'The most you accept. A higher price needs special approval.',
                    helperMaxLines: 2,
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final problem = _validatePrice(value);
                    if (problem != null) return problem;
                    final maximum = parseCents((value ?? '').trim());
                    final expected = parseCents(_expected.text.trim());
                    if (maximum != null && expected != null && maximum < expected) {
                      return 'At least the expected price';
                    }
                    return null;
                  },
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
