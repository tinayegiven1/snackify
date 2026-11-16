import '../../receipts/presentation/receipt_services.dart';
import '../../auth/domain/app_user.dart';
import '../data/purchases_repository.dart';
import '../domain/purchase_models.dart';

/// What the goods-bought screens need: the lists, and the goods-received screens to receive
/// against them.
class PurchaseServices {
  const PurchaseServices({required this.purchases, required this.receiptServices});

  final PurchasesRepository purchases;
  final ReceiptServices receiptServices;

  /// Records lists (every user).
  bool get canEnter => _user.can('purchase.enter') || canManage;

  /// Changes or cancels anyone's list, and verifies supplier documents (finance and
  /// administrators).
  bool get canManage => _user.can('purchase.manage');

  /// Changes, cancels or adds documents to [purchase]: whoever entered it, or finance and
  /// administrators.
  bool canChange(PurchaseSummary purchase) =>
      canManage || (canEnter && purchase.createdBy.id == _user.id);

  AppUser get _user => receiptServices.user;

  /// Receives what was bought (warehouse staff).
  bool get canReceive => receiptServices.canReceive;

  /// Head Office staff may record goods bought for a subsidiary.
  bool get canChooseOwner => receiptServices.canChooseOwner;
}
