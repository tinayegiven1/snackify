/// One entry in the audit log: who did what, when, for which organisation, from where.
class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.occurredAt,
    required this.action,
    required this.actorName,
    required this.organisationCode,
    required this.details,
    required this.ipAddress,
  });

  factory AuditEntry.fromJson(Map<String, dynamic> json) => AuditEntry(
    id: json['id'] as String,
    occurredAt: DateTime.parse(json['occurredAt'] as String).toLocal(),
    action: json['action'] as String,
    actorName: (json['actor'] as Map<String, dynamic>?)?['fullName'] as String?,
    organisationCode: (json['organisation'] as Map<String, dynamic>?)?['code'] as String?,
    details: (json['details'] as Map<String, dynamic>?) ?? const {},
    ipAddress: json['ipAddress'] as String?,
  );

  final String id;
  final DateTime occurredAt;

  /// For example "user.created" or "auth.login_failed".
  final String action;
  final String? actorName;
  final String? organisationCode;
  final Map<String, dynamic> details;
  final String? ipAddress;

  /// "user.roles_changed" -> "User roles changed".
  String get actionLabel {
    final words = action.replaceAll('.', ' ').replaceAll('_', ' ');
    return words.isEmpty ? words : words[0].toUpperCase() + words.substring(1);
  }
}

/// Filter groups for the audit log screen, by the first part of the action.
const auditGroups = <String, String>{
  'All': '',
  'Sign-ins': 'auth',
  'Staff': 'user',
  'Organisations': 'organisation',
  'Roles': 'role',
  'Stock': 'stock',
  'Products': 'product',
  'Customers': 'customer',
  'Dispatches': 'dispatch',
  'Invoices': 'invoice',
  'Payments': 'payment',
};
