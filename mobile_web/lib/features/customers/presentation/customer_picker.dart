import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../data/customers_repository.dart';
import '../domain/customer.dart';

/// Shows a searchable list of active customers and returns the one chosen (or null).
Future<Customer?> pickCustomer(BuildContext context, CustomersRepository repository) {
  return showDialog<Customer>(
    context: context,
    builder: (_) => _CustomerPickerDialog(repository: repository),
  );
}

class _CustomerPickerDialog extends StatefulWidget {
  const _CustomerPickerDialog({required this.repository});

  final CustomersRepository repository;

  @override
  State<_CustomerPickerDialog> createState() => _CustomerPickerDialogState();
}

class _CustomerPickerDialogState extends State<_CustomerPickerDialog> {
  final _search = TextEditingController();
  Timer? _searchDelay;
  int _latestRequest = 0;
  bool _loading = true;
  String? _error;
  List<Customer> _customers = const [];

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
        _customers = page.customers;
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
                    child: Text('Choose a customer', style: Theme.of(context).textTheme.titleLarge),
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
                onChanged: (_) {
                  _searchDelay?.cancel();
                  _searchDelay = Timer(const Duration(milliseconds: 300), _load);
                },
                decoration: const InputDecoration(
                  hintText: 'Search name, code or phone',
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
        title: 'Could not load customers',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    if (_loading && _customers.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_customers.isEmpty) {
      return const MessageView(
        icon: Icons.search_off,
        title: 'No matching customers',
        message: 'Check the spelling, or ask a salesperson to add the customer first.',
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: _customers.length,
      itemBuilder: (context, index) {
        final customer = _customers[index];
        return ListTile(
          title: Text(customer.name),
          subtitle: Text([customer.code, ?customer.phone].join(' · ')),
          onTap: () => Navigator.of(context).pop(customer),
        );
      },
    );
  }
}
