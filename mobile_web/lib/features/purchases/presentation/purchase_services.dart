import '../../receipts/presentation/receipt_services.dart';
import '../data/purchases_repository.dart';

/// What the goods-bought screens need: the lists, and the goods-received screens to receive
/// against them.
class PurchaseServices {
  const PurchaseServices({required this.purchases, required this.receiptServices});

  final PurchasesRepository purchases;
  final ReceiptServices receiptServices;

  /// Records, changes and cancels lists (finance and administrators).
  bool get canManage => receiptServices.user.can('purchase.manage');

  /// Receives what was bought (warehouse staff).
  bool get canReceive => receiptServices.canReceive;

  /// Head Office staff may record goods bought for a subsidiary.
  bool get canChooseOwner => receiptServices.canChooseOwner;
}
