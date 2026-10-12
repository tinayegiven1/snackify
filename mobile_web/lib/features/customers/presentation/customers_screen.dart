import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../data/customers_repository.dart';
import '../domain/customer.dart';
import 'customer_form_screen.dart';

/// Content width at which the list becomes a table.
const double _tableBreakpoint = 720;

/// Customers: everyone can search them; salespeople and admins add them; accounts staff
/// and admins set credit limits.
class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key, required this.repository, required this.permissions});

  final CustomersRepository repository;
  final CustomerPermissions permissions;

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  final _search = TextEditingController();
  Timer? _searchDelay;
  bool _includeInactive = false;
  int _latestRequest = 0;
  bool _loading = true;
  String? _error;
  ({List<Customer> customers, int total})? _page;

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

  Future<void> _openForm([Customer? customer]) async {
    // An earlier "Saved ..." message would otherwise cover the form's Save button.
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final saved = await Navigator.of(context).push<Customer>(
      MaterialPageRoute(
        builder: (_) => CustomerFormScreen(
          repository: widget.repository,
          permissions: widget.permissions,
          customer: customer,
        ),
      ),
    );
    if (saved == null || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Saved ${saved.name} (${saved.code})')));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: widget.permissions.canAdd
          ? FloatingActionButton.extended(
              onPressed: () => _openForm(),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add customer'),
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
        title: 'Could not load customers',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    final page = _page;
    if (page == null) return const Center(child: CircularProgressIndicator());
    if (page.customers.isEmpty) {
      final searching = _search.text.trim().isNotEmpty;
      return MessageView(
        icon: searching ? Icons.search_off : Icons.storefront_outlined,
        title: searching ? 'No customers match "${_search.text.trim()}"' : 'No customers yet',
        message: searching
            ? 'Check the spelling, or search by code or phone number.'
            : widget.permissions.canAdd
            ? 'Add your first customer with the Add customer button.'
            : 'A salesperson or admin can add customers.',
      );
    }

    final count = page.total == page.customers.length
        ? '${page.total} ${page.total == 1 ? 'customer' : 'customers'}'
        : 'Showing ${page.customers.length} of ${page.total} customers. Search to narrow the list.';
    final onTap = widget.permissions.canEditAnything ? _openForm : null;

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
                ? _CustomerTable(customers: page.customers, onTap: onTap)
                : _CustomerList(customers: page.customers, onTap: onTap),
          ),
        ],
      ),
    );
  }
}

class _CustomerList extends StatelessWidget {
  const _CustomerList({required this.customers, required this.onTap});

  final List<Customer> customers;
  final ValueChanged<Customer>? onTap;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: customers.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final customer = customers[index];
        return ListTile(
          title: Text(customer.name),
          subtitle: Text(
            [customer.code, ?customer.phone, ?customer.address].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (customer.formattedCreditLimit != null)
                Text('Limit ${customer.formattedCreditLimit}'),
              if (!customer.isActive) const StatusBadge('Inactive'),
            ],
          ),
          onTap: onTap == null ? null : () => onTap!(customer),
        );
      },
    );
  }
}

class _CustomerTable extends StatelessWidget {
  const _CustomerTable({required this.customers, required this.onTap});

  final List<Customer> customers;
  final ValueChanged<Customer>? onTap;

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
              DataColumn(label: Text('Code')),
              DataColumn(label: Text('Name')),
              DataColumn(label: Text('Phone')),
              DataColumn(label: Text('Address')),
              DataColumn(label: Text('Credit limit'), numeric: true),
              DataColumn(label: Text('Status')),
            ],
            rows: [
              for (final customer in customers)
                DataRow(
                  onSelectChanged: onTap == null ? null : (_) => onTap!(customer),
                  cells: [
                    DataCell(Text(customer.code)),
                    DataCell(Text(customer.name)),
                    DataCell(Text(customer.phone ?? '—')),
                    DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 260),
                        child: Text(customer.address ?? '—', overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    DataCell(Text(customer.formattedCreditLimit ?? 'None')),
                    DataCell(
                      customer.isActive ? const Text('Active') : const StatusBadge('Inactive'),
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
