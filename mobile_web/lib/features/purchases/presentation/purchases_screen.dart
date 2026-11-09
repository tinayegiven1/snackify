import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/formatting/dates.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../domain/purchase_models.dart';
import 'purchase_detail_screen.dart';
import 'purchase_editor_screen.dart';
import 'purchase_services.dart';

/// Goods bought from suppliers, newest first, filtered by how much has arrived. The
/// warehouse receives against them; finance records them.
class PurchasesScreen extends StatefulWidget {
  const PurchasesScreen({super.key, required this.services});

  final PurchaseServices services;

  @override
  State<PurchasesScreen> createState() => _PurchasesScreenState();
}

class _PurchasesScreenState extends State<PurchasesScreen> {
  final _search = TextEditingController();
  Timer? _searchDelay;
  PurchaseFilter? _filter;
  int _latestRequest = 0;
  List<PurchaseSummary>? _purchases;
  String? _error;
  bool _loading = false;

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
      final result = await widget.services.purchases.list(filter: _filter, search: _search.text);
      if (mounted && request == _latestRequest) setState(() => _purchases = result.purchases);
    } on ApiException catch (error) {
      if (mounted && request == _latestRequest) setState(() => _error = error.message);
    } finally {
      if (mounted && request == _latestRequest) setState(() => _loading = false);
    }
  }

  Future<void> _record() async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final saved = await Navigator.of(context).push<Purchase>(
      MaterialPageRoute(builder: (_) => PurchaseEditorScreen(services: widget.services)),
    );
    if (saved == null || !mounted) return;
    await _open(saved.id, note: 'Saved goods bought ${saved.purchaseNumber}.');
  }

  Future<void> _open(String id, {String? note}) async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PurchaseDetailScreen(services: widget.services, purchaseId: id, note: note),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: widget.services.canManage
          ? FloatingActionButton.extended(
              heroTag: 'record-goods-bought',
              onPressed: _record,
              icon: const Icon(Icons.add_shopping_cart),
              label: const Text('Record goods bought'),
            )
          : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: TextField(
              controller: _search,
              onChanged: (_) {
                _searchDelay?.cancel();
                _searchDelay = Timer(const Duration(milliseconds: 300), _load);
              },
              decoration: const InputDecoration(
                hintText: 'Search number, supplier or invoice',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                for (final filter in <PurchaseFilter?>[null, ...PurchaseFilter.values])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(filter?.label ?? 'All'),
                      selected: _filter == filter,
                      onSelected: (_) {
                        setState(() => _filter = filter);
                        _load();
                      },
                    ),
                  ),
              ],
            ),
          ),
          if (_loading && _purchases != null) const LinearProgressIndicator(),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  Widget _content() {
    if (_error != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load goods bought',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    final purchases = _purchases;
    if (purchases == null) return const Center(child: CircularProgressIndicator());
    if (purchases.isEmpty) {
      return MessageView(
        icon: Icons.shopping_bag_outlined,
        title: 'No goods bought',
        message: _filter != null || _search.text.trim().isNotEmpty
            ? 'None match.'
            : widget.services.canManage
            ? 'Lists recorded with "Record goods bought" appear here.'
            : 'Lists of goods bought appear here once finance records them.',
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 88),
          children: [
            for (final purchase in purchases) ...[
              ListTile(
                title: Text(
                  [
                    purchase.purchaseNumber,
                    ?purchase.supplier?.name,
                    ?purchase.supplierInvoiceNumber,
                  ].join(' · '),
                ),
                subtitle: Text(
                  [
                    '${formatApiDate(purchase.purchaseDate)} · ${purchase.owner.name}',
                    '${purchase.currency} ${purchase.total} · ${purchase.lineCount} line(s)',
                  ].join('\n'),
                ),
                isThreeLine: true,
                trailing: PurchaseStatusPill(purchase),
                onTap: () => _open(purchase.id),
              ),
              const Divider(height: 1),
            ],
          ],
        ),
      ),
    );
  }
}

/// Cancelled, or how much of a list has arrived.
class PurchaseStatusPill extends StatelessWidget {
  const PurchaseStatusPill(this.purchase, {super.key});

  final PurchaseSummary purchase;

  @override
  Widget build(BuildContext context) {
    final tone = purchase.isCancelled
        ? Tone.bad
        : switch (purchase.receivingStatus) {
            ReceivingStatus.notReceived => Tone.info,
            ReceivingStatus.partlyReceived => Tone.warn,
            ReceivingStatus.received => Tone.good,
          };
    return Pill(purchase.statusLabel, tone: tone);
  }
}
