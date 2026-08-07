import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'frosted_background.dart';

/// 全屏加载页：毛玻璃背景 + 中央转圈动画，与项目 UI 风格一致
class LoadingPage extends StatelessWidget {
  const LoadingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          FrostedBackground(),
          Center(
            child: SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(
                  AppTheme.loadingIndicatorColor,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
