import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Semantic color tokens that adapt to light/dark mode.
/// Use these instead of hardcoded whites/greys so every screen follows
/// the active theme: `context.her.card`, `context.her.ink`, `context.her.muted`.
@immutable
class HerCycleColors extends ThemeExtension<HerCycleColors> {
  /// Card / sheet surfaces (white in light, plum-charcoal in dark).
  final Color card;

  /// Primary text ink (soft dark grey in light, warm off-white in dark).
  final Color ink;

  /// Secondary / hint text.
  final Color muted;

  const HerCycleColors({
    required this.card,
    required this.ink,
    required this.muted,
  });

  @override
  HerCycleColors copyWith({Color? card, Color? ink, Color? muted}) {
    return HerCycleColors(
      card: card ?? this.card,
      ink: ink ?? this.ink,
      muted: muted ?? this.muted,
    );
  }

  @override
  HerCycleColors lerp(ThemeExtension<HerCycleColors>? other, double t) {
    if (other is! HerCycleColors) return this;
    return HerCycleColors(
      card: Color.lerp(card, other.card, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
    );
  }
}

/// Shorthand: `context.her.card` etc. Falls back to the light tokens when
/// no themed [HerCycleColors] extension is present (e.g. widget tests
/// pumping screens under a bare MaterialApp).
extension HerThemeContext on BuildContext {
  HerCycleColors get her =>
      Theme.of(this).extension<HerCycleColors>() ?? AppTheme.lightTokens;
}

class AppTheme {
  static const Color primaryColor = Color(0xFFC26D81); // Brand pink (both modes)
  static const Color secondaryColor = Color(0xFFF9C8D2); // Light pink accent
  static const Color backgroundColor = Color(0xFFFFF0F2); // Warm cream/pink
  static const Color textColor = Color(0xFF4A4A4A); // Soft dark grey

  // Dark palette: deep plum-charcoal that keeps the feminine brand feel.
  static const Color darkBackgroundColor = Color(0xFF1D1219);
  static const Color darkSurfaceColor = Color(0xFF2A1D26);
  static const Color darkTextColor = Color(0xFFF5E9EE);
  static const Color darkMutedColor = Color(0xFFB9A6B2);

  static const HerCycleColors lightTokens = HerCycleColors(
    card: Colors.white,
    ink: textColor,
    muted: Color(0xFF757575),
  );

  static const HerCycleColors darkTokens = HerCycleColors(
    card: darkSurfaceColor,
    ink: darkTextColor,
    muted: darkMutedColor,
  );

  static ThemeData get theme => light;
  static ThemeData get light => _build(
        brightness: Brightness.light,
        seedScheme: ColorScheme.fromSeed(
          seedColor: primaryColor,
          brightness: Brightness.light,
          primary: primaryColor,
          secondary: secondaryColor,
          surface: backgroundColor,
        ),
        scaffoldBackgroundColor: backgroundColor,
        tokens: lightTokens,
        inputFill: Colors.white,
        inputBorder: Colors.grey.shade300,
        displayColor: textColor,
        bodyColor: textColor,
      );

  static ThemeData get dark => _build(
        brightness: Brightness.dark,
        seedScheme: ColorScheme.fromSeed(
          seedColor: primaryColor,
          brightness: Brightness.dark,
          primary: primaryColor,
          secondary: secondaryColor,
          surface: darkSurfaceColor,
        ),
        scaffoldBackgroundColor: darkBackgroundColor,
        tokens: darkTokens,
        inputFill: darkSurfaceColor,
        inputBorder: const Color(0xFF4A3542),
        displayColor: darkTextColor,
        bodyColor: darkTextColor,
      );

  static ThemeData _build({
    required Brightness brightness,
    required ColorScheme seedScheme,
    required Color scaffoldBackgroundColor,
    required HerCycleColors tokens,
    required Color inputFill,
    required Color inputBorder,
    required Color displayColor,
    required Color bodyColor,
  }) {
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: seedScheme,
      scaffoldBackgroundColor: scaffoldBackgroundColor,
      extensions: [tokens],
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
      textTheme: GoogleFonts.poppinsTextTheme().copyWith(
        displayLarge: GoogleFonts.poppins(
            fontSize: 28, fontWeight: FontWeight.bold, color: displayColor),
        bodyMedium: GoogleFonts.poppins(fontSize: 14, color: bodyColor),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputFill,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: inputBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: inputBorder),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
          padding: const EdgeInsets.symmetric(vertical: 16),
          textStyle:
              const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
