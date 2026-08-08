import 'package:flutter/material.dart';

import 'github_login_page.dart';

/// 兼容旧入口：统一跳转到 GitHub Device Flow 登录页。
class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const GitHubLoginPage(embedded: false);
  }
}
