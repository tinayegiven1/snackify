import '../../../core/network/api_client.dart';
import '../domain/audit_entry.dart';

/// The audit log (permission audit.view), newest first.
class AuditRepository {
  AuditRepository(this._api);

  final ApiClient _api;

  static const pageSize = 50;

  /// [group] is an action prefix such as "stock", or empty for everything.
  Future<({List<AuditEntry> entries, int total})> list({String group = '', int offset = 0}) async {
    final query = Uri(
      queryParameters: {
        if (group.isNotEmpty) 'action': group,
        'limit': '$pageSize',
        'offset': '$offset',
      },
    ).query;
    final body = await _api.getJson('/api/v1/audit-logs?$query');
    return (
      entries: (body['entries'] as List)
          .map((item) => AuditEntry.fromJson(item as Map<String, dynamic>))
          .toList(),
      total: body['total'] as int,
    );
  }
}
