/// The product a stock record belongs to.
class ProductSummary {
  const ProductSummary({
    required this.id,
    required this.sku,
    required this.name,
    required this.flavour,
    required this.size,
  });

  factory ProductSummary.fromJson(Map<String, dynamic> json) => ProductSummary(
    id: json['id'] as String,
    sku: json['sku'] as String,
    name: json['name'] as String,
    flavour: json['flavour'] as String,
    size: json['size'] as String,
  );

  final String id;
  final String sku;
  final String name;
  final String flavour;
  final String size;

  String get description => '$name — $flavour — $size';
}

/// Stock on hand for one product.
class StockBalance {
  const StockBalance({
    required this.product,
    required this.quantityOnHand,
    required this.reorderLevel,
    required this.isLowStock,
  });

  factory StockBalance.fromJson(Map<String, dynamic> json) => StockBalance(
    product: ProductSummary.fromJson(json['product'] as Map<String, dynamic>),
    quantityOnHand: json['quantityOnHand'] as int,
    reorderLevel: json['reorderLevel'] as int?,
    isLowStock: json['isLowStock'] as bool,
  );

  final ProductSummary product;
  final int quantityOnHand;
  final int? reorderLevel;
  final bool isLowStock;
}

/// A delivery of stock (or an opening balance).
class StockReceipt {
  const StockReceipt({
    required this.id,
    required this.product,
    required this.quantity,
    required this.receivedDate,
    required this.batchNumber,
    required this.expiryDate,
    required this.supplierReference,
    required this.isOpeningBalance,
    required this.receivedBy,
  });

  factory StockReceipt.fromJson(Map<String, dynamic> json) => StockReceipt(
    id: json['id'] as String,
    product: ProductSummary.fromJson(json['product'] as Map<String, dynamic>),
    quantity: json['quantity'] as int,
    receivedDate: json['receivedDate'] as String,
    batchNumber: json['batchNumber'] as String?,
    expiryDate: json['expiryDate'] as String?,
    supplierReference: json['supplierReference'] as String?,
    isOpeningBalance: json['isOpeningBalance'] as bool,
    receivedBy: (json['receivedBy'] as Map<String, dynamic>)['fullName'] as String,
  );

  final String id;
  final ProductSummary product;
  final int quantity;

  /// API date strings ("2026-10-12").
  final String receivedDate;
  final String? batchNumber;
  final String? expiryDate;
  final String? supplierReference;
  final bool isOpeningBalance;

  /// Full name of the staff member who recorded it.
  final String receivedBy;
}

/// One entry in a product's stock ledger.
class StockMovement {
  const StockMovement({
    required this.id,
    required this.type,
    required this.quantityDelta,
    required this.businessDate,
    required this.reference,
    required this.reason,
    required this.batchNumber,
    required this.createdBy,
    required this.balanceAfter,
  });

  factory StockMovement.fromJson(Map<String, dynamic> json) => StockMovement(
    id: json['id'] as String,
    type: json['type'] as String,
    quantityDelta: json['quantityDelta'] as int,
    businessDate: json['businessDate'] as String,
    reference: json['reference'] as String?,
    reason: json['reason'] as String?,
    batchNumber: json['batchNumber'] as String?,
    createdBy: (json['createdBy'] as Map<String, dynamic>)['fullName'] as String,
    balanceAfter: json['balanceAfter'] as int,
  );

  final String id;
  final String type;

  /// Positive adds stock, negative removes it.
  final int quantityDelta;
  final String businessDate;
  final String? reference;
  final String? reason;
  final String? batchNumber;
  final String createdBy;
  final int balanceAfter;

  String get typeLabel => switch (type) {
    'opening_balance' => 'Opening balance',
    'receipt' => 'Received',
    'dispatch' => 'Dispatched',
    'customer_return' => 'Customer return',
    'damage' => 'Damaged',
    'adjustment' => 'Correction',
    'reversal' => 'Reversal',
    _ => type,
  };
}

/// What a storekeeper fills in when stock arrives.
class ReceiptInput {
  const ReceiptInput({
    required this.productId,
    required this.quantity,
    required this.receivedDate,
    this.batchNumber,
    this.expiryDate,
    this.supplierReference,
    this.isOpeningBalance = false,
  });

  final String productId;
  final int quantity;
  final String receivedDate;
  final String? batchNumber;
  final String? expiryDate;
  final String? supplierReference;
  final bool isOpeningBalance;

  Map<String, Object?> toJson() => {
    'productId': productId,
    'quantity': quantity,
    'receivedDate': receivedDate,
    'batchNumber': batchNumber,
    'expiryDate': expiryDate,
    'supplierReference': supplierReference,
    'isOpeningBalance': isOpeningBalance,
  };
}
