import '../../auth/domain/app_user.dart';

/// A staff account, as admins see it in Staff.
class StaffMember {
  const StaffMember({
    required this.id,
    required this.username,
    required this.fullName,
    required this.role,
    required this.isActive,
    required this.lastSignInAt,
  });

  factory StaffMember.fromJson(Map<String, dynamic> json) => StaffMember(
    id: json['id'] as String,
    username: json['username'] as String,
    fullName: json['fullName'] as String,
    role: StaffRole.fromApi(json['role'] as String),
    isActive: json['isActive'] as bool,
    lastSignInAt: json['lastSignInAt'] == null
        ? null
        : DateTime.parse(json['lastSignInAt'] as String).toLocal(),
  );

  final String id;
  final String username;
  final String fullName;
  final StaffRole role;

  /// Deactivated accounts cannot sign in. Their history (dispatches, payments...) is kept.
  final bool isActive;

  /// When they last signed in, or null if they never have.
  final DateTime? lastSignInAt;
}

/// What each role may do, in a sentence, to help admins choose (spec section 5).
String roleDescription(StaffRole role) => switch (role) {
  StaffRole.admin =>
    'Everything, including staff accounts, products, prices, adjustments, reversals and '
        'voiding.',
  StaffRole.storekeeper =>
    'Receives stock, confirms dispatches, prints barcode labels and sees stock reports and '
        'forecasts.',
  StaffRole.salesperson => 'Adds customers and drafts dispatches.',
  StaffRole.accounts =>
    'Invoices, payments, balances, statements, credit limits, reports and forecasts.',
};

// The same rules the server applies.
final usernameFormat = RegExp(r'^[a-z0-9][a-z0-9._-]{2,31}$');
const minPasswordLength = 10;
const maxPasswordLength = 128;

/// Checks a new password the way the server does; returns a message, or null when it is fine.
String? checkNewPassword(String value) {
  if (value.isEmpty) return 'Required';
  if (value.length < minPasswordLength) return 'Use at least $minPasswordLength characters';
  if (value.length > maxPasswordLength) return 'Use at most $maxPasswordLength characters';
  return null;
}
