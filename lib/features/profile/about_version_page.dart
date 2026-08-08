import 'package:flutter/material.dart';

import '../../app/app_glass_styles.dart';
import '../../app/app_version.dart';
import '../../app/frosted_background.dart';
import 'app_update_dialog.dart';
import 'app_update_page.dart';
import 'services/app_update_service.dart';

/// 关于版本页：应用 Logo、当前版本、GitHub 最新版本检查与更新入口。
/// 更新检查仅由本页「检查更新」按钮手动触发，App 启动不再自动检查。
class AboutVersionPage extends StatefulWidget {
  const AboutVersionPage({super.key});

  @override
  State<AboutVersionPage> createState() => _AboutVersionPageState();
}

class _AboutVersionPageState extends State<AboutVersionPage> {
  bool _checking = false;

  void _showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  /// 手动触发检查：有更新弹「发现新版本」对话框；已最新/失败给轻提示。
  /// `_checking` 期间按钮禁用，配合本守卫防连点。
  Future<void> _runManualCheck() async {
    if (_checking) return;
    setState(() => _checking = true);
    final result = await AppUpdateService.instance.checkManually();
    if (!mounted) return;
    setState(() => _checking = false);
    switch (result) {
      case AppUpdateManualCheckResult.updateAvailable:
        final status = AppUpdateService.instance.statusNotifier.value;
        if (status != null && status.updateAvailable) {
          await showAppUpdateDialog(context, status);
        }
      case AppUpdateManualCheckResult.upToDate:
        _showSnack('当前已是最新版本');
      case AppUpdateManualCheckResult.rateLimited:
        _showSnack('检查过于频繁，请稍后再试');
      case AppUpdateManualCheckResult.networkFailed:
      case AppUpdateManualCheckResult.failed:
        _showSnack('检查失败，请检查网络后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text('关于版本'),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          Positioned.fill(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
              children: [
                const SizedBox(height: 24),
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Image.asset(
                      // 跟随系统亮/暗：系统深色用深灰版，否则浅灰版
                      MediaQuery.platformBrightnessOf(context) == Brightness.dark
                          ? 'xhb-image/1_1_dark.png'
                          : 'xhb-image/1_1.png',
                      width: 96,
                      height: 96,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Center(
                  child: Text(
                    '当前版本  V $kAppDisplayVersion',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                ValueListenableBuilder<AppUpdateStatus?>(
                  valueListenable: AppUpdateService.instance.statusNotifier,
                  builder: (context, status, _) {
                    return AppGlassStyles.section(
                      context,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: _buildStatusContent(context, theme, cs, status),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 48),
                Center(
                  child: Text(
                    'Copyright © 2014 - 2025 三端同步助手. All Rights Reserved',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusContent(
    BuildContext context,
    ThemeData theme,
    ColorScheme cs,
    AppUpdateStatus? status,
  ) {
    final hasUpdate = status != null && status.updateAvailable;
    final sizeText = (hasUpdate && status.assetSizeForPlatform != null)
        ? '（${AppUpdateService.fmtBytes(status.assetSizeForPlatform!)}）'
        : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              hasUpdate ? Icons.system_update_alt : Icons.verified_outlined,
              color: hasUpdate ? cs.primary : cs.onSurfaceVariant,
              size: 22,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                hasUpdate
                    ? '发现新版本 V ${status.manifest.latestVersion} $sizeText'
                    : _checking
                        ? '正在检查更新…'
                        : status == null
                            ? '尚未检查更新'
                            : '当前已是最新版本',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: hasUpdate ? cs.primary : cs.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (hasUpdate)
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => AppUpdatePage(status: status),
                ),
              );
            },
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('立即更新'),
          )
        else
          OutlinedButton.icon(
            onPressed: _checking ? null : _runManualCheck,
            icon: _checking
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, size: 18),
            label: Text(_checking ? '检查中…' : '检查更新'),
          ),
      ],
    );
  }
}
