import 'package:flutter/material.dart';

import 'app_theme_extension.dart';
import 'theme_notifier.dart';

/// 全应用统一的毛玻璃面板样式（与 FrostedBackground + 登录页卡片一致）
/// 使用场景：列表卡片、设置分组、传输页区块、表单分区等
class AppGlassStyles {
  AppGlassStyles._();

  static const double radius = 16;
  static const double radiusSmall = 12;

  /// 与 AuthFormStyles.glassPanel 一致，作为唯一来源供各 feature 使用
  static BoxDecoration glassDecoration(BuildContext context) {
    final ext = Theme.of(context).extension<HibiThemeExtension>();
    final isAstralPhantasm = ext?.themeId == AppThemeId.astralPhantasm;
    final outline = Theme.of(context).colorScheme.outline;
    return BoxDecoration(
      color: Colors.white.withOpacity(isAstralPhantasm ? 0.09 : 0.06),
      borderRadius: BorderRadius.circular(isAstralPhantasm ? 22 : radius),
      border: Border.all(
        color: outline.withOpacity(isAstralPhantasm ? 0.48 : 0.35),
        width: 1,
      ),
    );
  }

  /// 带外边距的毛玻璃块（替代默认 Card 实底）
  static Widget section(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry margin = EdgeInsets.zero,
    EdgeInsetsGeometry padding = EdgeInsets.zero,
  }) {
    final ext = Theme.of(context).extension<HibiThemeExtension>();
    final isAstralPhantasm = ext?.themeId == AppThemeId.astralPhantasm;
    Widget wrapped = DecoratedBox(
      decoration: glassDecoration(context),
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(isAstralPhantasm ? 22 : radius),
        child: padding != EdgeInsets.zero ? Padding(padding: padding, child: child) : child,
      ),
    );
    if (margin != EdgeInsets.zero) {
      wrapped = Padding(padding: margin, child: wrapped);
    }
    return wrapped;
  }

  /// 列表项常用：底部分隔 + 圆角仅上下（单条时全圆角需调用方自行包）
  static Widget listCard(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry margin = const EdgeInsets.only(bottom: 10),
  }) {
    return section(context, margin: margin, child: child);
  }

  /// Dialog / BottomSheet 背景色（与主题 dialogTheme 一致时使用）
  static Color dialogBackground(BuildContext context) =>
      Theme.of(context).colorScheme.surfaceContainerHigh;

  /// 输入框填充色（与登录页输入统一）
  static Color inputFill(BuildContext context) => Colors.white.withOpacity(0.04);
}
