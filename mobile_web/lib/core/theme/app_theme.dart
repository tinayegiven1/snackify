import 'package:flutter/material.dart';

/// Colours taken from the Snackify logo, plus the soft blue workspace around the cards.
class SnackifyColors {
  SnackifyColors._();

  static const Color brandBlue = Color(0xFF0D47A1);

  /// The lighter end of the sidebar gradient.
  static const Color brandBlueLight = Color(0xFF1565C0);
  static const Color teal = Color(0xFF00A3A3);
  static const Color orange = Color(0xFFFF9800);
  static const Color red = Color(0xFFE64A19);
  static const Color success = Color(0xFF2E7D32);

  /// Chart marks: one step lighter than [brandBlue], which is too dark for bars. Checked with
  /// the data-visualisation palette validator (lightness band and 3:1 contrast on the surface).
  static const Color chart = Color(0xFF1565C0);

  /// The page behind the cards.
  static const Color workspace = Color(0xFFEAF3FB);

  /// Headings and strong text.
  static const Color ink = Color(0xFF13294B);

  /// Secondary text: labels, hints, column headings.
  static const Color muted = Color(0xFF66768C);

  /// Hairlines between rows and around fields.
  static const Color line = Color(0xFFDDE7F2);

  /// Fields and table headers: a shade off white.
  static const Color field = Color(0xFFF4F8FC);

  /// Status colours for stock and money (text on the pale fills below).
  static const Color good = Color(0xFF1E8E3E);
  static const Color warn = Color(0xFFD97706);
  static const Color bad = Color(0xFFD93025);
  static const Color goodFill = Color(0xFFE6F4EA);
  static const Color warnFill = Color(0xFFFFF4E0);
  static const Color badFill = Color(0xFFFDE8E6);
  static const Color infoFill = Color(0xFFE5EFFA);
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
      surface: Colors.white,
      onSurface: SnackifyColors.ink,
      onSurfaceVariant: SnackifyColors.muted,
      outlineVariant: SnackifyColors.line,
      surfaceContainerLowest: SnackifyColors.workspace,
      surfaceContainerLow: SnackifyColors.field,
      error: SnackifyColors.bad,
    );

    const radius = 12.0;
    OutlineInputBorder fieldBorder(Color color, [double width = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide(color: color, width: width),
    );
    final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
    const buttonPadding = EdgeInsets.symmetric(horizontal: 18, vertical: 14);
    final base = ThemeData(useMaterial3: true, colorScheme: colorScheme);
    final text = base.textTheme.apply(
      bodyColor: SnackifyColors.ink,
      displayColor: SnackifyColors.ink,
    );

    return base.copyWith(
      scaffoldBackgroundColor: SnackifyColors.workspace,
      textTheme: text.copyWith(
        headlineSmall: text.headlineSmall?.copyWith(
          fontWeight: FontWeight.w800,
          color: SnackifyColors.brandBlue,
          letterSpacing: -0.3,
        ),
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: SnackifyColors.workspace,
        foregroundColor: SnackifyColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: SnackifyColors.brandBlue,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
      ),
      // Cards float on the blue workspace: white, rounded, with a soft blue shadow.
      cardTheme: CardThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shadowColor: const Color(0x2E0D47A1),
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dividerTheme: const DividerThemeData(color: SnackifyColors.line, thickness: 1, space: 1),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        selectedColor: colorScheme.onSecondaryContainer,
        selectedTileColor: colorScheme.secondaryContainer,
        iconColor: SnackifyColors.muted,
      ),
      // Every state has its own border, so fields that ask for a plain OutlineInputBorder get
      // the rounded, quiet look too.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: SnackifyColors.field,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        labelStyle: const TextStyle(color: SnackifyColors.muted),
        hintStyle: const TextStyle(color: SnackifyColors.muted),
        prefixIconColor: SnackifyColors.muted,
        suffixIconColor: SnackifyColors.muted,
        border: fieldBorder(SnackifyColors.line),
        enabledBorder: fieldBorder(SnackifyColors.line),
        disabledBorder: fieldBorder(SnackifyColors.line.withValues(alpha: 0.6)),
        focusedBorder: fieldBorder(SnackifyColors.brandBlue, 1.6),
        errorBorder: fieldBorder(SnackifyColors.bad),
        focusedErrorBorder: fieldBorder(SnackifyColors.bad, 1.6),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: buttonShape,
          padding: buttonPadding,
          elevation: 2,
          shadowColor: const Color(0x400D47A1),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: buttonShape,
          padding: buttonPadding,
          backgroundColor: Colors.white,
          side: const BorderSide(color: SnackifyColors.line),
          foregroundColor: SnackifyColors.ink,
        ),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: buttonShape)),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: SnackifyColors.brandBlue,
        foregroundColor: Colors.white,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: const StadiumBorder(side: BorderSide(color: SnackifyColors.line)),
        backgroundColor: Colors.white,
        selectedColor: SnackifyColors.infoFill,
        labelStyle: const TextStyle(color: SnackifyColors.ink, fontWeight: FontWeight.w500),
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: SnackifyColors.brandBlue,
        unselectedLabelColor: SnackifyColors.muted,
        indicatorColor: SnackifyColors.brandBlue,
        dividerColor: SnackifyColors.line,
        labelStyle: TextStyle(fontWeight: FontWeight.w700),
      ),
      // Tables: a pale header with small capitals, airy rows and hairlines.
      dataTableTheme: DataTableThemeData(
        headingRowColor: const WidgetStatePropertyAll(SnackifyColors.field),
        headingTextStyle: const TextStyle(
          color: SnackifyColors.muted,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
        dataTextStyle: const TextStyle(color: SnackifyColors.ink, fontSize: 14),
        dataRowMinHeight: 56,
        dataRowMaxHeight: 64,
        horizontalMargin: 20,
        columnSpacing: 28,
        dividerThickness: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      drawerTheme: const DrawerThemeData(backgroundColor: SnackifyColors.brandBlue),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: SnackifyColors.brandBlue),
    );
  }
}
