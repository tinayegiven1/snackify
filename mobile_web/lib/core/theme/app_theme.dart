import 'package:flutter/material.dart';

/// Colours taken from the Snackify logo.
class SnackifyColors {
  SnackifyColors._();

  static const Color brandBlue = Color(0xFF0D47A1);
  static const Color teal = Color(0xFF00A3A3);
  static const Color orange = Color(0xFFFF9800);
  static const Color red = Color(0xFFE64A19);
  static const Color success = Color(0xFF2E7D32);
}

class AppTheme {
  AppTheme._();

  static ThemeData light() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: SnackifyColors.brandBlue,
      primary: SnackifyColors.brandBlue,
      secondary: SnackifyColors.teal,
      tertiary: SnackifyColors.orange,
      // Without these, Flutter derives a pink container from the blue seed.
      tertiaryContainer: const Color(0xFFFFE6C2),
      onTertiaryContainer: const Color(0xFF4A2800),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surfaceContainerLowest,
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        selectedColor: colorScheme.onSecondaryContainer,
        selectedTileColor: colorScheme.secondaryContainer,
      ),
    );
  }
}
