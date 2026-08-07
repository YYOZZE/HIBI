import 'dart:convert';

import 'package:flutter/material.dart';

/// 主题代码（JSON token）解析结果。
///
/// 目标：允许后台新增主题通过 token 驱动生成 ThemeData，而不是下发可执行代码。
class ThemeToken {
  const ThemeToken({
    required this.name,
    required this.mode,
    required this.colors,
    required this.shape,
    required this.typography,
    required this.effects,
  });

  final String name;
  /// light / dark
  final String mode;
  final ThemeTokenColors colors;
  final ThemeTokenShape shape;
  final ThemeTokenTypography typography;
  final ThemeTokenEffects effects;

  static ThemeToken? tryParse(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    try {
      final j = jsonDecode(t);
      if (j is! Map<String, dynamic>) return null;
      return ThemeToken._fromJson(j);
    } catch (_) {
      return null;
    }
  }

  static ThemeToken _fromJson(Map<String, dynamic> j) {
    final name = j['name']?.toString().trim() ?? '';
    final mode = (j['mode']?.toString().trim().toLowerCase() ?? 'light');
    final colors = ThemeTokenColors._fromJson((j['colors'] is Map) ? (j['colors'] as Map).cast<String, dynamic>() : const {});
    final shape = ThemeTokenShape._fromJson((j['shape'] is Map) ? (j['shape'] as Map).cast<String, dynamic>() : const {});
    final typography = ThemeTokenTypography._fromJson(
      (j['typography'] is Map) ? (j['typography'] as Map).cast<String, dynamic>() : const {},
    );
    final effects = ThemeTokenEffects._fromJson((j['effects'] is Map) ? (j['effects'] as Map).cast<String, dynamic>() : const {});
    return ThemeToken(
      name: name,
      mode: (mode == 'dark') ? 'dark' : 'light',
      colors: colors,
      shape: shape,
      typography: typography,
      effects: effects,
    );
  }
}

class ThemeTokenColors {
  const ThemeTokenColors({
    required this.primary,
    required this.secondary,
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.outline,
    required this.onBackground,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.success,
    required this.warning,
    required this.error,
  });

  final Color primary;
  final Color secondary;
  final Color background;
  final Color surface;
  final Color surfaceAlt;
  final Color outline;
  final Color onBackground;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color success;
  final Color warning;
  final Color error;

  static ThemeTokenColors _fromJson(Map<String, dynamic> j) {
    Color c(String k, Color fb) => _parseColor(j[k], fb);
    return ThemeTokenColors(
      primary: c('primary', const Color(0xFF2563EB)),
      secondary: c('secondary', const Color(0xFF14B8A6)),
      background: c('background', const Color(0xFFF6F7FB)),
      surface: c('surface', const Color(0xFFFFFFFF)),
      surfaceAlt: c('surfaceAlt', const Color(0xFFF1F3FA)),
      outline: c('outline', const Color(0x1A111827)),
      onBackground: c('onBackground', const Color(0xFF0F172A)),
      onSurface: c('onSurface', const Color(0xFF111827)),
      onSurfaceVariant: c('onSurfaceVariant', const Color(0xFF475569)),
      success: c('success', const Color(0xFF16A34A)),
      warning: c('warning', const Color(0xFFF59E0B)),
      error: c('error', const Color(0xFFDC2626)),
    );
  }
}

class ThemeTokenShape {
  const ThemeTokenShape({
    required this.radiusSm,
    required this.radiusMd,
    required this.radiusLg,
  });

  final double radiusSm;
  final double radiusMd;
  final double radiusLg;

  static ThemeTokenShape _fromJson(Map<String, dynamic> j) {
    double d(String k, double fb) {
      final v = j[k];
      if (v is num) return v.toDouble();
      return fb;
    }

    return ThemeTokenShape(
      radiusSm: d('radiusSm', 10),
      radiusMd: d('radiusMd', 14),
      radiusLg: d('radiusLg', 18),
    );
  }
}

class ThemeTokenTypography {
  const ThemeTokenTypography({
    required this.fontFamily,
    required this.baseSize,
    required this.titleScale,
  });

  final String? fontFamily;
  final double baseSize;
  final double titleScale;

  static ThemeTokenTypography _fromJson(Map<String, dynamic> j) {
    final ff = j['fontFamily']?.toString().trim();
    double d(String k, double fb) {
      final v = j[k];
      if (v is num) return v.toDouble();
      return fb;
    }

    return ThemeTokenTypography(
      fontFamily: (ff == null || ff.isEmpty) ? null : ff,
      baseSize: d('baseSize', 14),
      titleScale: d('titleScale', 1.05),
    );
  }
}

class ThemeTokenEffects {
  const ThemeTokenEffects({
    required this.elevation,
    required this.cardOpacity,
    required this.glassBlur,
  });

  final double elevation;
  final double cardOpacity;
  final double glassBlur;

  static ThemeTokenEffects _fromJson(Map<String, dynamic> j) {
    double d(String k, double fb) {
      final v = j[k];
      if (v is num) return v.toDouble();
      return fb;
    }

    double clamp01(double x) => x < 0 ? 0 : (x > 1 ? 1 : x);
    return ThemeTokenEffects(
      elevation: d('elevation', 2),
      cardOpacity: clamp01(d('cardOpacity', 0.72)),
      glassBlur: d('glassBlur', 10),
    );
  }
}

Color _parseColor(dynamic raw, Color fallback) {
  if (raw == null) return fallback;
  if (raw is int) {
    // 允许 0xAARRGGBB
    return Color(raw);
  }
  final s = raw.toString().trim();
  if (s.isEmpty) return fallback;
  String hex = s;
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (hex.startsWith('0x') || hex.startsWith('0X')) hex = hex.substring(2);
  if (hex.length == 6) hex = 'FF$hex';
  if (hex.length != 8) return fallback;
  final v = int.tryParse(hex, radix: 16);
  if (v == null) return fallback;
  return Color(v);
}

