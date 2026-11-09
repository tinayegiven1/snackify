import '../../receipts/domain/receipt_models.dart';

/// Goods bought from suppliers: what finance recorded, so the warehouse can receive
/// against it.
enum PurchaseStatus {
  open('OPEN', 'Open'),
  cancelled('CANCELLED', 'Cancelled');

  const PurchaseStatus(this.code, this.label);

  final String code;
  final String label;

  static PurchaseStatus fromCode(String code) =>
      values.firstWhere((status) => status.code == code, orElse: () => open);
}

/// How much of a goods-bought list has arrived, from its goods-received notes.
enum ReceivingStatus {
  notReceived('NOT_RECEIVED', 'Not received'),
  partlyReceived('PARTLY_RECEIVED', 'Partly received'),
  received('RECEIVED', 'Received');

  const ReceivingStatus(this.code, this.label);

  final String code;
  final String label;

  static ReceivingStatus fromCode(String code) =>
      values.firstWhere((status) => status.code == code, orElse: () => notReceived);
}

/// The filters on the Goods Bought list (null: all).
enum PurchaseFilter {
  notReceived('NOT_RECEIVED', 'Not received'),
  partlyReceived('PARTLY_RECEIVED', 'Partly received'),
  received('RECEIVED', 'Received'),
  cancelled('CANCELLED', 'Cancelled');

  const PurchaseFilter(this.code, this.label);

  /// The `status` the API filters by.
  final String code;
  final String label;
}

class PurchaseSummary {
  const PurchaseSummary({
    required this.id,
    required this.purchaseNumber,
    required this.status,
    required this.receivingStatus,
    required this.owner,
    required this.supplier,
    required this.supplierInvoiceNumber,
    required this.purchaseDate,
    required this.currency,
    required this.total,
    required this.lineCount,
    required this.createdBy,
    this.documentCount = 0,
    this.documentsPending = 0,
  });

  factory PurchaseSummary.fromJson(Map<String, dynamic> json) => PurchaseSummary(
    id: json['id'] as String,
    purchaseNumber: json['purchaseNumber'] as String,
    status: PurchaseStatus.fromCode(json['status'] as String),
    receivingStatus: ReceivingStatus.fromCode(json['receivingStatus'] as String),
    owner: Ref.fromJson(json['owner'] as Map<String, dynamic>),
    supplier: json['supplier'] == null
        ? null
        : Ref.fromJson(json['supplier'] as Map<String, dynamic>),
    supplierInvoiceNumber: json['supplierInvoiceNumber'] as String?,
    purchaseDate: json['purchaseDate'] as String,
    currency: json['currency'] as String,
    total: json['total'] as String,
    lineCount: json['lineCount'] as int,
    createdBy: PersonRef.fromJson(json['createdBy'] as Map<String, dynamic>),
    documentCount: (json['documentCount'] as int?) ?? 0,
    documentsPending: (json['documentsPending'] as int?) ?? 0,
  );

  final String id;

  /// e.g. "GB000001".
  final String purchaseNumber;
  final PurchaseStatus status;
  final ReceivingStatus receivingStatus;

  /// Whose stock it is for: the Head Office or a subsidiary.
  final Ref owner;
  final Ref? supplier;
  final String? supplierInvoiceNumber;
  final String purchaseDate;
  final String currency;

  /// Exact decimal text, e.g. "57.50".
  final String total;
  final int lineCount;
  final PersonRef createdBy;

  /// Supplier documents (invoices, delivery notes) attached to the list.
  final int documentCount;

  /// Documents finance has not verified or rejected yet.
  final int documentsPending;

  bool get isCancelled => status == PurchaseStatus.cancelled;

  /// What the list's pill says: cancelled, or how much has arrived.
  String get statusLabel => isCancelled ? status.label : receivingStatus.label;
}

class PurchaseLine {
  const PurchaseLine({
    required this.id,
    required this.lineNumber,
    required this.productId,
    required this.productSku,
    required this.productDescription,
    required this.unit,
    required this.quantity,
    required this.unitCost,
    required this.lineTotal,
    required this.quantityReceived,
    required this.quantityOutstanding,
    required this.notes,
  });

  factory PurchaseLine.fromJson(Map<String, dynamic> json) {
    final product = json['product'] as Map<String, dynamic>;
    return PurchaseLine(
      id: json['id'] as String,
      lineNumber: json['lineNumber'] as int,
      productId: product['id'] as String,
      productSku: product['sku'] as String,
      productDescription: product['description'] as String,
      unit: Ref.fromJson(json['unit'] as Map<String, dynamic>),
      quantity: json['quantity'] as int,
      unitCost: json['unitCost'] as String,
      lineTotal: json['lineTotal'] as String,
      quantityReceived: json['quantityReceived'] as int,
      quantityOutstanding: json['quantityOutstanding'] as int,
      notes: json['notes'] as String?,
    );
  }

  final String id;
  final int lineNumber;
  final String productId;
  final String productSku;
  final String productDescription;
  final Ref unit;

  /// How many [unit]s were bought.
  final int quantity;
  final String unitCost;
  final String lineTotal;

  /// Received so far on goods-received notes waiting for verification, verified or posted.
  final int quantityReceived;
  final int quantityOutstanding;
  final String? notes;

  String get productLabel => '$productDescription ($productSku)';

  PurchaseLineInput toInput() => PurchaseLineInput(
    productId: productId,
    productLabel: productLabel,
    unitId: unit.id,
    unitLabel: unit.name,
    quantity: quantity,
    unitCost: unitCost,
    notes: notes,
  );
}

/// A goods-received note made from a goods-bought list.
class PurchaseReceipt {
  const PurchaseReceipt({
    required this.id,
    required this.grnNumber,
    required this.status,
    required this.receivedDate,
  });

  factory PurchaseReceipt.fromJson(Map<String, dynamic> json) => PurchaseReceipt(
    id: json['id'] as String,
    grnNumber: json['grnNumber'] as String,
    status: ReceiptStatus.fromCode(json['status'] as String),
    receivedDate: json['receivedDate'] as String,
  );

  final String id;
  final String grnNumber;
  final ReceiptStatus status;
  final String receivedDate;
}

class Purchase extends PurchaseSummary {
  const Purchase({
    required super.id,
    required super.purchaseNumber,
    required super.status,
    required super.receivingStatus,
    required super.owner,
    required super.supplier,
    required super.supplierInvoiceNumber,
    required super.purchaseDate,
    required super.currency,
    required super.total,
    required super.lineCount,
    required super.createdBy,
    super.documentCount,
    super.documentsPending,
    required this.notes,
    required this.cancelledBy,
    required this.cancelReason,
    required this.canChange,
    required this.canCancel,
    required this.lines,
    required this.receipts,
    this.documents = const [],
  });

  factory Purchase.fromJson(Map<String, dynamic> json) {
    final summary = PurchaseSummary.fromJson(json);
    return Purchase(
      id: summary.id,
      purchaseNumber: summary.purchaseNumber,
      status: summary.status,
      receivingStatus: summary.receivingStatus,
      owner: summary.owner,
      supplier: summary.supplier,
      supplierInvoiceNumber: summary.supplierInvoiceNumber,
      purchaseDate: summary.purchaseDate,
      currency: summary.currency,
      total: summary.total,
      lineCount: summary.lineCount,
      createdBy: summary.createdBy,
      documentCount: summary.documentCount,
      documentsPending: summary.documentsPending,
      notes: json['notes'] as String?,
      cancelledBy: PersonRef.maybe(json['cancelledBy']),
      cancelReason: json['cancelReason'] as String?,
      canChange: json['canChange'] as bool,
      canCancel: json['canCancel'] as bool,
      lines: [
        for (final line in json['lines'] as List)
          PurchaseLine.fromJson(line as Map<String, dynamic>),
      ],
      receipts: [
        for (final receipt in (json['receipts'] as List?) ?? const [])
          PurchaseReceipt.fromJson(receipt as Map<String, dynamic>),
      ],
      documents: [
        for (final document in (json['attachments'] as List?) ?? const [])
          ReceiptDocument.fromJson(document as Map<String, dynamic>),
      ],
    );
  }

  final String? notes;
  final PersonRef? cancelledBy;
  final String? cancelReason;

  /// False once any goods-received note was made from it.
  final bool canChange;
  final bool canCancel;
  final List<PurchaseLine> lines;

  /// Goods-received notes made from it, oldest first.
  final List<PurchaseReceipt> receipts;

  /// Supplier documents (invoices, delivery notes, photos), oldest first.
  final List<ReceiptDocument> documents;

  /// A verified document whose total differs from the list's total (compared in cents).
  bool get documentTotalMismatch {
    final listCents = decimalCents(total);
    return documents.any(
      (document) =>
          document.status == DocumentStatus.verified &&
          document.documentTotal != null &&
          decimalCents(document.documentTotal!) != listCents,
    );
  }

  /// Open, with something still to arrive.
  bool get canReceive => !isCancelled && receivingStatus != ReceivingStatus.received;

  /// The goods-received note to start from it: one line per bought line still outstanding,
  /// expecting all of it, for the storekeeper to correct to what actually arrived.
  ///
  /// With [arriving] (line id → quantity), only those lines, each expecting that quantity: what
  /// the storekeeper said arrived this time. The rest stays outstanding for a later delivery.
  ReceiptPrefill toReceiptPrefill({Map<String, int>? arriving}) => ReceiptPrefill(
    purchaseId: id,
    purchaseNumber: purchaseNumber,
    ownerId: owner.id,
    supplierId: supplier?.id,
    supplierInvoiceNumber: supplierInvoiceNumber,
    purchaseDate: purchaseDate,
    lines: [
      for (final line in lines)
        if ((arriving == null ? line.quantityOutstanding : (arriving[line.id] ?? 0))
            case final quantity when quantity > 0)
          (
            input: ReceiptLineInput(
              productId: line.productId,
              productLabel: line.productLabel,
              unitId: line.unit.id,
              quantityPurchased: quantity,
              quantityReceived: quantity,
              unitCost: line.unitCost,
              purchaseLineId: line.id,
            ),
            unitLabel: line.unit.name,
          ),
    ],
  );
}

/// One line as entered on the form.
class PurchaseLineInput {
  const PurchaseLineInput({
    required this.productId,
    required this.productLabel,
    required this.unitId,
    required this.unitLabel,
    required this.quantity,
    required this.unitCost,
    this.notes,
  });

  final String productId;

  /// Shown on the form only.
  final String productLabel;
  final String unitId;

  /// Shown on the form only.
  final String unitLabel;
  final int quantity;
  final String unitCost;
  final String? notes;

  /// [quantity] × [unitCost] in cents, rounded half up (the server's total is the final word).
  int get totalCents => lineTotalCents(quantity, unitCost);

  Map<String, Object?> toJson() => {
    'productId': productId,
    'unitId': unitId,
    'quantity': quantity,
    'unitCost': unitCost,
    'notes': notes,
  };
}

/// An amount such as "57.5" or "57.50" in whole cents (rounded half up past 2 decimals).
int decimalCents(String amount) => lineTotalCents(1, amount);

/// [quantity] × [unitCost] (up to 4 decimals) in whole cents, rounded half up.
int lineTotalCents(int quantity, String unitCost) {
  final parts = unitCost.trim().split('.');
  final whole = int.tryParse(parts[0]) ?? 0;
  final fraction = int.tryParse((parts.length > 1 ? parts[1] : '').padRight(4, '0')) ?? 0;
  return (quantity * (whole * 10000 + fraction) + 50) ~/ 100;
}

/// A goods-bought list as entered on the form.
class PurchaseInput {
  const PurchaseInput({
    required this.organisationId,
    required this.supplierId,
    required this.supplierInvoiceNumber,
    required this.purchaseDate,
    required this.notes,
    required this.lines,
  });

  final String? organisationId;
  final String? supplierId;
  final String? supplierInvoiceNumber;
  final String purchaseDate;
  final String? notes;
  final List<PurchaseLineInput> lines;

  Map<String, Object?> toJson() => {
    'organisationId': ?organisationId,
    'supplierId': supplierId,
    'supplierInvoiceNumber': supplierInvoiceNumber,
    'purchaseDate': purchaseDate,
    'notes': notes,
    'lines': [for (final line in lines) line.toJson()],
  };
}
