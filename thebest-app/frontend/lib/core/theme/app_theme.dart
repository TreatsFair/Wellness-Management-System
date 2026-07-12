import 'package:flutter/material.dart';

/// Single source of truth for the app's visual language.
/// Screens must not hard-code hex colors, radii, or ad-hoc text styles —
/// pull everything from [AppColors], [AppSpacing], [AppRadius], [AppText].
abstract final class AppColors {
  // Brand
  static const primary = Color(0xFF1B6B72);
  static const primaryDark = Color(0xFF14545A);
  static const primarySoft = Color(0xFFE4F0F1);
  static const accent = Color(0xFFD97706);
  static const accentSoft = Color(0xFFFDF3E3);

  // Surfaces
  static const canvas = Color(0xFFF5F7F8);
  static const surface = Colors.white;
  static const border = Color(0xFFDFE5EA);

  // Ink
  static const text = Color(0xFF17202A);
  static const muted = Color(0xFF5C6B7A);
  static const subtle = Color(0xFF8A97A3);

  // Status
  static const success = Color(0xFF15803D);
  static const successSoft = Color(0xFFE8F5EC);
  static const warning = Color(0xFFB45309);
  static const warningSoft = Color(0xFFFDF3E3);
  static const danger = Color(0xFFB42318);
  static const dangerSoft = Color(0xFFFBEAE8);
  static const info = Color(0xFF2563EB);
  static const infoSoft = Color(0xFFE8EFFD);
}

abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

abstract final class AppRadius {
  /// Buttons, inputs, chips-with-corners.
  static const double control = 8;

  /// Cards, tiles, banners.
  static const double card = 12;

  /// Dialogs, bottom sheets.
  static const double sheet = 16;

  static const double pill = 999;
}

abstract final class AppText {
  /// Large stat numbers.
  static const display = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w800,
    color: AppColors.text,
    height: 1.15,
  );

  /// Screen titles.
  static const title = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    color: AppColors.text,
  );

  /// Card titles, dialog titles.
  static const heading = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    color: AppColors.text,
  );

  /// Default body copy.
  static const body = TextStyle(fontSize: 14, color: AppColors.text);

  /// Emphasised inline text, buttons, list titles.
  static const label = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: AppColors.text,
  );

  /// Secondary detail under a title.
  static const caption = TextStyle(fontSize: 12, color: AppColors.muted);
}

/// Semantic colors for appointment / booking statuses, shared by the
/// dashboard, appointments, and timetable screens so one status always
/// looks the same everywhere.
abstract final class AppStatusColors {
  static Color of(String status) => switch (status.toLowerCase().trim()) {
    'completed' || 'paid' || 'done' || 'free' => AppColors.success,
    'pending' || 'pending_payment' => AppColors.warning,
    'confirmed' => AppColors.info,
    'in_progress' || 'busy' => AppColors.primary,
    'cancelled' || 'canceled' || 'expired' || 'payment_failed' =>
      AppColors.danger,
    _ => AppColors.muted,
  };

  static Color softOf(String status) => switch (status.toLowerCase().trim()) {
    'completed' || 'paid' || 'done' || 'free' => AppColors.successSoft,
    'pending' || 'pending_payment' => AppColors.warningSoft,
    'confirmed' => AppColors.infoSoft,
    'in_progress' || 'busy' => AppColors.primarySoft,
    'cancelled' || 'canceled' || 'expired' || 'payment_failed' =>
      AppColors.dangerSoft,
    _ => AppColors.canvas,
  };
}

abstract final class AppTheme {
  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.light,
      primary: AppColors.primary,
      surface: AppColors.surface,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.canvas,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      dividerColor: AppColors.border,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: AppText.title,
        shape: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      cardTheme: const CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.card)),
          side: BorderSide(color: AppColors.border),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.sheet)),
        ),
        titleTextStyle: AppText.title,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.sheet),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.text,
        contentTextStyle: const TextStyle(fontSize: 14, color: Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.control)),
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.control)),
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.control)),
          borderSide: BorderSide(color: AppColors.primary, width: 1.5),
        ),
        hintStyle: TextStyle(color: AppColors.muted),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(48, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          minimumSize: const Size(48, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          side: const BorderSide(color: AppColors.border),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(44, 44),
          foregroundColor: AppColors.muted,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.primarySoft,
        height: 68,
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? AppColors.primary
                : AppColors.muted,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? AppColors.primary
                : AppColors.muted,
          ),
        ),
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.primarySoft,
        selectedIconTheme: IconThemeData(color: AppColors.primary),
        unselectedIconTheme: IconThemeData(color: AppColors.muted),
        selectedLabelTextStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppColors.primary,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: AppColors.muted,
        ),
      ),
    );
  }
}
