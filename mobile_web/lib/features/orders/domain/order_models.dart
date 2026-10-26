import '../../receipts/domain/receipt_models.dart' show PersonRef, Ref;

/// Orders from subsidiaries to the Head Office (StockFlow Stage 5): what the subsidiary
/// expects to pay, the most it accepts, and the actual price the Head Office sets.
enum OrderStatus {
  draft('DRAFT', 'Draft'),
  submitted('SUBMITTED', 'Submitted'),
  underReview('UNDER_REVIEW', 'Under review'),
  approved('APPROVED', 'Approved'),
  rejected('REJECTED', 'Rejected'),
  cancelled('CANCELLED', 'Cancelled'),
  partiallyDispatched('PARTIALLY_DISPATCHED', 'Partly dispatched'),
  fullyDispatched('FULLY_DISPATCHED', 'Dispatched'),
  completed('COMPLETED', 'Completed');

  const OrderStatus(this.code, this.label);

  final String code;
  final String label;

  static OrderStatus fromCode(String code) =>
      values.firstWhere((status) => status.code == code, orElse: () => draft);

  /// The statuses offered as filters (the dispatch ones arrive in a later stage).
  static const filters = [draft, submitted, underReview, approved, rejected, cancelled];
}

class OrderSummary {
  const OrderSummary({
    required this.id,
    required this.orderNumber,
    required this.status,
    required this.organisation,
    required this.orderDate,
    required this.requiredDate,
    required this.currency,
    required this.requestedBy,
    required this.lineCount,
    required this.expectedTotal,
    required this.maximumTotal,
    required this.actualTotal,
    required this.priceException,
  });

  factory OrderSummary.fromJson(Map<String, dynamic> json) => OrderSummary(
    id: json['id'] as String,
    orderNumber: json['orderNumber'] as String,
    status: OrderStatus.fromCode(json['status'] as String),
    organisation: Ref.fromJson(json['organisation'] as Map<String, dynamic>),
    orderDate: json['orderDate'] as String,
    requiredDate: json['requiredDate'] as String?,
    currency: json['currency'] as String,
    requestedBy: PersonRef.fromJson(json['requestedBy'] as Map<String, dynamic>),
    lineCount: json['lineCount'] as int,
    expectedTotal: json['expectedTotal'] as String,
    maximumTotal: json['maximumTotal'] as String,
    actualTotal: json['actualTotal'] as String?,
    priceException: json['priceException'] as bool,
  );

  final String id;
  final String orderNumber;
  final OrderStatus status;

  /// The subsidiary that orders.
  final Ref organisation;
  final String orderDate;
  final String? requiredDate;
  final String currency;
  final PersonRef requestedBy;
  final int lineCount;

  /// Exact decimal text worked out by the server, e.g. "12.30".
  final String expectedTotal;
  final String maximumTotal;

  /// Once every line has an actual price; null before that.
  final String? actualTotal;

  /// Some actual price is above the maximum the subsidiary accepts.
  final bool priceException;
}

class OrderLine {
  const OrderLine({
    required this.id,
    required this.lineNumber,
    required this.productId,
    required this.productSku,
    required this.productDescription,
    required this.unit,
    required this.requestedQuantity,
    required this.baseQuantity,
    required this.expectedUnitPrice,
    required this.maximumUnitPrice,
    required this.actualUnitPrice,
    required this.expectedLineTotal,
    required this.maximumLineTotal,
    required this.actualLineTotal,
    required this.priceException,
    required this.notes,
    required this.hqAvailable,
  });

  factory OrderLine.fromJson(Map<String, dynamic> json) {
    final product = json['product'] as Map<String, dynamic>;
    return OrderLine(
      id: json['id'] as String,
      lineNumber: json['lineNumber'] as int,
      productId: product['id'] as String,
      productSku: product['sku'] as String,
      productDescription: product['description'] as String,
      unit: Ref.fromJson(json['unit'] as Map<String, dynamic>),
      requestedQuantity: json['requestedQuantity'] as int,
      baseQuantity: json['baseQuantity'] as int,
      expectedUnitPrice: json['expectedUnitPrice'] as String,
      maximumUnitPrice: json['maximumUnitPrice'] as String,
      actualUnitPrice: json['actualUnitPrice'] as String?,
      expectedLineTotal: json['expectedLineTotal'] as String,
      maximumLineTotal: json['maximumLineTotal'] as String,
      actualLineTotal: json['actualLineTotal'] as String?,
      priceException: json['priceException'] as bool,
      notes: json['notes'] as String?,
      hqAvailable: json['hqAvailable'] as int?,
    );
  }

  final String id;
  final int lineNumber;
  final String productId;
  final String productSku;
  final String productDescription;
  final Ref unit;
  final int requestedQuantity;

  /// [requestedQuantity] in the product's base unit (packs).
  final int baseQuantity;
  final String expectedUnitPrice;
  final String maximumUnitPrice;
  final String? actualUnitPrice;
  final String expectedLineTotal;
  final String maximumLineTotal;
  final String? actualLineTotal;
  final bool priceException;
  final String? notes;

  /// The Head Office's available stock, in base units (Head Office staff only).
  final int? hqAvailable;

  OrderLineInput toInput() => OrderLineInput(
    productId: productId,
    productLabel: '$productDescription ($productSku)',
    unitId: unit.id,
    unitLabel: unit.name,
    requestedQuantity: requestedQuantity,
    expectedUnitPrice: expectedUnitPrice,
    maximumUnitPrice: maximumUnitPrice,
    notes: notes,
  );
}

class OrderHistoryEntry {
  const OrderHistoryEntry({
    required this.fromStatus,
    required this.toStatus,
    required this.changedBy,
    required this.changedAt,
    required this.comment,
  });

  factory OrderHistoryEntry.fromJson(Map<String, dynamic> json) => OrderHistoryEntry(
    fromStatus: json['fromStatus'] == null
        ? null
        : OrderStatus.fromCode(json['fromStatus'] as String),
    toStatus: OrderStatus.fromCode(json['toStatus'] as String),
    changedBy: PersonRef.fromJson(json['changedBy'] as Map<String, dynamic>),
    changedAt: DateTime.parse(json['changedAt'] as String),
    comment: json['comment'] as String?,
  );

  final OrderStatus? fromStatus;
  final OrderStatus toStatus;
  final PersonRef changedBy;
  final DateTime changedAt;
  final String? comment;
}

/// A change to a line after submission (the actual price), with the old and new value.
class OrderLineChange {
  const OrderLineChange({
    required this.lineNumber,
    required this.oldValue,
    required this.newValue,
    required this.changedBy,
    required this.changedAt,
    required this.comment,
  });

  factory OrderLineChange.fromJson(Map<String, dynamic> json) => OrderLineChange(
    lineNumber: json['lineNumber'] as int,
    oldValue: json['oldValue'] as String?,
    newValue: json['newValue'] as String?,
    changedBy: PersonRef.fromJson(json['changedBy'] as Map<String, dynamic>),
    changedAt: DateTime.parse(json['changedAt'] as String),
    comment: json['comment'] as String?,
  );

  final int lineNumber;
  final String? oldValue;
  final String? newValue;
  final PersonRef changedBy;
  final DateTime changedAt;
  final String? comment;
}

class SubsidiaryOrder extends OrderSummary {
  const SubsidiaryOrder({
    required super.id,
    required super.orderNumber,
    required super.status,
    required super.organisation,
    required super.orderDate,
    required super.requiredDate,
    required super.currency,
    required super.requestedBy,
    required super.lineCount,
    required super.expectedTotal,
    required super.maximumTotal,
    required super.actualTotal,
    required super.priceException,
    required this.notes,
    required this.submittedBy,
    required this.decidedBy,
    required this.decisionComment,
    required this.priceExceptionApproved,
    required this.cancelReason,
    required this.lines,
    required this.history,
    required this.changes,
  });

  factory SubsidiaryOrder.fromJson(Map<String, dynamic> json) {
    final summary = OrderSummary.fromJson(json);
    return SubsidiaryOrder(
      id: summary.id,
      orderNumber: summary.orderNumber,
      status: summary.status,
      organisation: summary.organisation,
      orderDate: summary.orderDate,
      requiredDate: summary.requiredDate,
      currency: summary.currency,
      requestedBy: summary.requestedBy,
      lineCount: summary.lineCount,
      expectedTotal: summary.expectedTotal,
      maximumTotal: summary.maximumTotal,
      actualTotal: summary.actualTotal,
      priceException: summary.priceException,
      notes: json['notes'] as String?,
      submittedBy: PersonRef.maybe(json['submittedBy']),
      decidedBy: PersonRef.maybe(json['decidedBy']),
      decisionComment: json['decisionComment'] as String?,
      priceExceptionApproved: json['priceExceptionApproved'] as bool,
      cancelReason: json['cancelReason'] as String?,
      lines: [
        for (final line in json['lines'] as List) OrderLine.fromJson(line as Map<String, dynamic>),
      ],
      history: [
        for (final entry in json['history'] as List)
          OrderHistoryEntry.fromJson(entry as Map<String, dynamic>),
      ],
      changes: [
        for (final change in json['changes'] as List)
          OrderLineChange.fromJson(change as Map<String, dynamic>),
      ],
    );
  }

  final String? notes;
  final PersonRef? submittedBy;
  final PersonRef? decidedBy;
  final String? decisionComment;
  final bool priceExceptionApproved;
  final String? cancelReason;
  final List<OrderLine> lines;
  final List<OrderHistoryEntry> history;
  final List<OrderLineChange> changes;
}

/// One line as entered on the form.
class OrderLineInput {
  const OrderLineInput({
    required this.productId,
    required this.productLabel,
    required this.unitId,
    required this.unitLabel,
    required this.requestedQuantity,
    required this.expectedUnitPrice,
    required this.maximumUnitPrice,
    this.notes,
  });

  final String productId;

  /// Shown on the form only.
  final String productLabel;
  final String unitId;
  final String unitLabel;
  final int requestedQuantity;
  final String expectedUnitPrice;
  final String maximumUnitPrice;
  final String? notes;

  Map<String, Object?> toJson() => {
    'productId': productId,
    'unitId': unitId,
    'requestedQuantity': requestedQuantity,
    'expectedUnitPrice': expectedUnitPrice,
    'maximumUnitPrice': maximumUnitPrice,
    'notes': notes,
  };
}

class OrderInput {
  const OrderInput({
    required this.requiredDate,
    required this.notes,
    required this.lines,
    this.organisationId,
  });

  final String? organisationId;
  final String? requiredDate;
  final String? notes;
  final List<OrderLineInput> lines;

  Map<String, Object?> toJson() => {
    'organisationId': ?organisationId,
    'requiredDate': requiredDate,
    'notes': notes,
    'lines': [for (final line in lines) line.toJson()],
  };
}
