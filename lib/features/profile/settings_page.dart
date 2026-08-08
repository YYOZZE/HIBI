import 'dart:io' show Platform;

import 'package:app_settings/app_settings.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/app_version.dart';
import '../../app/app_glass_styles.dart';
import '../../app/frosted_background.dart';
import '../../app/theme_notifier.dart';
import '../../app/theme_notifier_scope.dart';
import '../../app/theme_policy_service.dart';
import '../lan_sync/lan_sync_page.dart';
import '../transfer/transfer_file_actions.dart';
import '../transfer/transfer_save_path.dart';
import 'about_version_page.dart';
import 'agent_config_page.dart';
import 'privacy_terms_page.dart';
import 'services/app_update_service.dart';

/// 设置页：通知、权限、文件传输保存路径、关于等（与希比主题统一：毛玻璃背景 + 卡片）
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _transferSavePath;

  @override
  void initState() {
    super.initState();
    _loadTransferSavePath();
  }

  Future<void> _loadTransferSavePath() async {
    final path = await TransferSavePath.getPath();
    if (mounted) setState(() => _transferSavePath = path);
  }

  Future<void> _pickTransferSavePath() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null || !mounted) return;
    await TransferSavePath.setPath(dir);
    setState(() => _transferSavePath = dir);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已设置保存路径：$dir')),
      );
    }
  }

  Future<void> _resetTransferSavePath() async {
    await TransferSavePath.setPath(null);
    if (mounted) {
      setState(() => _transferSavePath = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已恢复为默认保存路径')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isZh = Localizations.localeOf(context).languageCode.toLowerCase().startsWith('zh');
    final appName = isZh ? '希比-2023' : 'hibi-2023';

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('设置'),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          Positioned.fill(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              children: [
                _SettingsCard(
                  children: [
                    _SettingsTile(
                      icon: Icons.notifications_outlined,
                      title: '通知',
                      subtitle: '推送与提醒',
                      onTap: () {
                        if (Platform.isAndroid) {
                          try {
                            AppSettings.openAppSettings(type: AppSettingsType.notification);
                          } catch (_) {
                            try { AppSettings.openAppSettings(); } catch (_) {}
                          }
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('请在系统设置中管理通知')),
                          );
                        }
                      },
                    ),
                    Divider(height: 1, color: colorScheme.outline.withOpacity(0.3)),
                    _SettingsTile(
                      icon: Icons.security_outlined,
                      title: '应用权限',
                      subtitle: '网络、存储等',
                      onTap: () async {
                        try {
                          await AppSettings.openAppSettings();
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('无法打开设置')),
                            );
                          }
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _SettingsCard(
                  children: [
                    _SettingsTile(
                      icon: Icons.folder_outlined,
                      title: '文件传输 · 默认保存路径',
                      subtitle: _transferSavePath != null && _transferSavePath!.isNotEmpty
                          ? _transferSavePath!
                          : '默认：应用文档目录 / HIBI_Received',
                      onTap: () async {
                        await _pickTransferSavePath();
                      },
                    ),
                    Divider(height: 1, color: colorScheme.outline.withOpacity(0.3)),
                    _SettingsTile(
                      icon: Icons.folder_open_outlined,
                      title: '文件传输 · 接收文件管理',
                      subtitle: '浏览、打开或删除已接收的文件',
                      onTap: () => TransferFileActions.openReceivedFilesManager(context),
                    ),
                    Divider(height: 1, color: colorScheme.outline.withOpacity(0.3)),
                    _SettingsTile(
                      icon: Icons.restore_outlined,
                      title: '恢复默认保存路径',
                      subtitle: '使用应用文档目录下的 HIBI_Received',
                      onTap: () async {
                        await _resetTransferSavePath();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _SettingsCard(
                  children: [
                    _SettingsTile(
                      icon: Icons.smart_toy_outlined,
                      title: '智能体配置',
                      subtitle: '自定义 API Key / Base URL，供助理对话调用',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const AgentConfigPage(),
                          ),
                        );
                      },
                    ),
                    Divider(height: 1, color: colorScheme.outline.withOpacity(0.3)),
                    _SettingsTile(
                      icon: Icons.sync_alt_outlined,
                      title: '局域网数据同步',
                      subtitle: '同网设备发现、配对并同步思维/日程/智能体',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const LanSyncPage(),
                          ),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _SettingsCard(
                  children: [
                    ValueListenableBuilder<AppUpdateStatus?>(
                      valueListenable: AppUpdateService.instance.statusNotifier,
                      builder: (context, updateStatus, _) {
                        final hasUpdate =
                            updateStatus != null && updateStatus.updateAvailable;
                        return _SettingsTile(
                          icon: Icons.info_outline,
                          title: '关于$appName',
                          subtitle: hasUpdate
                              ? '版本 $kAppDisplayVersion · 发现新版本 ${updateStatus.manifest.latestVersion}'
                              : '版本 $kAppDisplayVersion',
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const AboutVersionPage(),
                              ),
                            );
                          },
                        );
                      },
                    ),
                    Divider(height: 1, color: colorScheme.outline.withOpacity(0.3)),
                    _SettingsTile(
                      icon: Icons.policy_outlined,
                      title: '隐私条款',
                      subtitle: '查看我们如何收集与使用数据',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const PrivacyTermsPage(),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AppGlassStyles.section(
      context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ListTile(
      leading: Icon(icon, color: colorScheme.primary),
      title: Text(
        title,
        style: theme.textTheme.titleMedium,
      ),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodySmall,
      ),
      trailing: Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
      onTap: onTap,
    );
  }
}

/// 主题设置页：选择 hibi 主题 / 暗色主题 / 亮色主题
class ThemeSettingsPage extends StatelessWidget {
  const ThemeSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final notifier = ThemeNotifierScope.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final svc = ThemePolicyService.instance;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('主题设置'),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          Positioned.fill(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
            child: ClipRect(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                children: [
                  ValueListenableBuilder<List<ThemeCatalogItem>>(
                    valueListenable: svc.themeCatalogNotifier,
                    builder: (context, catalog, _) {
                      final items = catalog.isNotEmpty
                          ? _withSystemThemeFirst(catalog)
                          : AppThemeId.values
                              .map(
                                (id) => ThemeCatalogItem(
                                  id: id.value,
                                  name: id.displayName,
                                  applyThemeId: id.value,
                                ),
                              )
                              .toList();
                      return AppGlassStyles.section(
                        context,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: items.map((it) {
                            final isCustom = it.kind == 'custom' || it.id.startsWith('custom_');
                            final applyBuiltIn = it.applyThemeId.trim().isEmpty
                                ? AppThemeId.astral
                                : AppThemeId.fromValue(it.applyThemeId);
                            final selected = isCustom
                                ? notifier.themeKey == it.id
                                : notifier.themeId == applyBuiltIn;
                            final isLast = it == items.last;
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ListTile(
                                  leading: Icon(
                                    isCustom ? Icons.palette_outlined : _iconFor(applyBuiltIn),
                                    color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
                                  ),
                                  title: Text(
                                    it.name,
                                    style: theme.textTheme.titleMedium,
                                  ),
                                  subtitle: Text(
                                    isCustom
                                        ? (it.applyThemeId.trim().isEmpty
                                            ? '自定义主题（token）'
                                            : '自定义主题 · 绑定到 ${it.applyThemeId}')
                                        : _subtitleFor(applyBuiltIn),
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  trailing: selected
                                      ? Icon(Icons.check_circle, color: colorScheme.primary, size: 22)
                                      : null,
                                  onTap: () async {
                                    if (isCustom && it.styleCode.trim().isNotEmpty && it.applyThemeId.trim().isEmpty) {
                                      await notifier.setCustomTheme(
                                        themeKey: it.id,
                                        styleCode: it.styleCode,
                                        userInitiated: true,
                                      );
                                    } else {
                                      await notifier.setThemeId(applyBuiltIn, userInitiated: true);
                                    }
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text('已切换为${it.name}'),
                                          behavior: SnackBarBehavior.floating,
                                        ),
                                      );
                                    }
                                  },
                                ),
                                if (!isLast)
                                  Divider(
                                    height: 1,
                                    color: colorScheme.outline.withOpacity(0.3),
                                  ),
                              ],
                            );
                          }).toList(),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 「跟随系统」始终置顶：服务端目录未包含时插入首项，已包含则移到首位
  static List<ThemeCatalogItem> _withSystemThemeFirst(List<ThemeCatalogItem> catalog) {
    const autoId = '2026ss_auto';
    final existing = catalog.where((it) => it.applyThemeId.trim() == autoId || it.id == autoId).toList();
    final rest = catalog.where((it) => it.applyThemeId.trim() != autoId && it.id != autoId).toList();
    final entry = existing.isNotEmpty
        ? existing.first
        : const ThemeCatalogItem(
            id: autoId,
            name: '跟随系统',
            applyThemeId: autoId,
          );
    return [entry, ...rest];
  }

  static IconData _iconFor(AppThemeId id) {
    switch (id) {
      case AppThemeId.system2026:
        return Icons.brightness_auto_outlined;
      case AppThemeId.hibi:
        return Icons.image_outlined;
      case AppThemeId.dark:
        return Icons.dark_mode_outlined;
      case AppThemeId.light:
        return Icons.light_mode_outlined;
      case AppThemeId.light2026:
        return Icons.wb_sunny_outlined;
      case AppThemeId.dark2026:
        return Icons.nightlight_outlined;
      case AppThemeId.spring2027:
        return Icons.auto_awesome_outlined;
      case AppThemeId.dreamy:
        return Icons.favorite_border_rounded;
      case AppThemeId.dreamyNight:
        return Icons.nights_stay_outlined;
      case AppThemeId.cyberpunk:
        return Icons.bolt_outlined;
      case AppThemeId.astral:
        return Icons.auto_awesome_rounded;
      case AppThemeId.astralPhantasm:
        return Icons.flare_outlined;
      case AppThemeId.earthrealm:
        return Icons.public_outlined;
    }
  }

  static String _subtitleFor(AppThemeId id) {
    switch (id) {
      case AppThemeId.system2026:
        return '随系统亮暗自动切换亮色/暗色2026SS';
      case AppThemeId.hibi:
        return 'hibi主题背景 + 深紫色系';
      case AppThemeId.dark:
        return '纯色深色背景 + 蓝色点缀';
      case AppThemeId.light:
        return '纯色浅色背景 + 蓝色点缀';
      case AppThemeId.light2026:
        return 'iOS 风高级亮色：纯白卡片 + 高级灰点缀（默认）';
      case AppThemeId.dark2026:
        return 'iOS 风高级暗色：深灰卡片 + 银灰点缀';
      case AppThemeId.spring2027:
        return '2027SS 高级深色 + 柔光蓝色点缀';
      case AppThemeId.dreamy:
        return '梦幻粉紫 + 奶油黄浅蓝，女性向清透风格';
      case AppThemeId.dreamyNight:
        return '梦幻夜色 + 柔和霓彩光晕，适合夜间使用';
      case AppThemeId.cyberpunk:
        return '霓虹黄/青蓝/洋红，赛博科技夜景风格';
      case AppThemeId.astral:
        return '宇宙紫 + 星蓝青 + 金色点缀，星界科技风';
      case AppThemeId.astralPhantasm:
        return '星界进阶版：冰蓝紫雾玻璃质感';
      case AppThemeId.earthrealm:
        return '深海蓝 + 苍穹光蓝 + 铠甲金，地界史诗风';
    }
  }
}
