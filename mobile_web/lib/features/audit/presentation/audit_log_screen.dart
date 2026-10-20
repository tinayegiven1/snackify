import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/formatting/dates.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../data/audit_repository.dart';
import '../domain/audit_entry.dart';

/// Who did what and when: sign-ins, staff and role changes, and every sensitive action.
class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({super.key, required this.repository});

  final AuditRepository repository;

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  String _group = '';
  final List<AuditEntry> _entries = [];
  int _total = 0;
  bool _loading = true;
  String? _error;
  int _latestRequest = 0;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({required bool reset}) async {
    final request = ++_latestRequest;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) _entries.clear();
    });
    try {
      final page = await widget.repository.list(group: _group, offset: _entries.length);
      if (!mounted || request != _latestRequest) return;
      setState(() {
        _entries.addAll(page.entries);
        _total = page.total;
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
        SizedBox(
          height: 56,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            children: [
              for (final MapEntry(key: label, value: group) in auditGroups.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: _group == group,
                    onSelected: (_) {
                      setState(() => _group = group);
                      _load(reset: true);
                    },
                  ),
                ),
            ],
          ),
        ),
        if (_loading && _entries.isNotEmpty) const LinearProgressIndicator(),
        Expanded(child: _content()),
      ],
    );
  }

  Widget _content() {
    if (_error != null && _entries.isEmpty) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load the audit log',
        message: _error!,
        action: RetryButton(onPressed: () => _load(reset: true)),
      );
    }
    if (_loading && _entries.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_entries.isEmpty) {
      return const MessageView(
        icon: Icons.history,
        title: 'Nothing recorded yet',
        message: 'Actions appear here as staff sign in and make changes.',
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: ListView.separated(
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: _entries.length + 1,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            if (index == _entries.length) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: _entries.length < _total
                    ? OutlinedButton(
                        onPressed: _loading ? null : () => _load(reset: false),
                        child: Text('Show more (${_total - _entries.length} older)'),
                      )
                    : Text(
                        '$_total ${_total == 1 ? 'entry' : 'entries'}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
              );
            }
            return _EntryTile(entry: _entries[index]);
          },
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final AuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final time = entry.occurredAt;
    final when =
        '${formatApiDate(toApiDate(time))} ${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
    final who = [
      entry.actorName ?? 'Unknown or system',
      ?entry.organisationCode,
      ?entry.ipAddress,
    ].join(' · ');
    final details = entry.details.isEmpty ? null : jsonEncode(entry.details);
    return ListTile(
      title: Text(entry.actionLabel),
      subtitle: Text(
        [when, who, ?details].join('\n'),
        maxLines: details == null ? 2 : 4,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
    );
  }
}
