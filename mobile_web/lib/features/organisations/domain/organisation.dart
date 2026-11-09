import '../../../core/config/app_config.dart';

/// The Head Office or a subsidiary, with its contact and billing details. Subsidiaries are also
/// the customers that dispatches, invoices and payments are for.
class Organisation {
  const Organisation({
    required this.id,
    required this.code,
    required this.name,
    required this.isHeadOffice,
    required this.isActive,
    this.contactName,
    this.contactPhone,
    this.contactEmail,
    this.address,
    this.billingName,
    this.billingAddress,
    this.taxNumber,
    this.whatsappNumber,
    this.creditLimit,
  });

  factory Organisation.fromJson(Map<String, dynamic> json) => Organisation(
    id: json['id'] as String,
    code: json['code'] as String,
    name: json['name'] as String,
    isHeadOffice: json['type'] == 'HQ',
    isActive: json['isActive'] as bool,
    contactName: json['contactName'] as String?,
    contactPhone: json['contactPhone'] as String?,
    contactEmail: json['contactEmail'] as String?,
    address: json['address'] as String?,
    billingName: json['billingName'] as String?,
    billingAddress: json['billingAddress'] as String?,
    taxNumber: json['taxNumber'] as String?,
    whatsappNumber: json['whatsappNumber'] as String?,
    creditLimit: json['creditLimit'] as String?,
  );

  final String id;
  final String code;
  final String name;
  final bool isHeadOffice;
  final bool isActive;
  final String? contactName;
  final String? contactPhone;
  final String? contactEmail;
  final String? address;
  final String? billingName;
  final String? billingAddress;
  final String? taxNumber;

  /// Where approved goods-received notes are sent on WhatsApp.
  final String? whatsappNumber;

  /// Most it may owe at once, as exact decimal text in the base currency; null means no limit.
  final String? creditLimit;

  String get typeLabel => isHeadOffice ? 'Head Office' : 'Subsidiary';

  String? get formattedCreditLimit =>
      creditLimit == null ? null : '${AppConfig.currencyCode} $creditLimit';
}
