import 'package:flutter/material.dart';

abstract final class SafeAtHomeTheme {
  static const ivory = Color(0xFFF7F7F2);
  static const teal = Color(0xFF204D43);
  static const ink = Color(0xFF243C34);
  static const mutedInk = Color(0xFF59675E);
  static const coral = Color(0xFF965038);
  static const line = Color(0xFFDFE4DA);

  static ThemeData light() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: teal,
          brightness: Brightness.light,
        ).copyWith(
          primary: teal,
          onPrimary: Colors.white,
          primaryContainer: const Color(0xFFE3EDDE),
          onPrimaryContainer: teal,
          secondary: const Color(0xFF526653),
          secondaryContainer: const Color(0xFFECEEE0),
          onSecondaryContainer: ink,
          tertiary: coral,
          tertiaryContainer: const Color(0xFFF6E7D9),
          onTertiaryContainer: const Color(0xFF743326),
          surface: const Color(0xFFFFFFFC),
          onSurface: ink,
          onSurfaceVariant: mutedInk,
          surfaceContainerLowest: const Color(0xFFFFFFFC),
          surfaceContainerLow: const Color(0xFFF0F2E9),
          surfaceContainer: const Color(0xFFE9EDE3),
          outline: const Color(0xFF77877E),
          outlineVariant: line,
          error: const Color(0xFF9B3028),
          onError: Colors.white,
          errorContainer: const Color(0xFFF9E3DF),
          onErrorContainer: const Color(0xFF74231D),
        );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: ivory,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
    );
    final text = base.textTheme.apply(bodyColor: ink, displayColor: ink);
    return base.copyWith(
      textTheme: text.copyWith(
        headlineMedium: text.headlineMedium?.copyWith(
          fontSize: 32,
          fontWeight: FontWeight.w600,
          height: 1.18,
          letterSpacing: -.9,
        ),
        headlineSmall: text.headlineSmall?.copyWith(
          fontSize: 26,
          fontWeight: FontWeight.w600,
          height: 1.2,
          letterSpacing: -.4,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
        titleMedium: text.titleMedium?.copyWith(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          height: 1.35,
        ),
        bodyLarge: text.bodyLarge?.copyWith(fontSize: 17, height: 1.5),
        bodyMedium: text.bodyMedium?.copyWith(fontSize: 15, height: 1.5),
        bodySmall: text.bodySmall?.copyWith(fontSize: 13, height: 1.5),
        labelLarge: text.labelLarge?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: ivory,
        foregroundColor: teal,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 20,
        titleTextStyle: text.titleMedium?.copyWith(
          color: teal,
          fontSize: 17,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: line),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 18,
        ),
        helperMaxLines: 5,
        errorMaxLines: 5,
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: teal, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 52),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          side: BorderSide(color: scheme.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      dividerTheme: const DividerThemeData(color: line, space: 32),
      listTileTheme: const ListTileThemeData(
        minVerticalPadding: 16,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: ink,
        contentTextStyle: text.bodyMedium?.copyWith(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: teal),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: teal,
        collapsedIconColor: mutedInk,
        textColor: ink,
        collapsedTextColor: ink,
        shape: const Border(),
        collapsedShape: const Border(),
        childrenPadding: const EdgeInsets.only(bottom: 16),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        labelStyle: text.labelMedium?.copyWith(color: ink),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }
}
