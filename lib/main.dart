import 'package:flutter/material.dart';

import 'app/app_theme.dart';
import 'app/initial_app_loader.dart';
import 'app/theme_notifier.dart';
import 'app/theme_notifier_scope.dart';
import 'features/auth/services/auth_repository.dart';
import 'features/mind/services/mind_hbm_service.dart';
import 'features/schedule/schedule_event_store.dart';
import 'features/schedule/schedule_reminder_service.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  MindHbmLaunchService.initialize(arguments);
  await AuthRepository.instance.ensureLoaded();
  // 启动即初始化提醒服务并加载本地日程，避免“未进入日程页时提醒不生效”。
  await ScheduleReminderService.instance.init();
  await ScheduleEventStore.instance.ensureLoaded();
  final themeNotifier = ThemeNotifier();
  await themeNotifier.load();
  runApp(HibiApp(themeNotifier: themeNotifier));
}

/// 希比 HIBI - 助手应用（支持 hibi 主题 / 暗色 / 亮色）
class HibiApp extends StatelessWidget {
  const HibiApp({super.key, required this.themeNotifier});

  final ThemeNotifier themeNotifier;

  @override
  Widget build(BuildContext context) {
    return ThemeNotifierScope(
      notifier: themeNotifier,
      child: ListenableBuilder(
        listenable: themeNotifier,
        builder: (_, __) {
          return MaterialApp(
            onGenerateTitle: (ctx) {
              final code = Localizations.localeOf(ctx).languageCode.toLowerCase();
              return code.startsWith('zh') ? '希比-2023' : 'hibi-2023';
            },
            debugShowCheckedModeBanner: false,
            theme: themeNotifier.dynamicTheme ?? AppTheme.getTheme(themeNotifier.themeId),
            home: const InitialAppLoader(),
          );
        },
      ),
    );
  }
}
