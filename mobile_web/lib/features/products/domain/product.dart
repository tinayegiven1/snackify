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
    required this.reorderLevel,
    this.safetyStock = 0,
    required this.isActive,
    this.details,
    this.category,
    this.baseUnit = ProductUnit.pack,
    this.conversions = const [],
  });

  factory Product.fromJson(Map<String, dynamic> json) => Product(
    id: json['id'] as String,
    sku: json['sku'] as String,
    name: json['name'] as String,
    flavour: json['flavour'] as String,
    size: json['size'] as String,
    barcode: json['barcode'] as String?,
    defaultPrice: json['defaultPrice'] as String,
    reorderLevel: json['reorderLevel'] as int?,
    safetyStock: json['safetyStock'] as int? ?? 0,
    isActive: json['isActive'] as bool,
    details: json['description'] as String?,
    category: json['category'] == null
        ? null
        : ProductCategory.fromJson(json['category'] as Map<String, dynamic>),
    baseUnit: json['baseUnit'] == null
        ? ProductUnit.pack
        : ProductUnit.fromJson(json['baseUnit'] as Map<String, dynamic>),
    conversions: [
      for (final conversion in json['conversions'] as List? ?? const [])
        ProductUnit.fromJson(
          (conversion as Map<String, dynamic>)['unit'] as Map<String, dynamic>,
          baseQuantity: conversion['baseQuantity'] as int,
        ),
    ],
  );

  final String id;
  final String sku;
  final String name;
  final String flavour;
  final String size;
  final String? barcode;

  /// Exact decimal text from the server, e.g. "0.50". Kept as text so money is never rounded.
  final String defaultPrice;

  /// Stock level (in packs) at or below which the product counts as low; null for no alert.
  final int? reorderLevel;

  /// Packs to keep on top of forecast demand when suggesting how much to receive.
  final int safetyStock;
  final bool isActive;

  /// Free text about the product, e.g. "Thick-cut, 125 g" (StockFlow Stage 4).
  final String? details;
  final ProductCategory? category;

  /// The unit stock is counted in (normally packs).
  final ProductUnit baseUnit;

  /// Larger units it is bought in, e.g. 1 carton = 24 packs.
  final List<ProductUnit> conversions;

  /// Units a quantity may be entered in: the base unit first.
  List<ProductUnit> get units => [baseUnit, ...conversions];

  String get description => '$name — $flavour — $size';

  String get formattedPrice => '${AppConfig.currencyCode} $defaultPrice';
}

class ProductCategory {
  const ProductCategory({required this.id, required this.name});

  factory ProductCategory.fromJson(Map<String, dynamic> json) =>
      ProductCategory(id: json['id'] as String, name: json['name'] as String);

  final String id;
  final String name;
}

/// A unit of measure for one product, with how many base units it holds.
class ProductUnit {
  const ProductUnit({
    required this.id,
    required this.code,
    required this.name,
    this.baseQuantity = 1,
  });

  factory ProductUnit.fromJson(Map<String, dynamic> json, {int baseQuantity = 1}) => ProductUnit(
    id: json['id'] as String,
    code: json['code'] as String,
    name: json['name'] as String,
    baseQuantity: baseQuantity,
  );

  /// Used until the server says otherwise (older servers have no units).
  static const pack = ProductUnit(id: 'unit-pack', code: 'pack', name: 'Pack');

  final String id;
  final String code;
  final String name;

  /// Base units in one of this unit (1 for the base unit itself).
  final int baseQuantity;

  /// e.g. "Carton (24 packs)" or "Pack".
  String labelFor(ProductUnit base) =>
      baseQuantity == 1 ? name : '$name ($baseQuantity ${base.name.toLowerCase()}s)';
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
    this.reorderLevel,
    this.safetyStock = 0,
    this.isActive = true,
    this.details,
    this.categoryId,
  });

  final String sku;
  final String name;
  final String flavour;
  final String size;

  /// Null when the product has no barcode.
  final String? barcode;
  final String defaultPrice;
  final int? reorderLevel;
  final int safetyStock;
  final bool isActive;
  final String? details;
  final String? categoryId;

  Map<String, Object?> toJson() => {
    'sku': sku,
    'name': name,
    'flavour': flavour,
    'size': size,
    'barcode': barcode,
    'defaultPrice': defaultPrice,
    'reorderLevel': reorderLevel,
    'safetyStock': safetyStock,
    'description': details,
    'categoryId': categoryId,
  };
}
