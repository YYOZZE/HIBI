import 'package:flutter/material.dart';

import 'theme_notifier.dart';

/// 在根节点提供 ThemeNotifier，供设置页等切换主题
class ThemeNotifierScope extends InheritedNotifier<ThemeNotifier> {
  const ThemeNotifierScope({
    super.key,
    required ThemeNotifier notifier,
    required super.child,
  }) : super(notifier: notifier);

  static ThemeNotifier of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeNotifierScope>();
    assert(scope != null, 'ThemeNotifierScope 未找到，请确保根节点包裹了 ThemeNotifierScope');
    return scope!.notifier!;
  }
}
