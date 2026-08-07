import 'package:flutter/material.dart';

import 'app_theme_extension.dart';
import 'theme_notifier.dart';

/// 应用主题：hibi 主题（图三毛玻璃）、暗色主题、亮色主题；可保留 logo 蓝为点缀色
class AppTheme {
  AppTheme._();

  /// Logo 蓝（点缀色，暗色/亮色主题主色）
  static const Color logoBlue = Color(0xFF1976D2);
  static const Color logoBlueLight = Color(0xFF42A5F5);

  /// hibi 主题：深紫主色
  static const Color _mainPurple = Color(0xFF1D1155);
  static const Color _onSelected = Color(0xFFE8E4F0);
  static const Color _surfaceDark = Color(0xFF120A33);
  static const Color _surfaceGlass = Color(0x1A1D1155);
  static const Color _textPrimary = Color(0xFFF0EEF5);
  static const Color _textSecondary = Color(0xFFD0CCE0);

  /// 暗色主题：纯色背景色
  static const Color _darkSolidBg = Color(0xFF121212);
  static const Color _darkSurface = Color(0xFF1E1E1E);

  /// 亮色主题：毛玻璃灰背景（略降亮度，减少刺眼）
  static const Color _lightSolidBg = Color(0xFFDEDEE0);
  static const Color _lightSurface = Color(0xFFE4E4E6);
  /// 亮色主题正文/副标题用深灰，提升可读性
  static const Color _lightOnSurfaceVariant = Color(0xFF424242);

  /// 2027SS：高级感、类苹果风格（深色基底 + 发光蓝 + 暖灰中和）
  static const Color _ss2027Bg = Color(0xFF0D1016);
  static const Color _ss2027Surface = Color(0xFF171C25);
  static const Color _ss2027Elevated = Color(0xFF1E2430);
  static const Color _ss2027Primary = Color(0xFF4A8BFF); // Luminous Blue 风格
  static const Color _ss2027OnSurface = Color(0xFFF4F7FF);
  static const Color _ss2027OnSurfaceVariant = Color(0xFFB7C2D6);
  static const Color _ss2027Outline = Color(0x334A8BFF);

  /// 梦幻：女性向柔和配色（参考粉紫/奶油黄/浅蓝），类苹果清透卡片风格
  static const Color _dreamBg = Color(0xFFF8F2FF);
  static const Color _dreamSurface = Color(0xFFFFF9FF);
  static const Color _dreamSurfaceElevated = Color(0xFFF6ECFF);
  static const Color _dreamPrimary = Color(0xFFD76EEA);
  static const Color _dreamSecondary = Color(0xFF7CC7FF);
  static const Color _dreamOnSurface = Color(0xFF3B2C4A);
  static const Color _dreamOnSurfaceVariant = Color(0xFF6E6280);
  static const Color _dreamOutline = Color(0x66E2C7FF);

  /// 梦幻·夜：梦幻风格的夜间版本（更深背景，更柔和发光）
  static const Color _dreamNightBg = Color(0xFF171222);
  static const Color _dreamNightSurface = Color(0xFF221A31);
  static const Color _dreamNightSurfaceElevated = Color(0xFF2A213B);
  static const Color _dreamNightPrimary = Color(0xFFE089FF);
  static const Color _dreamNightSecondary = Color(0xFF8ECFFF);
  static const Color _dreamNightOnSurface = Color(0xFFF9F3FF);
  static const Color _dreamNightOnSurfaceVariant = Color(0xFFD4C8E5);
  static const Color _dreamNightOutline = Color(0x55DFA6FF);

  /// CyberPunk：赛博科技感（霓虹黄 + 青蓝 + 洋红）+ 深夜高对比
  static const Color _cpBg = Color(0xFF05070C);
  static const Color _cpSurface = Color(0xFF0D111A);
  static const Color _cpSurfaceElevated = Color(0xFF121827);
  static const Color _cpNeonYellow = Color(0xFFF2E900);
  static const Color _cpNeonCyan = Color(0xFF02D7F2);
  static const Color _cpNeonMagenta = Color(0xFFFF2FA3);
  static const Color _cpOnSurface = Color(0xFFEAF7FF);
  static const Color _cpOnSurfaceVariant = Color(0xFF8EA6BD);
  static const Color _cpOutline = Color(0x6602D7F2);

  /// 星界：宇宙紫 + 星蓝青 + 金属金边点缀
  static const Color _astralBg = Color(0xFF0A0716);
  static const Color _astralSurface = Color(0xFF151033);
  static const Color _astralElevated = Color(0xFF1B1540);
  static const Color _astralPrimary = Color(0xFF39D4FF); // 星蓝青
  static const Color _astralSecondary = Color(0xFF6F86FF); // 深空蓝
  static const Color _astralAccentGold = Color(0xFFD8B36A); // 金属装饰色
  static const Color _astralOnSurface = Color(0xFFF2F4FF);
  static const Color _astralOnSurfaceVariant = Color(0xFFB6BCE8);
  static const Color _astralOutline = Color(0x6639D4FF);

  /// 星界·幻：在星界基础上的冰蓝-紫雾玻璃质感进阶。
  static const Color _astralPhBg = Color(0xFF070A16);
  static const Color _astralPhSurface = Color(0xFF131A33);
  static const Color _astralPhElevated = Color(0xFF1A2344);
  static const Color _astralPhPrimary = Color(0xFF7EE3FF);
  static const Color _astralPhSecondary = Color(0xFF9EACFF);
  static const Color _astralPhTertiary = Color(0xFFCBA3FF);
  static const Color _astralPhOnSurface = Color(0xFFF6F8FF);
  static const Color _astralPhOnSurfaceVariant = Color(0xFFC9D3F3);
  static const Color _astralPhOutline = Color(0x668AB8FF);

  /// 地界：深海蓝 + 苍穹光蓝 + 铠甲金，稳重史诗感
  static const Color _earthBg = Color(0xFF081227);
  static const Color _earthSurface = Color(0xFF11213D);
  static const Color _earthElevated = Color(0xFF162B4D);
  static const Color _earthPrimary = Color(0xFF4CC3FF);
  static const Color _earthSecondary = Color(0xFF7FE2FF);
  static const Color _earthAccentGold = Color(0xFFCCA86A);
  static const Color _earthOnSurface = Color(0xFFF1F7FF);
  static const Color _earthOnSurfaceVariant = Color(0xFFB6C6E0);
  static const Color _earthOutline = Color(0x6651C8FF);

  static const Color loadingIndicatorColor = _onSelected;

  /// 全局统一字号与字重：页面标题与区块标题统一 16px w400，副标题 14px w400
  static const double _fontSizeAppBar = 16.0;
  static const double _fontSizeTitle = 16.0;
  static const double _fontSizeListTitle = 16.0;
  static const double _fontSizeBody = 15.0;
  static const double _fontSizeListSubtitle = 14.0;
  static const double _fontSizeCaption = 12.0;

  /// 根据主题 ID 返回对应 ThemeData（含 HibiThemeExtension）
  static ThemeData getTheme(AppThemeId id) {
    switch (id) {
      case AppThemeId.hibi:
        return _hibiTheme;
      case AppThemeId.dark:
        return _darkPureTheme;
      case AppThemeId.light:
        return _lightPureTheme;
      case AppThemeId.spring2027:
        return _spring2027Theme;
      case AppThemeId.dreamy:
        return _dreamyTheme;
      case AppThemeId.dreamyNight:
        return _dreamyNightTheme;
      case AppThemeId.cyberpunk:
        return _cyberpunkTheme;
      case AppThemeId.astral:
        return _astralTheme;
      case AppThemeId.astralPhantasm:
        return _astralPhantasmTheme;
      case AppThemeId.earthrealm:
        return _earthrealmTheme;
    }
  }

  /// hibi 主题：hibi主题背景 + 深紫色系
  static ThemeData get _hibiTheme {
    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: _mainPurple,
        onPrimary: _onSelected,
        primaryContainer: _mainPurple.withOpacity(0.6),
        onPrimaryContainer: _onSelected,
        secondary: _mainPurple,
        onSecondary: _onSelected,
        surface: _surfaceDark,
        onSurface: _textPrimary,
        surfaceContainerHighest: _mainPurple.withOpacity(0.5),
        onSurfaceVariant: _textSecondary,
        outline: _mainPurple.withOpacity(0.6),
        error: const Color(0xFFE07A5F),
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: Colors.transparent,
      // 正文/描述统一 w400；标题、卡片标题可用 w500/w600。使用 copyWith 时请显式指定 fontWeight，避免同句内粗细不一致。
      textTheme: TextTheme(
        headlineSmall: const TextStyle(
          color: _textPrimary,
          fontWeight: FontWeight.w400,
          fontSize: _fontSizeListTitle,
        ),
        titleLarge: const TextStyle(
          color: _textPrimary,
          fontWeight: FontWeight.w400,
          fontSize: _fontSizeListTitle,
        ),
        titleMedium: const TextStyle(
          color: _textPrimary,
          fontWeight: FontWeight.w400,
          fontSize: _fontSizeTitle,
        ),
        titleSmall: const TextStyle(
          color: _textPrimary,
          fontWeight: FontWeight.w400,
          fontSize: _fontSizeListTitle,
        ),
        bodyLarge: const TextStyle(color: _textPrimary, fontWeight: FontWeight.w400, fontSize: _fontSizeBody + 1),
        bodyMedium: const TextStyle(color: _textSecondary, fontWeight: FontWeight.w400, fontSize: _fontSizeBody),
        bodySmall: const TextStyle(color: _textSecondary, fontWeight: FontWeight.w400, fontSize: _fontSizeListSubtitle),
        labelLarge: const TextStyle(color: _textSecondary, fontWeight: FontWeight.w400, fontSize: _fontSizeListSubtitle),
        labelMedium: const TextStyle(color: _textSecondary, fontWeight: FontWeight.w400, fontSize: _fontSizeCaption),
        labelSmall: const TextStyle(color: _textSecondary, fontWeight: FontWeight.w400, fontSize: 11),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: _textPrimary),
        titleTextStyle: TextStyle(
          color: _textPrimary,
          fontSize: _fontSizeAppBar,
          fontWeight: FontWeight.w400,
        ),
      ),
      // 底部导航：选中 = 浅灰字/图标（深紫底对比）；未选中 = 次要文字色
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _surfaceGlass,
        elevation: 0,
        height: 64,
        indicatorColor: _mainPurple,
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: Color(0xFFE0E0E0), size: 24);
          }
          return const IconThemeData(color: _textSecondary, size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              color: Color(0xFFE0E0E0),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            );
          }
          return const TextStyle(
            color: _textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w400,
          );
        }),
      ),
      cardTheme: CardTheme(
        color: Colors.white.withOpacity(0.06),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: _mainPurple.withOpacity(0.35), width: 1),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: _mainPurple.withOpacity(0.5),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: _mainPurple.withOpacity(0.4), width: 1),
        ),
        titleTextStyle: const TextStyle(
          color: _textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w400,
        ),
        contentTextStyle: const TextStyle(
          color: _textSecondary,
          fontSize: 14,
          fontWeight: FontWeight.w400,
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: _textSecondary,
        textColor: _textPrimary,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: _mainPurple.withOpacity(0.55),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withOpacity(0.04),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _mainPurple.withOpacity(0.25)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _mainPurple.withOpacity(0.25)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _mainPurple.withOpacity(0.65), width: 1.2),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: _mainPurple.withOpacity(0.35),
        thickness: 0.5,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
      ),
    );
    return theme.copyWith(
      extensions: <ThemeExtension<dynamic>>[
        const HibiThemeExtension(
          themeId: AppThemeId.hibi,
          useImageBackground: true,
          solidBackgroundColor: _surfaceDark,
        ),
      ],
    );
  }

  /// 暗色主题：纯色深色背景 + Logo 蓝点缀
  static ThemeData get _darkPureTheme {
    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: logoBlue,
        onPrimary: Colors.white,
        primaryContainer: logoBlue.withOpacity(0.3),
        onPrimaryContainer: logoBlueLight,
        secondary: logoBlue,
        onSecondary: Colors.white,
        surface: _darkSurface,
        onSurface: const Color(0xFFE3E3E3),
        surfaceContainerHighest: const Color(0xFF2C2C2C),
        onSurfaceVariant: const Color(0xFFB0B0B0),
        outline: const Color(0xFF404040),
        error: const Color(0xFFCF6679),
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFFE3E3E3)),
        titleTextStyle: const TextStyle(
          color: Color(0xFFE3E3E3),
          fontSize: _fontSizeAppBar,
          fontWeight: FontWeight.w400,
        ),
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(color: Color(0xFFE3E3E3), fontWeight: FontWeight.w400, fontSize: _fontSizeListTitle),
        titleMedium: TextStyle(color: Color(0xFFE3E3E3), fontWeight: FontWeight.w400, fontSize: _fontSizeTitle),
        titleSmall: TextStyle(color: Color(0xFFE3E3E3), fontWeight: FontWeight.w400, fontSize: _fontSizeListTitle),
        bodyLarge: TextStyle(color: Color(0xFFE3E3E3), fontWeight: FontWeight.w400, fontSize: _fontSizeBody + 1),
        bodyMedium: TextStyle(color: Color(0xFFB0B0B0), fontWeight: FontWeight.w400, fontSize: _fontSizeBody),
        bodySmall: TextStyle(color: Color(0xFFB0B0B0), fontWeight: FontWeight.w400, fontSize: _fontSizeListSubtitle),
        labelLarge: TextStyle(color: Color(0xFFB0B0B0), fontWeight: FontWeight.w400, fontSize: _fontSizeListSubtitle),
        labelMedium: TextStyle(color: Color(0xFFB0B0B0), fontWeight: FontWeight.w400, fontSize: _fontSizeCaption),
        labelSmall: TextStyle(color: Color(0xFFB0B0B0), fontWeight: FontWeight.w400, fontSize: 11),
      ),
      // 底部导航：选中 = 深灰字/图标（蓝底对比）；未选中 = 次要文字色
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xE6121212),
        elevation: 0,
        height: 64,
        indicatorColor: logoBlue,
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: Color(0xFF2D2D2D), size: 24);
          }
          return const IconThemeData(color: Color(0xFF9AA0A6), size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              color: Color(0xFF2D2D2D),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            );
          }
          return const TextStyle(
            color: Color(0xFF9AA0A6),
            fontSize: 12,
            fontWeight: FontWeight.w400,
          );
        }),
      ),
      cardTheme: CardTheme(
        color: const Color(0xFF2C2C2C),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withOpacity(0.08), width: 1),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: _darkSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withOpacity(0.1), width: 1),
        ),
        titleTextStyle: const TextStyle(color: Color(0xFFE3E3E3), fontSize: 16, fontWeight: FontWeight.w400),
        contentTextStyle: const TextStyle(color: Color(0xFFB0B0B0), fontSize: 14, fontWeight: FontWeight.w400),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withOpacity(0.08),
        hintStyle: TextStyle(color: const Color(0xFFB0B0B0).withOpacity(0.9)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: logoBlue, width: 1.2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: _darkSurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.all(logoBlue),
          foregroundColor: WidgetStateProperty.all(Colors.white),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all(logoBlue),
          side: WidgetStateProperty.all(const BorderSide(color: logoBlue)),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
      ),
    );
    return theme.copyWith(
      extensions: <ThemeExtension<dynamic>>[
        const HibiThemeExtension(
          themeId: AppThemeId.dark,
          useImageBackground: false,
          solidBackgroundColor: _darkSolidBg,
        ),
      ],
    );
  }

  /// 亮色主题：纯色浅色背景 + Logo 蓝点缀（柔和不刺眼，AppBar 与字体对比度优化）
  static ThemeData get _lightPureTheme {
    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.light(
        primary: logoBlue,
        onPrimary: Colors.white,
        primaryContainer: logoBlue.withOpacity(0.15),
        onPrimaryContainer: const Color(0xFF0D47A1),
        secondary: logoBlue,
        onSecondary: Colors.white,
        surface: _lightSurface,
        onSurface: const Color(0xFF1C1C1C),
        surfaceContainerHighest: const Color(0xFFE0E0E0),
        onSurfaceVariant: _lightOnSurfaceVariant,
        outline: const Color(0xFFBDBDBD),
        error: const Color(0xFFB00020),
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: Colors.transparent,
      textTheme: const TextTheme(
        titleLarge: TextStyle(color: Color(0xFF1C1C1C), fontWeight: FontWeight.w400, fontSize: _fontSizeListTitle),
        titleMedium: TextStyle(color: Color(0xFF1C1C1C), fontWeight: FontWeight.w400, fontSize: _fontSizeTitle),
        titleSmall: TextStyle(color: Color(0xFF1C1C1C), fontWeight: FontWeight.w400, fontSize: _fontSizeListTitle),
        bodyLarge: TextStyle(color: Color(0xFF1C1C1C), fontWeight: FontWeight.w400, fontSize: _fontSizeBody + 1),
        bodyMedium: TextStyle(color: Color(0xFF1C1C1C), fontWeight: FontWeight.w400, fontSize: _fontSizeBody),
        bodySmall: TextStyle(color: Color(0xFF424242), fontWeight: FontWeight.w400, fontSize: _fontSizeListSubtitle),
        labelLarge: TextStyle(color: Color(0xFF424242), fontWeight: FontWeight.w400, fontSize: _fontSizeListSubtitle),
        labelMedium: TextStyle(color: Color(0xFF424242), fontWeight: FontWeight.w400, fontSize: _fontSizeCaption),
        labelSmall: TextStyle(color: Color(0xFF424242), fontWeight: FontWeight.w400, fontSize: 11),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: _lightSolidBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF1C1C1C)),
        titleTextStyle: const TextStyle(
          color: Color(0xFF1C1C1C),
          fontSize: _fontSizeAppBar,
          fontWeight: FontWeight.w400,
        ),
      ),
      // 底部导航：选中 = 深灰字/图标（蓝底对比）；未选中 = 深灰 #5F6368
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _lightSolidBg,
        elevation: 0,
        height: 64,
        indicatorColor: logoBlue,
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: Color(0xFF2D2D2D), size: 24);
          }
          return const IconThemeData(color: Color(0xFF5F6368), size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              color: Color(0xFF2D2D2D),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            );
          }
          return const TextStyle(
            color: Color(0xFF5F6368),
            fontSize: 12,
            fontWeight: FontWeight.w400,
          );
        }),
      ),
      cardTheme: CardTheme(
        color: _lightSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.black.withOpacity(0.08), width: 1),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: _lightSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.black.withOpacity(0.1), width: 1),
        ),
        titleTextStyle: const TextStyle(color: Color(0xFF1C1C1C), fontSize: 16, fontWeight: FontWeight.w400),
        contentTextStyle: const TextStyle(color: Color(0xFF424242), fontSize: 14, fontWeight: FontWeight.w400),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFE0E0E0).withOpacity(0.8),
        hintStyle: const TextStyle(color: Color(0xFF616161)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.black.withOpacity(0.12)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: logoBlue, width: 1.2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: _lightSurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.all(logoBlue),
          foregroundColor: WidgetStateProperty.all(Colors.white),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all(logoBlue),
          side: WidgetStateProperty.all(const BorderSide(color: logoBlue)),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
      ),
    );
    return theme.copyWith(
      extensions: <ThemeExtension<dynamic>>[
        const HibiThemeExtension(
          themeId: AppThemeId.light,
          useImageBackground: false,
          solidBackgroundColor: _lightSolidBg,
        ),
      ],
    );
  }

  /// 2027SS：更高级、类苹果风格（深色分层 + 柔和高光 + 更大圆角）
  static ThemeData get _spring2027Theme {
    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: _ss2027Primary,
        onPrimary: Colors.white,
        primaryContainer: _ss2027Primary.withOpacity(0.22),
        onPrimaryContainer: const Color(0xFFDDE8FF),
        secondary: const Color(0xFF8DA4CC),
        onSecondary: _ss2027OnSurface,
        surface: _ss2027Surface,
        onSurface: _ss2027OnSurface,
        surfaceContainerHighest: _ss2027Elevated,
        onSurfaceVariant: _ss2027OnSurfaceVariant,
        outline: _ss2027Outline,
        error: const Color(0xFFFF6B6B),
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: _ss2027OnSurface),
        titleTextStyle: TextStyle(
          color: _ss2027OnSurface,
          fontSize: _fontSizeAppBar,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.1,
        ),
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(color: _ss2027OnSurface, fontWeight: FontWeight.w500, fontSize: _fontSizeListTitle),
        titleMedium: TextStyle(color: _ss2027OnSurface, fontWeight: FontWeight.w500, fontSize: _fontSizeTitle),
        titleSmall: TextStyle(color: _ss2027OnSurface, fontWeight: FontWeight.w500, fontSize: _fontSizeListTitle),
        bodyLarge: TextStyle(color: _ss2027OnSurface, fontWeight: FontWeight.w400, fontSize: _fontSizeBody + 1),
        bodyMedium: TextStyle(color: _ss2027OnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeBody),
        bodySmall: TextStyle(color: _ss2027OnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeListSubtitle),
        labelLarge: TextStyle(color: _ss2027OnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeListSubtitle),
        labelMedium: TextStyle(color: _ss2027OnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeCaption),
        labelSmall: TextStyle(color: _ss2027OnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: 11),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xC80D1016),
        elevation: 0,
        height: 64,
        indicatorColor: _ss2027Primary.withOpacity(0.9),
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: Color(0xFF11223F), size: 24);
          }
          return const IconThemeData(color: _ss2027OnSurfaceVariant, size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              color: Color(0xFF11223F),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            );
          }
          return const TextStyle(
            color: _ss2027OnSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w400,
          );
        }),
      ),
      cardTheme: CardTheme(
        color: _ss2027Surface.withOpacity(0.82),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: _ss2027Outline, width: 1),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: _ss2027Surface.withOpacity(0.96),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: _ss2027Outline, width: 1),
        ),
        titleTextStyle: const TextStyle(color: _ss2027OnSurface, fontSize: 16, fontWeight: FontWeight.w500),
        contentTextStyle: const TextStyle(color: _ss2027OnSurfaceVariant, fontSize: 14, fontWeight: FontWeight.w400),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withOpacity(0.06),
        hintStyle: const TextStyle(color: _ss2027OnSurfaceVariant),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.12)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: _ss2027Primary.withOpacity(0.95), width: 1.3),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: _ss2027Surface.withOpacity(0.98),
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.all(_ss2027Primary),
          foregroundColor: WidgetStateProperty.all(Colors.white),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all(_ss2027Primary),
          side: WidgetStateProperty.all(BorderSide(color: _ss2027Primary.withOpacity(0.75))),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
    );
    return theme.copyWith(
      extensions: <ThemeExtension<dynamic>>[
        const HibiThemeExtension(
          themeId: AppThemeId.spring2027,
          useImageBackground: false,
          solidBackgroundColor: _ss2027Bg,
        ),
      ],
    );
  }

  /// 梦幻：柔和粉紫 + 浅蓝点缀，圆角更大，整体清透（类苹果）
  static ThemeData get _dreamyTheme {
    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.light(
        primary: _dreamPrimary,
        onPrimary: Colors.white,
        primaryContainer: const Color(0xFFF5D8FF),
        onPrimaryContainer: const Color(0xFF6A2E79),
        secondary: _dreamSecondary,
        onSecondary: Colors.white,
        surface: _dreamSurface,
        onSurface: _dreamOnSurface,
        surfaceContainerHighest: _dreamSurfaceElevated,
        onSurfaceVariant: _dreamOnSurfaceVariant,
        outline: _dreamOutline,
        error: const Color(0xFFCC4B7A),
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: _dreamOnSurface),
        titleTextStyle: TextStyle(
          color: _dreamOnSurface,
          fontSize: _fontSizeAppBar,
          fontWeight: FontWeight.w500,
        ),
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(color: _dreamOnSurface, fontWeight: FontWeight.w500, fontSize: _fontSizeListTitle),
        titleMedium: TextStyle(color: _dreamOnSurface, fontWeight: FontWeight.w500, fontSize: _fontSizeTitle),
        titleSmall: TextStyle(color: _dreamOnSurface, fontWeight: FontWeight.w500, fontSize: _fontSizeListTitle),
        bodyLarge: TextStyle(color: _dreamOnSurface, fontWeight: FontWeight.w400, fontSize: _fontSizeBody + 1),
        bodyMedium: TextStyle(color: _dreamOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeBody),
        bodySmall: TextStyle(color: _dreamOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeListSubtitle),
        labelLarge: TextStyle(color: _dreamOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeListSubtitle),
        labelMedium: TextStyle(color: _dreamOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeCaption),
        labelSmall: TextStyle(color: _dreamOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: 11),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xE8FFF6FF),
        elevation: 0,
        height: 64,
        indicatorColor: _dreamPrimary.withOpacity(0.9),
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: Colors.white, size: 24);
          }
          return const IconThemeData(color: _dreamOnSurfaceVariant, size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            );
          }
          return const TextStyle(
            color: _dreamOnSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w400,
          );
        }),
      ),
      cardTheme: CardTheme(
        color: _dreamSurface.withOpacity(0.86),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: _dreamOutline, width: 1),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: _dreamSurface.withOpacity(0.94),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: _dreamOutline, width: 1),
        ),
        titleTextStyle: const TextStyle(color: _dreamOnSurface, fontSize: 16, fontWeight: FontWeight.w500),
        contentTextStyle: const TextStyle(color: _dreamOnSurfaceVariant, fontSize: 14, fontWeight: FontWeight.w400),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withOpacity(0.72),
        hintStyle: const TextStyle(color: _dreamOnSurfaceVariant),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: _dreamOutline.withOpacity(0.9)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: _dreamPrimary.withOpacity(0.85), width: 1.2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: _dreamSurface.withOpacity(0.96),
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.all(_dreamPrimary),
          foregroundColor: WidgetStateProperty.all(Colors.white),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all(_dreamPrimary),
          side: WidgetStateProperty.all(BorderSide(color: _dreamPrimary.withOpacity(0.55))),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
    );
    return theme.copyWith(
      extensions: <ThemeExtension<dynamic>>[
        const HibiThemeExtension(
          themeId: AppThemeId.dreamy,
          useImageBackground: false,
          solidBackgroundColor: _dreamBg,
        ),
      ],
    );
  }

  /// 梦幻·夜：梦幻配色的夜间版本
  static ThemeData get _dreamyNightTheme {
    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: _dreamNightPrimary,
        onPrimary: const Color(0xFF31143D),
        primaryContainer: _dreamNightPrimary.withOpacity(0.26),
        onPrimaryContainer: _dreamNightOnSurface,
        secondary: _dreamNightSecondary,
        onSecondary: const Color(0xFF1A2A3B),
        surface: _dreamNightSurface,
        onSurface: _dreamNightOnSurface,
        surfaceContainerHighest: _dreamNightSurfaceElevated,
        onSurfaceVariant: _dreamNightOnSurfaceVariant,
        outline: _dreamNightOutline,
        error: const Color(0xFFFF7AA2),
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: _dreamNightOnSurface),
        titleTextStyle: TextStyle(
          color: _dreamNightOnSurface,
          fontSize: _fontSizeAppBar,
          fontWeight: FontWeight.w500,
        ),
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(color: _dreamNightOnSurface, fontWeight: FontWeight.w500, fontSize: _fontSizeListTitle),
        titleMedium: TextStyle(color: _dreamNightOnSurface, fontWeight: FontWeight.w500, fontSize: _fontSizeTitle),
        titleSmall: TextStyle(color: _dreamNightOnSurface, fontWeight: FontWeight.w500, fontSize: _fontSizeListTitle),
        bodyLarge: TextStyle(color: _dreamNightOnSurface, fontWeight: FontWeight.w400, fontSize: _fontSizeBody + 1),
        bodyMedium: TextStyle(color: _dreamNightOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeBody),
        bodySmall: TextStyle(color: _dreamNightOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeListSubtitle),
        labelLarge: TextStyle(color: _dreamNightOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeListSubtitle),
        labelMedium: TextStyle(color: _dreamNightOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeCaption),
        labelSmall: TextStyle(color: _dreamNightOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: 11),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xD9171222),
        elevation: 0,
        height: 64,
        indicatorColor: _dreamNightPrimary.withOpacity(0.92),
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: Color(0xFF2D1237), size: 24);
          }
          return const IconThemeData(color: _dreamNightOnSurfaceVariant, size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              color: Color(0xFF2D1237),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            );
          }
          return const TextStyle(
            color: _dreamNightOnSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w400,
          );
        }),
      ),
      cardTheme: CardTheme(
        color: _dreamNightSurface.withOpacity(0.82),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: _dreamNightOutline, width: 1),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: _dreamNightSurface.withOpacity(0.94),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: _dreamNightOutline, width: 1),
        ),
        titleTextStyle: const TextStyle(color: _dreamNightOnSurface, fontSize: 16, fontWeight: FontWeight.w500),
        contentTextStyle: const TextStyle(color: _dreamNightOnSurfaceVariant, fontSize: 14, fontWeight: FontWeight.w400),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withOpacity(0.08),
        hintStyle: const TextStyle(color: _dreamNightOnSurfaceVariant),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.15)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: _dreamNightPrimary.withOpacity(0.9), width: 1.2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: _dreamNightSurface.withOpacity(0.96),
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.all(_dreamNightPrimary),
          foregroundColor: WidgetStateProperty.all(const Color(0xFF2D1237)),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all(_dreamNightPrimary),
          side: WidgetStateProperty.all(BorderSide(color: _dreamNightPrimary.withOpacity(0.6))),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
    );
    return theme.copyWith(
      extensions: <ThemeExtension<dynamic>>[
        const HibiThemeExtension(
          themeId: AppThemeId.dreamyNight,
          useImageBackground: false,
          solidBackgroundColor: _dreamNightBg,
        ),
      ],
    );
  }

  /// CyberPunk：赛博科技感主题
  static ThemeData get _cyberpunkTheme {
    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: _cpNeonYellow,
        onPrimary: const Color(0xFF171300),
        primaryContainer: _cpNeonYellow.withOpacity(0.26),
        onPrimaryContainer: const Color(0xFFFFF9A8),
        secondary: _cpNeonCyan,
        onSecondary: const Color(0xFF00171B),
        tertiary: _cpNeonMagenta,
        onTertiary: Colors.white,
        surface: _cpSurface,
        onSurface: _cpOnSurface,
        surfaceContainerHighest: _cpSurfaceElevated,
        onSurfaceVariant: _cpOnSurfaceVariant,
        outline: _cpOutline,
        error: const Color(0xFFFF365A),
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: _cpOnSurface),
        titleTextStyle: TextStyle(
          color: _cpOnSurface,
          fontSize: _fontSizeAppBar,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(color: _cpOnSurface, fontWeight: FontWeight.w600, fontSize: _fontSizeListTitle, letterSpacing: 0.4),
        titleMedium: TextStyle(color: _cpOnSurface, fontWeight: FontWeight.w600, fontSize: _fontSizeTitle, letterSpacing: 0.3),
        titleSmall: TextStyle(color: _cpOnSurface, fontWeight: FontWeight.w600, fontSize: _fontSizeListTitle, letterSpacing: 0.3),
        bodyLarge: TextStyle(color: _cpOnSurface, fontWeight: FontWeight.w400, fontSize: _fontSizeBody + 1),
        bodyMedium: TextStyle(color: _cpOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeBody),
        bodySmall: TextStyle(color: _cpOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeListSubtitle),
        labelLarge: TextStyle(color: _cpOnSurfaceVariant, fontWeight: FontWeight.w500, fontSize: _fontSizeListSubtitle, letterSpacing: 0.2),
        labelMedium: TextStyle(color: _cpOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeCaption),
        labelSmall: TextStyle(color: _cpOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: 11),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xD805070C),
        elevation: 0,
        height: 64,
        indicatorColor: _cpNeonYellow.withOpacity(0.92),
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: Color(0xFF1C1700), size: 24);
          }
          return const IconThemeData(color: _cpOnSurfaceVariant, size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              color: Color(0xFF1C1700),
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            );
          }
          return const TextStyle(
            color: _cpOnSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          );
        }),
      ),
      cardTheme: CardTheme(
        color: _cpSurface.withOpacity(0.84),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: _cpNeonCyan.withOpacity(0.45), width: 1),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: _cpSurface.withOpacity(0.95),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: _cpNeonCyan.withOpacity(0.45), width: 1),
        ),
        titleTextStyle: const TextStyle(color: _cpOnSurface, fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0.4),
        contentTextStyle: const TextStyle(color: _cpOnSurfaceVariant, fontSize: 14, fontWeight: FontWeight.w400),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withOpacity(0.04),
        hintStyle: const TextStyle(color: _cpOnSurfaceVariant),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: _cpNeonCyan.withOpacity(0.38)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: _cpNeonYellow.withOpacity(0.9), width: 1.35),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: _cpSurface.withOpacity(0.97),
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: _cpNeonCyan.withOpacity(0.3),
        thickness: 0.5,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.all(_cpNeonYellow),
          foregroundColor: WidgetStateProperty.all(const Color(0xFF171300)),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all(_cpNeonCyan),
          side: WidgetStateProperty.all(BorderSide(color: _cpNeonCyan.withOpacity(0.7))),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all(_cpNeonMagenta),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
    );
    return theme.copyWith(
      extensions: <ThemeExtension<dynamic>>[
        const HibiThemeExtension(
          themeId: AppThemeId.cyberpunk,
          useImageBackground: false,
          solidBackgroundColor: _cpBg,
        ),
      ],
    );
  }

  /// 星界：赛博宇宙感（紫色星云底 + 蓝青发光 + 金色边饰）
  static ThemeData get _astralTheme {
    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: _astralPrimary,
        onPrimary: const Color(0xFF062332),
        primaryContainer: _astralPrimary.withOpacity(0.22),
        onPrimaryContainer: const Color(0xFFCFF4FF),
        secondary: _astralSecondary,
        onSecondary: Colors.white,
        tertiary: _astralAccentGold,
        onTertiary: const Color(0xFF2B1F0D),
        surface: _astralSurface,
        onSurface: _astralOnSurface,
        surfaceContainerHighest: _astralElevated,
        onSurfaceVariant: _astralOnSurfaceVariant,
        outline: _astralOutline,
        error: const Color(0xFFFF6E8F),
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: _astralOnSurface),
        titleTextStyle: TextStyle(
          color: _astralOnSurface,
          fontSize: _fontSizeAppBar,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.35,
        ),
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(color: _astralOnSurface, fontWeight: FontWeight.w600, fontSize: _fontSizeListTitle, letterSpacing: 0.25),
        titleMedium: TextStyle(color: _astralOnSurface, fontWeight: FontWeight.w600, fontSize: _fontSizeTitle, letterSpacing: 0.2),
        titleSmall: TextStyle(color: _astralOnSurface, fontWeight: FontWeight.w600, fontSize: _fontSizeListTitle, letterSpacing: 0.2),
        bodyLarge: TextStyle(color: _astralOnSurface, fontWeight: FontWeight.w400, fontSize: _fontSizeBody + 1),
        bodyMedium: TextStyle(color: _astralOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeBody),
        bodySmall: TextStyle(color: _astralOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeListSubtitle),
        labelLarge: TextStyle(color: _astralOnSurfaceVariant, fontWeight: FontWeight.w500, fontSize: _fontSizeListSubtitle),
        labelMedium: TextStyle(color: _astralOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeCaption),
        labelSmall: TextStyle(color: _astralOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: 11),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xD30A0716),
        elevation: 0,
        height: 64,
        indicatorColor: _astralPrimary.withOpacity(0.88),
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: Color(0xFF052334), size: 24);
          }
          return const IconThemeData(color: _astralOnSurfaceVariant, size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              color: Color(0xFF052334),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            );
          }
          return const TextStyle(
            color: _astralOnSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          );
        }),
      ),
      cardTheme: CardTheme(
        color: _astralSurface.withOpacity(0.84),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: _astralPrimary.withOpacity(0.4), width: 1),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: _astralSurface.withOpacity(0.95),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: _astralPrimary.withOpacity(0.42), width: 1),
        ),
        titleTextStyle: const TextStyle(color: _astralOnSurface, fontSize: 16, fontWeight: FontWeight.w600),
        contentTextStyle: const TextStyle(color: _astralOnSurfaceVariant, fontSize: 14, fontWeight: FontWeight.w400),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withOpacity(0.04),
        hintStyle: const TextStyle(color: _astralOnSurfaceVariant),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _astralPrimary.withOpacity(0.35)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _astralPrimary.withOpacity(0.9), width: 1.25),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: _astralSurface.withOpacity(0.97),
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: _astralPrimary.withOpacity(0.26),
        thickness: 0.5,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.all(_astralPrimary),
          foregroundColor: WidgetStateProperty.all(const Color(0xFF052334)),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all(_astralPrimary),
          side: WidgetStateProperty.all(BorderSide(color: _astralPrimary.withOpacity(0.7))),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all(_astralAccentGold),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
    );
    return theme.copyWith(
      extensions: <ThemeExtension<dynamic>>[
        const HibiThemeExtension(
          themeId: AppThemeId.astral,
          useImageBackground: false,
          solidBackgroundColor: _astralBg,
        ),
      ],
    );
  }

  /// 星界·幻：星界进阶版（更柔和玻璃、更大圆角、更细腻字重）。
  static ThemeData get _astralPhantasmTheme {
    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: _astralPhPrimary,
        onPrimary: const Color(0xFF052330),
        primaryContainer: _astralPhPrimary.withOpacity(0.2),
        onPrimaryContainer: const Color(0xFFE4F8FF),
        secondary: _astralPhSecondary,
        onSecondary: const Color(0xFF111A38),
        tertiary: _astralPhTertiary,
        onTertiary: const Color(0xFF2A1B3E),
        surface: _astralPhSurface,
        onSurface: _astralPhOnSurface,
        surfaceContainerHighest: _astralPhElevated,
        onSurfaceVariant: _astralPhOnSurfaceVariant,
        outline: _astralPhOutline,
        error: const Color(0xFFFF778D),
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: _astralPhOnSurface),
        titleTextStyle: TextStyle(
          color: _astralPhOnSurface,
          fontSize: _fontSizeAppBar + 1,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.15,
        ),
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(
          color: _astralPhOnSurface,
          fontWeight: FontWeight.w600,
          fontSize: _fontSizeListTitle + 0.5,
          letterSpacing: 0.12,
        ),
        titleMedium: TextStyle(
          color: _astralPhOnSurface,
          fontWeight: FontWeight.w600,
          fontSize: _fontSizeTitle + 0.2,
          letterSpacing: 0.1,
        ),
        titleSmall: TextStyle(
          color: _astralPhOnSurface,
          fontWeight: FontWeight.w600,
          fontSize: _fontSizeListTitle,
          letterSpacing: 0.08,
        ),
        bodyLarge: TextStyle(
          color: _astralPhOnSurface,
          fontWeight: FontWeight.w400,
          fontSize: _fontSizeBody + 1,
          letterSpacing: 0.02,
        ),
        bodyMedium: TextStyle(
          color: _astralPhOnSurfaceVariant,
          fontWeight: FontWeight.w400,
          fontSize: _fontSizeBody,
        ),
        bodySmall: TextStyle(
          color: _astralPhOnSurfaceVariant,
          fontWeight: FontWeight.w400,
          fontSize: _fontSizeListSubtitle,
        ),
        labelLarge: TextStyle(
          color: _astralPhOnSurfaceVariant,
          fontWeight: FontWeight.w500,
          fontSize: _fontSizeListSubtitle,
          letterSpacing: 0.08,
        ),
        labelMedium: TextStyle(
          color: _astralPhOnSurfaceVariant,
          fontWeight: FontWeight.w400,
          fontSize: _fontSizeCaption,
        ),
        labelSmall: TextStyle(
          color: _astralPhOnSurfaceVariant,
          fontWeight: FontWeight.w400,
          fontSize: 11,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xCC090E20),
        elevation: 0,
        height: 66,
        indicatorColor: _astralPhPrimary.withOpacity(0.92),
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: Color(0xFF032233), size: 24);
          }
          return const IconThemeData(color: _astralPhOnSurfaceVariant, size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              color: Color(0xFF032233),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            );
          }
          return const TextStyle(
            color: _astralPhOnSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          );
        }),
      ),
      cardTheme: CardTheme(
        color: _astralPhSurface.withOpacity(0.82),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: _astralPhPrimary.withOpacity(0.34), width: 1),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: _astralPhSurface.withOpacity(0.95),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: _astralPhPrimary.withOpacity(0.34), width: 1),
        ),
        titleTextStyle: const TextStyle(
          color: _astralPhOnSurface,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: const TextStyle(
          color: _astralPhOnSurfaceVariant,
          fontSize: 14,
          fontWeight: FontWeight.w400,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withOpacity(0.05),
        hintStyle: const TextStyle(color: _astralPhOnSurfaceVariant),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: _astralPhPrimary.withOpacity(0.32)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: _astralPhPrimary.withOpacity(0.92), width: 1.3),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: _astralPhSurface.withOpacity(0.97),
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: _astralPhPrimary.withOpacity(0.24),
        thickness: 0.5,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.all(_astralPhPrimary),
          foregroundColor: WidgetStateProperty.all(const Color(0xFF032233)),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all(_astralPhPrimary),
          side: WidgetStateProperty.all(BorderSide(color: _astralPhPrimary.withOpacity(0.6))),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all(_astralPhTertiary),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
        ),
      ),
    );
    return theme.copyWith(
      extensions: <ThemeExtension<dynamic>>[
        const HibiThemeExtension(
          themeId: AppThemeId.astralPhantasm,
          useImageBackground: false,
          solidBackgroundColor: _astralPhBg,
        ),
      ],
    );
  }

  /// 地界：蓝金史诗科技风（更沉稳、层次更硬朗）
  static ThemeData get _earthrealmTheme {
    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: _earthPrimary,
        onPrimary: const Color(0xFF052538),
        primaryContainer: _earthPrimary.withOpacity(0.22),
        onPrimaryContainer: const Color(0xFFD7F4FF),
        secondary: _earthSecondary,
        onSecondary: const Color(0xFF042330),
        tertiary: _earthAccentGold,
        onTertiary: const Color(0xFF2C1F10),
        surface: _earthSurface,
        onSurface: _earthOnSurface,
        surfaceContainerHighest: _earthElevated,
        onSurfaceVariant: _earthOnSurfaceVariant,
        outline: _earthOutline,
        error: const Color(0xFFFF6B7E),
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: _earthOnSurface),
        titleTextStyle: TextStyle(
          color: _earthOnSurface,
          fontSize: _fontSizeAppBar,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.25,
        ),
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(color: _earthOnSurface, fontWeight: FontWeight.w600, fontSize: _fontSizeListTitle),
        titleMedium: TextStyle(color: _earthOnSurface, fontWeight: FontWeight.w600, fontSize: _fontSizeTitle),
        titleSmall: TextStyle(color: _earthOnSurface, fontWeight: FontWeight.w600, fontSize: _fontSizeListTitle),
        bodyLarge: TextStyle(color: _earthOnSurface, fontWeight: FontWeight.w400, fontSize: _fontSizeBody + 1),
        bodyMedium: TextStyle(color: _earthOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeBody),
        bodySmall: TextStyle(color: _earthOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeListSubtitle),
        labelLarge: TextStyle(color: _earthOnSurfaceVariant, fontWeight: FontWeight.w500, fontSize: _fontSizeListSubtitle),
        labelMedium: TextStyle(color: _earthOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: _fontSizeCaption),
        labelSmall: TextStyle(color: _earthOnSurfaceVariant, fontWeight: FontWeight.w400, fontSize: 11),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xD9081227),
        elevation: 0,
        height: 64,
        indicatorColor: _earthPrimary.withOpacity(0.9),
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: Color(0xFF04283C), size: 24);
          }
          return const IconThemeData(color: _earthOnSurfaceVariant, size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              color: Color(0xFF04283C),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            );
          }
          return const TextStyle(
            color: _earthOnSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          );
        }),
      ),
      cardTheme: CardTheme(
        color: _earthSurface.withOpacity(0.84),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: _earthPrimary.withOpacity(0.34), width: 1),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: _earthSurface.withOpacity(0.95),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: _earthPrimary.withOpacity(0.34), width: 1),
        ),
        titleTextStyle: const TextStyle(color: _earthOnSurface, fontSize: 16, fontWeight: FontWeight.w600),
        contentTextStyle: const TextStyle(color: _earthOnSurfaceVariant, fontSize: 14, fontWeight: FontWeight.w400),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withOpacity(0.05),
        hintStyle: const TextStyle(color: _earthOnSurfaceVariant),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _earthPrimary.withOpacity(0.32)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _earthPrimary.withOpacity(0.88), width: 1.25),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: _earthSurface.withOpacity(0.97),
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: _earthPrimary.withOpacity(0.25),
        thickness: 0.5,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.all(_earthPrimary),
          foregroundColor: WidgetStateProperty.all(const Color(0xFF04283C)),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all(_earthPrimary),
          side: WidgetStateProperty.all(BorderSide(color: _earthPrimary.withOpacity(0.65))),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all(_earthAccentGold),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
    );
    return theme.copyWith(
      extensions: <ThemeExtension<dynamic>>[
        const HibiThemeExtension(
          themeId: AppThemeId.earthrealm,
          useImageBackground: false,
          solidBackgroundColor: _earthBg,
        ),
      ],
    );
  }

  /// 兼容旧引用：等同于 getTheme(AppThemeId.hibi)
  static ThemeData get dark => getTheme(AppThemeId.hibi);
}
