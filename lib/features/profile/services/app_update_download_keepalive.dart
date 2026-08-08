import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'app_update_service.dart';

/// Android 下载保活：WakeLock + 通知栏进度，降低锁屏/黑屏时进程被挂起的概率。
/// iOS/桌面仅尽力更新通知（无前台服务）。
class AppUpdateDownloadKeepAlive {
  AppUpdateDownloadKeepAlive._();
  static final AppUpdateDownloadKeepAlive instance =
      AppUpdateDownloadKeepAlive._();

  static const MethodChannel _channel = MethodChannel('hibi/network');
  static const String _channelId = 'hibi_app_update_download';
  static const String _channelName = '应用更新下载';
  static const int _notificationId = 92031;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _wakeHeld = false;

  Future<void> ensureReady() async {
    if (kIsWeb || _ready) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwin = DarwinInitializationSettings();
      await _plugin.initialize(
        const InitializationSettings(
          android: android,
          iOS: darwin,
          macOS: darwin,
        ),
      );
      if (Platform.isAndroid) {
        final androidPlugin =
            _plugin.resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        await androidPlugin?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: '希比应用更新包下载进度',
            importance: Importance.low,
            playSound: false,
            showBadge: false,
          ),
        );
      }
      _ready = true;
    } catch (e) {
      debugPrint('AppUpdateDownloadKeepAlive init failed: $e');
    }
  }

  Future<void> begin() async {
    await ensureReady();
    await _acquireWakeLock();
  }

  Future<void> end({bool clearNotification = true}) async {
    await _releaseWakeLock();
    if (clearNotification) {
      try {
        await _plugin.cancel(_notificationId);
      } catch (_) {}
    }
  }

  Future<void> publishProgress(AppUpdateDownloadProgress p) async {
    if (kIsWeb) return;
    await ensureReady();
    final total = p.totalBytes;
    final frac = (total != null && total > 0)
        ? (p.downloadedBytes / total).clamp(0.0, 1.0)
        : null;
    final percent =
        frac == null ? null : (frac * 100).clamp(0, 100).toStringAsFixed(0);

    String title;
    String body;
    var ongoing = false;
    var maxProgress = 0;
    var progress = 0;
    var indeterminate = false;

    switch (p.state) {
      case AppUpdateDownloadState.downloading:
        title = '正在下载更新';
        body = percent != null
            ? '$percent% · ${AppUpdateService.fmtBytes(p.downloadedBytes)}'
            : AppUpdateService.fmtBytes(p.downloadedBytes);
        ongoing = true;
        if (frac != null) {
          maxProgress = 100;
          progress = (frac * 100).round();
        } else {
          indeterminate = true;
        }
      case AppUpdateDownloadState.paused:
        title = '更新下载已暂停';
        body = percent != null ? '已完成 $percent%' : '可返回应用继续';
        ongoing = true;
        if (frac != null) {
          maxProgress = 100;
          progress = (frac * 100).round();
        }
      case AppUpdateDownloadState.completed:
        title = '更新包已就绪';
        body = '点击通知或返回应用安装';
        ongoing = false;
        maxProgress = 100;
        progress = 100;
      case AppUpdateDownloadState.error:
        title = '更新下载失败';
        body = (p.message ?? '请返回应用重试').trim();
        ongoing = false;
      case AppUpdateDownloadState.cancelled:
        await end(clearNotification: true);
        return;
      case AppUpdateDownloadState.idle:
        return;
    }

    try {
      await _plugin.show(
        _notificationId,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: '希比应用更新包下载进度',
            importance: Importance.low,
            priority: Priority.low,
            ongoing: ongoing,
            onlyAlertOnce: true,
            showProgress: p.state == AppUpdateDownloadState.downloading ||
                p.state == AppUpdateDownloadState.paused ||
                p.state == AppUpdateDownloadState.completed,
            maxProgress: maxProgress,
            progress: progress,
            indeterminate: indeterminate,
            playSound: false,
            category: AndroidNotificationCategory.progress,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: false,
            presentBadge: false,
            presentSound: false,
          ),
        ),
      );
    } catch (e) {
      debugPrint('update download notification failed: $e');
    }
  }

  Future<void> _acquireWakeLock() async {
    if (!Platform.isAndroid || _wakeHeld) return;
    try {
      await _channel.invokeMethod<bool>('acquireWakeLock');
      _wakeHeld = true;
    } catch (_) {}
  }

  Future<void> _releaseWakeLock() async {
    if (!Platform.isAndroid || !_wakeHeld) return;
    try {
      await _channel.invokeMethod<bool>('releaseWakeLock');
    } catch (_) {}
    _wakeHeld = false;
  }
}
