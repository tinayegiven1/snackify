import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/message_view.dart';
import '../../receipts/domain/receipt_models.dart';
import '../../receipts/presentation/receipt_editor_screen.dart';
import '../../receipts/presentation/receipt_services.dart';
import '../data/purchases_repository.dart';
import '../domain/purchase_models.dart';

/// Receives goods against a goods-bought list: fetches the list as it is now (it may have been
/// changed elsewhere), asks which goods arrived this time and how many, then opens the
/// goods-received note filled in with just those. Returns the saved note, or null when nothing
/// was saved. Problems (nothing left to receive, no connection) are thrown as [ApiException].
Future<GoodsReceipt?> receiveAgainstPurchase(
  BuildContext context, {
  required PurchasesRepository purchases,
  required ReceiptServices receiptServices,
  required String purchaseId,
}) async {
  final purchase = await purchases.get(purchaseId);
  if (!purchase.canReceive) {
    throw ApiException('Nothing is left to receive on ${purchase.purchaseNumber}.');
  }
  if (!context.mounted) return null;
  final arriving = await Navigator.of(context).push<Map<String, int>>(
    MaterialPageRoute(builder: (_) => ChooseArrivingGoodsScreen(purchase: purchase)),
  );
  if (arriving == null || !context.mounted) return null;
  return Navigator.of(context).push<GoodsReceipt>(
    MaterialPageRoute(
      builder: (_) => ReceiptEditorScreen(
        services: receiptServices,
        prefill: purchase.toReceiptPrefill(arriving: arriving),
      ),
    ),
  );
}

/// "What arrived?": each line still to come, ticked with its outstanding quantity; the
/// storekeeper unticks what did not come and changes quantities for a part delivery.
class ChooseArrivingGoodsScreen extends StatefulWidget {
  const ChooseArrivingGoodsScreen({super.key, required this.purchase});

  final Purchase purchase;

  @override
  State<ChooseArrivingGoodsScreen> createState() => _ChooseArrivingGoodsScreenState();
}

class _ChooseArrivingGoodsScreenState extends State<ChooseArrivingGoodsScreen> {
  late final List<PurchaseLine> _lines = [
    for (final line in widget.purchase.lines)
      if (line.quantityOutstanding > 0) line,
  ];
  late final Set<String> _ticked = {for (final line in _lines) line.id};
  late final Map<String, TextEditingController> _quantities = {
    for (final line in _lines) line.id: TextEditingController(text: '${line.quantityOutstanding}'),
  };
  String? _error;

  @override
  void dispose() {
    for (final controller in _quantities.values) {
      controller.dispose();
    }
    super.dispose();
  }

  int? _quantityOf(String lineId) => int.tryParse(_quantities[lineId]!.text.trim());

  void _continue() {
    final arriving = <String, int>{};
    for (final line in _lines) {
      if (!_ticked.contains(line.id)) continue;
      final quantity = _quantityOf(line.id);
      if (quantity == null || quantity < 1) {
        setState(() => _error = 'Enter how many ${line.productDescription} arrived (1 or more).');
        return;
      }
      arriving[line.id] = quantity;
    }
    if (arriving.isEmpty) {
      setState(() => _error = 'Tick at least one product that arrived.');
      return;
    }
    Navigator.of(context).pop(arriving);
  }

  @override
  Widget build(BuildContext context) {
    final purchase = widget.purchase;
    return Scaffold(
      appBar: AppBar(title: Text('Receive against ${purchase.purchaseNumber}')),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'What arrived this time? Untick what did not come, and change the quantity '
                    'for a part delivery. The rest stays waiting on the list.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  if (_error != null) ...[
                    ErrorBanner(message: _error!),
                    const SizedBox(height: 12),
                  ],
                  Card(
                    child: Column(
                      children: [
                        for (final (index, line) in _lines.indexed) ...[
                          if (index > 0) const Divider(height: 1),
                          _LineChoice(
                            line: line,
                            ticked: _ticked.contains(line.id),
                            quantity: _quantities[line.id]!,
                            onTicked: (ticked) => setState(() {
                              _error = null;
                              ticked ? _ticked.add(line.id) : _ticked.remove(line.id);
                            }),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                onPressed: _continue,
                icon: const Icon(Icons.arrow_forward),
                label: Text(
                  _ticked.isEmpty
                      ? 'Choose what arrived'
                      : 'Receive ${_ticked.length} product${_ticked.length == 1 ? '' : 's'}',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LineChoice extends StatelessWidget {
  const _LineChoice({
    required this.line,
    required this.ticked,
    required this.quantity,
    required this.onTicked,
  });

  final PurchaseLine line;
  final bool ticked;
  final TextEditingController quantity;
  final ValueChanged<bool> onTicked;

  @override
  Widget build(BuildContext context) {
    final unit = line.unit.name.toLowerCase();
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
      child: Row(
        children: [
          Checkbox(value: ticked, onChanged: (value) => onTicked(value ?? false)),
          Expanded(
            child: InkWell(
              onTap: () => onTicked(!ticked),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${line.productDescription} (${line.productSku})',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Bought ${line.quantity} $unit · Received ${line.quantityReceived} · '
                    'Still to come ${line.quantityOutstanding}',
                    style: const TextStyle(color: SnackifyColors.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 88,
            child: TextField(
              controller: quantity,
              enabled: ticked,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textAlign: TextAlign.end,
              decoration: const InputDecoration(labelText: 'Arrived'),
            ),
          ),
        ],
      ),
    );
  }
}
