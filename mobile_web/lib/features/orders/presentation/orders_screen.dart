import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/formatting/dates.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/message_view.dart';
import '../../organisations/domain/organisation.dart';
import '../domain/order_models.dart';
import 'order_detail_screen.dart';
import 'order_editor_screen.dart';
import 'order_services.dart';

/// Orders the user may see: a subsidiary its own; the Head Office every subsidiary's, as a
/// review queue filtered by subsidiary, status and price exceptions.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key, required this.services});

  final OrderServices services;

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  final _search = TextEditingController();
  Timer? _searchDelay;
  OrderStatus? _status;
  String? _organisationId;
  bool _exceptionsOnly = false;
  List<Organisation>? _subsidiaries;
  List<OrderSummary>? _orders;
  String? _error;
  bool _loading = false;
  int _latest = 0;

  OrderServices get _services => widget.services;

  @override
  void initState() {
    super.initState();
    if (_services.seesAll) {
      // The Head Office's reviewers start with what waits for them.
      if (_services.canPrice || _services.canDecide) _status = OrderStatus.submitted;
      _services.organisations.list().then((organisations) {
        if (mounted) {
          setState(() => _subsidiaries = organisations.where((o) => !o.isHeadOffice).toList());
        }
      }, onError: (Object _) {});
    }
    _load();
  }

  @override
  void dispose() {
    _searchDelay?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_latest;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _services.orders.list(
        status: _status,
        organisationId: _organisationId,
        priceExceptionOnly: _exceptionsOnly,
        search: _search.text,
      );
      if (mounted && request == _latest) setState(() => _orders = result.orders);
    } on ApiException catch (error) {
      if (mounted && request == _latest) setState(() => _error = error.message);
    } finally {
      if (mounted && request == _latest) setState(() => _loading = false);
    }
  }

  Future<void> _newOrder() async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final order = await Navigator.of(context).push<SubsidiaryOrder>(
      MaterialPageRoute(builder: (_) => OrderEditorScreen(services: _services)),
    );
    if (order == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          order.status == OrderStatus.draft
              ? 'Saved draft ${order.orderNumber}.'
              : 'Submitted ${order.orderNumber} to the Head Office.',
        ),
      ),
    );
    _load();
  }

  Future<void> _open(OrderSummary order) async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => OrderDetailScreen(services: _services, orderId: order.id),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final subsidiaries = _subsidiaries;
    return Scaffold(
      floatingActionButton: _services.canCreate
          ? FloatingActionButton.extended(
              heroTag: 'new-order',
              onPressed: _newOrder,
              icon: const Icon(Icons.add_shopping_cart),
              label: const Text('New order'),
            )
          : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _search,
                    onChanged: (_) {
                      _searchDelay?.cancel();
                      _searchDelay = Timer(const Duration(milliseconds: 300), _load);
                    },
                    decoration: const InputDecoration(
                      hintText: 'Order number',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                if (subsidiaries != null)
                  SizedBox(
                    width: 240,
                    child: DropdownButtonFormField<String?>(
                      initialValue: _organisationId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Subsidiary',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('All subsidiaries')),
                        for (final subsidiary in subsidiaries)
                          DropdownMenuItem(value: subsidiary.id, child: Text(subsidiary.name)),
                      ],
                      onChanged: (value) {
                        setState(() => _organisationId = value);
                        _load();
                      },
                    ),
                  ),
                if (_services.seesAll)
                  FilterChip(
                    label: const Text('Price exceptions'),
                    selected: _exceptionsOnly,
                    onSelected: (value) {
                      setState(() => _exceptionsOnly = value);
                      _load();
                    },
                  ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                for (final status in <OrderStatus?>[null, ...OrderStatus.filters])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(status?.label ?? 'All'),
                      selected: _status == status,
                      onSelected: (_) {
                        setState(() => _status = status);
                        _load();
                      },
                    ),
                  ),
              ],
            ),
          ),
          if (_loading && _orders != null) const LinearProgressIndicator(),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  Widget _content() {
    if (_error != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load orders',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    final orders = _orders;
    if (orders == null) return const Center(child: CircularProgressIndicator());
    if (orders.isEmpty) {
      return MessageView(
        icon: Icons.shopping_cart_outlined,
        title: 'No orders',
        message: _services.canCreate
            ? 'Start one with "New order".'
            : 'Orders from subsidiaries appear here.',
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 88),
          children: [
            for (final order in orders) ...[
              ListTile(
                title: Text('${order.orderNumber} · ${order.organisation.name}'),
                subtitle: Text(
                  [
                    'Ordered ${formatApiDate(order.orderDate)}'
                        '${order.requiredDate == null ? '' : ' · needed by ${formatApiDate(order.requiredDate!)}'}',
                    '${order.lineCount} line(s) · expected ${order.currency} ${order.expectedTotal}'
                        ' · max ${order.maximumTotal}'
                        '${order.actualTotal == null ? '' : ' · actual ${order.actualTotal}'}',
                    if (order.priceException) 'Price above maximum',
                  ].join('\n'),
                ),
                isThreeLine: true,
                trailing: OrderStatusBadge(order.status),
                onTap: () => _open(order),
              ),
              const Divider(height: 1),
            ],
          ],
        ),
      ),
    );
  }
}

class OrderStatusBadge extends StatelessWidget {
  const OrderStatusBadge(this.status, {super.key});

  final OrderStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return switch (status) {
      OrderStatus.approved => StatusBadge(
        status.label,
        color: SnackifyColors.success.withValues(alpha: 0.15),
        textColor: SnackifyColors.success,
      ),
      OrderStatus.rejected || OrderStatus.cancelled => StatusBadge(
        status.label,
        color: colors.errorContainer,
        textColor: colors.onErrorContainer,
      ),
      OrderStatus.submitted || OrderStatus.underReview => StatusBadge(
        status.label,
        color: colors.tertiaryContainer,
        textColor: colors.onTertiaryContainer,
      ),
      _ => StatusBadge(status.label),
    };
  }
}
