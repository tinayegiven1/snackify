import '../../../core/files/pdf_sharer.dart';
import '../../auth/domain/app_user.dart';
import '../../organisations/data/organisations_repository.dart';
import '../../products/data/products_repository.dart';
import '../data/orders_repository.dart';

/// What the order screens need, passed along together, and what the user may do.
class OrderServices {
  const OrderServices({
    required this.orders,
    required this.products,
    required this.organisations,
    required this.user,
    required this.sharePdf,
  });

  final OrdersRepository orders;
  final ProductsRepository products;
  final OrganisationsRepository organisations;
  final AppUser user;
  final PdfSharer sharePdf;

  /// The Head Office sees every subsidiary's orders; a subsidiary only its own.
  bool get seesAll => user.seesAllOrganisations;

  /// Creates, changes, submits and cancels orders (a subsidiary's manager).
  bool get canCreate => user.can('order.create');

  /// Reviews orders and sets actual prices (Head Office only).
  bool get canPrice => seesAll && user.can('order.price');

  /// Approves or rejects orders (Head Office only).
  bool get canDecide => seesAll && user.can('order.approve');

  /// May approve an actual price above the maximum.
  bool get canApproveException => user.can('price.exception.approve');
}
