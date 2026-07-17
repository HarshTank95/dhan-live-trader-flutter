import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens — the single source of truth for the app's premium dark skin.
///
/// Discipline rules (this is what makes it look expensive):
///  * ONE accent color (champagne gold), used in <5% of pixels: active tab,
///    live dot, primary CTA. Never on rows, never on numbers.
///  * Green/red are reserved EXCLUSIVELY for price/P&L numbers — softened
///    emerald/rose, not stoplight Colors.green/red.
///  * No colored chrome: app bar, body and nav share the same near-black.
///  * All numbers use tabular figures so digit columns align.
class AppColors {
  AppColors._();

  static const bg = Color(0xFF0B0D10); // everything: app bar, body, sheets base
  static const surface = Color(0xFF14171C); // search field, cards, sheets
  static const surfaceRaised = Color(0xFF1B1F26); // pressed / raised elements
  static const hairline = Color(0x0FFFFFFF); // 6% white row separators

  static const textPrimary = Color(0xFFECEFF4);
  static const textMuted = Color(0xFF8A919E);
  static const textFaint = Color(0xFF565D69);

  static const up = Color(0xFF34D399); // emerald — numbers only
  static const down = Color(0xFFF87171); // rose — numbers only
  static const warn = Color(0xFFF59E0B); // amber — rate-limit / caution

  static const accent = Color(0xFFD8B56A); // champagne gold — signature
  static const accentDim = Color(0x1FD8B56A); // 12% gold fills
}

class AppText {
  AppText._();

  static const _tabular = [FontFeature.tabularFigures()];

  /// Row symbol — e.g. "TCS"
  static const symbol = TextStyle(
      fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0.2);

  /// Row company name under the symbol
  static const rowSub = TextStyle(fontSize: 11.5, color: AppColors.textMuted);

  /// Row price — tabular so the column aligns
  static const price = TextStyle(
      fontSize: 16, fontWeight: FontWeight.w600, fontFeatures: _tabular);

  /// Row change line — color applied at call site (up/down only)
  static const change = TextStyle(
      fontSize: 12.5, fontWeight: FontWeight.w500, fontFeatures: _tabular);

  /// Big price in the detail sheet
  static const priceXL = TextStyle(
      fontSize: 30, fontWeight: FontWeight.w700, fontFeatures: _tabular);

  /// Small tabular figures (counters like 6/20)
  static const counter = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w500,
      color: AppColors.textMuted,
      fontFeatures: _tabular);

  /// Screen title
  static const title = TextStyle(
      fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.3);
}

class AppFmt {
  AppFmt._();

  /// Indian digit grouping without the intl dependency:
  /// 819.6 → "819.60", 2269 → "2,269.00", 123456.7 → "1,23,456.70".
  static String inr(double value, {int decimals = 2}) {
    final neg = value < 0;
    final s = value.abs().toStringAsFixed(decimals);
    final dot = s.indexOf('.');
    var intPart = dot == -1 ? s : s.substring(0, dot);
    final fracPart = dot == -1 ? '' : s.substring(dot);
    if (intPart.length > 3) {
      final last3 = intPart.substring(intPart.length - 3);
      var rest = intPart.substring(0, intPart.length - 3);
      final groups = <String>[];
      while (rest.length > 2) {
        groups.insert(0, rest.substring(rest.length - 2));
        rest = rest.substring(0, rest.length - 2);
      }
      if (rest.isNotEmpty) groups.insert(0, rest);
      intPart = '${groups.join(',')},$last3';
    }
    return '${neg ? '-' : ''}$intPart$fracPart';
  }

  /// Signed change line: "+68.00 (3.09%)" / "-11.30 (1.40%)".
  static String changeLine(double change, double pct) =>
      '${change >= 0 ? '+' : '-'}${inr(change.abs())} '
      '(${pct.abs().toStringAsFixed(2)}%)';
}

class AppTheme {
  AppTheme._();

  static ThemeData dark() {
    final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
    final textTheme = GoogleFonts.interTextTheme(base.textTheme).apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    );
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.bg,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.accent,
        secondary: AppColors.accent,
        surface: AppColors.bg,
        surfaceContainerHighest: AppColors.surface,
        onSurface: AppColors.textPrimary,
        error: AppColors.down,
      ),
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        titleTextStyle: GoogleFonts.inter(textStyle: AppText.title)
            .copyWith(color: AppColors.textPrimary),
      ),
      dividerTheme: const DividerThemeData(
          color: AppColors.hairline, thickness: 1, space: 1),
      drawerTheme: const DrawerThemeData(
          backgroundColor: AppColors.bg, surfaceTintColor: Colors.transparent),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: AppColors.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        textStyle: TextStyle(fontSize: 13.5, color: AppColors.textPrimary),
      ),
      dialogTheme: const DialogThemeData(
          backgroundColor: AppColors.surfaceRaised,
          surfaceTintColor: Colors.transparent),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surfaceRaised,
        contentTextStyle:
            const TextStyle(color: AppColors.textPrimary, fontSize: 13.5),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      listTileTheme: const ListTileThemeData(iconColor: AppColors.textMuted),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? AppColors.accent
                : AppColors.textMuted),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? AppColors.accentDim
                : AppColors.surfaceRaised),
      ),
      progressIndicatorTheme:
          const ProgressIndicatorThemeData(color: AppColors.accent),
    );
  }

  /// Light theme kept functional (user runs dark); same accent, white base.
  static ThemeData light() {
    final base = ThemeData(brightness: Brightness.light, useMaterial3: true);
    return base.copyWith(
      textTheme: GoogleFonts.interTextTheme(base.textTheme),
      colorScheme: ColorScheme.fromSeed(seedColor: AppColors.accent),
      appBarTheme: const AppBarTheme(
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
    );
  }
}
