import '../../auth/domain/app_user.dart';

/// A staff account, as admins see it under Users & Roles.
class StaffMember {
  const StaffMember({
    required this.id,
    required this.username,
    required this.fullName,
    required this.organisation,
    required this.roles,
    required this.isActive,
    required this.lastSignInAt,
  });

  factory StaffMember.fromJson(Map<String, dynamic> json) => StaffMember(
    id: json['id'] as String,
    username: json['username'] as String,
    fullName: json['fullName'] as String,
    organisation: OrganisationRef.fromJson(json['organisation'] as Map<String, dynamic>),
    roles: [
      for (final role in json['roles'] as List) RoleRef.fromJson(role as Map<String, dynamic>),
    ],
    isActive: json['isActive'] as bool,
    lastSignInAt: json['lastSignInAt'] == null
        ? null
        : DateTime.parse(json['lastSignInAt'] as String).toLocal(),
  );

  final String id;
  final String username;
  final String fullName;
  final OrganisationRef organisation;
  final List<RoleRef> roles;

  /// Deactivated accounts cannot sign in. Their history (dispatches, payments...) is kept.
  final bool isActive;

  /// When they last signed in, or null if they never have.
  final DateTime? lastSignInAt;

  List<String> get roleCodes => [for (final role in roles) role.code]..sort();
  String get roleNames => roles.map((role) => role.name).join(', ');
}

/// A role that can be given, with what it allows (from the server, so it matches what the
/// server enforces).
class RoleOption {
  const RoleOption({
    required this.code,
    required this.name,
    required this.description,
    required this.forHeadOffice,
  });

  factory RoleOption.fromJson(Map<String, dynamic> json) => RoleOption(
    code: json['code'] as String,
    name: json['name'] as String,
    description: json['description'] as String,
    forHeadOffice: json['organisationType'] == 'HQ',
  );

  final String code;
  final String name;
  final String description;

  /// Head Office roles; the others are for a subsidiary's staff.
  final bool forHeadOffice;
}

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
