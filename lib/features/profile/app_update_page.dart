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
  AppUpdateDownloadTask? _task;

  String _fmtBytes(int n) {
    const kb = 1024.0;
    const mb = kb * 1024;
    const gb = mb * 1024;
    final v = n.toDouble();
    if (v >= gb) return '${(v / gb).toStringAsFixed(2)}GB';
    if (v >= mb) return '${(v / mb).toStringAsFixed(1)}MB';
    if (v >= kb) return '${(v / kb).toStringAsFixed(0)}KB';
    return '${n}B';
  }

  String _fmtSpeed(int? bps) {
    if (bps == null || bps <= 0) return '';
    return '${_fmtBytes(bps)}/s';
  }

  Future<void> _startOrOpen() async {
    final url = widget.status.downloadUrlForPlatform;
    if (url == null || url.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('后台未配置本平台的安装包地址，请联系管理员或前往官网下载。')),
        );
      }
      return;
    }
    try {
      if (kIsWeb) return;
      if (Platform.isIOS) {
        await AppUpdateService.instance.openExternalUrl(url);
      } else {
        _task ??= AppUpdateService.instance.createDownloadTask(url);
        final st = _task!.progressNotifier.value.state;
        if (st == AppUpdateDownloadState.completed) {
          final p = _task!.progressNotifier.value.filePath;
          if (p != null && p.isNotEmpty) {
            await AppUpdateService.instance.downloadAndOpenInstaller(p);
          }
        } else if (st == AppUpdateDownloadState.paused) {
          await _task!.resume();
        } else if (st == AppUpdateDownloadState.downloading) {
          // no-op
        } else {
          await _task!.start();
        }
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
                    valueListenable: (_task ??= (hasUrl ? AppUpdateService.instance.createDownloadTask(s.downloadUrlForPlatform!) : null))
                            ?.progressNotifier ??
                        ValueNotifier<AppUpdateDownloadProgress>(
                          const AppUpdateDownloadProgress(state: AppUpdateDownloadState.idle),
                        ),
                    builder: (context, p, _) {
                      final total = p.totalBytes;
                      final frac = (total != null && total > 0) ? (p.downloadedBytes / total).clamp(0.0, 1.0) : null;
                      final state = p.state;
                      final canStart = hasUrl && (state == AppUpdateDownloadState.idle || state == AppUpdateDownloadState.error || state == AppUpdateDownloadState.cancelled);
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
                                if (frac != null)
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(999),
                                    child: LinearProgressIndicator(value: frac, minHeight: 8),
                                  )
                                else
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(999),
                                    child: const LinearProgressIndicator(minHeight: 8),
                                  ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Text(
                                      total == null
                                          ? _fmtBytes(p.downloadedBytes)
                                          : '${_fmtBytes(p.downloadedBytes)} / ${_fmtBytes(total)}',
                                      style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                                    ),
                                    const Spacer(),
                                    if (state == AppUpdateDownloadState.downloading)
                                      Text(
                                        _fmtSpeed(p.speedBytesPerSec),
                                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
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
                                      ? () async {
                                          final fp = p.filePath;
                                          if (fp == null || fp.isEmpty) return;
                                          await AppUpdateService.instance.downloadAndOpenInstaller(fp);
                                        }
                                      : (canStart ? _startOrOpen : (canResume ? () => _task!.resume() : null)),
                                  child: Text(
                                    canInstall ? '安装' : (canResume ? '继续' : '开始下载'),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton(
                                onPressed: canPause ? () => _task!.pause() : null,
                                child: const Text('暂停'),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton(
                                onPressed: canCancel ? () => _task!.cancel() : null,
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
                    '尚未配置本平台的下载地址，请在管理后台「升级推送地址」中填写。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.outline,
                    ),
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
