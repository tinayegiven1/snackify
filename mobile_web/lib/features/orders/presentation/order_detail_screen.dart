import 'package:flutter/material.dart';

import '../../../core/files/pdf_sharer.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../domain/order_models.dart';
import 'order_editor_screen.dart';
import 'order_services.dart';
import 'orders_screen.dart' show OrderStatusBadge;

/// One order: its lines with expected, maximum and actual prices, the totals, the history and
/// what the user may do next. Every decision asks for confirmation first.
class OrderDetailScreen extends StatefulWidget {
  const OrderDetailScreen({super.key, required this.services, required this.orderId});

  final OrderServices services;
  final String orderId;

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  SubsidiaryOrder? _order;
  String? _loadError;
  String? _error;

  /// What the last action did, shown at the top (a snackbar would cover the buttons).
  String? _note;
  bool _busy = false;

  OrderServices get _services => widget.services;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final order = await _services.orders.get(widget.orderId);
      if (mounted) setState(() => _order = order);
    } on ApiException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    }
  }

  Future<void> _run(Future<SubsidiaryOrder> Function() action, String done) async {
    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });
    try {
      final order = await action();
      if (!mounted) return;
      setState(() {
        _order = order;
        _note = done;
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Asks to confirm an action; with [commentLabel], also for a comment (required unless
  /// [commentOptional]). Returns null when cancelled, otherwise the comment ('' when none).
  Future<String?> _confirm({
    required String title,
    required String message,
    required String action,
    String? commentLabel,
    bool commentOptional = false,
  }) {
    final comment = TextEditingController();
    final formKey = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(message),
              if (commentLabel != null) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: comment,
                  autofocus: true,
                  maxLength: 1000,
                  maxLines: 3,
                  minLines: 1,
                  decoration: InputDecoration(
                    labelText: commentLabel,
                    border: const OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final text = (value ?? '').trim();
                    if (text.isEmpty && commentOptional) return null;
                    return text.length < 3 ? 'Explain in a few words' : null;
                  },
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Go back')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) Navigator.pop(context, comment.text.trim());
            },
            child: Text(action),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(SubsidiaryOrder order) async {
    final saved = await Navigator.of(context).push<SubsidiaryOrder>(
      MaterialPageRoute(
        builder: (_) => OrderEditorScreen(services: _services, order: order),
      ),
    );
    if (saved != null && mounted) {
      setState(() {
        _order = saved;
        _note = saved.status == OrderStatus.draft
            ? 'Saved draft ${saved.orderNumber}.'
            : 'Submitted ${saved.orderNumber} to the Head Office.';
      });
    }
  }

  Future<void> _submit(SubsidiaryOrder order) async {
    final ok = await _confirm(
      title: 'Submit order?',
      message:
          'The Head Office will review it and set the actual prices. You can cancel it until '
          'the review starts, but not change it.',
      action: 'Submit',
    );
    if (ok == null) return;
    await _run(
      () => _services.orders.submit(order.id),
      'Submitted ${order.orderNumber} to the Head Office.',
    );
  }

  Future<void> _cancel(SubsidiaryOrder order) async {
    final reason = await _confirm(
      title: 'Cancel order?',
      message: 'The order is kept, marked as cancelled.',
      action: 'Cancel order',
      commentLabel: 'Reason',
    );
    if (reason == null) return;
    await _run(() => _services.orders.cancel(order.id, reason), 'Cancelled ${order.orderNumber}.');
  }

  Future<void> _setPrices(SubsidiaryOrder order) async {
    final prices =
        await showDialog<List<({String itemId, String actualUnitPrice, String? comment})>>(
          context: context,
          builder: (_) => _PricesDialog(order: order),
        );
    if (prices == null || prices.isEmpty) return;
    await _run(() => _services.orders.setPrices(order.id, prices), 'Actual prices saved.');
  }

  Future<void> _approve(SubsidiaryOrder order) async {
    final exception = order.priceException;
    final comment = await _confirm(
      title: 'Approve order?',
      message: exception
          ? 'An actual price is above the maximum ${order.organisation.name} accepts. Approving '
                'it is a price exception: say why.'
          : 'Approve ${order.orderNumber} for ${order.organisation.name} at '
                '${order.currency} ${order.actualTotal}.',
      action: 'Approve',
      commentLabel: exception ? 'Why the higher price is approved' : 'Comment (optional)',
      commentOptional: !exception,
    );
    if (comment == null) return;
    await _run(
      () => _services.orders.approve(order.id, comment: comment.isEmpty ? null : comment),
      'Approved ${order.orderNumber}.',
    );
  }

  Future<void> _reject(SubsidiaryOrder order) async {
    final comment = await _confirm(
      title: 'Reject order?',
      message: '${order.organisation.name} will see your reason.',
      action: 'Reject',
      commentLabel: 'Reason',
    );
    if (comment == null) return;
    await _run(() => _services.orders.reject(order.id, comment), 'Rejected ${order.orderNumber}.');
  }

  Future<void> _downloadPdf(SubsidiaryOrder order) async {
    setState(() => _error = null);
    try {
      await _services.sharePdf(await _services.orders.pdf(order.id), '${order.orderNumber}.pdf');
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = _order;
    return Scaffold(
      appBar: AppBar(
        title: Text(order == null ? 'Order' : 'Order ${order.orderNumber}'),
        actions: [
          if (order != null)
            IconButton(
              tooltip: sharePdfLabel,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              onPressed: () => _downloadPdf(order),
            ),
        ],
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loadError != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load the order',
        message: _loadError!,
        action: RetryButton(onPressed: _load),
      );
    }
    final order = _order;
    if (order == null) return const Center(child: CircularProgressIndicator());
    final theme = Theme.of(context);
    final status = order.status;
    String money(String amount) => '${order.currency} $amount';
    final reviewable = status == OrderStatus.submitted || status == OrderStatus.underReview;
    final ownOrder = _services.canCreate && !_services.seesAll;

    final actions = <Widget>[
      if (status == OrderStatus.draft && _services.canCreate) ...[
        OutlinedButton(
          onPressed: _busy ? null : () => _cancel(order),
          child: const Text('Cancel order'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _edit(order),
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Change'),
        ),
        FilledButton(onPressed: _busy ? null : () => _submit(order), child: const Text('Submit')),
      ],
      if (status == OrderStatus.submitted && ownOrder)
        OutlinedButton(
          onPressed: _busy ? null : () => _cancel(order),
          child: const Text('Cancel order'),
        ),
      if (status == OrderStatus.submitted && _services.canPrice)
        OutlinedButton(
          onPressed: _busy
              ? null
              : () => _run(
                  () => _services.orders.startReview(order.id),
                  'Review started: ${order.organisation.name} can no longer cancel it.',
                ),
          child: const Text('Start review'),
        ),
      if (reviewable && _services.canPrice)
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _setPrices(order),
          icon: const Icon(Icons.price_change_outlined),
          label: const Text('Set actual prices'),
        ),
      if (reviewable && _services.canDecide)
        OutlinedButton(onPressed: _busy ? null : () => _reject(order), child: const Text('Reject')),
      if (status == OrderStatus.underReview && _services.canDecide)
        FilledButton(
          onPressed: _busy || (order.priceException && !_services.canApproveException)
              ? null
              : () => _approve(order),
          child: const Text('Approve'),
        ),
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (_error != null) ...[ErrorBanner(message: _error!), const SizedBox(height: 12)],
                if (_note != null) ...[SuccessBanner(message: _note!), const SizedBox(height: 12)],
                Row(
                  children: [
                    OrderStatusBadge(status),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${order.organisation.name} · ordered ${formatApiDate(order.orderDate)}'
                        '${order.requiredDate == null ? '' : ' · needed by ${formatApiDate(order.requiredDate!)}'}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
                if (order.priceException) ...[
                  const SizedBox(height: 12),
                  ErrorBanner(
                    message: order.priceExceptionApproved
                        ? 'A price above the maximum was approved as a price exception.'
                        : _services.canDecide && !_services.canApproveException
                        ? 'An actual price is above the maximum. Only someone allowed to approve '
                              'price exceptions can approve this order.'
                        : 'An actual price is above the maximum the subsidiary accepts (price '
                              'exception).',
                  ),
                ],
                const SizedBox(height: 16),
                Text('Products', style: theme.textTheme.titleMedium),
                for (final line in order.lines) _LineTile(line: line, money: money),
                const Divider(),
                _Totals(order: order, money: money),
                if (order.notes != null) ...[
                  const SizedBox(height: 12),
                  Text('Notes: ${order.notes}'),
                ],
                if (order.decisionComment != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${status == OrderStatus.rejected ? 'Rejected' : 'Approved'} by '
                    '${order.decidedBy?.fullName}: ${order.decisionComment}',
                  ),
                ],
                if (order.cancelReason != null) ...[
                  const SizedBox(height: 8),
                  Text('Cancelled: ${order.cancelReason}'),
                ],
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 12,
                    runSpacing: 12,
                    children: actions,
                  ),
                ],
                const SizedBox(height: 24),
                Text('History', style: theme.textTheme.titleMedium),
                for (final entry in order.history)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.history, size: 20),
                    title: Text(
                      entry.fromStatus == null
                          ? 'Created as ${entry.toStatus.label.toLowerCase()}'
                          // Plain words: the web font has no arrow character.
                          : '${entry.toStatus.label} (was ${entry.fromStatus!.label.toLowerCase()})',
                    ),
                    subtitle: Text(
                      [
                        '${entry.changedBy.fullName} · ${_when(entry.changedAt)}',
                        ?entry.comment,
                      ].join('\n'),
                    ),
                  ),
                for (final change in order.changes)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.price_change_outlined, size: 20),
                    title: Text(
                      change.oldValue == null
                          ? 'Line ${change.lineNumber}: actual price set to ${change.newValue}'
                          : 'Line ${change.lineNumber}: actual price changed from '
                                '${change.oldValue} to ${change.newValue}',
                    ),
                    subtitle: Text(
                      [
                        '${change.changedBy.fullName} · ${_when(change.changedAt)}',
                        ?change.comment,
                      ].join('\n'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _when(DateTime at) {
    final local = at.toLocal();
    final time =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    return '${formatApiDate(toApiDate(local))} $time';
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({required this.line, required this.money});

  final OrderLine line;
  final String Function(String amount) money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = line.hqAvailable;
    final unit = line.unit.name.toLowerCase();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${line.productDescription} (${line.productSku})',
            style: theme.textTheme.titleSmall,
          ),
          Text('${line.requestedQuantity} $unit'),
          const SizedBox(height: 4),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              Text('Expected ${money(line.expectedUnitPrice)} = ${money(line.expectedLineTotal)}'),
              Text('Maximum ${money(line.maximumUnitPrice)} = ${money(line.maximumLineTotal)}'),
              Text(
                line.actualUnitPrice == null
                    ? 'Actual: not set'
                    : 'Actual ${money(line.actualUnitPrice!)} = ${money(line.actualLineTotal!)}',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: line.priceException ? theme.colorScheme.error : null,
                ),
              ),
            ],
          ),
          if (line.priceException)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: StatusBadge(
                'Above maximum',
                color: theme.colorScheme.errorContainer,
                textColor: theme.colorScheme.onErrorContainer,
              ),
            ),
          if (available != null)
            Text(
              available >= line.baseQuantity
                  ? 'Head Office has $available in stock (needs ${line.baseQuantity}).'
                  : 'Backorder: Head Office has only $available of ${line.baseQuantity}.',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.order, required this.money});

  final SubsidiaryOrder order;
  final String Function(String amount) money;

  @override
  Widget build(BuildContext context) {
    final rows = [
      ('Expected total', money(order.expectedTotal)),
      ('Maximum total', money(order.maximumTotal)),
      ('Actual total', order.actualTotal == null ? 'Not priced yet' : money(order.actualTotal!)),
    ];
    return Column(
      children: [
        for (final (label, value) in rows)
          Row(
            children: [
              Expanded(child: Text(label)),
              Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
      ],
    );
  }
}

typedef _Price = ({String itemId, String actualUnitPrice, String? comment});

/// The Head Office sets each line's actual price; lines left unchanged are not sent.
class _PricesDialog extends StatefulWidget {
  const _PricesDialog({required this.order});

  final SubsidiaryOrder order;

  @override
  State<_PricesDialog> createState() => _PricesDialogState();
}

class _PricesDialogState extends State<_PricesDialog> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _prices = {
    for (final line in widget.order.lines)
      line.id: TextEditingController(text: line.actualUnitPrice ?? line.expectedUnitPrice),
  };
  final _comment = TextEditingController();

  @override
  void dispose() {
    for (final controller in [..._prices.values, _comment]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    return AlertDialog(
      title: const Text('Set actual prices'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final line in order.lines) ...[
                  Text(
                    '${line.productDescription} · ${line.requestedQuantity} '
                    '${line.unit.name.toLowerCase()}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    'Expected ${line.expectedUnitPrice} · maximum ${line.maximumUnitPrice}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _prices[line.id],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Actual price each (${order.currency})',
                      border: const OutlineInputBorder(),
                    ),
                    validator: (value) =>
                        RegExp(r'^\d{1,10}(\.\d{1,2})?$').hasMatch((value ?? '').trim())
                        ? null
                        : 'Use an amount like 0.50',
                  ),
                  const SizedBox(height: 14),
                ],
                TextFormField(
                  controller: _comment,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    labelText: 'Comment on the change (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            final comment = _comment.text.trim();
            Navigator.pop<List<_Price>>(context, [
              for (final line in order.lines)
                if (_prices[line.id]!.text.trim() != line.actualUnitPrice)
                  (
                    itemId: line.id,
                    actualUnitPrice: _prices[line.id]!.text.trim(),
                    comment: comment.isEmpty ? null : comment,
                  ),
            ]);
          },
          child: const Text('Save prices'),
        ),
      ],
    );
  }
}
