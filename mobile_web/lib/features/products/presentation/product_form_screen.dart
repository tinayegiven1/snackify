import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/scanning/barcode_reader.dart';
import '../../catalogue/data/catalogue_repository.dart';
import '../../catalogue/domain/catalogue_models.dart';
import '../data/products_repository.dart';
import '../domain/product.dart';
import '../../../shared/widgets/message_view.dart';

// The same rules the server applies, so most mistakes are caught before sending.
final _skuFormat = RegExp(r'^[A-Z0-9][A-Z0-9._-]{0,39}$');
final _barcodeFormat = RegExp(r'^[A-Za-z0-9-]{4,48}$');
final _priceFormat = RegExp(r'^\d{1,10}(\.\d{1,2})?$');

/// Adds a product, or edits [product] when it is given. Pops with the saved product.
class ProductFormScreen extends StatefulWidget {
  const ProductFormScreen({
    super.key,
    required this.repository,
    required this.readBarcode,
    required this.catalogue,
    this.product,
  });

  final ProductsRepository repository;
  final BarcodeReader readBarcode;

  /// Categories and units to choose from.
  final CatalogueRepository catalogue;
  final Product? product;

  @override
  State<ProductFormScreen> createState() => _ProductFormScreenState();
}

class _ProductFormScreenState extends State<ProductFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.product?.name);
  late final _flavour = TextEditingController(text: widget.product?.flavour);
  late final _size = TextEditingController(text: widget.product?.size);
  late final _sku = TextEditingController(text: widget.product?.sku);
  late final _barcode = TextEditingController(text: widget.product?.barcode);
  late final _price = TextEditingController(text: widget.product?.defaultPrice);
  late final _reorderLevel = TextEditingController(text: widget.product?.reorderLevel?.toString());
  late final _safetyStock = TextEditingController(text: '${widget.product?.safetyStock ?? 0}');
  late bool _isActive = widget.product?.isActive ?? true;
  late final _details = TextEditingController(text: widget.product?.details);
  late String? _categoryId = widget.product?.category?.id;

  /// Larger units and how many base units each holds, e.g. carton → 24.
  late final List<({String? unitId, TextEditingController quantity})> _conversions = [
    for (final unit in widget.product?.conversions ?? const <ProductUnit>[])
      (unitId: unit.id, quantity: TextEditingController(text: '${unit.baseQuantity}')),
  ];
  List<CatalogueItem>? _categories;
  List<CatalogueItem>? _units;

  @override
  void initState() {
    super.initState();
    _loadChoices();
  }

  Future<void> _loadChoices() async {
    try {
      final categories = await widget.catalogue.list(CatalogueKind.categories);
      final units = await widget.catalogue.list(CatalogueKind.units);
      if (mounted) {
        setState(() {
          _categories = categories;
          _units = units;
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  String get _baseUnitId => widget.product?.baseUnit.id ?? _baseUnitFromList ?? '';

  String? get _baseUnitFromList => _units?.where((unit) => unit.code == 'pack').firstOrNull?.id;

  Map<String, int> get _conversionValues => {
    for (final row in _conversions)
      if (row.unitId != null && int.tryParse(row.quantity.text.trim()) != null)
        row.unitId!: int.parse(row.quantity.text.trim()),
  };

  bool get _conversionsChanged {
    final before = {
      for (final unit in widget.product?.conversions ?? const <ProductUnit>[])
        unit.id: unit.baseQuantity,
    };
    final after = _conversionValues;
    return before.length != after.length ||
        after.entries.any((entry) => before[entry.key] != entry.value);
  }

  bool _saving = false;
  String? _error;

  /// Shown under the barcode once one has been generated.
  String? _barcodeNote;

  /// Messages from the server for individual fields, e.g. a SKU that is already used.
  Map<String, String> _serverErrors = {};

  bool get _isNew => widget.product == null;

  /// Fills in the barcode by scanning the pack (or typing it on the web).
  Future<void> _scanBarcode() async {
    final barcode = await widget.readBarcode(context);
    if (barcode == null || !mounted) return;
    setState(() {
      _barcode.text = barcode;
      _serverErrors = {..._serverErrors}..remove('barcode');
    });
  }

  /// Gives the product one of Snackify's own barcodes, for packs without one. It is saved
  /// straight away, so labels can be printed for it.
  Future<void> _generateBarcode() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final product = await widget.repository.generateBarcode(widget.product!.id);
      if (!mounted) return;
      // Said under the field rather than in a snackbar, which would cover buttons on phones.
      setState(() {
        _barcode.text = product.barcode ?? '';
        _barcodeNote = 'Saved. Print labels for it from Stock.';
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _flavour,
      _size,
      _sku,
      _barcode,
      _price,
      _reorderLevel,
      _safetyStock,
      _details,
      for (final row in _conversions) row.quantity,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _serverErrors = {};
      _error = null;
    });
    if (_saving || !_formKey.currentState!.validate()) return;

    final input = ProductInput(
      sku: _sku.text.trim().toUpperCase(),
      name: _name.text.trim(),
      flavour: _flavour.text.trim(),
      size: _size.text.trim(),
      barcode: _barcode.text.trim().isEmpty ? null : _barcode.text.trim(),
      defaultPrice: _price.text.trim(),
      reorderLevel: int.tryParse(_reorderLevel.text.trim()),
      safetyStock: int.tryParse(_safetyStock.text.trim()) ?? 0,
      isActive: _isActive,
      details: _details.text.trim().isEmpty ? null : _details.text.trim(),
      categoryId: _categoryId,
    );

    setState(() => _saving = true);
    try {
      var saved = _isNew
          ? await widget.repository.create(input)
          : await widget.repository.update(widget.product!.id, input);
      if (_conversionsChanged) {
        saved = await widget.repository.setConversions(saved.id, _conversionValues);
      }
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _serverErrors = error.fieldErrors;
        _error = error.fieldErrors.isEmpty ? error.message : null;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isNew ? 'Add product' : 'Edit product')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null) ...[
                      ErrorBanner(message: _error!),
                      const SizedBox(height: 16),
                    ],
                    _textField(
                      'name',
                      _name,
                      'Product name',
                      hint: 'e.g. Potato Crisps',
                      maxLength: 100,
                    ),
                    _textField('flavour', _flavour, 'Flavour', hint: 'e.g. BBQ', maxLength: 60),
                    _textField('size', _size, 'Size', hint: 'e.g. Small or 50 g', maxLength: 40),
                    _textField(
                      'description',
                      _details,
                      'Description (optional)',
                      hint: 'e.g. Thick-cut, 125 g',
                      maxLength: 500,
                      required: false,
                    ),
                    if (_categories case final categories?)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: DropdownButtonFormField<String?>(
                          initialValue: _categoryId,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: 'Category (optional)',
                            border: const OutlineInputBorder(),
                            errorText: _serverErrors['categoryId'],
                          ),
                          items: [
                            const DropdownMenuItem(value: null, child: Text('No category')),
                            for (final category in categories)
                              DropdownMenuItem(value: category.id, child: Text(category.name)),
                          ],
                          onChanged: _saving
                              ? null
                              : (value) => setState(() => _categoryId = value),
                        ),
                      ),
                    _textField(
                      'sku',
                      _sku,
                      'SKU (product code)',
                      hint: 'e.g. PC-BBQ-S',
                      capitalization: TextCapitalization.characters,
                      validator: (value) => _skuFormat.hasMatch(value.toUpperCase())
                          ? null
                          : 'Use up to 40 letters, digits, dots, dashes or underscores',
                    ),
                    _textField(
                      'barcode',
                      _barcode,
                      'Barcode (optional)',
                      helper: _barcodeNote ?? 'Leave empty if the product has no barcode',
                      required: false,
                      suffix: IconButton(
                        tooltip: 'Scan the barcode',
                        icon: const Icon(Icons.qr_code_scanner),
                        onPressed: _saving ? null : _scanBarcode,
                      ),
                      validator: (value) => value.isEmpty || _barcodeFormat.hasMatch(value)
                          ? null
                          : 'Use 4–48 letters, digits or dashes',
                    ),
                    if (!_isNew && (widget.product!.barcode ?? '').isEmpty)
                      ListenableBuilder(
                        listenable: _barcode,
                        builder: (context, _) => _barcode.text.trim().isNotEmpty
                            ? const SizedBox.shrink()
                            : Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                    onPressed: _saving ? null : _generateBarcode,
                                    icon: const Icon(Icons.qr_code_2),
                                    label: const Text('No barcode on the pack? Generate one'),
                                  ),
                                ),
                              ),
                      ),
                    _textField(
                      'defaultPrice',
                      _price,
                      'Default selling price',
                      prefix: '${AppConfig.currencyCode} ',
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      validator: (value) => _priceFormat.hasMatch(value)
                          ? null
                          : 'Use an amount like 0.50 (up to 2 decimal places)',
                    ),
                    _textField(
                      'reorderLevel',
                      _reorderLevel,
                      'Reorder level (optional)',
                      helper:
                          'Warn when stock falls to this many packs. Leave empty for no warning.',
                      required: false,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: (value) => (int.tryParse(value) ?? 1000001) <= 1000000
                          ? null
                          : 'Use a whole number up to 1,000,000',
                    ),
                    _textField(
                      'safetyStock',
                      _safetyStock,
                      'Safety stock (packs)',
                      helper:
                          'Extra packs to keep on top of the forecast when Forecasts suggests how '
                          'much to receive. 0 for none.',
                      required: false,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: (value) => (int.tryParse(value) ?? 1000001) <= 1000000
                          ? null
                          : 'Use a whole number up to 1,000,000',
                    ),
                    if (_units case final units?) ..._conversionRows(units),
                    if (!_isNew)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Active'),
                        subtitle: const Text(
                          'Inactive products are hidden from lists and cannot be used in new '
                          'transactions. Their history is kept.',
                        ),
                        value: _isActive,
                        onChanged: _saving ? null : (value) => setState(() => _isActive = value),
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
                          : const Text('Save product'),
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

  /// The units the product is also bought in, e.g. "1 carton = 24 packs".
  List<Widget> _conversionRows(List<CatalogueItem> units) {
    final baseName = widget.product?.baseUnit.name.toLowerCase() ?? 'pack';
    final choices = units.where((unit) => unit.id != _baseUnitId).toList();
    return [
      Text('Bought in larger units', style: Theme.of(context).textTheme.titleSmall),
      Text(
        'Stock is counted in ${baseName}s. Add cartons or cases so deliveries can be '
        'entered in them.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      if (_serverErrors.entries.where((e) => e.key.startsWith('conversions')).firstOrNull
          case final problem?)
        Text(problem.value, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      const SizedBox(height: 8),
      for (final (index, row) in _conversions.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(padding: EdgeInsets.only(top: 16), child: Text('1 ')),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: row.unitId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Unit',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final unit in choices)
                      DropdownMenuItem(value: unit.id, child: Text(unit.name)),
                  ],
                  validator: (value) {
                    if (value == null) return 'Choose a unit';
                    final uses = _conversions.where((other) => other.unitId == value).length;
                    return uses > 1 ? 'Listed twice' : null;
                  },
                  onChanged: _saving
                      ? null
                      : (value) => setState(
                          () => _conversions[index] = (unitId: value, quantity: row.quantity),
                        ),
                ),
              ),
              const Padding(padding: EdgeInsets.fromLTRB(8, 16, 8, 0), child: Text('=')),
              SizedBox(
                width: 110,
                child: TextFormField(
                  controller: row.quantity,
                  enabled: !_saving,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: '${baseName}s',
                    border: const OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final quantity = int.tryParse((value ?? '').trim());
                    if (quantity == null || quantity < 2 || quantity > 100000) return '2–100,000';
                    return null;
                  },
                ),
              ),
              IconButton(
                tooltip: 'Remove this unit',
                icon: const Icon(Icons.close),
                onPressed: _saving
                    ? null
                    : () => setState(() => _conversions.removeAt(index).quantity.dispose()),
              ),
            ],
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _saving || choices.isEmpty
              ? null
              : () => setState(
                  () => _conversions.add((unitId: null, quantity: TextEditingController())),
                ),
          icon: const Icon(Icons.add),
          label: const Text('Add a unit'),
        ),
      ),
      const SizedBox(height: 8),
    ];
  }

  /// A text field that is required by default, trims input before checking it, and shows
  /// the server's message for [field] if saving failed because of it.
  Widget _textField(
    String field,
    TextEditingController controller,
    String label, {
    String? hint,
    String? helper,
    String? prefix,
    Widget? suffix,
    int? maxLength,
    bool required = true,
    TextCapitalization capitalization = TextCapitalization.sentences,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String value)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        enabled: !_saving,
        textCapitalization: capitalization,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        maxLength: maxLength,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          prefixText: prefix,
          suffixIcon: suffix,
          border: const OutlineInputBorder(),
          errorText: _serverErrors[field],
          counterText: '',
        ),
        onChanged: (_) {
          if (_serverErrors.containsKey(field)) {
            setState(() => _serverErrors = {..._serverErrors}..remove(field));
          }
        },
        validator: (raw) {
          final value = (raw ?? '').trim();
          if (value.isEmpty) return required ? 'Required' : null;
          return validator?.call(value);
        },
      ),
    );
  }
}
