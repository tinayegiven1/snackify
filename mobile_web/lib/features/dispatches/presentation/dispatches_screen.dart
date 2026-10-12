import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../customers/data/customers_repository.dart';
import '../../products/data/products_repository.dart';
import '../data/dispatches_repository.dart';
import '../domain/dispatch_models.dart';
import 'dispatch_detail_screen.dart';
import 'dispatch_editor_screen.dart';

/// All dispatches, newest first, with a status filter and search.
class DispatchesScreen extends StatefulWidget {
  const DispatchesScreen({
    super.key,
    required this.dispatches,
    required this.customers,
    required this.products,
    required this.permissions,
  });

  final DispatchesRepository dispatches;
  final CustomersRepository customers;
  final ProductsRepository products;
  final DispatchPermissions permissions;

  @override
  State<DispatchesScreen> createState() => _DispatchesScreenState();
}

class _DispatchesScreenState extends State<DispatchesScreen> {
  final _search = TextEditingController();
  Timer? _searchDelay;
  DispatchStatus? _status;
  int _latestRequest = 0;
  bool _loading = true;
  String? _error;
  List<DispatchSummary>? _dispatches;

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
      final page = await widget.dispatches.list(status: _status, search: _search.text);
      if (!mounted || request != _latestRequest) return;
      setState(() {
        _dispatches = page.dispatches;
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

  Future<void> _open(String dispatchId) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DispatchDetailScreen(
          dispatchId: dispatchId,
          dispatches: widget.dispatches,
          customers: widget.customers,
          products: widget.products,
          permissions: widget.permissions,
        ),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _create() async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final saved = await Navigator.of(context).push<Dispatch>(
      MaterialPageRoute(
        builder: (_) => DispatchEditorScreen(
          dispatches: widget.dispatches,
          customers: widget.customers,
          products: widget.products,
        ),
      ),
    );
    if (saved == null || !mounted) return;
    await _open(saved.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: widget.permissions.canCreate
          ? FloatingActionButton.extended(
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: const Text('New dispatch'),
            )
          : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (_) {
                _searchDelay?.cancel();
                _searchDelay = Timer(const Duration(milliseconds: 300), _load);
              },
              decoration: const InputDecoration(
                hintText: 'Search dispatch number or customer',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              children: [
                for (final (label, status) in [
                  ('All', null),
                  ('Drafts', DispatchStatus.draft),
                  ('Confirmed', DispatchStatus.confirmed),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: _status == status,
                    onSelected: (_) {
                      setState(() => _status = status);
                      _load();
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (_loading && _dispatches != null) const LinearProgressIndicator(),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_error != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load dispatches',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    final dispatches = _dispatches;
    if (dispatches == null) return const Center(child: CircularProgressIndicator());
    if (dispatches.isEmpty) {
      return MessageView(
        icon: Icons.local_shipping_outlined,
        title: 'No dispatches found',
        message: widget.permissions.canCreate
            ? 'Start one with the New dispatch button.'
            : 'Dispatches appear here once staff create them.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: dispatches.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final dispatch = dispatches[index];
        return ListTile(
          title: Text('${dispatch.dispatchNumber} · ${dispatch.customerName}'),
          subtitle: Text(
            '${formatApiDate(dispatch.dispatchDate)} · ${dispatch.totalQuantity} packs',
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(withCurrency(dispatch.totalValue)),
              DispatchStatusBadge(dispatch.status),
            ],
          ),
          onTap: () => _open(dispatch.id),
        );
      },
    );
  }
}
