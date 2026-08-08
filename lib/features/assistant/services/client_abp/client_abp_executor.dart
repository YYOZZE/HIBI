import 'dart:convert';
import 'dart:math';

import '../../../mind/models/mind_node.dart';
import '../../../mind/services/mind_repository.dart';
import '../../../schedule/models/schedule_event.dart';
import '../../../schedule/schedule_event_store.dart';

/// 未指定提醒时默认提前分钟数（与 runtime 工具描述共用，避免循环 import）。
const int kClientAbpDefaultReminderMinutes = 15;

/// 在 App 本地执行 tools：写 [ScheduleEventStore] / [MindRepository]。
class ClientAbpExecutor {
  ClientAbpExecutor({
    ScheduleEventStore? schedule,
    MindRepository? mind,
  })  : _schedule = schedule ?? ScheduleEventStore.instance,
        _mind = mind ?? MindRepository.instance;

  final ScheduleEventStore _schedule;
  final MindRepository _mind;

  Future<String> execute(
    String name,
    Map<String, dynamic> args, {
    String? currentMindNodeId,
  }) async {
    try {
      switch (name) {
        case 'list_mind_projects':
          return _listMind();
        case 'get_mind_canvas':
          return _getCanvas(args, currentMindNodeId);
        case 'get_schedule':
          return _getSchedule(args);
        case 'create_schedule':
          return _createSchedule(args);
        case 'update_schedule':
          return _updateSchedule(args);
        case 'delete_schedule':
          return _deleteSchedule(args);
        case 'set_block_reminder':
          return await _setBlockReminder(args, currentMindNodeId);
        default:
          return jsonEncode({'error': '未知工具: $name'});
      }
    } catch (e) {
      return jsonEncode({'error': e.toString()});
    }
  }

  String _listMind() {
    final list = _mind.nodes
        .map((n) => {'id': n.id, 'title': n.title, 'essence': n.essence})
        .toList();
    return jsonEncode({'projects': list, 'count': list.length});
  }

  String _getCanvas(Map<String, dynamic> args, String? currentMindNodeId) {
    final name = (args['project_name'] ?? '').toString().trim();
    MindNode? node;
    if (name.isNotEmpty) {
      for (final n in _mind.nodes) {
        if (n.title == name) {
          node = n;
          break;
        }
      }
    } else if (currentMindNodeId != null && currentMindNodeId.isNotEmpty) {
      for (final n in _mind.nodes) {
        if (n.id == currentMindNodeId) {
          node = n;
          break;
        }
      }
    }
    if (node == null) {
      return jsonEncode({'error': '未找到项目'});
    }
    final blocks = <Map<String, dynamic>>[];
    final lines = <Map<String, dynamic>>[];
    for (final raw in node.canvasItems) {
      final type = (raw['type'] ?? '').toString();
      if (type == 'block' ||
          (raw.containsKey('text') && raw.containsKey('x'))) {
        blocks.add({
          'id': raw['id'],
          'text': (raw['text'] ?? raw['content'] ?? '').toString(),
          'hasReminder':
              raw['reminderAt'] != null || raw['reminderTime'] != null,
          'reminderAt': raw['reminderAt'] ?? raw['reminderTime'],
        });
      } else if (type == 'line') {
        lines.add({
          'id': raw['id'],
          'fromId': raw['fromId'],
          'toId': raw['toId'],
        });
      }
    }
    return jsonEncode({
      'project': {'id': node.id, 'title': node.title},
      'blocks': blocks,
      'lines': lines,
    });
  }

  String _getSchedule(Map<String, dynamic> args) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime start;
    DateTime end;
    final sd = (args['start_date'] ?? '').toString().trim();
    final ed = (args['end_date'] ?? '').toString().trim();
    if (sd.isNotEmpty && ed.isNotEmpty) {
      start = DateTime.parse(sd);
      end = DateTime.parse(ed);
    } else {
      final days = (args['days'] is int)
          ? args['days'] as int
          : int.tryParse('${args['days']}') ?? 7;
      start = today;
      end = today.add(Duration(days: max(1, days) - 1));
    }
    final events = _schedule.events.where((e) {
      for (var d = start;
          !d.isAfter(end);
          d = d.add(const Duration(days: 1))) {
        if (e.occursOn(d)) return true;
      }
      return false;
    }).map((e) => {
          'id': e.id,
          'title': e.title,
          'startTime': e.startTime.toIso8601String(),
          'endTime': e.endTime.toIso8601String(),
          'isAllDay': e.isAllDay,
          'reminderMinutes': e.reminderMinutes,
          'location': e.location,
        }).toList();
    return jsonEncode({
      'meta': {
        'start_date': start.toIso8601String().substring(0, 10),
        'end_date': end.toIso8601String().substring(0, 10),
        'count': events.length,
      },
      'events': events,
    });
  }

  String _createSchedule(Map<String, dynamic> args) {
    final title = (args['title'] ?? '').toString().trim();
    if (title.isEmpty) return jsonEncode({'error': 'title 必填'});
    final start = _parseTime(args['start_time']);
    final end = _parseTime(args['end_time']);
    if (start == null || end == null) {
      return jsonEncode({'error': 'start_time 与 end_time 必填且需为 ISO8601'});
    }
    final id =
        'evt_${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}${Random().nextInt(0xfff).toRadixString(16)}';
    final reminder = args['reminder_minutes'] != null
        ? int.tryParse('${args['reminder_minutes']}')
        : kClientAbpDefaultReminderMinutes;
    final ev = ScheduleEvent(
      id: id,
      title: title,
      startTime: start,
      endTime: end,
      isAllDay: args['is_all_day'] == true,
      location: _optStr(args['location']),
      reminderMinutes: reminder,
      essence: _optStr(args['essence']),
    );
    _schedule.add(ev);
    return jsonEncode({
      'ok': true,
      'title': ev.title,
      'startTime': ev.startTime.toIso8601String(),
      'endTime': ev.endTime.toIso8601String(),
      'reminderMinutes': ev.reminderMinutes,
    });
  }

  String _updateSchedule(Map<String, dynamic> args) {
    final eventId = (args['event_id'] ?? '').toString().trim();
    if (eventId.isEmpty) return jsonEncode({'error': 'event_id 必填'});
    if (eventId.startsWith('mind_block_')) {
      return jsonEncode({'error': '方块关联日程请用 set_block_reminder'});
    }
    final all = _schedule.eventsAll;
    final i = all.indexWhere((e) => e.id == eventId);
    if (i < 0) return jsonEncode({'error': '未找到日程'});
    final ev = all[i];
    if (ev.isDeleted) return jsonEncode({'error': '该日程已删除'});
    if (args['title'] != null) ev.title = args['title'].toString().trim();
    final st = _parseTime(args['start_time']);
    final et = _parseTime(args['end_time']);
    if (st != null) ev.startTime = st;
    if (et != null) ev.endTime = et;
    if (args['is_all_day'] != null) ev.isAllDay = args['is_all_day'] == true;
    if (args.containsKey('location')) {
      ev.location = _optStr(args['location']);
    }
    if (args['reminder_minutes'] != null) {
      ev.reminderMinutes = int.tryParse('${args['reminder_minutes']}');
    }
    if (args.containsKey('essence')) {
      ev.essence = _optStr(args['essence']);
    }
    _schedule.addOrUpdate(ev);
    return jsonEncode({'ok': true, 'title': ev.title});
  }

  String _deleteSchedule(Map<String, dynamic> args) {
    final eventId = (args['event_id'] ?? '').toString().trim();
    if (eventId.isEmpty) return jsonEncode({'error': 'event_id 必填'});
    if (eventId.startsWith('mind_block_')) {
      return jsonEncode({'error': '方块关联日程请在白板清除提醒'});
    }
    _schedule.removeById(eventId);
    return jsonEncode({'ok': true});
  }

  Future<String> _setBlockReminder(
    Map<String, dynamic> args,
    String? currentMindNodeId,
  ) async {
    final blockId = (args['block_id'] ?? '').toString().trim();
    final start = _parseTime(args['start_time']);
    final end = _parseTime(args['end_time']);
    if (blockId.isEmpty || start == null || end == null) {
      return jsonEncode({'error': 'block_id/start_time/end_time 必填'});
    }
    final projectName = (args['project_name'] ?? '').toString().trim();
    MindNode? node;
    if (projectName.isNotEmpty) {
      for (final n in _mind.nodes) {
        if (n.title == projectName) {
          node = n;
          break;
        }
      }
    } else if (currentMindNodeId != null) {
      for (final n in _mind.nodes) {
        if (n.id == currentMindNodeId) {
          node = n;
          break;
        }
      }
    }
    if (node == null) return jsonEncode({'error': '未找到项目'});

    Map<String, dynamic>? block;
    for (final raw in node.canvasItems) {
      if (raw['id']?.toString() == blockId) {
        block = raw;
        break;
      }
    }
    if (block == null) return jsonEncode({'error': '未找到方块'});
    if (block['reminderAt'] != null || block['reminderTime'] != null) {
      return jsonEncode({
        'error': '该方块已有提醒，不覆盖。可用 create_schedule 新建独立日程。',
      });
    }
    block['reminderAt'] = start.toIso8601String();
    node.updatedAt = DateTime.now();
    await _mind.update(node);

    final title = (block['text'] ?? block['content'] ?? node.title).toString();
    final eventId = ScheduleEventStore.mindBlockEventId(blockId);
    _schedule.addOrUpdate(
      ScheduleEvent(
        id: eventId,
        title: title.trim().isEmpty ? '方块提醒' : title.trim(),
        startTime: start,
        endTime: end,
        reminderMinutes: kClientAbpDefaultReminderMinutes,
      ),
    );
    return jsonEncode({'ok': true, 'title': title});
  }

  static String? _optStr(dynamic v) {
    final s = (v ?? '').toString().trim();
    return s.isEmpty ? null : s;
  }

  static DateTime? _parseTime(dynamic v) {
    if (v == null) return null;
    var s = v.toString().trim();
    if (s.isEmpty) return null;
    if (s.length >= 19 && s[10] == ' ') {
      s = '${s.substring(0, 10)}T${s.substring(11)}';
    }
    return DateTime.tryParse(s);
  }
}
