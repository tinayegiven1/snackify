import '../../auth/domain/app_user.dart';

enum DispatchStatus {
  draft('Draft'),
  confirmed('Confirmed'),
  cancelled('Cancelled'),
  reversed('Reversed');

  const DispatchStatus(this.label);

  final String label;

  static DispatchStatus fromApi(String value) => DispatchStatus.values.byName(value);
}

/// What each role may do with dispatches. The server enforces the same rules.
class DispatchPermissions {
  const DispatchPermissions._({
    required this.canCreate,
    required this.canConfirm,
    required this.canReverse,
  });

  factory DispatchPermissions.forRole(StaffRole role) => DispatchPermissions._(
    canCreate: role != StaffRole.accounts,
    canConfirm: role == StaffRole.admin || role == StaffRole.storekeeper,
    canReverse: role == StaffRole.admin,
  );

  /// Create, edit and cancel drafts.
  final bool canCreate;

  /// Confirm a draft: the goods leave the store and stock is deducted.
  final bool canConfirm;

  /// Undo a confirmed dispatch, putting the stock back.
  final bool canReverse;
}

class DispatchSummary {
  const DispatchSummary({
    required this.id,
    required this.dispatchNumber,
    required this.status,
    required this.dispatchDate,
    required this.customerName,
    required this.totalQuantity,
    required this.totalValue,
  });

  factory DispatchSummary.fromJson(Map<String, dynamic> json) => DispatchSummary(
    id: json['id'] as String,
    dispatchNumber: json['dispatchNumber'] as String,
    status: DispatchStatus.fromApi(json['status'] as String),
    dispatchDate: json['dispatchDate'] as String,
    customerName: (json['customer'] as Map<String, dynamic>)['name'] as String,
    totalQuantity: json['totalQuantity'] as int,
    totalValue: json['totalValue'] as String,
  );

  final String id;
  final String dispatchNumber;
  final DispatchStatus status;
  final String dispatchDate;
  final String customerName;
  final int totalQuantity;
  final String totalValue;
}

class DispatchLine {
  const DispatchLine({
    required this.productId,
    required this.description,
    required this.sku,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
    required this.quantityOnHand,
  });

  factory DispatchLine.fromJson(Map<String, dynamic> json) {
    final product = json['product'] as Map<String, dynamic>;
    return DispatchLine(
      productId: product['id'] as String,
      description: '${product['name']} — ${product['flavour']} — ${product['size']}',
      sku: product['sku'] as String,
      quantity: json['quantity'] as int,
      unitPrice: json['unitPrice'] as String,
      lineTotal: json['lineTotal'] as String,
      quantityOnHand: json['quantityOnHand'] as int,
    );
  }

  final String productId;
  final String description;
  final String sku;
  final int quantity;
  final String unitPrice;
  final String lineTotal;
  final int quantityOnHand;
}

/// What confirming would do to the customer's unpaid balance (drafts only).
class CreditCheck {
  const CreditCheck({
    required this.creditLimit,
    required this.balanceBefore,
    required this.balanceAfter,
    required this.exceedsLimit,
  });

  factory CreditCheck.fromJson(Map<String, dynamic> json) => CreditCheck(
    creditLimit: json['creditLimit'] as String?,
    balanceBefore: json['balanceBefore'] as String,
    balanceAfter: json['balanceAfter'] as String,
    exceedsLimit: json['exceedsLimit'] as bool,
  );

  final String? creditLimit;
  final String balanceBefore;
  final String balanceAfter;
  final bool exceedsLimit;
}

class Dispatch {
  const Dispatch({
    required this.id,
    required this.dispatchNumber,
    required this.status,
    required this.dispatchDate,
    required this.notes,
    required this.customerId,
    required this.customerName,
    required this.customerCode,
    required this.items,
    required this.totalQuantity,
    required this.totalValue,
    required this.createdBy,
    required this.confirmedBy,
    required this.confirmedOverCreditLimit,
    required this.cancelReason,
    required this.reversalReason,
    required this.creditCheck,
  });

  factory Dispatch.fromJson(Map<String, dynamic> json) {
    final customer = json['customer'] as Map<String, dynamic>;
    String? name(Object? person) => (person as Map<String, dynamic>?)?['fullName'] as String?;
    return Dispatch(
      id: json['id'] as String,
      dispatchNumber: json['dispatchNumber'] as String,
      status: DispatchStatus.fromApi(json['status'] as String),
      dispatchDate: json['dispatchDate'] as String,
      notes: json['notes'] as String?,
      customerId: customer['id'] as String,
      customerName: customer['name'] as String,
      customerCode: customer['code'] as String,
      items: (json['items'] as List)
          .map((item) => DispatchLine.fromJson(item as Map<String, dynamic>))
          .toList(),
      totalQuantity: json['totalQuantity'] as int,
      totalValue: json['totalValue'] as String,
      createdBy: name(json['createdBy'])!,
      confirmedBy: name(json['confirmedBy']),
      confirmedOverCreditLimit: json['confirmedOverCreditLimit'] as bool,
      cancelReason: json['cancelReason'] as String?,
      reversalReason: json['reversalReason'] as String?,
      creditCheck: json['creditCheck'] == null
          ? null
          : CreditCheck.fromJson(json['creditCheck'] as Map<String, dynamic>),
    );
  }

  final String id;
  final String dispatchNumber;
  final DispatchStatus status;
  final String dispatchDate;
  final String? notes;
  final String customerId;
  final String customerName;
  final String customerCode;
  final List<DispatchLine> items;
  final int totalQuantity;
  final String totalValue;
  final String createdBy;
  final String? confirmedBy;
  final bool confirmedOverCreditLimit;
  final String? cancelReason;
  final String? reversalReason;
  final CreditCheck? creditCheck;

  /// Lines that need more stock than is on hand right now.
  List<DispatchLine> get shortLines =>
      items.where((line) => line.quantity > line.quantityOnHand).toList();
}

/// One line of a draft being edited.
class DraftLine {
  DraftLine({
    required this.productId,
    required this.description,
    required this.quantity,
    required this.unitPrice,
  });

  final String productId;
  final String description;
  int quantity;
  String unitPrice;

  Map<String, Object?> toJson() => {
    'productId': productId,
    'quantity': quantity,
    'unitPrice': unitPrice,
  };
}
