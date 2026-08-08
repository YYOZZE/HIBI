import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/frosted_background.dart';
import 'services/app_update_service.dart';

/// 版本更新说明与安装入口
class AppUpdatePage extends StatefulWidget {
  const AppUpdatePage({super.key, required this.status});

  final AppUpdateStatus status;

  @override
  State<AppUpdatePage> createState() => _AppUpdatePageState();
}

class _AppUpdatePageState extends State<AppUpdatePage> {
  /// 下载任务由 AppUpdateService 按 URL 持有：页面退出后下载在后台继续，
  /// 重新进入时复用同一任务恢复进度展示，因此无需在 dispose 中取消。
  AppUpdateDownloadTask? _task;
  bool _installing = false;

  @override
  void initState() {
    super.initState();
    final url = widget.status.downloadUrlForPlatform;
    if (!kIsWeb && (url ?? '').isNotEmpty && !Platform.isIOS) {
      _task = AppUpdateService.instance.createDownloadTask(url!);
    }
  }

  String _fmtBytes(int n) => AppUpdateService.fmtBytes(n);

  String _fmtSpeed(int? bps) {
    if (bps == null || bps <= 0) return '';
    return '${_fmtBytes(bps)}/s';
  }

  Future<void> _install(String? filePath) async {
    if (_installing) return; // 连点防护：避免重复拉起安装器
    if (filePath == null || filePath.isEmpty) return;
    _installing = true;
    try {
      await AppUpdateService.instance.downloadAndOpenInstaller(filePath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开安装包：$e')),
        );
      }
    } finally {
      _installing = false;
    }
  }

  Future<void> _startOrOpen() async {
    final url = widget.status.downloadUrlForPlatform;
    if (url == null || url.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('发布页暂未提供本平台的安装包，请前往 GitHub 发布页下载。')),
        );
      }
      return;
    }
    try {
      if (kIsWeb) return;
      if (Platform.isIOS) {
        await AppUpdateService.instance.openExternalUrl(url);
        return;
      }
      final task = _task;
      if (task == null) return;
      final st = task.progressNotifier.value;
      if (st.state == AppUpdateDownloadState.completed) {
        await _install(st.filePath);
      } else if (st.state == AppUpdateDownloadState.paused) {
        task.resume();
      } else if (st.state == AppUpdateDownloadState.downloading) {
        // 下载中，无需重复触发
      } else {
        await task.start();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('更新失败：$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final s = widget.status;
    final notes = s.manifest.releaseNotes.trim();
    final hasUrl = (s.downloadUrlForPlatform ?? '').isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('版本更新'),
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
                Text(
                  '发现新版本 ${s.manifest.latestVersion}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '当前版本 ${s.currentVersion}（构建 ${s.currentBuildNumber}）',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                if (s.assetSizeForPlatform != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '文件大小：${_fmtBytes(s.assetSizeForPlatform!)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Text(
                  '更新内容',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    notes.isEmpty ? '（管理员未填写更新说明）' : notes,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      height: 1.45,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                if (Platform.isIOS) ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: !hasUrl ? null : _startOrOpen,
                      child: const Text('前往 App Store 更新'),
                    ),
                  ),
                ] else ...[
                  ValueListenableBuilder<AppUpdateDownloadProgress>(
                    valueListenable: _task?.progressNotifier ??
                        ValueNotifier<AppUpdateDownloadProgress>(
                          const AppUpdateDownloadProgress(state: AppUpdateDownloadState.idle),
                        ),
                    builder: (context, p, _) {
                      // 有效总大小：优先响应的 Content-Length，未建立连接时回退 manifest 资产大小
                      final total = AppUpdateService.effectiveTotalBytes(
                          p.totalBytes, s.assetSizeForPlatform);
                      final frac = (total != null && total > 0) ? (p.downloadedBytes / total).clamp(0.0, 1.0) : null;
                      final state = p.state;
                      final canStart = hasUrl && (state == AppUpdateDownloadState.idle || state == AppUpdateDownloadState.cancelled);
                      final canRetry = hasUrl && state == AppUpdateDownloadState.error;
                      final canPause = state == AppUpdateDownloadState.downloading;
                      final canResume = state == AppUpdateDownloadState.paused;
                      final canCancel = state == AppUpdateDownloadState.downloading || state == AppUpdateDownloadState.paused;
                      final canInstall = state == AppUpdateDownloadState.completed;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  state == AppUpdateDownloadState.completed
                                      ? '下载完成'
                                      : state == AppUpdateDownloadState.paused
                                          ? '已暂停'
                                          : state == AppUpdateDownloadState.downloading
                                              ? '下载中...'
                                              : state == AppUpdateDownloadState.error
                                                  ? '下载失败'
                                                  : '准备下载',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: cs.onSurface,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                TweenAnimationBuilder<double>(
                                  tween: Tween<double>(
                                    begin: 0,
                                    end: frac ?? 0,
                                  ),
                                  duration: const Duration(milliseconds: 280),
                                  curve: Curves.easeOutCubic,
                                  builder: (context, animated, _) {
                                    return ClipRRect(
                                      borderRadius: BorderRadius.circular(999),
                                      child: LinearProgressIndicator(
                                        value: frac == null &&
                                                state ==
                                                    AppUpdateDownloadState
                                                        .downloading
                                            ? null
                                            : (frac == null ? 0 : animated),
                                        minHeight: 8,
                                      ),
                                    );
                                  },
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        AppUpdateService.formatDownloadSizeText(
                                          state: state,
                                          downloadedBytes: p.downloadedBytes,
                                          totalBytes: p.totalBytes,
                                          manifestAssetSize: s.assetSizeForPlatform,
                                        ),
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: cs.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                    if (frac != null) ...[
                                      Text(
                                        '${(frac * 100).clamp(0, 100).toStringAsFixed(0)}%',
                                        style: theme.textTheme.labelLarge?.copyWith(
                                          color: cs.primary,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                    ],
                                    if (state == AppUpdateDownloadState.downloading)
                                      Text(
                                        _fmtSpeed(p.speedBytesPerSec),
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: cs.onSurfaceVariant,
                                        ),
                                      ),
                                  ],
                                ),
                                if ((p.message ?? '').isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    p.message!,
                                    style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton(
                                  onPressed: canInstall
                                      ? () => _install(p.filePath)
                                      : ((canStart || canRetry || canResume) ? _startOrOpen : null),
                                  child: Text(
                                    canInstall
                                        ? '安装'
                                        : (canResume ? '继续' : (canRetry ? '重试下载' : '开始下载')),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton(
                                onPressed: canPause ? () => _task?.pause() : null,
                                child: const Text('暂停'),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton(
                                onPressed: canCancel ? () => _task?.cancel() : null,
                                child: const Text('取消'),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ],
                if (!hasUrl) ...[
                  const SizedBox(height: 12),
                  Text(
                    '暂未提供本平台的安装包，可前往 GitHub 发布页手动下载。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.outline,
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      try {
                        await AppUpdateService.instance
                            .openExternalUrl(s.manifest.releasePageUrl);
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('无法打开发布页：$e')),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('打开 GitHub 发布页'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
