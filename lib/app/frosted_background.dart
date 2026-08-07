import 'dart:ui';

import 'package:flutter/material.dart';

import 'app_theme_extension.dart';
import 'theme_notifier.dart';

/// 全局背景：hibi 主题为「图三 + 毛玻璃」；暗色/亮色主题为纯色
class FrostedBackground extends StatelessWidget {
  const FrostedBackground({super.key});

  static const double blurSigma = 15;

  @override
  Widget build(BuildContext context) {
    final ext = Theme.of(context).extension<HibiThemeExtension>();
    if (ext != null && ext.themeId == AppThemeId.astralPhantasm) {
      return Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF070A16),
                  Color(0xFF111733),
                  Color(0xFF131E40),
                  Color(0xFF1A1C3D),
                ],
                stops: [0.0, 0.34, 0.72, 1.0],
              ),
            ),
          ),
          Positioned(
            top: -130,
            right: -160,
            child: Container(
              width: 520,
              height: 520,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFF87DFFF).withOpacity(0.22),
                  width: 44,
                ),
              ),
            ),
          ),
          Positioned(
            top: -90,
            left: -120,
            child: Container(
              width: 360,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF7EE3FF).withOpacity(0.22),
              ),
            ),
          ),
          Positioned(
            top: 180,
            right: -70,
            child: Container(
              width: 300,
              height: 240,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF9EACFF).withOpacity(0.18),
              ),
            ),
          ),
          Positioned(
            bottom: -160,
            left: 70,
            child: Container(
              width: 460,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFCBA3FF).withOpacity(0.16),
              ),
            ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
              child: Container(
                color: Colors.black.withOpacity(0.16),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.12,
                child: CustomPaint(
                  painter: _AstralPhantasmDustPainter(),
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (ext != null && ext.themeId == AppThemeId.earthrealm) {
      return Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF081227),
                  Color(0xFF0E1C39),
                  Color(0xFF12284A),
                  Color(0xFF09162E),
                ],
                stops: [0.0, 0.35, 0.72, 1.0],
              ),
            ),
          ),
          // 中部苍穹能量圈
          Positioned(
            top: -40,
            right: -120,
            child: Container(
              width: 420,
              height: 420,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFF4CC3FF).withOpacity(0.25),
                  width: 34,
                ),
              ),
            ),
          ),
          // 左侧星云蓝光
          Positioned(
            top: 40,
            left: -130,
            child: Container(
              width: 340,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF7FE2FF).withOpacity(0.18),
              ),
            ),
          ),
          // 右下深蓝光雾
          Positioned(
            bottom: -140,
            right: -80,
            child: Container(
              width: 360,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF3C83FF).withOpacity(0.15),
              ),
            ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                color: Colors.black.withOpacity(0.18),
              ),
            ),
          ),
          const Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _EarthSparkPainter(),
              ),
            ),
          ),
        ],
      );
    }
    if (ext != null && ext.themeId == AppThemeId.astral) {
      return Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF0B0718),
                  Color(0xFF150C2E),
                  Color(0xFF0A0E22),
                  Color(0xFF1A0B2B),
                ],
                stops: [0.0, 0.36, 0.72, 1.0],
              ),
            ),
          ),
          // 星云紫环
          Positioned(
            top: -120,
            right: -180,
            child: Container(
              width: 520,
              height: 520,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFFB84BFF).withOpacity(0.26),
                  width: 42,
                ),
              ),
            ),
          ),
          // 星蓝光晕
          Positioned(
            top: -80,
            left: -120,
            child: Container(
              width: 360,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF39D4FF).withOpacity(0.2),
              ),
            ),
          ),
          // 底部洋红雾感
          Positioned(
            bottom: -150,
            left: 80,
            child: Container(
              width: 420,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFC54DFF).withOpacity(0.17),
              ),
            ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
              child: Container(
                color: Colors.black.withOpacity(0.2),
              ),
            ),
          ),
          // 微弱星点
          const Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _AstralStarPainter(),
              ),
            ),
          ),
        ],
      );
    }
    if (ext != null && ext.themeId == AppThemeId.cyberpunk) {
      return Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF05070C),
                  Color(0xFF090C13),
                  Color(0xFF04060A),
                ],
                stops: [0.0, 0.55, 1.0],
              ),
            ),
          ),
          Positioned(
            top: -140,
            left: -90,
            child: Container(
              width: 360,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF02D7F2).withOpacity(0.2),
              ),
            ),
          ),
          Positioned(
            top: 190,
            right: -120,
            child: Container(
              width: 340,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFFF2FA3).withOpacity(0.16),
              ),
            ),
          ),
          Positioned(
            bottom: -140,
            left: 70,
            child: Container(
              width: 380,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFF2E900).withOpacity(0.14),
              ),
            ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                color: Colors.black.withOpacity(0.22),
              ),
            ),
          ),
          // 轻微扫描线，增强赛博科技质感
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.06,
                child: CustomPaint(
                  painter: _CyberScanlinePainter(),
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (ext != null && ext.themeId == AppThemeId.dreamyNight) {
      return Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF1A1327),
                  Color(0xFF221735),
                  Color(0xFF162237),
                  Color(0xFF2A1830),
                ],
                stops: [0.0, 0.36, 0.72, 1.0],
              ),
            ),
          ),
          Positioned(
            top: -110,
            left: -60,
            child: Container(
              width: 320,
              height: 270,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFE089FF).withOpacity(0.2),
              ),
            ),
          ),
          Positioned(
            top: 160,
            right: -90,
            child: Container(
              width: 280,
              height: 240,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF8ECFFF).withOpacity(0.18),
              ),
            ),
          ),
          Positioned(
            bottom: -120,
            left: 70,
            child: Container(
              width: 360,
              height: 270,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFFFA8D8).withOpacity(0.14),
              ),
            ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
              child: Container(
                color: Colors.black.withOpacity(0.18),
              ),
            ),
          ),
        ],
      );
    }
    if (ext != null && ext.themeId == AppThemeId.dreamy) {
      return Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFFFF4F8), // 柔粉
                  Color(0xFFF3E8FF), // 粉紫
                  Color(0xFFEFF9FF), // 淡蓝
                  Color(0xFFFFF7D9), // 奶油黄
                ],
                stops: [0.0, 0.38, 0.72, 1.0],
              ),
            ),
          ),
          Positioned(
            top: -90,
            left: -50,
            child: Container(
              width: 280,
              height: 240,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFD76EEA).withOpacity(0.17),
              ),
            ),
          ),
          Positioned(
            top: 120,
            right: -70,
            child: Container(
              width: 260,
              height: 230,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF7CC7FF).withOpacity(0.19),
              ),
            ),
          ),
          Positioned(
            bottom: -110,
            left: 40,
            child: Container(
              width: 320,
              height: 250,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFFFDFA6).withOpacity(0.18),
              ),
            ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                color: Colors.white.withOpacity(0.1),
              ),
            ),
          ),
        ],
      );
    }
    if (ext != null && ext.themeId == AppThemeId.spring2027) {
      return Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF0E1118),
                  Color(0xFF121722),
                  Color(0xFF0B1018),
                ],
                stops: [0.0, 0.45, 1.0],
              ),
            ),
          ),
          // 顶部冷蓝柔光
          Positioned(
            top: -120,
            left: -80,
            child: Container(
              width: 360,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF4A8BFF).withOpacity(0.17),
              ),
            ),
          ),
          // 右下暖灰光晕，平衡科技感
          Positioned(
            bottom: -140,
            right: -110,
            child: Container(
              width: 380,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF7B6A5A).withOpacity(0.11),
              ),
            ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: Container(
                color: Colors.black.withOpacity(0.2),
              ),
            ),
          ),
        ],
      );
    }
    if (ext != null && !ext.useImageBackground) {
      return ColoredBox(color: ext.solidBackgroundColor);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          'xhb-image/3.png',
          fit: BoxFit.cover,
        ),
        Positioned.fill(
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
              child: Container(
                color: Colors.black.withOpacity(0.25),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AstralStarPainter extends CustomPainter {
  const _AstralStarPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p1 = Paint()..color = const Color(0x88E8F5FF);
    final p2 = Paint()..color = const Color(0x66A6CCFF);
    final points = <Offset>[
      const Offset(40, 60),
      Offset(size.width * 0.2, size.height * 0.15),
      Offset(size.width * 0.37, size.height * 0.08),
      Offset(size.width * 0.55, size.height * 0.22),
      Offset(size.width * 0.74, size.height * 0.11),
      Offset(size.width * 0.86, size.height * 0.31),
      Offset(size.width * 0.68, size.height * 0.47),
      Offset(size.width * 0.49, size.height * 0.39),
      Offset(size.width * 0.28, size.height * 0.57),
      Offset(size.width * 0.12, size.height * 0.44),
      Offset(size.width * 0.91, size.height * 0.73),
      Offset(size.width * 0.63, size.height * 0.79),
      Offset(size.width * 0.39, size.height * 0.71),
      Offset(size.width * 0.18, size.height * 0.84),
    ];
    for (var i = 0; i < points.length; i++) {
      final paint = i.isEven ? p1 : p2;
      canvas.drawCircle(points[i], i.isEven ? 1.2 : 0.9, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _EarthSparkPainter extends CustomPainter {
  const _EarthSparkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final pA = Paint()..color = const Color(0x88DFF5FF);
    final pB = Paint()..color = const Color(0x66A7DFFF);
    final points = <Offset>[
      Offset(size.width * 0.12, size.height * 0.22),
      Offset(size.width * 0.27, size.height * 0.12),
      Offset(size.width * 0.41, size.height * 0.2),
      Offset(size.width * 0.63, size.height * 0.13),
      Offset(size.width * 0.79, size.height * 0.25),
      Offset(size.width * 0.89, size.height * 0.41),
      Offset(size.width * 0.72, size.height * 0.53),
      Offset(size.width * 0.53, size.height * 0.48),
      Offset(size.width * 0.34, size.height * 0.58),
      Offset(size.width * 0.2, size.height * 0.46),
      Offset(size.width * 0.86, size.height * 0.73),
      Offset(size.width * 0.61, size.height * 0.82),
      Offset(size.width * 0.41, size.height * 0.72),
      Offset(size.width * 0.24, size.height * 0.86),
    ];
    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(points[i], i.isEven ? 1.15 : 0.9, i.isEven ? pA : pB);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _CyberScanlinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFF9FD4FF);
    const gap = 3.0;
    for (double y = 0; y < size.height; y += gap) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _AstralPhantasmDustPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p1 = Paint()..color = const Color(0xB8E8F6FF);
    final p2 = Paint()..color = const Color(0x88BFD3FF);
    final p3 = Paint()..color = const Color(0x66DAC0FF);
    final points = <Offset>[
      Offset(size.width * 0.08, size.height * 0.12),
      Offset(size.width * 0.16, size.height * 0.22),
      Offset(size.width * 0.28, size.height * 0.09),
      Offset(size.width * 0.35, size.height * 0.19),
      Offset(size.width * 0.47, size.height * 0.11),
      Offset(size.width * 0.61, size.height * 0.23),
      Offset(size.width * 0.72, size.height * 0.14),
      Offset(size.width * 0.84, size.height * 0.25),
      Offset(size.width * 0.92, size.height * 0.17),
      Offset(size.width * 0.11, size.height * 0.38),
      Offset(size.width * 0.24, size.height * 0.44),
      Offset(size.width * 0.38, size.height * 0.36),
      Offset(size.width * 0.52, size.height * 0.47),
      Offset(size.width * 0.66, size.height * 0.4),
      Offset(size.width * 0.79, size.height * 0.49),
      Offset(size.width * 0.9, size.height * 0.42),
      Offset(size.width * 0.19, size.height * 0.69),
      Offset(size.width * 0.33, size.height * 0.74),
      Offset(size.width * 0.46, size.height * 0.66),
      Offset(size.width * 0.58, size.height * 0.79),
      Offset(size.width * 0.72, size.height * 0.7),
      Offset(size.width * 0.85, size.height * 0.81),
    ];
    for (var i = 0; i < points.length; i++) {
      final paint = i % 3 == 0 ? p1 : (i % 3 == 1 ? p2 : p3);
      canvas.drawCircle(points[i], i.isEven ? 1.15 : 0.95, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
