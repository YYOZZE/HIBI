import 'dart:async';

import 'package:flutter/material.dart';

import 'app_permissions.dart';
import 'loading_page.dart';
import 'main_shell.dart';
import 'theme_notifier.dart';
import 'theme_policy_service.dart';

import '../features/auth/github_login_page.dart';
import '../features/auth/models/auth_user.dart';
import '../features/auth/services/auth_repository.dart';
import '../features/schedule/schedule_event_store.dart';

/// 应用启动：加载后经 GitHub + Star 门禁，再进主壳。
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
    return const _GitHubAuthGate();
  }
}

/// 未登录 / 未 Star 时展示 GitHub 登录页；通过后进入主壳。
/// 回到前台时复检 Star，取消 Star 后再次拦截。
class _GitHubAuthGate extends StatefulWidget {
  const _GitHubAuthGate();

  @override
  State<_GitHubAuthGate> createState() => _GitHubAuthGateState();
}

class _GitHubAuthGateState extends State<_GitHubAuthGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final u = AuthRepository.instance.currentUser;
      if (u != null && u.isGitHub) {
        unawaited(AuthRepository.instance.refreshGitHubStarStatus());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthRepository.instance;
    return ValueListenableBuilder<AuthUser?>(
      valueListenable: auth.currentUserNotifier,
      builder: (context, user, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: auth.githubAccessGrantedNotifier,
          builder: (context, starred, _) {
            if (user != null && user.isGitHub && starred) {
              return const MainShell();
            }
            return const GitHubLoginPage(embedded: true);
          },
        );
      },
    );
  }
}
