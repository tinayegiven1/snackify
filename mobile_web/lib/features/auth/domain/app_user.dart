/// The Head Office or a subsidiary, as shown with a user.
class OrganisationRef {
  const OrganisationRef({
    required this.id,
    required this.code,
    required this.name,
    required this.isHeadOffice,
  });

  factory OrganisationRef.fromJson(Map<String, dynamic> json) => OrganisationRef(
    id: json['id'] as String,
    code: json['code'] as String,
    name: json['name'] as String,
    isHeadOffice: json['type'] == 'HQ',
  );

  final String id;
  final String code;
  final String name;
  final bool isHeadOffice;
}

/// A role a user holds, e.g. HQ Warehouse Officer.
class RoleRef {
  const RoleRef({required this.code, required this.name});

  factory RoleRef.fromJson(Map<String, dynamic> json) =>
      RoleRef(code: json['code'] as String, name: json['name'] as String);

  final String code;
  final String name;
}

/// The signed-in staff member: who they are, where they work and what they may do.
///
/// What the app shows follows [permissions] (from all their roles); the server checks the same
/// permissions on every request, so hiding a button is never the only protection.
class AppUser {
  const AppUser({
    required this.id,
    required this.username,
    required this.fullName,
    required this.organisation,
    required this.roles,
    required this.permissions,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
    id: json['id'] as String,
    username: json['username'] as String,
    fullName: json['fullName'] as String,
    organisation: OrganisationRef.fromJson(json['organisation'] as Map<String, dynamic>),
    roles: [
      for (final role in json['roles'] as List) RoleRef.fromJson(role as Map<String, dynamic>),
    ],
    permissions: {for (final code in json['permissions'] as List) code as String},
  );

  final String id;
  final String username;
  final String fullName;
  final OrganisationRef organisation;
  final List<RoleRef> roles;
  final Set<String> permissions;

  /// True when one of the user's roles allows [permission], e.g. 'stock.receive'.
  bool can(String permission) => permissions.contains(permission);

  /// Head Office staff may see every organisation's records; a subsidiary's only their own.
  bool get seesAllOrganisations => organisation.isHeadOffice;

  /// "HQ Warehouse Officer, HQ Sales Officer".
  String get roleNames => roles.map((role) => role.name).join(', ');

  String get initials => initialsOf(fullName);
}

/// Up to two initials for an avatar, e.g. "Tendai Moyo" -> "TM".
String initialsOf(String fullName) {
  final parts = fullName.trim().split(RegExp(r'\s+')).where((part) => part.isNotEmpty);
  return parts.take(2).map((part) => part[0].toUpperCase()).join();
}
