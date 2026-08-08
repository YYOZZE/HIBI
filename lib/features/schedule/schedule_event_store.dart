import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../auth/services/account_storage_paths.dart';
import '../auth/services/user_sync_scheduler.dart';
import 'models/schedule_event.dart';
import 'schedule_reminder_service.dart';

/// 日程事件共享存储，供日程页与思维节点方块提醒同步使用；持久化到本地，重启后保留
class ScheduleEventStore {
  ScheduleEventStore._() {
    _loadFuture = _load();
  }

  late final Future<void> _loadFuture;
  bool _loaded = false;

  final ValueNotifier<List<ScheduleEvent>> eventsNotifier = ValueNotifier<List<ScheduleEvent>>([]);

  /// 确保已从磁盘加载完成（日程页/思维画布使用前调用，避免重启后日程丢失）
  Future<void> ensureLoaded() => _loadFuture;

  Future<File> _file() async => AccountStoragePaths.scheduleEventsFile();

  Future<void> _load() async {
    if (_loaded) return;
    try {
      if (AccountStoragePaths.activeKey == AccountStoragePaths.localKey) {
        await AccountStoragePaths.migrateLegacyIntoLocalIfNeeded();
      }
      final file = await _file();
      if (await file.exists()) {
        final list = jsonDecode(await file.readAsString()) as List<dynamic>;
        final events = <ScheduleEvent>[];
        for (final e in list) {
          if (e is! Map) continue;
          try {
            events.add(ScheduleEvent.fromJson(Map<String, dynamic>.from(e)));
          } catch (err, st) {
            debugPrint('日程单条解析跳过: $err\n$st');
          }
        }
        eventsNotifier.value = events;
        unawaited(ScheduleReminderService.instance.rescheduleAll(events));
      } else {
        // 无持久化文件（全新安装/新账号/本地模式）：一律空列表，不注入任何演示数据
        eventsNotifier.value = [];
        await _save(notifySync: false);
        unawaited(ScheduleReminderService.instance.rescheduleAll(const []));
      }
    } catch (_) {
      // 读取失败：内存置空；仅在文件不存在时落盘空文件，避免覆盖可能可恢复的既有数据
      eventsNotifier.value = [];
      final file = await _file();
      if (!await file.exists()) {
        await _save(notifySync: false);
      }
      unawaited(ScheduleReminderService.instance.rescheduleAll(const []));
    }
    _loaded = true;
  }

  Future<void> _save({bool notifySync = true}) async {
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode(eventsNotifier.value.map((e) => e.toJson()).toList()),
      );
      if (notifySync) UserSyncScheduler.requestPush();
    } catch (_) {}
  }

  /// 切换账户后清空日程内存与文件，不写入演示数据；不写盘触发 push，避免把空覆盖到刚 push 完的账户
  void resetToEmpty() {
    eventsNotifier.value = [];
    _save(notifySync: false);
    unawaited(ScheduleReminderService.instance.rescheduleAll(const []));
  }

  /// 登录后从服务端写回本地文件后调用；文件不存在时一律回落为空列表（全新安装无任何演示数据）
  Future<void> reloadFromDisk() async {
    try {
      final file = await _file();
      if (!await file.exists()) {
        if (AccountStoragePaths.activeKey == AccountStoragePaths.localKey) {
          await AccountStoragePaths.migrateLegacyIntoLocalIfNeeded();
          if (!await file.exists()) {
            eventsNotifier.value = [];
            await _save(notifySync: false);
            unawaited(ScheduleReminderService.instance.rescheduleAll(const []));
          } else {
            final list = jsonDecode(await file.readAsString()) as List<dynamic>;
            final ev = <ScheduleEvent>[];
            for (final e in list) {
              if (e is! Map) continue;
              try {
                ev.add(ScheduleEvent.fromJson(Map<String, dynamic>.from(e)));
              } catch (_) {}
            }
            eventsNotifier.value = ev;
            unawaited(ScheduleReminderService.instance.rescheduleAll(eventsNotifier.value));
          }
        } else {
          eventsNotifier.value = [];
          unawaited(ScheduleReminderService.instance.rescheduleAll(const []));
        }
        return;
      }
      final list = jsonDecode(await file.readAsString()) as List<dynamic>;
      final events = <ScheduleEvent>[];
      for (final e in list) {
        if (e is! Map) continue;
        try {
          events.add(ScheduleEvent.fromJson(Map<String, dynamic>.from(e)));
        } catch (err, st) {
          debugPrint('日程单条解析跳过: $err\n$st');
        }
      }
      eventsNotifier.value = events;
      unawaited(ScheduleReminderService.instance.rescheduleAll(events));
    } catch (_) {}
  }

  static final ScheduleEventStore instance = ScheduleEventStore._();

  /// 仅用于展示/提醒调度的“有效日程”（已软删除的不返回）
  List<ScheduleEvent> get events => eventsNotifier.value.where((e) => !e.isDeleted).toList();

  /// 全量（含软删除 tombstone），用于持久化与云端同步合并
  List<ScheduleEvent> get eventsAll => eventsNotifier.value;

  void add(ScheduleEvent event) {
    event.isDeleted = false;
    event.deletedAt = null;
    eventsNotifier.value = [...eventsNotifier.value, event];
    _save();
    unawaited(ScheduleReminderService.instance.upsertEvent(event));
  }

  void update(ScheduleEvent event) {
    event.isDeleted = false;
    event.deletedAt = null;
    final list = eventsNotifier.value;
    final i = list.indexWhere((e) => e.id == event.id);
    if (i >= 0) {
      final next = List<ScheduleEvent>.from(list)..[i] = event;
      eventsNotifier.value = next;
    } else {
      eventsNotifier.value = [...list, event];
    }
    _save();
    unawaited(ScheduleReminderService.instance.upsertEvent(event));
  }

  void addOrUpdate(ScheduleEvent event) {
    event.isDeleted = false;
    event.deletedAt = null;
    final list = eventsNotifier.value;
    final i = list.indexWhere((e) => e.id == event.id);
    if (i >= 0) {
      final next = List<ScheduleEvent>.from(list)..[i] = event;
      eventsNotifier.value = next;
    } else {
      eventsNotifier.value = [...list, event];
    }
    _save();
    unawaited(ScheduleReminderService.instance.upsertEvent(event));
  }

  void removeById(String id) {
    // 软删除：保留 tombstone 以便跨端同步删除（否则 merge 会把云端旧日程重新并回来）
    final list = List<ScheduleEvent>.from(eventsNotifier.value);
    final i = list.indexWhere((e) => e.id == id);
    final now = DateTime.now();
    if (i >= 0) {
      final e = list[i];
      e.isDeleted = true;
      e.deletedAt = now;
      list[i] = e;
    } else {
      list.add(
        ScheduleEvent(
          id: id,
          title: '',
          startTime: now,
          endTime: now,
          isDeleted: true,
          deletedAt: now,
        ),
      );
    }
    eventsNotifier.value = list;
    _save();
    unawaited(ScheduleReminderService.instance.removeEvent(id));
  }

  /// 思维节点方块关联的日程 id 前缀，用于同步
  static const String mindBlockEventIdPrefix = 'mind_block_';

  static String mindBlockEventId(String blockId) => '$mindBlockEventIdPrefix$blockId';
}
