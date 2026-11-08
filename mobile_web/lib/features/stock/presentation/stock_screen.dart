import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/files/pdf_sharer.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/network/api_client.dart';
import '../../../core/scanning/barcode_reader.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/message_view.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../auth/domain/app_user.dart';
import '../../organisations/domain/organisation.dart';
import '../../products/data/products_repository.dart';
import '../../receipts/domain/receipt_models.dart';
import '../../receipts/presentation/receipt_editor_screen.dart';
import '../../receipts/presentation/receipt_services.dart';
import '../../receipts/presentation/receipts_screen.dart' show receivedMessage;
import '../data/stock_repository.dart';
import '../domain/stock_models.dart';
import 'receive_stock_screen.dart';
import 'stock_product_screen.dart';

/// Stock on hand and stock received. Warehouse staff record deliveries as goods-received
/// notes; administrators record opening balances. Head Office staff can look at any
/// organisation's stock.
class StockScreen extends StatefulWidget {
  const StockScreen({
    super.key,
    required this.stock,
    required this.products,
    required this.user,
    required this.readBarcode,
    required this.sharePdf,
    required this.receiptServices,
  });

  final StockRepository stock;
  final ProductsRepository products;
  final AppUser user;
  final BarcodeReader readBarcode;
  final PdfSharer sharePdf;
  final ReceiptServices receiptServices;

  @override
  State<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends State<StockScreen> {
  /// Changing this rebuilds both tabs, so they reload after stock changes.
  int _version = 0;

  /// Whose stock "On hand" shows; null for the user's own organisation.
  String? _organisationId;
  List<Organisation>? _organisations;

  @override
  void initState() {
    super.initState();
    if (widget.user.seesAllOrganisations) _loadOrganisations();
  }

  Future<void> _loadOrganisations() async {
    try {
      final organisations = await widget.receiptServices.organisations.list();
      if (mounted) setState(() => _organisations = organisations);
    } on ApiException {
      // Without the list, the Head Office's own stock is still shown.
    }
  }

  bool get _ownStock => _organisationId == null || _organisationId == widget.user.organisation.id;

  Future<void> _receiveStock() async {
    // An earlier confirmation message would otherwise cover the form's button.
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final receipt = await Navigator.of(context).push<GoodsReceipt>(
      MaterialPageRoute(builder: (_) => ReceiptEditorScreen(services: widget.receiptServices)),
    );
    if (receipt == null || !mounted) return;
    setState(() => _version++);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(receivedMessage(receipt))));
  }

  Future<void> _recordOpeningBalance() async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final result = await Navigator.of(context).push<ReceivedStock>(
      MaterialPageRoute(
        builder: (_) => ReceiveStockScreen(
          stock: widget.stock,
          products: widget.products,
          readBarcode: widget.readBarcode,
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _version++);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Opening balance: ${result.receipt.quantity} × ${result.receipt.product.description}. '
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
          // Only the user's own organisation's stock is adjusted from here.
          canAdjust: widget.user.can('stock.adjust') && _ownStock,
          organisationId: _organisationId,
          products: widget.products,
          sharePdf: widget.sharePdf,
          canPrintLabels: widget.user.can('label.print'),
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
        floatingActionButton: widget.user.can('stock.receive')
            ? FloatingActionButton.extended(
                heroTag: 'stock-receive',
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
            if (_organisations != null || widget.user.can('stock.opening_balance'))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (_organisations case final organisations?)
                      SizedBox(
                        width: 320,
                        child: DropdownButtonFormField<String>(
                          initialValue: _organisationId ?? widget.user.organisation.id,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Whose stock',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            for (final organisation in organisations)
                              DropdownMenuItem(
                                value: organisation.id,
                                child: Text('${organisation.name} (${organisation.code})'),
                              ),
                          ],
                          onChanged: (value) => setState(() {
                            _organisationId = value;
                            _version++;
                          }),
                        ),
                      ),
                    if (widget.user.can('stock.opening_balance'))
                      TextButton.icon(
                        onPressed: _recordOpeningBalance,
                        icon: const Icon(Icons.playlist_add_outlined),
                        label: const Text('Opening balance'),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: TabBarView(
                children: [
                  _OnHandTab(
                    key: ValueKey('on-hand-$_version'),
                    stock: widget.stock,
                    organisationId: _organisationId,
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
  const _OnHandTab({
    super.key,
    required this.stock,
    required this.organisationId,
    required this.onOpen,
  });

  final StockRepository stock;
  final String? organisationId;
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

  /// Headline figures, from the last list loaded without a search or filter.
  ({int total, int low, int out})? _summary;

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
        organisationId: widget.organisationId,
      );
      if (!mounted || request != _latestRequest) return;
      setState(() {
        _balances = balances;
        _loading = false;
        if (!_lowStockOnly && _search.text.trim().isEmpty) {
          _summary = (
            total: balances.length,
            low: balances.where((b) => b.isLowStock && b.quantityOnHand > 0).length,
            out: balances.where((b) => b.quantityOnHand <= 0).length,
          );
        }
      });
    } on ApiException catch (error) {
      if (!mounted || request != _latestRequest) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  void _setLowStockOnly(bool value) {
    setState(() => _lowStockOnly = value);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          sliver: SliverList.list(
            children: [
              if (summary != null) ...[
                StatCardRow(
                  children: [
                    StatCard(
                      label: 'Products',
                      value: '${summary.total}',
                      icon: Icons.inventory_2_outlined,
                    ),
                    StatCard(
                      label: 'Running low',
                      value: '${summary.low}',
                      icon: Icons.warning_amber_rounded,
                      tone: Tone.warn,
                      selected: _lowStockOnly,
                      onTap: () => _setLowStockOnly(!_lowStockOnly),
                    ),
                    StatCard(
                      label: 'Out of stock',
                      value: '${summary.out}',
                      icon: Icons.highlight_off,
                      tone: Tone.bad,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              Panel(
                padding: const EdgeInsets.all(12),
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
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: const Text('Low stock'),
                      selected: _lowStockOnly,
                      onSelected: _setLowStockOnly,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (_loading && _balances != null) const LinearProgressIndicator(),
            ],
          ),
        ),
        ..._buildContent(),
      ],
    );
  }

  List<Widget> _buildContent() {
    Widget fill(Widget child) => SliverFillRemaining(hasScrollBody: false, child: child);
    if (_error != null) {
      return [
        fill(
          MessageView(
            icon: Icons.cloud_off_outlined,
            title: 'Could not load stock',
            message: _error!,
            action: RetryButton(onPressed: _load),
          ),
        ),
      ];
    }
    final balances = _balances;
    if (balances == null) return [fill(const Center(child: CircularProgressIndicator()))];
    if (balances.isEmpty) {
      return [
        fill(
          MessageView(
            icon: _lowStockOnly ? Icons.check_circle_outline : Icons.inventory_2_outlined,
            title: _lowStockOnly ? 'Nothing is low on stock' : 'No products found',
            message: _lowStockOnly
                ? 'Every product with a reorder level has more stock than that level.'
                : 'Products appear here once an admin has added them.',
          ),
        ),
      ];
    }

    return [
      SliverPadding(
        // Room at the bottom for the Receive stock button.
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
        sliver: SliverToBoxAdapter(
          child: LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth >= 720
                ? _StockTable(balances: balances, onOpen: widget.onOpen)
                : _StockCards(balances: balances, onOpen: widget.onOpen),
          ),
        ),
      ),
    ];
  }
}

/// The status pill for a stock row: nothing when there is plenty.
Widget? _stockPill(StockBalance balance) {
  if (balance.quantityOnHand <= 0) return const Pill('Out of stock', tone: Tone.bad);
  if (balance.isLowStock) return const Pill('Low stock', tone: Tone.warn);
  return null;
}

/// Phones: one white panel with a row per product.
class _StockCards extends StatelessWidget {
  const _StockCards({required this.balances, required this.onOpen});

  final List<StockBalance> balances;
  final ValueChanged<StockBalance> onOpen;

  @override
  Widget build(BuildContext context) {
    return Panel(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (final (index, balance) in balances.indexed) ...[
            if (index > 0) const Divider(height: 1, indent: 16, endIndent: 16),
            InkWell(
              onTap: () => onOpen(balance),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            balance.product.description,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              balance.product.sku,
                              if (balance.reorderLevel != null)
                                'reorder at ${balance.reorderLevel}',
                            ].join(' · '),
                            style: const TextStyle(color: SnackifyColors.muted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        StockLevel(
                          quantity: balance.quantityOnHand,
                          isLow: balance.isLowStock,
                          large: true,
                        ),
                        if (_stockPill(balance) case final pill?) ...[
                          const SizedBox(height: 4),
                          pill,
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Wide screens: a table with the product code, levels and a status.
class _StockTable extends StatelessWidget {
  const _StockTable({required this.balances, required this.onOpen});

  final List<StockBalance> balances;
  final ValueChanged<StockBalance> onOpen;

  @override
  Widget build(BuildContext context) {
    return Panel(
      padding: EdgeInsets.zero,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: DataTable(
              showCheckboxColumn: false,
              columns: const [
                DataColumn(label: Text('CODE')),
                DataColumn(label: Text('PRODUCT')),
                DataColumn(label: Text('REORDER AT'), numeric: true),
                DataColumn(label: Text('ON HAND'), numeric: true),
                DataColumn(label: Text('STATUS')),
              ],
              rows: [
                for (final balance in balances)
                  DataRow(
                    onSelectChanged: (_) => onOpen(balance),
                    cells: [
                      DataCell(CodeText(balance.product.sku)),
                      DataCell(
                        Text(
                          balance.product.description,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      DataCell(
                        Text(
                          balance.reorderLevel == null ? '—' : '${balance.reorderLevel}',
                          style: const TextStyle(color: SnackifyColors.muted),
                        ),
                      ),
                      DataCell(
                        StockLevel(quantity: balance.quantityOnHand, isLow: balance.isLowStock),
                      ),
                      DataCell(_stockPill(balance) ?? const Pill('In stock', tone: Tone.good)),
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
