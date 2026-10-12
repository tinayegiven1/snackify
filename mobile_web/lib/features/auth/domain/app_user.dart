/// Staff roles, matching the backend (spec section 5).
enum StaffRole {
  admin('Admin'),
  storekeeper('Storekeeper'),
  salesperson('Salesperson'),
  accounts('Accounts');

  const StaffRole(this.label);

  final String label;

  static StaffRole fromApi(String value) => StaffRole.values.firstWhere(
    (role) => role.name == value,
    orElse: () => StaffRole.salesperson,
  );
}

/// The signed-in staff member.
class AppUser {
  const AppUser({
    required this.id,
    required this.username,
    required this.fullName,
    required this.role,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
    id: json['id'] as String,
    username: json['username'] as String,
    fullName: json['fullName'] as String,
    role: StaffRole.fromApi(json['role'] as String),
  );

  final String id;
  final String username;
  final String fullName;
  final StaffRole role;

  /// Up to two initials for an avatar, e.g. "Tendai Moyo" -> "TM".
  String get initials {
    final parts = fullName.trim().split(RegExp(r'\s+')).where((part) => part.isNotEmpty);
    return parts.take(2).map((part) => part[0].toUpperCase()).join();
  }
}
