import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_update_service.dart';

/// Android 下载保活：前台服务 (FGS) + 通知栏进度，保证锁屏/黑屏时继续下载。
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
  bool _fgsActive = false;
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
        // Android 13+：无通知权限时无法展示 FGS 通知，下载易被系统限制
        final status = await Permission.notification.status;
        if (!status.isGranted) {
          await Permission.notification.request();
        }
      }
      _ready = true;
    } catch (e) {
      debugPrint('AppUpdateDownloadKeepAlive init failed: $e');
    }
  }

  Future<void> begin() async {
    await ensureReady();
    if (Platform.isAndroid) {
      await _startForegroundService(
        title: '正在下载更新',
        body: '准备开始…',
        ongoing: true,
        indeterminate: true,
      );
    } else {
      await _acquireWakeLock();
    }
  }

  Future<void> end({bool clearNotification = true}) async {
    if (Platform.isAndroid) {
      await _stopForegroundService(clear: clearNotification);
    } else {
      await _releaseWakeLock();
    }
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
    var useFgs = false;

    switch (p.state) {
      case AppUpdateDownloadState.downloading:
        title = '正在下载更新';
        body = percent != null
            ? '$percent% · ${AppUpdateService.fmtBytes(p.downloadedBytes)}'
            : AppUpdateService.fmtBytes(p.downloadedBytes);
        if (p.speedBytesPerSec != null && p.speedBytesPerSec! > 0) {
          body =
              '$body · ${AppUpdateService.fmtBytes(p.speedBytesPerSec!)}/s';
        }
        ongoing = true;
        useFgs = true;
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
        useFgs = true;
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

    // 下载中/暂停：Android 走前台服务通知（系统级保活）
    if (Platform.isAndroid && useFgs) {
      await _updateForegroundService(
        title: title,
        body: body,
        progress: progress,
        maxProgress: maxProgress,
        indeterminate: indeterminate,
        ongoing: ongoing,
      );
      return;
    }

    // 完成/失败：先停 FGS，再用普通通知提示（可点击）
    if (Platform.isAndroid && _fgsActive) {
      await _stopForegroundService(clear: true);
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

  Future<void> _startForegroundService({
    required String title,
    required String body,
    required bool ongoing,
    required bool indeterminate,
    int progress = 0,
    int maxProgress = 0,
  }) async {
    try {
      await _channel.invokeMethod<bool>('startUpdateDownloadForeground', {
        'title': title,
        'body': body,
        'progress': progress,
        'maxProgress': maxProgress,
        'indeterminate': indeterminate,
        'ongoing': ongoing,
      });
      _fgsActive = true;
    } catch (e) {
      debugPrint('startUpdateDownloadForeground failed: $e');
      // 回退：至少持有 Activity 侧 WakeLock
      await _acquireWakeLock();
    }
  }

  Future<void> _updateForegroundService({
    required String title,
    required String body,
    required int progress,
    required int maxProgress,
    required bool indeterminate,
    required bool ongoing,
  }) async {
    try {
      await _channel.invokeMethod<bool>('updateUpdateDownloadForeground', {
        'title': title,
        'body': body,
        'progress': progress,
        'maxProgress': maxProgress,
        'indeterminate': indeterminate,
        'ongoing': ongoing,
      });
      _fgsActive = true;
    } catch (e) {
      debugPrint('updateUpdateDownloadForeground failed: $e');
      if (!_fgsActive) {
        await _startForegroundService(
          title: title,
          body: body,
          ongoing: ongoing,
          indeterminate: indeterminate,
          progress: progress,
          maxProgress: maxProgress,
        );
      }
    }
  }

  Future<void> _stopForegroundService({required bool clear}) async {
    if (!_fgsActive && !_wakeHeld) {
      try {
        await _channel.invokeMethod<bool>('stopUpdateDownloadForeground', {
          'clear': clear,
        });
      } catch (_) {}
      return;
    }
    try {
      await _channel.invokeMethod<bool>('stopUpdateDownloadForeground', {
        'clear': clear,
      });
    } catch (_) {}
    _fgsActive = false;
    await _releaseWakeLock();
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

  /// 是否已忽略电池优化（未忽略时息屏易被国产 ROM 杀进程）。
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      return await _channel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 弹出系统「忽略电池优化」对话框；已忽略则直接返回 true。
  Future<bool> requestIgnoreBatteryOptimizations() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      return await _channel
              .invokeMethod<bool>('requestIgnoreBatteryOptimizations') ??
          false;
    } catch (_) {
      return false;
    }
  }
}
