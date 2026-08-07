import 'dart:io';
import 'dart:async';
import 'dart:ffi' as ffi;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'models/schedule_event.dart';

/// 日程提醒调度：将 ScheduleEvent 的 reminderMinutes 映射为系统本地通知（Android/Windows）。
class ScheduleReminderService {
  ScheduleReminderService._();
  static final ScheduleReminderService instance = ScheduleReminderService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  final Map<String, ScheduleEvent> _eventCache = <String, ScheduleEvent>{};
  final Set<String> _foregroundFiredKeys = <String>{};
  final Set<String> _uiAlertFiredKeys = <String>{};
  Timer? _foregroundTicker;
  Timer? _windowsBeepLoopTimer;
  final ValueNotifier<ScheduleReminderAlert?> alertNotifier = ValueNotifier<ScheduleReminderAlert?>(null);

  /// 升级渠道 id，使「闹钟类」铃声/振动在 Android 8+ 上按新渠道生效（旧渠道用户可在系统设置里改或重装应用）
  static const String _androidChannelId = 'hibi_schedule_alarm_v1';
  static const String _androidChannelName = '日程提醒';
  static const String _androidChannelDesc = '日程与白板提醒（铃声与振动，类似系统闹钟流）';
  static const int _mbIconExclamation = 0x00000030;

  static final Int64List _kVibrationPattern = Int64List.fromList([0, 380, 200, 380]);

  // Windows 前台兜底：触发系统提示音（不依赖通知中心是否静音显示弹窗）。
  static final ffi.DynamicLibrary? _user32 = (!kIsWeb && Platform.isWindows)
      ? ffi.DynamicLibrary.open('user32.dll')
      : null;
  static final int Function(int)? _messageBeep = _user32
      ?.lookupFunction<ffi.Int32 Function(ffi.Uint32), int Function(int)>('MessageBeep');

  Future<void> init() async {
    if (_initialized) return;
    tz.initializeTimeZones();
    await _configureLocalTimeZone();

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    final isZh = Platform.localeName.toLowerCase().startsWith('zh');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    final windows = WindowsInitializationSettings(
      appName: isZh ? '希比-2023' : 'hibi-2023',
      appUserModelId: 'Tsingcoop.Hibi2023',
      guid: 'd8b3b4d1-1bb5-4c65-8d22-5178a111cc73',
    );
    final settings = InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
      windows: windows,
    );
    await _plugin.initialize(settings);

    if (Platform.isIOS) {
      final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      await ios?.requestPermissions(alert: true, badge: true, sound: true);
    }
    if (Platform.isMacOS) {
      final mac = _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
      await mac?.requestPermissions(alert: true, badge: true, sound: true);
    }

    if (Platform.isAndroid) {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.requestNotificationsPermission();
      await androidPlugin?.requestExactAlarmsPermission();
      await androidPlugin?.createNotificationChannel(
        AndroidNotificationChannel(
          _androidChannelId,
          _androidChannelName,
          description: _androidChannelDesc,
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 380, 200, 380]),
          audioAttributesUsage: AudioAttributesUsage.alarm,
        ),
      );
    }
    _startForegroundFallbackTicker();
    _initialized = true;
  }

  Future<void> _configureLocalTimeZone() async {
    try {
      final timezoneName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timezoneName));
    } catch (_) {
      tz.setLocalLocation(tz.UTC);
    }
  }

  Future<void> rescheduleAll(Iterable<ScheduleEvent> events) async {
    await init();
    await _plugin.cancelAll();
    _eventCache
      ..clear()
      ..addEntries(events.map((e) => MapEntry(e.id, e)));
    for (final e in events) {
      await _scheduleEvent(e);
    }
  }

  Future<void> upsertEvent(ScheduleEvent event) async {
    await init();
    _eventCache[event.id] = event;
    await removeEvent(event.id);
    await _scheduleEvent(event);
  }

  Future<void> removeEvent(String eventId) async {
    await init();
    _eventCache.remove(eventId);
    _foregroundFiredKeys.removeWhere((k) => k.startsWith('$eventId|'));
    _uiAlertFiredKeys.removeWhere((k) => k.startsWith('$eventId|'));
    for (var i = 0; i < _maxSchedulesPerEvent; i++) {
      await _plugin.cancel(_notificationId(eventId, i));
    }
  }

  static const int _maxSchedulesPerEvent = 96;

  DarwinNotificationDetails _darwinReminderDetails() {
    return const DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'default',
      // iOS 15+：timeSensitive 比 active 更接近“到点提醒”的期望（critical 需额外 entitlement）
      interruptionLevel: InterruptionLevel.timeSensitive,
    );
  }

  AndroidNotificationDetails _androidReminderDetails() {
    return AndroidNotificationDetails(
      _androidChannelId,
      _androidChannelName,
      channelDescription: _androidChannelDesc,
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
      enableVibration: true,
      vibrationPattern: _kVibrationPattern,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      category: AndroidNotificationCategory.alarm,
      fullScreenIntent: true,
      ticker: '日程提醒',
      visibility: NotificationVisibility.public,
    );
  }

  NotificationDetails _notificationDetails() {
    return NotificationDetails(
      android: _androidReminderDetails(),
      iOS: _darwinReminderDetails(),
      macOS: _darwinReminderDetails(),
      windows: _windowsAlarmDetails(),
    );
  }

  Future<void> _zonedScheduleWithFallback({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails details,
    String? payload,
  }) async {
    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        scheduledDate,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: payload,
      );
      return;
    } catch (e) {
      debugPrint('ScheduleReminder zoned exact failed: $e');
    }
    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        scheduledDate,
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: payload,
      );
    } catch (e) {
      debugPrint('ScheduleReminder zoned inexact failed: $e');
    }
  }

  Future<void> _scheduleEvent(ScheduleEvent event) async {
    final reminders = _nextReminderTimes(event).take(_maxSchedulesPerEvent).toList();
    final details = _notificationDetails();
    for (var i = 0; i < reminders.length; i++) {
      final when = reminders[i];
      await _zonedScheduleWithFallback(
        id: _notificationId(event.id, i),
        title: event.title,
        body: _buildBody(event),
        scheduledDate: tz.TZDateTime.from(when, tz.local),
        details: details,
        payload: event.id,
      );
    }
  }

  String _buildBody(ScheduleEvent event) {
    final start = event.startTime;
    final hh = start.hour.toString().padLeft(2, '0');
    final mm = start.minute.toString().padLeft(2, '0');
    if (event.isAllDay) return '今天：${event.title}';
    return '$hh:$mm 开始：${event.title}';
  }

  List<DateTime> _nextReminderTimes(ScheduleEvent event) {
    final reminderMinutes = event.reminderMinutes;
    if (reminderMinutes == null) return const [];

    final now = DateTime.now();
    final horizon = now.add(const Duration(days: 90));

    if (event.recurrence == ScheduleRecurrence.none) {
      final t = event.startTime.subtract(Duration(minutes: reminderMinutes));
      if (!t.isBefore(now)) return [t];
      return const [];
    }

    final startDay = DateTime(event.startTime.year, event.startTime.month, event.startTime.day);
    final endDay = event.recurrenceEndDate != null
        ? DateTime(
            event.recurrenceEndDate!.year,
            event.recurrenceEndDate!.month,
            event.recurrenceEndDate!.day,
          )
        : horizon;

    final out = <DateTime>[];
    var cursorDay = DateTime(now.year, now.month, now.day);
    if (cursorDay.isBefore(startDay)) cursorDay = startDay;

    while (!cursorDay.isAfter(endDay) && !cursorDay.isAfter(horizon)) {
      final occurs = switch (event.recurrence) {
        ScheduleRecurrence.daily => true,
        ScheduleRecurrence.weekly => cursorDay.weekday == event.startTime.weekday,
        ScheduleRecurrence.monthly => cursorDay.day == event.startTime.day,
        ScheduleRecurrence.none => false,
      };
      if (occurs) {
        final scheduledStart = DateTime(
          cursorDay.year,
          cursorDay.month,
          cursorDay.day,
          event.startTime.hour,
          event.startTime.minute,
        );
        final reminderAt = scheduledStart.subtract(Duration(minutes: reminderMinutes));
        if (!reminderAt.isBefore(now)) out.add(reminderAt);
      }
      cursorDay = cursorDay.add(const Duration(days: 1));
    }
    return out;
  }

  int _notificationId(String eventId, int index) {
    return (_stableHash(eventId) + index) & 0x3fffffff;
  }

  void _startForegroundFallbackTicker() {
    _foregroundTicker?.cancel();
    _foregroundTicker = Timer.periodic(const Duration(seconds: 6), (_) {
      unawaited(_runForegroundFallbackTick());
    });
  }

  Future<void> _runForegroundFallbackTick() async {
    if (_eventCache.isEmpty) return;
    final now = DateTime.now();
    final windowStart = now.subtract(const Duration(seconds: 35));
    final windowEnd = now.add(const Duration(seconds: 5));
    for (final event in _eventCache.values) {
      final reminders = _reminderTimesInWindow(event, windowStart, windowEnd);
      for (final reminderAt in reminders) {
        if (reminderAt.isBefore(windowStart) || reminderAt.isAfter(windowEnd)) continue;
        final fireKey = '${event.id}|${reminderAt.millisecondsSinceEpoch}';
        if (_foregroundFiredKeys.contains(fireKey)) continue;
        _foregroundFiredKeys.add(fireKey);
        await _showNow(event, reminderAt);
        _emitUiAlarm(event, reminderAt, fireKey);
      }
    }
  }

  Iterable<DateTime> _reminderTimesInWindow(
    ScheduleEvent event,
    DateTime windowStart,
    DateTime windowEnd,
  ) sync* {
    final reminderMinutes = event.reminderMinutes;
    if (reminderMinutes == null) return;

    if (event.recurrence == ScheduleRecurrence.none) {
      final t = event.startTime.subtract(Duration(minutes: reminderMinutes));
      if (!t.isBefore(windowStart) && !t.isAfter(windowEnd)) {
        yield t;
      }
      return;
    }

    final startDay = DateTime(event.startTime.year, event.startTime.month, event.startTime.day);
    final endDay = event.recurrenceEndDate != null
        ? DateTime(
            event.recurrenceEndDate!.year,
            event.recurrenceEndDate!.month,
            event.recurrenceEndDate!.day,
          )
        : windowEnd.add(const Duration(days: 90));

    // 提前/延后一天，覆盖“提醒时间跨日”的场景（如 00:05 提前 30 分钟）。
    var cursorDay = DateTime(
      windowStart.year,
      windowStart.month,
      windowStart.day,
    ).subtract(const Duration(days: 1));
    final untilDay = DateTime(
      windowEnd.year,
      windowEnd.month,
      windowEnd.day,
    ).add(const Duration(days: 1));

    if (cursorDay.isBefore(startDay)) cursorDay = startDay;
    while (!cursorDay.isAfter(endDay) && !cursorDay.isAfter(untilDay)) {
      final occurs = switch (event.recurrence) {
        ScheduleRecurrence.daily => true,
        ScheduleRecurrence.weekly => cursorDay.weekday == event.startTime.weekday,
        ScheduleRecurrence.monthly => cursorDay.day == event.startTime.day,
        ScheduleRecurrence.none => false,
      };
      if (occurs) {
        final scheduledStart = DateTime(
          cursorDay.year,
          cursorDay.month,
          cursorDay.day,
          event.startTime.hour,
          event.startTime.minute,
        );
        final reminderAt = scheduledStart.subtract(Duration(minutes: reminderMinutes));
        if (!reminderAt.isBefore(windowStart) && !reminderAt.isAfter(windowEnd)) {
          yield reminderAt;
        }
      }
      cursorDay = cursorDay.add(const Duration(days: 1));
    }
  }

  void _emitUiAlarm(ScheduleEvent event, DateTime reminderAt, String fireKey) {
    if (_uiAlertFiredKeys.contains(fireKey)) return;
    _uiAlertFiredKeys.add(fireKey);
    _startWindowsAlarmCueLoop();
    alertNotifier.value = ScheduleReminderAlert(
      eventId: event.id,
      title: event.title,
      body: _buildBody(event),
      reminderAt: reminderAt,
    );
  }

  void clearActiveAlert() {
    alertNotifier.value = null;
    _stopWindowsAlarmCueLoop();
  }

  Future<void> snooze(String eventId, {Duration delay = const Duration(minutes: 5)}) async {
    await init();
    final event = _eventCache[eventId];
    if (event == null) return;
    final when = DateTime.now().add(delay);
    final id = (_notificationId(event.id, 0) ^ (when.millisecondsSinceEpoch >> 1)) & 0x3fffffff;
    final details = _notificationDetails();
    await _zonedScheduleWithFallback(
      id: id,
      title: '${event.title}（稍后提醒）',
      body: _buildBody(event),
      scheduledDate: tz.TZDateTime.from(when, tz.local),
      details: details,
      payload: event.id,
    );
    // 兜底：前台运行时也会再弹一次明确提醒
    Timer(delay, () async {
      final key = '${event.id}|${when.millisecondsSinceEpoch}';
      await _showNow(event, when);
      _emitUiAlarm(event, when, key);
    });
  }

  Future<void> _showNow(ScheduleEvent event, DateTime reminderAt) async {
    final details = _notificationDetails();
    final id = (_notificationId(event.id, 0) ^ reminderAt.millisecondsSinceEpoch) & 0x3fffffff;
    try {
      await _plugin.show(
        id,
        event.title,
        _buildBody(event),
        details,
        payload: event.id,
      );
    } catch (_) {}
  }

  int _stableHash(String text) {
    var hash = 0;
    for (final c in text.codeUnits) {
      hash = 0x1fffffff & (hash + c);
      hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
      hash ^= (hash >> 6);
    }
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    hash ^= (hash >> 11);
    hash = 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
    return hash;
  }

  WindowsNotificationDetails _windowsAlarmDetails() {
    return WindowsNotificationDetails(
      scenario: WindowsNotificationScenario.alarm,
      duration: WindowsNotificationDuration.long,
      audio: WindowsNotificationAudio.preset(
        sound: WindowsNotificationSound.alarm2,
        // Windows toast 是否播放/弹窗强依赖系统通知设置、AUMID/快捷方式注册等；
        // 这里尽量用“闹钟场景 + 循环铃声”提升到点可感知性。
        shouldLoop: true,
      ),
      subtitle: '到点提醒',
    );
  }

  void _startWindowsAlarmCueLoop() {
    if (kIsWeb || !Platform.isWindows) return;
    // 前台兜底：系统提示音循环一段时间，直到用户点“我知道了/稍后提醒”之类关闭弹窗。
    _windowsBeepLoopTimer?.cancel();
    var ticks = 0;
    _windowsBeepLoopTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      ticks++;
      try {
        _messageBeep?.call(_mbIconExclamation);
      } catch (_) {}
      // 最多响约 40 秒，避免打扰过久（真正后台强提醒应依赖系统 toast 设置/闹钟场景）
      if (ticks >= 20) {
        _stopWindowsAlarmCueLoop();
      }
    });
    // 立即响一次
    try {
      _messageBeep?.call(_mbIconExclamation);
    } catch (_) {}
  }

  void _stopWindowsAlarmCueLoop() {
    _windowsBeepLoopTimer?.cancel();
    _windowsBeepLoopTimer = null;
  }
}

class ScheduleReminderAlert {
  const ScheduleReminderAlert({
    required this.eventId,
    required this.title,
    required this.body,
    required this.reminderAt,
  });

  final String eventId;
  final String title;
  final String body;
  final DateTime reminderAt;
}

