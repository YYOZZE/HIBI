import 'dart:async';

import 'package:flutter/material.dart';

import 'app_permissions.dart';
import 'loading_page.dart';
import 'main_shell.dart';
import 'theme_notifier.dart';
import 'theme_policy_service.dart';

import '../features/auth/services/auth_repository.dart';
import '../features/profile/services/app_update_service.dart';
import '../features/schedule/schedule_event_store.dart';

/// 应用启动：加载权限与资源后直接进主壳；不强制登录，个人中心以「本地账户」展示，点头像再登录
class InitialAppLoader extends StatefulWidget {
  const InitialAppLoader({super.key});

  @override
  State<InitialAppLoader> createState() => _InitialAppLoaderState();
}

class _InitialAppLoaderState extends State<InitialAppLoader> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final stopwatch = Stopwatch()..start();
    await AuthRepository.instance.ensureLoaded();
    await ScheduleEventStore.instance.ensureLoaded();
    if (!mounted) return;
    await AppPermissions.requestAll();
    unawaited(AppUpdateService.instance.checkSilently());
    final tn = ThemeNotifier.maybeInstance;
    if (tn != null) {
      unawaited(ThemePolicyService.instance.refreshAndApply(tn));
    }
    if (!mounted) return;
    await precacheImage(const AssetImage('xhb-image/3.png'), context)
        .catchError((_) => null);
    if (!mounted) return;
    const minDuration = Duration(milliseconds: 600);
    final elapsed = stopwatch.elapsed;
    if (elapsed < minDuration) {
      await Future.delayed(minDuration - elapsed);
    }
    if (mounted) {
      setState(() => _ready = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const LoadingPage();
    }
    return const MainShell();
  }
}
