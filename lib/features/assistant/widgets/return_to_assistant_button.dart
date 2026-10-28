import 'package:flutter/material.dart';

/// 盖在思维导图或日程页上，右下角悬浮「返回助手」。
class AssistantReturnHost extends StatelessWidget {
  const AssistantReturnHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom + 20;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          right: 16,
          bottom: bottom,
          child: Material(
            color: const Color(0xE61A1A2E),
            elevation: 6,
            borderRadius: BorderRadius.circular(24),
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: () => Navigator.of(context).maybePop(),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.arrow_back, size: 18, color: Colors.white),
                    SizedBox(width: 6),
                    Text(
                      '返回助手',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
