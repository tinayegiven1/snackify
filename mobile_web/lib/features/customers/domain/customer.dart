import '../../../core/config/app_config.dart';
import '../../auth/domain/app_user.dart';

/// A customer (shop, kiosk, ...) that receives dispatches and invoices.
class Customer {
  const Customer({
    required this.id,
    required this.code,
    required this.name,
    required this.phone,
    required this.address,
    required this.creditLimit,
    required this.isActive,
    this.organisationId,
  });

  factory Customer.fromJson(Map<String, dynamic> json) => Customer(
    id: json['id'] as String,
    code: json['code'] as String,
    name: json['name'] as String,
    phone: json['phone'] as String?,
    address: json['address'] as String?,
    creditLimit: json['creditLimit'] as String?,
    isActive: json['isActive'] as bool,
    organisationId: json['organisationId'] as String?,
  );

  final String id;
  final String code;
  final String name;
  final String? phone;
  final String? address;

  /// Exact decimal text in the base currency, or null when no limit is set.
  final String? creditLimit;
  final bool isActive;

  /// The subsidiary this customer record stands for, if any (decision D1).
  final String? organisationId;

  String? get formattedCreditLimit =>
      creditLimit == null ? null : '${AppConfig.currencyCode} $creditLimit';
}

/// Which customer fields a role may change. The server enforces the same rules (spec 5:
/// salespeople manage "permitted" customer information).
class CustomerPermissions {
  const CustomerPermissions._({
    required this.canAdd,
    required this.canEditDetails,
    required this.canEditCreditLimit,
    required this.canChangeActive,
  });

  /// Customers are no longer added on their own: each subsidiary brings its customer record
  /// (decision D1), so [canAdd] is always false.
  factory CustomerPermissions.forUser(AppUser user) => CustomerPermissions._(
    canAdd: false,
    canEditDetails: user.can('customer.edit_details'),
    canEditCreditLimit: user.can('customer.edit_credit_limit'),
    canChangeActive: user.can('customer.change_active'),
  );

  final bool canAdd;

  /// Code, name, phone and address.
  final bool canEditDetails;
  final bool canEditCreditLimit;
  final bool canChangeActive;

  bool get canEditAnything => canEditDetails || canEditCreditLimit || canChangeActive;
}
