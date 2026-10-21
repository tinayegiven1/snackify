import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../core/scanning/barcode_reader.dart';
import '../../../shared/widgets/message_view.dart';
import '../../catalogue/data/catalogue_repository.dart';
import '../data/products_repository.dart';
import '../domain/product.dart';
import 'product_form_screen.dart';
import 'scan_product.dart';

/// Content width at which the list becomes a table.
const double _tableBreakpoint = 720;

/// The product catalogue: everyone can search it; admins can add and edit products.
class ProductsScreen extends StatefulWidget {
  const ProductsScreen({
    super.key,
    required this.repository,
    required this.canEdit,
    required this.readBarcode,
    required this.catalogue,
  });

  final ProductsRepository repository;
  final bool canEdit;
  final BarcodeReader readBarcode;
  final CatalogueRepository catalogue;

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  final _search = TextEditingController();
  Timer? _searchDelay;
  bool _includeInactive = false;

  bool _loading = true;
  String? _error;
  ProductPage? _page;

  /// Ignores answers to older requests when the user types quickly.
  int _latestRequest = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchDelay?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_latestRequest;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.repository.list(
        search: _search.text,
        includeInactive: _includeInactive,
      );
      if (!mounted || request != _latestRequest) return;
      setState(() {
        _page = page;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || request != _latestRequest) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  void _onSearchChanged(String _) {
    // Wait until typing pauses, so each keystroke does not send a request.
    _searchDelay?.cancel();
    _searchDelay = Timer(const Duration(milliseconds: 300), _load);
    setState(() {}); // Show or hide the clear button.
  }

  Future<void> _openForm([Product? product]) async {
    // An earlier "Saved ..." message would otherwise cover the form's Save button.
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final saved = await Navigator.of(context).push<Product>(
      MaterialPageRoute(
        builder: (_) => ProductFormScreen(
          repository: widget.repository,
          product: product,
          readBarcode: widget.readBarcode,
          catalogue: widget.catalogue,
        ),
      ),
    );
    if (saved == null || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Saved ${saved.description}')));
    _load();
  }

  /// Finds a product by scanning its pack: admins go straight to it; others see it listed.
  Future<void> _scan() async {
    final product = await scanForProduct(
      context,
      products: widget.repository,
      readBarcode: widget.readBarcode,
    );
    if (product == null || !mounted) return;
    if (widget.canEdit) {
      await _openForm(product);
      return;
    }
    _search.text = product.barcode ?? product.sku;
    if (!product.isActive) _includeInactive = true;
    _onSearchChanged(_search.text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: widget.canEdit
          ? FloatingActionButton.extended(
              onPressed: () => _openForm(),
              icon: const Icon(Icons.add),
              label: const Text('Add product'),
            )
          : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    onChanged: _onSearchChanged,
                    decoration: InputDecoration(
                      hintText: 'Search name, flavour, size, SKU or barcode',
                      prefixIcon: const Icon(Icons.search),
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: _search.text.isEmpty
                          ? IconButton(
                              tooltip: 'Scan a barcode',
                              icon: const Icon(Icons.qr_code_scanner),
                              onPressed: _scan,
                            )
                          : IconButton(
                              tooltip: 'Clear search',
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _search.clear();
                                _onSearchChanged('');
                              },
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('Show inactive'),
                  selected: _includeInactive,
                  onSelected: (value) {
                    setState(() => _includeInactive = value);
                    _load();
                  },
                ),
              ],
            ),
          ),
          if (_loading && _page != null) const LinearProgressIndicator(),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_error != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load products',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    final page = _page;
    if (page == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (page.products.isEmpty) {
      final searching = _search.text.trim().isNotEmpty;
      return MessageView(
        icon: searching ? Icons.search_off : Icons.inventory_2_outlined,
        title: searching ? 'No products match "${_search.text.trim()}"' : 'No products yet',
        message: searching
            ? 'Check the spelling, or search by SKU or barcode.'
            : widget.canEdit
            ? 'Add your first product with the Add product button.'
            : 'An admin can add products.',
      );
    }

    final count = page.total == page.products.length
        ? '${page.total} ${page.total == 1 ? 'product' : 'products'}'
        : 'Showing ${page.products.length} of ${page.total} products. Search to narrow the list.';
    final onTap = widget.canEdit ? _openForm : null;

    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(count, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: constraints.maxWidth >= _tableBreakpoint
                ? _ProductTable(products: page.products, onTap: onTap)
                : _ProductList(products: page.products, onTap: onTap),
          ),
        ],
      ),
    );
  }
}

/// Phones: touch-friendly rows.
class _ProductList extends StatelessWidget {
  const _ProductList({required this.products, required this.onTap});

  final List<Product> products;
  final ValueChanged<Product>? onTap;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88), // Room for the Add button.
      itemCount: products.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final product = products[index];
        return ListTile(
          title: Text('${product.name} — ${product.flavour}'),
          subtitle: Text(
            [product.size, product.sku, ?product.barcode].join(' · '),
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(product.formattedPrice, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (!product.isActive) const StatusBadge('Inactive'),
            ],
          ),
          onTap: onTap == null ? null : () => onTap!(product),
        );
      },
    );
  }
}

/// Wide screens: a table.
class _ProductTable extends StatelessWidget {
  const _ProductTable({required this.products, required this.onTap});

  final List<Product> products;
  final ValueChanged<Product>? onTap;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            showCheckboxColumn: false,
            columns: const [
              DataColumn(label: Text('Product')),
              DataColumn(label: Text('Flavour')),
              DataColumn(label: Text('Size')),
              DataColumn(label: Text('SKU')),
              DataColumn(label: Text('Barcode')),
              DataColumn(label: Text('Price'), numeric: true),
              DataColumn(label: Text('Status')),
            ],
            rows: [
              for (final product in products)
                DataRow(
                  onSelectChanged: onTap == null ? null : (_) => onTap!(product),
                  cells: [
                    DataCell(Text(product.name)),
                    DataCell(Text(product.flavour)),
                    DataCell(Text(product.size)),
                    DataCell(Text(product.sku)),
                    DataCell(Text(product.barcode ?? '—')),
                    DataCell(Text(product.formattedPrice)),
                    DataCell(
                      product.isActive ? const Text('Active') : const StatusBadge('Inactive'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
