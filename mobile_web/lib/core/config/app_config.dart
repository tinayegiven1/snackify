import 'package:flutter/foundation.dart';

/// App-wide settings.
///
/// Override the API address at build/run time, for example on a physical phone:
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.50:3000
class AppConfig {
  AppConfig._();

  static const String _apiBaseUrlOverride = String.fromEnvironment('API_BASE_URL');

  /// The business's base currency: product default prices are in this currency.
  static const String currencyCode = 'USD';

  static String get apiBaseUrl {
    if (_apiBaseUrlOverride.isNotEmpty) return _apiBaseUrlOverride;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      // The Android emulator reaches the host computer's localhost through 10.0.2.2.
      return 'http://10.0.2.2:3000';
    }
    return 'http://localhost:3000';
  }
}
