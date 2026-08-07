/// 日程重复规则（仿飞书）
enum ScheduleRecurrence {
  none,
  daily,
  weekly,
  monthly,
}

/// 单条日程（仿飞书：标题、时间、重复、地点、提醒、要义；不含协作）
class ScheduleEvent {
  ScheduleEvent({
    required this.id,
    required this.title,
    required this.startTime,
    required this.endTime,
    this.isDeleted = false,
    this.deletedAt,
    this.isAllDay = false,
    this.location,
    this.recurrence = ScheduleRecurrence.none,
    this.reminderMinutes,
    this.recurrenceEndDate,
    this.essence,
  });

  final String id;
  String title;
  DateTime startTime;
  DateTime endTime;
  /// 软删除：用于跨端同步删除（tombstone），避免 merge 时被云端旧数据“复活”。
  bool isDeleted;
  DateTime? deletedAt;
  bool isAllDay;
  String? location;
  ScheduleRecurrence recurrence;
  /// 提前多少分钟提醒，如 15 表示提前 15 分钟
  int? reminderMinutes;
  /// 重复结束日期（仅重复日程有效）
  DateTime? recurrenceEndDate;
  /// 要义 / 要点摘要
  String? essence;

  bool occursOn(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final start = DateTime(startTime.year, startTime.month, startTime.day);
    final end = endTime.isBefore(startTime)
        ? start
        : DateTime(endTime.year, endTime.month, endTime.day);
    final endLimit = recurrenceEndDate != null
        ? DateTime(recurrenceEndDate!.year, recurrenceEndDate!.month, recurrenceEndDate!.day)
        : null;

    if (recurrence == ScheduleRecurrence.none) {
      return (d.isAtSameMomentAs(start) || d.isAfter(start)) &&
          (d.isAtSameMomentAs(end) || d.isBefore(end));
    }

    if (endLimit != null && d.isAfter(endLimit)) return false;
    if (d.isBefore(start)) return false;

    switch (recurrence) {
      case ScheduleRecurrence.daily:
        return true;
      case ScheduleRecurrence.weekly:
        return date.weekday == startTime.weekday;
      case ScheduleRecurrence.monthly:
        return date.day == startTime.day;
      case ScheduleRecurrence.none:
        return d.isAtSameMomentAs(start) || (d.isAfter(start) && (d.isBefore(end) || d.isAtSameMomentAs(end)));
    }
  }

  ScheduleEvent copyWith({
    String? id,
    String? title,
    DateTime? startTime,
    DateTime? endTime,
    bool? isDeleted,
    DateTime? deletedAt,
    bool? isAllDay,
    String? location,
    ScheduleRecurrence? recurrence,
    int? reminderMinutes,
    DateTime? recurrenceEndDate,
    String? essence,
  }) {
    return ScheduleEvent(
      id: id ?? this.id,
      title: title ?? this.title,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      isDeleted: isDeleted ?? this.isDeleted,
      deletedAt: deletedAt ?? this.deletedAt,
      isAllDay: isAllDay ?? this.isAllDay,
      location: location ?? this.location,
      recurrence: recurrence ?? this.recurrence,
      reminderMinutes: reminderMinutes ?? this.reminderMinutes,
      recurrenceEndDate: recurrenceEndDate ?? this.recurrenceEndDate,
      essence: essence ?? this.essence,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        if (isDeleted) 'isDeleted': true,
        if (deletedAt != null) 'deletedAt': deletedAt!.toIso8601String(),
        'isAllDay': isAllDay,
        if (location != null) 'location': location,
        'recurrence': recurrence.name,
        if (reminderMinutes != null) 'reminderMinutes': reminderMinutes,
        if (recurrenceEndDate != null) 'recurrenceEndDate': recurrenceEndDate!.toIso8601String(),
        if (essence != null) 'essence': essence,
      };

  /// 兼容 `2026-03-28T20:00:00` 与模型偶发的 `2026-03-28 20:00:00`（空格）。
  static DateTime _parseTime(dynamic v) {
    final s = v?.toString().trim() ?? '';
    if (s.length >= 19 && s[10] == ' ') {
      return DateTime.parse('${s.substring(0, 10)}T${s.substring(11)}');
    }
    return DateTime.parse(s);
  }

  static ScheduleEvent fromJson(Map<String, dynamic> json) {
    return ScheduleEvent(
      id: json['id'] as String,
      title: json['title'] as String,
      startTime: _parseTime(json['startTime']),
      endTime: _parseTime(json['endTime']),
      isDeleted: json['isDeleted'] == true,
      deletedAt: json['deletedAt'] != null ? _parseTime(json['deletedAt']) : null,
      isAllDay: json['isAllDay'] as bool? ?? false,
      location: json['location'] as String?,
      recurrence: ScheduleRecurrence.values.firstWhere(
        (e) => e.name == json['recurrence'],
        orElse: () => ScheduleRecurrence.none,
      ),
      reminderMinutes: json['reminderMinutes'] as int?,
      recurrenceEndDate: json['recurrenceEndDate'] != null
          ? DateTime.parse(json['recurrenceEndDate'] as String)
          : null,
      essence: json['essence'] as String?,
    );
  }
}
