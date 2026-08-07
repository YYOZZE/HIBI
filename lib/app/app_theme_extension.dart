import 'package:flutter/material.dart';

import 'theme_notifier.dart';

/// 主题扩展：供 FrostedBackground 等判断当前是否为「图三毛玻璃」或「纯色背景」
class HibiThemeExtension extends ThemeExtension<HibiThemeExtension> {
  const HibiThemeExtension({
    required this.themeId,
    required this.useImageBackground,
    required this.solidBackgroundColor,
  });

  final AppThemeId themeId;
  /// true = hibi 主题，使用图三 + 毛玻璃；false = 暗色/亮色主题，使用纯色
  final bool useImageBackground;
  /// 暗色/亮色主题时的全局背景色
  final Color solidBackgroundColor;

  @override
  ThemeExtension<HibiThemeExtension> copyWith({
    AppThemeId? themeId,
    bool? useImageBackground,
    Color? solidBackgroundColor,
  }) {
    return HibiThemeExtension(
      themeId: themeId ?? this.themeId,
      useImageBackground: useImageBackground ?? this.useImageBackground,
      solidBackgroundColor: solidBackgroundColor ?? this.solidBackgroundColor,
    );
  }

  @override
  ThemeExtension<HibiThemeExtension> lerp(
    covariant ThemeExtension<HibiThemeExtension>? other,
    double t,
  ) {
    if (other is! HibiThemeExtension) return this;
    return HibiThemeExtension(
      themeId: other.themeId,
      useImageBackground: t < 0.5 ? useImageBackground : other.useImageBackground,
      solidBackgroundColor: Color.lerp(
        solidBackgroundColor,
        other.solidBackgroundColor,
        t,
      )!,
    );
  }

  static HibiThemeExtension of(BuildContext context) {
    final ext = Theme.of(context).extension<HibiThemeExtension>();
    assert(ext != null, 'MaterialApp theme 必须提供 HibiThemeExtension');
    return ext!;
  }
}
