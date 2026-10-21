/// The lists products and goods-received notes refer to (StockFlow Stage 4). The server
/// describes them all the same way, so one screen manages them.
enum CatalogueKind {
  suppliers(
    path: 'suppliers',
    title: 'Suppliers',
    singular: 'supplier',
    permission: 'supplier.manage',
    fields: [
      CatalogueField('code', 'Code', required: true, maxLength: 20, upperCase: true),
      CatalogueField('name', 'Name', required: true, maxLength: 120),
      CatalogueField('contactName', 'Contact person', maxLength: 120),
      CatalogueField('phone', 'Phone', maxLength: 30, phone: true),
      CatalogueField('email', 'Email', maxLength: 254, email: true),
      CatalogueField('address', 'Address', maxLength: 300),
    ],
  ),
  categories(
    path: 'categories',
    title: 'Categories',
    singular: 'category',
    permission: 'catalogue.manage',
    fields: [CatalogueField('name', 'Name', required: true, maxLength: 60)],
  ),
  warehouses(
    path: 'warehouses',
    title: 'Warehouses',
    singular: 'warehouse',
    permission: 'catalogue.manage',
    fields: [
      CatalogueField('code', 'Code', required: true, maxLength: 20, upperCase: true),
      CatalogueField('name', 'Name', required: true, maxLength: 120),
      CatalogueField('address', 'Address', maxLength: 300),
    ],
  ),
  units(
    path: 'units',
    title: 'Units',
    singular: 'unit',
    permission: 'catalogue.manage',
    fields: [
      CatalogueField('code', 'Code (e.g. carton)', required: true, maxLength: 20),
      CatalogueField('name', 'Name', required: true, maxLength: 40),
    ],
  );

  const CatalogueKind({
    required this.path,
    required this.title,
    required this.singular,
    required this.permission,
    required this.fields,
  });

  /// The API path under /api/v1/.
  final String path;
  final String title;
  final String singular;

  /// Needed to add or change entries (everyone signed in may read them).
  final String permission;
  final List<CatalogueField> fields;
}

/// One editable field of a catalogue entry.
class CatalogueField {
  const CatalogueField(
    this.key,
    this.label, {
    this.required = false,
    required this.maxLength,
    this.upperCase = false,
    this.phone = false,
    this.email = false,
  });

  final String key;
  final String label;
  final bool required;
  final int maxLength;
  final bool upperCase;
  final bool phone;
  final bool email;
}

/// A supplier, category, warehouse or unit as the server returns it.
class CatalogueItem {
  const CatalogueItem({
    required this.id,
    required this.values,
    required this.isActive,
    this.isDefault = false,
  });

  factory CatalogueItem.fromJson(Map<String, dynamic> json) => CatalogueItem(
    id: json['id'] as String,
    values: json,
    isActive: json['isActive'] as bool? ?? true,
    isDefault: json['isDefault'] as bool? ?? false,
  );

  final String id;

  /// Every field the server sent, e.g. {'code': 'SUP-01', 'name': 'Harare Potato Co-op'}.
  final Map<String, dynamic> values;
  final bool isActive;

  /// The default warehouse, which always stays active.
  final bool isDefault;

  String get name => values['name'] as String? ?? '';
  String? get code => values['code'] as String?;

  /// e.g. "Harare Potato Co-op (SUP-01)".
  String get label => code == null ? name : '$name ($code)';
}
