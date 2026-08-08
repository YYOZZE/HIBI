import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'app_theme_extension.dart';
import 'theme_notifier.dart';
import 'theme_policy_service.dart';
import 'frosted_background.dart';

import '../features/assistant/assistant_page.dart';
import '../features/auth/services/auth_repository.dart';
import '../features/auth/services/local_account_import_service.dart';
import '../features/auth/services/user_sync_scheduler.dart';
import '../features/mind/mind_page.dart';
import '../features/profile/profile_page.dart';
import '../features/schedule/schedule_event_store.dart';
import '../features/schedule/schedule_page.dart';
import '../features/schedule/schedule_reminder_service.dart';
import '../features/transfer/transfer_page.dart';

/// 主壳：图三毛玻璃全局背景 + 底部导航五大功能模块
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _currentIndex = 0;
  bool _showingAlarmDialog = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ScheduleReminderService.instance.alertNotifier.addListener(_onReminderAlert);
    // GitHub+Star 进壳后：其他账号目录有未合并数据则弹一次导入决策
    AuthRepository.instance.currentUserNotifier.addListener(_maybePromptImport);
    AuthRepository.instance.githubAccessGrantedNotifier
        .addListener(_maybePromptImport);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePromptImport());
  }

  @override
  void dispose() {
    AuthRepository.instance.currentUserNotifier
        .removeListener(_maybePromptImport);
    AuthRepository.instance.githubAccessGrantedNotifier
        .removeListener(_maybePromptImport);
    ScheduleReminderService.instance.alertNotifier.removeListener(_onReminderAlert);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _maybePromptImport() {
    if (!mounted) return;
    unawaited(LocalAccountImportService.maybeShowPrompt(context));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      UserSyncScheduler.pullAndNotify();
      final tn = ThemeNotifier.maybeInstance;
      if (tn != null) {
        unawaited(ThemePolicyService.instance.refreshAndApply(tn));
      }
      // 回到前台时按当前本地日程重新登记系统定时通知，减少「杀后台/省电策略」导致的漏提醒
      unawaited(
        ScheduleReminderService.instance.rescheduleAll(ScheduleEventStore.instance.events),
      );
    }
  }

  void _onReminderAlert() {
    if (!mounted || _showingAlarmDialog) return;
    final alert = ScheduleReminderService.instance.alertNotifier.value;
    if (alert == null) return;
    _showingAlarmDialog = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final colorScheme = theme.colorScheme;
        return AlertDialog(
          backgroundColor: theme.dialogTheme.backgroundColor ?? colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            '日程提醒',
            style: theme.textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Text(
            '${alert.title}\n${alert.body}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
              height: 1.45,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                ScheduleReminderService.instance.clearActiveAlert();
                await ScheduleReminderService.instance.snooze(alert.eventId);
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: const Text('5分钟后再提醒'),
            ),
            FilledButton(
              onPressed: () {
                ScheduleReminderService.instance.clearActiveAlert();
                Navigator.of(ctx).pop();
              },
              child: const Text('我知道了'),
            ),
          ],
        );
      },
    ).whenComplete(() {
      _showingAlarmDialog = false;
    });
  }

  static const List<Widget> _pages = [
    MindPage(),
    SchedulePage(),
    AssistantPage(),
    TransferPage(),
    ProfilePage(),
  ];

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom + kBottomNavigationBarHeight;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          Padding(
            padding: EdgeInsets.only(bottom: bottomPadding),
            child: IndexedStack(
              index: _currentIndex,
              children: _pages,
            ),
          ),
        ],
      ),
      bottomNavigationBar: _buildBottomBar(context),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    final ext = Theme.of(context).extension<HibiThemeExtension>();
    final useGlass = ext?.useImageBackground ?? true;
    final isAstralPhantasm = ext?.themeId == AppThemeId.astralPhantasm;
    // 非毛玻璃主题下必须使用不透明背景，避免页面内容与底部功能键重叠
    final barBg = useGlass
        ? Colors.transparent
        : (ext?.solidBackgroundColor ?? const Color(0xFF121212));

    final bar = NavigationBar(
      backgroundColor: barBg,
      animationDuration: Duration.zero,
      selectedIndex: _currentIndex,
      onDestinationSelected: (int index) {
        setState(() => _currentIndex = index);
        if (index == 0 || index == 2) {
          UserSyncScheduler.pullAndNotify();
        }
      },
      destinations: isAstralPhantasm
          ? const [
              NavigationDestination(
                icon: Icon(Icons.hub_outlined),
                selectedIcon: Icon(Icons.hub_rounded),
                label: '思维',
              ),
              NavigationDestination(
                icon: Icon(Icons.event_note_outlined),
                selectedIcon: Icon(Icons.event_note_rounded),
                label: '日程',
              ),
              NavigationDestination(
                icon: Icon(Icons.psychology_alt_outlined),
                selectedIcon: Icon(Icons.psychology_alt_rounded),
                label: '助理',
              ),
              NavigationDestination(
                icon: Icon(Icons.folder_zip_outlined),
                selectedIcon: Icon(Icons.folder_zip_rounded),
                label: '传输',
              ),
              NavigationDestination(
                icon: Icon(Icons.account_circle_outlined),
                selectedIcon: Icon(Icons.account_circle_rounded),
                label: '我的',
              ),
            ]
          : const [
              NavigationDestination(
                icon: Icon(Icons.account_tree_outlined),
                selectedIcon: Icon(Icons.account_tree),
                label: '思维',
              ),
              NavigationDestination(
                icon: Icon(Icons.calendar_today_outlined),
                selectedIcon: Icon(Icons.calendar_today),
                label: '日程',
              ),
              NavigationDestination(
                icon: Icon(Icons.smart_toy_outlined),
                selectedIcon: Icon(Icons.smart_toy),
                label: '助理',
              ),
              NavigationDestination(
                icon: Icon(Icons.folder_shared_outlined),
                selectedIcon: Icon(Icons.folder_shared),
                label: '传输',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: '我的',
              ),
            ],
    );

    if (useGlass) {
      return ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            color: Colors.black.withOpacity(0.2),
            child: bar,
          ),
        ),
      );
    }
    return bar;
  }
}
