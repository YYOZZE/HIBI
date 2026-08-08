import 'package:flutter/material.dart';
import 'dart:io';

import '../auth/login_page.dart';
import '../auth/models/auth_user.dart';
import '../auth/services/auth_repository.dart';
import 'app_update_page.dart';
import 'settings_page.dart';
import 'profile_edit_page.dart';
import 'services/app_update_service.dart';
import 'value_added_page.dart';
import 'agile_course_page.dart';
import '../../app/app_glass_styles.dart';
import '../../app/frosted_background.dart';

/// 个人中心：本地账号显示「本地账号」+ id，可 GitHub 登录；
/// 有会话时可「退出并重新登录」回到门禁页。
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  /// 清空会话 → [AuthRepository.canEnterShell] 为 false → 门禁回登录页。
  static Future<void> _signOutAndReturnToGate() async {
    await AuthRepository.instance.logout();
  }

  static void _confirmSignOut(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          backgroundColor:
              theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          title: const Text('退出并重新登录'),
          content: const Text('将返回登录页，可重新选择本地或 GitHub。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await _signOutAndReturnToGate();
              },
              child: const Text('退出'),
            ),
          ],
        );
      },
    );
  }

  void _openGitHubLogin(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const LoginPage()),
    );
  }

  void _openProfileEdit(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ProfileEditPage()),
    );
  }

  void _openValueAdded(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ValueAddedPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('个人中心'),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          Positioned.fill(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
            child: ValueListenableBuilder<AuthUser?>(
              valueListenable: AuthRepository.instance.currentUserNotifier,
              builder: (context, user, _) {
                final hasSession = user != null;
                final isLocal = user?.isLocal == true;
                final isGitHub = user?.isGitHub == true;
                return ValueListenableBuilder<AppUpdateStatus?>(
                  valueListenable: AppUpdateService.instance.statusNotifier,
                  builder: (context, updateStatus, _) {
                    return ListView(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                      children: [
                        _buildHeaderCard(
                          context,
                          theme,
                          colorScheme,
                          user,
                          isLocal: isLocal,
                          isGitHub: isGitHub,
                        ),
                        const SizedBox(height: 20),
                        _buildMainActionsCard(
                          context,
                          theme,
                          colorScheme,
                          hasSession: hasSession,
                          updateStatus: updateStatus,
                        ),
                        if (hasSession) ...[
                          const SizedBox(height: 20),
                          _buildAccountActionsCard(
                            context,
                            theme,
                            colorScheme,
                            isLocal: isLocal,
                          ),
                        ],
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderCard(
    BuildContext context,
    ThemeData theme,
    ColorScheme colorScheme,
    AuthUser? user, {
    required bool isLocal,
    required bool isGitHub,
  }) {
    final String displayName;
    final String subtitle;
    if (isLocal && user != null) {
      displayName = '本地账号';
      subtitle = user.phoneOrEmail;
    } else if (isGitHub && user != null) {
      displayName = user.githubLogin != null
          ? '@${user.githubLogin}'
          : user.displayName;
      subtitle = AuthRepository.instance.canUseAssistant
          ? 'GitHub · 助理可用'
          : 'GitHub';
    } else {
      displayName = '未登录';
      subtitle = '选择本地进入或 GitHub 登录';
    }

    return _ProfileCard(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(18),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () {
                  if (user == null) {
                    _openGitHubLogin(context);
                  } else {
                    _openProfileEdit(context);
                  }
                },
                borderRadius: BorderRadius.circular(18),
                child: Ink(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: colorScheme.primaryContainer,
                    boxShadow: [
                      BoxShadow(
                        color: colorScheme.primary.withOpacity(0.2),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  width: 72,
                  height: 72,
                  child: _AvatarView(user: user, colorScheme: colorScheme),
                ),
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    displayName,
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (isLocal)
                        FilledButton.tonalIcon(
                          onPressed: () => _openGitHubLogin(context),
                          icon: const Icon(Icons.login_rounded, size: 16),
                          label: const Text('GitHub 登录'),
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                          ),
                        ),
                      if (user == null)
                        FilledButton.tonalIcon(
                          onPressed: () => _openGitHubLogin(context),
                          icon: const Icon(Icons.login_rounded, size: 16),
                          label: const Text('登录账号'),
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                          ),
                        ),
                      OutlinedButton.icon(
                        onPressed: () => _openValueAdded(context),
                        icon: const Icon(Icons.workspace_premium_outlined,
                            size: 16),
                        label: const Text('订阅'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainActionsCard(
    BuildContext context,
    ThemeData theme,
    ColorScheme colorScheme, {
    required bool hasSession,
    required AppUpdateStatus? updateStatus,
  }) {
    final us = updateStatus;
    return _ProfileCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (us != null && us.updateAvailable) ...[
            _profileTile(
              context,
              colorScheme,
              theme,
              icon: Icons.system_update_alt,
              title: '版本更新',
              showUpdateDot: true,
              subtitle: '新版本 ${us.manifest.latestVersion}',
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AppUpdatePage(status: us),
                  ),
                );
              },
            ),
            Divider(height: 1, color: colorScheme.outline.withOpacity(0.3)),
          ],
          _profileTile(
            context,
            colorScheme,
            theme,
            icon: Icons.school_outlined,
            title: '敏捷管理',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                    builder: (_) => const AgileCoursePage()),
              );
            },
          ),
          Divider(height: 1, color: colorScheme.outline.withOpacity(0.3)),
          _profileTile(
            context,
            colorScheme,
            theme,
            icon: Icons.person_outline,
            title: '个人资料',
            onTap: () {
              if (!hasSession) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请先登录')),
                );
                _openGitHubLogin(context);
                return;
              }
              _openProfileEdit(context);
            },
          ),
          Divider(height: 1, color: colorScheme.outline.withOpacity(0.3)),
          _profileTile(
            context,
            colorScheme,
            theme,
            icon: Icons.workspace_premium_outlined,
            title: '服务增值',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const ValueAddedPage(),
                ),
              );
            },
          ),
          Divider(height: 1, color: colorScheme.outline.withOpacity(0.3)),
          _profileTile(
            context,
            colorScheme,
            theme,
            icon: Icons.palette_outlined,
            title: '主题设置',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const ThemeSettingsPage(),
                ),
              );
            },
          ),
          Divider(height: 1, color: colorScheme.outline.withOpacity(0.3)),
          _profileTile(
            context,
            colorScheme,
            theme,
            icon: Icons.settings_outlined,
            title: '设置',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const SettingsPage(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAccountActionsCard(
    BuildContext context,
    ThemeData theme,
    ColorScheme colorScheme, {
    required bool isLocal,
  }) {
    return _ProfileCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isLocal) ...[
            _profileTile(
              context,
              colorScheme,
              theme,
              icon: Icons.login_rounded,
              title: 'GitHub 登录',
              onTap: () => _openGitHubLogin(context),
            ),
            Divider(height: 1, color: colorScheme.outline.withOpacity(0.3)),
          ],
          _profileTile(
            context,
            colorScheme,
            theme,
            icon: Icons.logout_rounded,
            title: '退出当前账号',
            onTap: () => _confirmSignOut(context),
          ),
        ],
      ),
    );
  }

  static Widget _profileTile(
    BuildContext context,
    ColorScheme colorScheme,
    ThemeData theme, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    String? subtitle,
    bool showUpdateDot = false,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      minLeadingWidth: 56,
      leading: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: colorScheme.onSurfaceVariant, size: 24),
      ),
      title: Text(
        title,
        // 显式统一字重，避免 Windows 中文字体合成粗体导致同句内粗细不一
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: subtitle == null || subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showUpdateDot)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: colorScheme.tertiary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          Icon(Icons.chevron_right,
              color: colorScheme.onSurfaceVariant, size: 24),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// 个人中心卡片：毛玻璃样式 + 轻微阴影，统一圆角
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: (theme.shadowColor).withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: AppGlassStyles.section(
        context,
        padding: EdgeInsets.zero,
        child: child,
      ),
    );
  }
}

class _AvatarView extends StatelessWidget {
  const _AvatarView({
    required this.user,
    required this.colorScheme,
  });

  final AuthUser? user;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final avatar = user?.avatarUrl?.trim() ?? '';
    if (avatar.isNotEmpty) {
      if (avatar.startsWith('http://') || avatar.startsWith('https://')) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Image.network(
            avatar,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _fallback(),
          ),
        );
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Image.file(
          File(avatar),
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _fallback(),
        ),
      );
    }
    return _fallback();
  }

  Widget _fallback() => Icon(
        Icons.person,
        size: 40,
        color: colorScheme.onPrimaryContainer,
      );
}
