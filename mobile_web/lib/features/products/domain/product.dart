import '../../../core/config/app_config.dart';

/// A sellable variation, e.g. "Potato Crisps — BBQ — Small".
class Product {
  const Product({
    required this.id,
    required this.sku,
    required this.name,
    required this.flavour,
    required this.size,
    required this.barcode,
    required this.defaultPrice,
    required this.isActive,
  });

  factory Product.fromJson(Map<String, dynamic> json) => Product(
    id: json['id'] as String,
    sku: json['sku'] as String,
    name: json['name'] as String,
    flavour: json['flavour'] as String,
    size: json['size'] as String,
    barcode: json['barcode'] as String?,
    defaultPrice: json['defaultPrice'] as String,
    isActive: json['isActive'] as bool,
  );

  final String id;
  final String sku;
  final String name;
  final String flavour;
  final String size;
  final String? barcode;

  /// Exact decimal text from the server, e.g. "0.50". Kept as text so money is never rounded.
  final String defaultPrice;
  final bool isActive;

  String get description => '$name — $flavour — $size';

  String get formattedPrice => '${AppConfig.currencyCode} $defaultPrice';
}

/// The fields an admin fills in to add or edit a product.
class ProductInput {
  const ProductInput({
    required this.sku,
    required this.name,
    required this.flavour,
    required this.size,
    required this.barcode,
    required this.defaultPrice,
    this.isActive = true,
  });

  final String sku;
  final String name;
  final String flavour;
  final String size;

  /// Null when the product has no barcode.
  final String? barcode;
  final String defaultPrice;
  final bool isActive;

  Map<String, Object?> toJson() => {
    'sku': sku,
    'name': name,
    'flavour': flavour,
    'size': size,
    'barcode': barcode,
    'defaultPrice': defaultPrice,
  };
}
