import '../config/app_config.dart';

final _moneyFormat = RegExp(r'^\d{1,10}(\.\d{1,2})?$');

/// "0.5" -> 50 cents. Null when the text is not a valid amount. Whole cents avoid the
/// rounding errors of floating-point maths; the server's totals are always the final word.
int? parseCents(String text) {
  final value = text.trim();
  if (!_moneyFormat.hasMatch(value)) return null;
  final parts = value.split('.');
  final cents = parts.length == 2 ? parts[1].padRight(2, '0') : '00';
  return int.parse(parts[0]) * 100 + int.parse(cents);
}

/// 1234 -> "12.34".
String formatCents(int cents) => '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';

/// "12.34" -> "USD 12.34".
String withCurrency(String amount) => '${AppConfig.currencyCode} $amount';
