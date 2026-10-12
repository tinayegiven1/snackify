import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/formatting/dates.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../auth/domain/app_user.dart';
import '../../products/data/products_repository.dart';
import '../data/stock_repository.dart';
import '../domain/stock_models.dart';
import 'receive_stock_screen.dart';
import 'stock_product_screen.dart';

/// Stock on hand and stock received. Storekeepers and admins can record deliveries.
class StockScreen extends StatefulWidget {
  const StockScreen({super.key, required this.stock, required this.products, required this.user});

  final StockRepository stock;
  final ProductsRepository products;
  final AppUser user;

  @override
  State<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends State<StockScreen> {
  /// Changing this rebuilds both tabs, so they reload after stock changes.
  int _version = 0;

  bool get _canReceive =>
      widget.user.role == StaffRole.admin || widget.user.role == StaffRole.storekeeper;

  Future<void> _receiveStock() async {
    // An earlier confirmation message would otherwise cover the form's button.
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final result = await Navigator.of(context).push<ReceivedStock>(
      MaterialPageRoute(
        builder: (_) => ReceiveStockScreen(
          stock: widget.stock,
          products: widget.products,
          canRecordOpeningBalance: widget.user.role == StaffRole.admin,
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _version++);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Received ${result.receipt.quantity} × ${result.receipt.product.description}. '
          'In stock now: ${result.quantityOnHand}',
        ),
      ),
    );
  }

  Future<void> _openProduct(StockBalance balance) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => StockProductScreen(
          stock: widget.stock,
          balance: balance,
          canAdjust: widget.user.role == StaffRole.admin,
        ),
      ),
    );
    if (mounted) setState(() => _version++);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        floatingActionButton: _canReceive
            ? FloatingActionButton.extended(
                onPressed: _receiveStock,
                icon: const Icon(Icons.move_to_inbox_outlined),
                label: const Text('Receive stock'),
              )
            : null,
        body: Column(
          children: [
            const TabBar(
              tabs: [
                Tab(text: 'On hand'),
                Tab(text: 'Receipts'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _OnHandTab(
                    key: ValueKey('on-hand-$_version'),
                    stock: widget.stock,
                    onOpen: _openProduct,
                  ),
                  _ReceiptsTab(key: ValueKey('receipts-$_version'), stock: widget.stock),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ On hand

class _OnHandTab extends StatefulWidget {
  const _OnHandTab({super.key, required this.stock, required this.onOpen});

  final StockRepository stock;
  final ValueChanged<StockBalance> onOpen;

  @override
  State<_OnHandTab> createState() => _OnHandTabState();
}

class _OnHandTabState extends State<_OnHandTab> {
  final _search = TextEditingController();
  Timer? _searchDelay;
  bool _lowStockOnly = false;
  int _latestRequest = 0;
  bool _loading = true;
  String? _error;
  List<StockBalance>? _balances;

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
      final balances = await widget.stock.balances(
        search: _search.text,
        lowStockOnly: _lowStockOnly,
      );
      if (!mounted || request != _latestRequest) return;
      setState(() {
        _balances = balances;
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: (_) {
                    _searchDelay?.cancel();
                    _searchDelay = Timer(const Duration(milliseconds: 300), _load);
                  },
                  decoration: const InputDecoration(
                    hintText: 'Search products',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('Low stock'),
                selected: _lowStockOnly,
                onSelected: (value) {
                  setState(() => _lowStockOnly = value);
                  _load();
                },
              ),
            ],
          ),
        ),
        if (_loading && _balances != null) const LinearProgressIndicator(),
        Expanded(child: _buildContent()),
      ],
    );
  }

  Widget _buildContent() {
    if (_error != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load stock',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    final balances = _balances;
    if (balances == null) return const Center(child: CircularProgressIndicator());
    if (balances.isEmpty) {
      return MessageView(
        icon: _lowStockOnly ? Icons.check_circle_outline : Icons.inventory_2_outlined,
        title: _lowStockOnly ? 'Nothing is low on stock' : 'No products found',
        message: _lowStockOnly
            ? 'Every product with a reorder level has more stock than that level.'
            : 'Products appear here once an admin has added them.',
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: balances.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final balance = balances[index];
        return ListTile(
          title: Text(balance.product.description),
          subtitle: Text(
            [
              balance.product.sku,
              if (balance.reorderLevel != null) 'reorder at ${balance.reorderLevel}',
            ].join(' · '),
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${balance.quantityOnHand}',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: balance.isLowStock ? colorScheme.error : null,
                ),
              ),
              if (balance.isLowStock)
                StatusBadge(
                  'Low stock',
                  color: colorScheme.errorContainer,
                  textColor: colorScheme.onErrorContainer,
                ),
            ],
          ),
          onTap: () => widget.onOpen(balance),
        );
      },
    );
  }
}

// ------------------------------------------------------------------ Receipts

enum _Range { today, lastSevenDays, custom }

class _ReceiptsTab extends StatefulWidget {
  const _ReceiptsTab({super.key, required this.stock});

  final StockRepository stock;

  @override
  State<_ReceiptsTab> createState() => _ReceiptsTabState();
}

class _ReceiptsTabState extends State<_ReceiptsTab> {
  _Range _range = _Range.today;
  DateTimeRange _dates = DateTimeRange(start: today(), end: today());
  bool _loading = true;
  String? _error;
  ({List<StockReceipt> receipts, int totalQuantity})? _result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.stock.receipts(
        from: toApiDate(_dates.start),
        to: toApiDate(_dates.end),
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _selectRange(_Range range) async {
    var dates = _dates;
    switch (range) {
      case _Range.today:
        dates = DateTimeRange(start: today(), end: today());
      case _Range.lastSevenDays:
        dates = DateTimeRange(start: today().subtract(const Duration(days: 6)), end: today());
      case _Range.custom:
        final picked = await showDateRangePicker(
          context: context,
          firstDate: today().subtract(const Duration(days: 365 * 3)),
          lastDate: today(),
          initialDateRange: _dates,
        );
        if (picked == null) return;
        dates = picked;
    }
    setState(() {
      _range = range;
      _dates = dates;
    });
    _load();
  }

  String get _rangeLabel {
    final start = formatApiDate(toApiDate(_dates.start));
    final end = formatApiDate(toApiDate(_dates.end));
    return start == end ? start : '$start – $end';
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Today'),
                selected: _range == _Range.today,
                onSelected: (_) => _selectRange(_Range.today),
              ),
              ChoiceChip(
                label: const Text('Last 7 days'),
                selected: _range == _Range.lastSevenDays,
                onSelected: (_) => _selectRange(_Range.lastSevenDays),
              ),
              ChoiceChip(
                label: const Text('Choose dates'),
                selected: _range == _Range.custom,
                onSelected: (_) => _selectRange(_Range.custom),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            result == null || _error != null
                ? _rangeLabel
                : '$_rangeLabel · ${result.receipts.length} '
                      '${result.receipts.length == 1 ? 'receipt' : 'receipts'} · '
                      '${result.totalQuantity} packs',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (_loading && result != null) const LinearProgressIndicator(),
        Expanded(child: _buildContent()),
      ],
    );
  }

  Widget _buildContent() {
    if (_error != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load receipts',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    final result = _result;
    if (result == null) return const Center(child: CircularProgressIndicator());
    if (result.receipts.isEmpty) {
      return const MessageView(
        icon: Icons.move_to_inbox_outlined,
        title: 'No stock received',
        message: 'Nothing was received on these dates.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: result.receipts.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final receipt = result.receipts[index];
        return ListTile(
          leading: Icon(
            receipt.isOpeningBalance ? Icons.flag_outlined : Icons.move_to_inbox_outlined,
          ),
          title: Text('${receipt.quantity} × ${receipt.product.description}'),
          subtitle: Text(
            [
              formatApiDate(receipt.receivedDate),
              if (receipt.isOpeningBalance) 'Opening balance',
              if (receipt.batchNumber != null) 'Batch ${receipt.batchNumber}',
              if (receipt.expiryDate != null) 'Expires ${formatApiDate(receipt.expiryDate!)}',
              ?receipt.supplierReference,
              'by ${receipt.receivedBy}',
            ].join(' · '),
          ),
        );
      },
    );
  }
}
