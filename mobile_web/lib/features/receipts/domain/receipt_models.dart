/// Goods-received notes (GRNs): a delivery, its supplier documents and its stock
/// (StockFlow Stage 4).
enum ReceiptStatus {
  draft('DRAFT', 'Draft'),
  pendingVerification('PENDING_VERIFICATION', 'Waiting for verification'),
  verified('VERIFIED', 'Verified, not posted'),
  rejected('REJECTED', 'Rejected'),
  posted('POSTED', 'Posted'),
  reversed('REVERSED', 'Reversed');

  const ReceiptStatus(this.code, this.label);

  final String code;
  final String label;

  static ReceiptStatus fromCode(String code) =>
      values.firstWhere((status) => status.code == code, orElse: () => draft);
}

/// Something referred to by id, code and name (organisation, warehouse, supplier, unit).
class Ref {
  const Ref({required this.id, required this.code, required this.name});

  factory Ref.fromJson(Map<String, dynamic> json) =>
      Ref(id: json['id'] as String, code: json['code'] as String, name: json['name'] as String);

  final String id;
  final String code;
  final String name;
}

class PersonRef {
  const PersonRef({required this.id, required this.fullName});

  factory PersonRef.fromJson(Map<String, dynamic> json) =>
      PersonRef(id: json['id'] as String, fullName: json['fullName'] as String);

  static PersonRef? maybe(Object? json) =>
      json is Map<String, dynamic> ? PersonRef.fromJson(json) : null;

  final String id;
  final String fullName;
}

/// What the server noticed about a receipt, for the reviewer.
class ReceiptFlags {
  const ReceiptFlags({
    required this.discrepancies,
    required this.documentTotalMismatch,
    required this.documentsPending,
  });

  factory ReceiptFlags.fromJson(Map<String, dynamic> json) => ReceiptFlags(
    discrepancies: json['discrepancies'] as int,
    documentTotalMismatch: json['documentTotalMismatch'] as bool,
    documentsPending: json['documentsPending'] as int,
  );

  /// Lines where what arrived differs from what was bought.
  final int discrepancies;

  /// A verified document's total differs from the receipt's total.
  final bool documentTotalMismatch;
  final int documentsPending;
}

class ReceiptSummary {
  const ReceiptSummary({
    required this.id,
    required this.grnNumber,
    required this.status,
    required this.owner,
    required this.warehouse,
    required this.supplier,
    required this.supplierInvoiceNumber,
    required this.receivedDate,
    required this.currency,
    required this.total,
    required this.lineCount,
    required this.attachmentCount,
    required this.stockAdded,
    required this.flags,
  });

  factory ReceiptSummary.fromJson(Map<String, dynamic> json) => ReceiptSummary(
    id: json['id'] as String,
    grnNumber: json['grnNumber'] as String,
    status: ReceiptStatus.fromCode(json['status'] as String),
    owner: Ref.fromJson(json['owner'] as Map<String, dynamic>),
    warehouse: Ref.fromJson(json['warehouse'] as Map<String, dynamic>),
    supplier: json['supplier'] == null
        ? null
        : Ref.fromJson(json['supplier'] as Map<String, dynamic>),
    supplierInvoiceNumber: json['supplierInvoiceNumber'] as String?,
    receivedDate: json['receivedDate'] as String,
    currency: json['currency'] as String,
    total: json['total'] as String,
    lineCount: json['lineCount'] as int,
    attachmentCount: json['attachmentCount'] as int,
    stockAdded: json['stockAdded'] as bool,
    flags: ReceiptFlags.fromJson(json['flags'] as Map<String, dynamic>),
  );

  final String id;
  final String grnNumber;
  final ReceiptStatus status;

  /// Whose stock arrived: the Head Office or a subsidiary.
  final Ref owner;
  final Ref warehouse;
  final Ref? supplier;
  final String? supplierInvoiceNumber;
  final String receivedDate;
  final String currency;

  /// Exact decimal text, e.g. "43.78".
  final String total;
  final int lineCount;
  final int attachmentCount;

  /// True while the receipt's stock is counted (posted and not taken back).
  final bool stockAdded;
  final ReceiptFlags flags;
}

class ReceiptLine {
  const ReceiptLine({
    required this.id,
    required this.lineNumber,
    required this.productId,
    required this.productSku,
    required this.productDescription,
    required this.unit,
    required this.quantityPurchased,
    required this.quantityReceived,
    required this.baseQuantityReceived,
    required this.unitCost,
    required this.lineTotal,
    required this.batchNumber,
    required this.expiryDate,
    required this.discrepancyReason,
    required this.notes,
  });

  factory ReceiptLine.fromJson(Map<String, dynamic> json) {
    final product = json['product'] as Map<String, dynamic>;
    return ReceiptLine(
      id: json['id'] as String,
      lineNumber: json['lineNumber'] as int,
      productId: product['id'] as String,
      productSku: product['sku'] as String,
      productDescription: product['description'] as String,
      unit: Ref.fromJson(json['unit'] as Map<String, dynamic>),
      quantityPurchased: json['quantityPurchased'] as int,
      quantityReceived: json['quantityReceived'] as int,
      baseQuantityReceived: json['baseQuantityReceived'] as int,
      unitCost: json['unitCost'] as String,
      lineTotal: json['lineTotal'] as String,
      batchNumber: json['batchNumber'] as String?,
      expiryDate: json['expiryDate'] as String?,
      discrepancyReason: json['discrepancyReason'] as String?,
      notes: json['notes'] as String?,
    );
  }

  final String id;
  final int lineNumber;
  final String productId;
  final String productSku;
  final String productDescription;
  final Ref unit;
  final int quantityPurchased;
  final int quantityReceived;

  /// [quantityReceived] in the product's base unit (packs): what is added to stock.
  final int baseQuantityReceived;
  final String unitCost;
  final String lineTotal;
  final String? batchNumber;
  final String? expiryDate;
  final String? discrepancyReason;
  final String? notes;

  ReceiptLineInput toInput() => ReceiptLineInput(
    productId: productId,
    productLabel: '$productDescription ($productSku)',
    unitId: unit.id,
    quantityPurchased: quantityPurchased,
    quantityReceived: quantityReceived,
    unitCost: unitCost,
    batchNumber: batchNumber,
    expiryDate: expiryDate,
    discrepancyReason: discrepancyReason,
    notes: notes,
  );
}

enum DocumentStatus {
  pending('PENDING', 'Not reviewed'),
  verified('VERIFIED', 'Verified'),
  rejected('REJECTED', 'Rejected');

  const DocumentStatus(this.code, this.label);

  final String code;
  final String label;

  static DocumentStatus fromCode(String code) =>
      values.firstWhere((status) => status.code == code, orElse: () => pending);
}

class ReceiptDocument {
  const ReceiptDocument({
    required this.id,
    required this.filename,
    required this.mimeType,
    required this.sizeBytes,
    required this.uploadedBy,
    required this.status,
    required this.reviewedBy,
    required this.reviewNotes,
    required this.documentTotal,
  });

  factory ReceiptDocument.fromJson(Map<String, dynamic> json) => ReceiptDocument(
    id: json['id'] as String,
    filename: json['filename'] as String,
    mimeType: json['mimeType'] as String,
    sizeBytes: json['sizeBytes'] as int,
    uploadedBy: PersonRef.fromJson(json['uploadedBy'] as Map<String, dynamic>),
    status: DocumentStatus.fromCode(json['verificationStatus'] as String),
    reviewedBy: PersonRef.maybe(json['reviewedBy']),
    reviewNotes: json['reviewNotes'] as String?,
    documentTotal: json['documentTotal'] as String?,
  );

  final String id;
  final String filename;
  final String mimeType;
  final int sizeBytes;
  final PersonRef uploadedBy;
  final DocumentStatus status;
  final PersonRef? reviewedBy;
  final String? reviewNotes;

  /// The total printed on the document, as the reviewer read it.
  final String? documentTotal;

  bool get isPdf => mimeType == 'application/pdf';

  /// e.g. "1.2 MB" or "350 KB".
  String get sizeLabel => sizeBytes >= 1024 * 1024
      ? '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(sizeBytes / 1024).ceil()} KB';
}

class GoodsReceipt extends ReceiptSummary {
  const GoodsReceipt({
    required super.id,
    required super.grnNumber,
    required super.status,
    required super.owner,
    required super.warehouse,
    required super.supplier,
    required super.supplierInvoiceNumber,
    required super.receivedDate,
    required super.currency,
    required super.total,
    required super.lineCount,
    required super.attachmentCount,
    required super.stockAdded,
    required super.flags,
    required this.purchaseDate,
    required this.notes,
    required this.receivedBy,
    required this.verifiedBy,
    required this.verificationNotes,
    required this.rejectedReason,
    required this.reversalReason,
    required this.noDocumentReason,
    required this.lines,
    required this.documents,
  });

  factory GoodsReceipt.fromJson(Map<String, dynamic> json) {
    final summary = ReceiptSummary.fromJson(json);
    return GoodsReceipt(
      id: summary.id,
      grnNumber: summary.grnNumber,
      status: summary.status,
      owner: summary.owner,
      warehouse: summary.warehouse,
      supplier: summary.supplier,
      supplierInvoiceNumber: summary.supplierInvoiceNumber,
      receivedDate: summary.receivedDate,
      currency: summary.currency,
      total: summary.total,
      lineCount: summary.lineCount,
      attachmentCount: summary.attachmentCount,
      stockAdded: summary.stockAdded,
      flags: summary.flags,
      purchaseDate: json['purchaseDate'] as String?,
      notes: json['notes'] as String?,
      receivedBy: PersonRef.fromJson(json['receivedBy'] as Map<String, dynamic>),
      verifiedBy: PersonRef.maybe(json['verifiedBy']),
      verificationNotes: json['verificationNotes'] as String?,
      rejectedReason: json['rejectedReason'] as String?,
      reversalReason: json['reversalReason'] as String?,
      noDocumentReason: json['noDocumentReason'] as String?,
      lines: [
        for (final line in json['lines'] as List)
          ReceiptLine.fromJson(line as Map<String, dynamic>),
      ],
      documents: [
        for (final document in json['attachments'] as List)
          ReceiptDocument.fromJson(document as Map<String, dynamic>),
      ],
    );
  }

  final String? purchaseDate;
  final String? notes;
  final PersonRef receivedBy;
  final PersonRef? verifiedBy;
  final String? verificationNotes;
  final String? rejectedReason;
  final String? reversalReason;
  final String? noDocumentReason;
  final List<ReceiptLine> lines;
  final List<ReceiptDocument> documents;
}

/// One line as entered on the form.
class ReceiptLineInput {
  const ReceiptLineInput({
    required this.productId,
    required this.productLabel,
    required this.unitId,
    required this.quantityPurchased,
    required this.quantityReceived,
    required this.unitCost,
    this.batchNumber,
    this.expiryDate,
    this.discrepancyReason,
    this.notes,
  });

  final String productId;

  /// Shown on the form only.
  final String productLabel;
  final String unitId;
  final int quantityPurchased;
  final int quantityReceived;
  final String unitCost;
  final String? batchNumber;
  final String? expiryDate;
  final String? discrepancyReason;
  final String? notes;

  Map<String, Object?> toJson() => {
    'productId': productId,
    'unitId': unitId,
    'quantityPurchased': quantityPurchased,
    'quantityReceived': quantityReceived,
    'unitCost': unitCost,
    'batchNumber': batchNumber,
    'expiryDate': expiryDate,
    'discrepancyReason': quantityPurchased == quantityReceived ? null : discrepancyReason,
    'notes': notes,
  };
}

/// A receipt's details as entered on the form.
class ReceiptInput {
  const ReceiptInput({
    required this.organisationId,
    required this.warehouseId,
    required this.supplierId,
    required this.supplierInvoiceNumber,
    required this.purchaseDate,
    required this.receivedDate,
    required this.notes,
    required this.lines,
  });

  final String? organisationId;
  final String? warehouseId;
  final String? supplierId;
  final String? supplierInvoiceNumber;
  final String? purchaseDate;
  final String receivedDate;
  final String? notes;
  final List<ReceiptLineInput> lines;

  Map<String, Object?> toJson() => {
    'organisationId': ?organisationId,
    'warehouseId': warehouseId,
    'supplierId': supplierId,
    'supplierInvoiceNumber': supplierInvoiceNumber,
    'purchaseDate': purchaseDate,
    'receivedDate': receivedDate,
    'notes': notes,
    'lines': [for (final line in lines) line.toJson()],
  };
}

/// Reasons a line's quantity received may differ from the quantity bought.
const discrepancyReasons = <String, String>{
  'shortage': 'Shortage',
  'overage': 'Overage',
  'damaged': 'Damaged',
  'rejected': 'Rejected at the door',
};
