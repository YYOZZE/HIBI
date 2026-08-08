import 'package:flutter/material.dart';

import 'theme_token.dart';

class ThemeTokenBuilder {
  ThemeTokenBuilder._();

  static ThemeData build(ThemeToken t) {
    final isDark = t.mode == 'dark';
    final cs = ColorScheme(
      brightness: isDark ? Brightness.dark : Brightness.light,
      primary: t.colors.primary,
      onPrimary: _onColor(t.colors.primary, fallback: isDark ? Colors.black : Colors.white),
      secondary: t.colors.secondary,
      onSecondary: _onColor(t.colors.secondary, fallback: isDark ? Colors.black : Colors.white),
      error: t.colors.error,
      onError: Colors.white,
      surface: t.colors.surface,
      onSurface: t.colors.onSurface,
      surfaceContainerHighest: t.colors.surfaceAlt,
      onSurfaceVariant: t.colors.onSurfaceVariant,
      outline: t.colors.outline,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: cs.brightness,
      colorScheme: cs,
      scaffoldBackgroundColor: t.colors.background,
      fontFamily: t.typography.fontFamily,
    );

    final rMd = Radius.circular(t.shape.radiusMd);
    final rLg = Radius.circular(t.shape.radiusLg);

    final shapeMd = RoundedRectangleBorder(borderRadius: BorderRadius.all(rMd));
    final shapeLg = RoundedRectangleBorder(borderRadius: BorderRadius.all(rLg));

    final txt = base.textTheme.apply(
      bodyColor: t.colors.onSurface,
      displayColor: t.colors.onSurface,
    );

    final scale = t.typography.titleScale;
    // 标题规格与内置主题的全局规范对齐（16 × titleScale，w600），正文由 token 的 baseSize 驱动
    final sized = txt.copyWith(
      titleLarge: txt.titleLarge?.copyWith(fontSize: 16 * scale, fontWeight: FontWeight.w600),
      titleMedium: txt.titleMedium?.copyWith(fontSize: 16 * scale, fontWeight: FontWeight.w600),
      titleSmall: txt.titleSmall?.copyWith(fontSize: 16 * scale, fontWeight: FontWeight.w600),
      bodyLarge: txt.bodyLarge?.copyWith(fontSize: t.typography.baseSize + 2, height: 1.35),
      bodyMedium: txt.bodyMedium?.copyWith(fontSize: t.typography.baseSize, height: 1.35),
      bodySmall: txt.bodySmall?.copyWith(fontSize: t.typography.baseSize - 1, height: 1.35),
    );

    return base.copyWith(
      textTheme: sized,
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: cs.onSurface,
        titleTextStyle: sized.titleMedium?.copyWith(color: cs.onSurface),
      ),
      cardTheme: base.cardTheme.copyWith(
        color: cs.surface.withOpacity(t.effects.cardOpacity),
        elevation: t.effects.elevation,
        shape: shapeLg,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: base.dialogTheme.copyWith(
        backgroundColor: cs.surface.withOpacity(0.94),
        elevation: t.effects.elevation + 2,
        shape: shapeLg,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: base.bottomSheetTheme.copyWith(
        backgroundColor: cs.surface.withOpacity(0.94),
        shape: shapeLg,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: base.snackBarTheme.copyWith(
        backgroundColor: cs.surfaceContainerHighest.withOpacity(0.92),
        contentTextStyle: sized.bodyMedium?.copyWith(color: cs.onSurface),
        behavior: SnackBarBehavior.floating,
        shape: shapeMd,
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: cs.surfaceContainerHighest.withOpacity(0.8),
        border: OutlineInputBorder(borderRadius: BorderRadius.all(rMd), borderSide: BorderSide(color: cs.outline)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.all(rMd), borderSide: BorderSide(color: cs.outline.withOpacity(0.8))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.all(rMd), borderSide: BorderSide(color: cs.primary, width: 1.4)),
        hintStyle: sized.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: shapeMd,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: shapeMd,
          side: BorderSide(color: cs.outline.withOpacity(0.9)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      listTileTheme: base.listTileTheme.copyWith(
        shape: shapeMd,
        iconColor: cs.primary,
        textColor: cs.onSurface,
      ),
    );
  }
}

Color _onColor(Color bg, {required Color fallback}) {
  final l = bg.computeLuminance();
  if (l > 0.56) return Colors.black;
  if (l < 0.2) return Colors.white;
  return fallback;
}

