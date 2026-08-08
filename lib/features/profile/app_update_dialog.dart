import 'package:flutter/material.dart';

import '../../app/app_glass_styles.dart';
import 'app_update_page.dart';
import 'services/app_update_service.dart';

/// 「发现新版本」对话框：设置「关于版本」页手动检查到更新后弹出。
/// 「立即更新」跳转 [AppUpdatePage]；「稍后」仅关闭。
Future<void> showAppUpdateDialog(BuildContext context, AppUpdateStatus status) {
  final size = status.assetSizeForPlatform;
  final notes = status.manifest.releaseNotes.trim();
  const maxNotes = 420;
  final notesExcerpt =
      notes.length > maxNotes ? '${notes.substring(0, maxNotes)}…' : notes;

  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final cs = theme.colorScheme;
      final maxH = MediaQuery.sizeOf(ctx).height * 0.72;
      final maxW = MediaQuery.sizeOf(ctx).width.clamp(280.0, 420.0);

      return Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
          child: AppGlassStyles.section(
            ctx,
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: cs.primary.withOpacity(0.14),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.system_update_alt_rounded,
                        color: cs.primary,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '发现新版本',
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: cs.onSurface,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '希比 HIBI 有可用更新',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: cs.primary.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: cs.primary.withOpacity(0.22)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '最新版本',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'V${status.manifest.latestVersion}',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                color: cs.onSurface,
                                fontWeight: FontWeight.w700,
                                height: 1.15,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '当前 ${status.currentVersion}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          if (size != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              AppUpdateService.fmtBytes(size),
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: cs.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                if (notesExcerpt.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    '更新说明',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 220),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withOpacity(0.55),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: cs.outline.withOpacity(0.28),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        notesExcerpt,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => AppUpdatePage(status: status),
                        ),
                      );
                    },
                    child: const Text('立即更新'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 44,
                  child: TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text(
                      '稍后',
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
