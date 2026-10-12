import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../data/products_repository.dart';
import '../domain/product.dart';

/// Shows a searchable list of active products and returns the one chosen (or null).
///
/// The search box also matches an exact barcode, so a USB or Bluetooth barcode scanner
/// (which types the code like a keyboard) can be used to pick a product.
Future<Product?> pickProduct(BuildContext context, ProductsRepository repository) {
  return showDialog<Product>(
    context: context,
    builder: (_) => _ProductPickerDialog(repository: repository),
  );
}

class _ProductPickerDialog extends StatefulWidget {
  const _ProductPickerDialog({required this.repository});

  final ProductsRepository repository;

  @override
  State<_ProductPickerDialog> createState() => _ProductPickerDialogState();
}

class _ProductPickerDialogState extends State<_ProductPickerDialog> {
  final _search = TextEditingController();
  Timer? _searchDelay;
  int _latestRequest = 0;
  bool _loading = true;
  String? _error;
  List<Product> _products = const [];

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
      final page = await widget.repository.list(search: _search.text);
      if (!mounted || request != _latestRequest) return;
      setState(() {
        _products = page.products;
        _loading = false;
      });
      // A scanned barcode matches exactly one product: choose it straight away.
      final scanned = page.products.where((p) => p.barcode == _search.text.trim());
      if (scanned.length == 1) Navigator.of(context).pop(scanned.first);
    } on ApiException catch (error) {
      if (!mounted || request != _latestRequest) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  void _onSearchChanged(String _) {
    _searchDelay?.cancel();
    _searchDelay = Timer(const Duration(milliseconds: 300), _load);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Choose a product', style: Theme.of(context).textTheme.titleLarge),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _search,
                autofocus: true,
                onChanged: _onSearchChanged,
                onSubmitted: (_) => _load(),
                decoration: const InputDecoration(
                  hintText: 'Search or scan a barcode',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(child: _buildResults()),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (_error != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load products',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    if (_loading && _products.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_products.isEmpty) {
      return const MessageView(
        icon: Icons.search_off,
        title: 'No matching products',
        message: 'Check the spelling, or ask an admin to add the product first.',
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: _products.length,
      itemBuilder: (context, index) {
        final product = _products[index];
        return ListTile(
          title: Text(product.description),
          subtitle: Text([product.sku, ?product.barcode].join(' · ')),
          onTap: () => Navigator.of(context).pop(product),
        );
      },
    );
  }
}
