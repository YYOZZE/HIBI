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

/// 门禁：仅 [AuthRepository.canEnterShell] 进主壳（本地账号或 GitHub+Star）；
/// 未登录 / GitHub 未 Star 一律展示登录页（永不白屏）。
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
      final access = AuthRepository.instance.accessState;
      if (access == AppAccessState.githubOk ||
          access == AppAccessState.githubNeedStar) {
        unawaited(AuthRepository.instance.refreshGitHubStarStatus());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthRepository.instance;
    return ValueListenableBuilder<AuthUser?>(
      valueListenable: auth.currentUserNotifier,
      builder: (context, _, __) {
        return ValueListenableBuilder<bool>(
          valueListenable: auth.githubAccessGrantedNotifier,
          builder: (context, __, ___) {
            if (auth.canEnterShell) {
              return const MainShell();
            }
            return const GitHubLoginPage(embedded: true);
          },
        );
      },
    );
  }
}
