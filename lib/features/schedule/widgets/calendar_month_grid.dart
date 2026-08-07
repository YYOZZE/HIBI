import 'package:flutter/material.dart';

import '../models/schedule_event.dart';

/// 月历网格（仿飞书）：按周分行，可在选中日所在周下方插入当日详情，实现“上下劈开”
class CalendarMonthGrid extends StatelessWidget {
  const CalendarMonthGrid({
    super.key,
    required this.year,
    required this.month,
    required this.selectedDate,
    required this.onSelectDate,
    required this.eventsForMonth,
    this.detailWidget,
  });

  final int year;
  final int month;
  final DateTime selectedDate;
  final ValueChanged<DateTime> onSelectDate;
  final List<ScheduleEvent> eventsForMonth;
  /// 展开时插入在选中日所在周下方（从日历中间劈开）
  final Widget? detailWidget;

  static const List<String> _weekdays = ['日', '一', '二', '三', '四', '五', '六'];
  /// 每日固定显示 4 条事项位，不足也保留空位，整体协调
  static const int kEventSlotsPerDay = 4;
  /// 事项条高度
  static const double kSlotHeight = 16;
  /// 两条事项之间的间隙
  static const double kSlotGap = 2;
  /// 每日格子固定高度：日期区 + 4 条事项位 + 间隙
  static const double kDayCellHeight = 36 + kEventSlotsPerDay * kSlotHeight + (kEventSlotsPerDay - 1) * kSlotGap;

  bool _isCurrentMonth(DateTime? d) {
    return d != null && d.month == month;
  }

  DateTime get _firstDayOfMonth => DateTime(year, month, 1);

  DateTime get _firstDayOfGrid {
    final w = _firstDayOfMonth.weekday % 7;
    return _firstDayOfMonth.subtract(Duration(days: w));
  }

  DateTime get _lastDayOfMonth => DateTime(year, month + 1, 0);

  int get _totalGridCells {
    final first = _firstDayOfGrid;
    final last = _lastDayOfMonth;
    final days = last.difference(first).inDays + 1;
    return (days / 7).ceil() * 7;
  }

  int get _numWeeks => _totalGridCells ~/ 7;

  /// 选中日落在第几周（0-based），仅当选中日在当前月内时有效
  int get _selectedWeekIndex {
    if (selectedDate.year != year || selectedDate.month != month) return 0;
    final first = _firstDayOfGrid;
    final firstDate = DateTime(first.year, first.month, first.day);
    final selectedDateOnly = DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
    final diff = selectedDateOnly.difference(firstDate).inDays;
    if (diff < 0) return 0;
    final week = diff ~/ 7;
    if (week >= _numWeeks) return _numWeeks - 1;
    return week;
  }

  List<ScheduleEvent> _eventsOn(DateTime date) {
    return eventsForMonth.where((e) => e.occursOn(date)).toList();
  }

  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final first = _firstDayOfGrid;
    final last = _lastDayOfMonth;
    final numWeeks = _numWeeks;
    final selectedWeek = _selectedWeekIndex;
    final insertDetail = detailWidget != null;

    final children = <Widget>[
      Row(
        children: List.generate(
          7,
          (i) => Expanded(
            child: Center(
              child: Text(
                _weekdays[i],
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w400,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
    ];

    for (var w = 0; w < numWeeks; w++) {
      children.add(_buildWeekRow(context, first, last, w));
      if (insertDetail && w == selectedWeek) {
        children.add(detailWidget!);
      }
    }

    return ClipRect(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  Widget _buildWeekRow(BuildContext context, DateTime first, DateTime last, int weekIndex) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final startOffset = weekIndex * 7;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SizedBox(
        height: kDayCellHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: List.generate(7, (col) {
            final date = first.add(Duration(days: startOffset + col));
            final isPastMonth = date.isAfter(last);
            final dateOrNull = isPastMonth ? null : date;
            return Expanded(
              child: _buildDayCell(context, dateOrNull, colorScheme, theme),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildDayCell(
    BuildContext context,
    DateTime? date,
    ColorScheme colorScheme,
    ThemeData theme,
  ) {
    if (date == null) {
      return const SizedBox(height: kDayCellHeight);
    }
    final isCurrentMonth = _isCurrentMonth(date);
    final isToday = _isToday(date);
    final isSelected = _isSameDay(date, selectedDate);
    final dayEvents = _eventsOn(date);
    // 当天始终有选中式高亮：选中时用实心，未选中时用描边
    final isTodayHighlight = isToday;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onSelectDate(date),
        borderRadius: BorderRadius.circular(6),
        child: ClipRect(
          child: SizedBox(
            height: kDayCellHeight,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 2),
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? colorScheme.primary
                        : isTodayHighlight
                            ? colorScheme.primary.withOpacity(0.4)
                            : null,
                    shape: BoxShape.circle,
                    border: isTodayHighlight && !isSelected
                        ? Border.all(color: colorScheme.primary, width: 1.5)
                        : null,
                  ),
                  child: Text(
                    '${date.day}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isCurrentMonth
                          ? (isSelected || isTodayHighlight
                              ? colorScheme.onPrimary
                              : colorScheme.onSurface)
                          : colorScheme.onSurface.withOpacity(0.4),
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                // 固定 4 条事项位，有则显示标题，无则留空；条与条之间留小间隙
                ...List.generate(kEventSlotsPerDay, (i) {
                  final isLast = i == kEventSlotsPerDay - 1;
                  final hasEvent = i < dayEvents.length;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      hasEvent
                          ? Tooltip(
                              message: dayEvents[i].title,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 1, right: 1),
                                child: Container(
                                  height: kSlotHeight,
                                  width: double.infinity,
                                  alignment: Alignment.centerLeft,
                                  padding: const EdgeInsets.only(left: 4),
                                  decoration: BoxDecoration(
                                    color: colorScheme.primaryContainer.withOpacity(0.75),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                  child: Text(
                                    dayEvents[i].title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelMedium?.copyWith(
                                      color: colorScheme.onPrimaryContainer,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                            )
                          : SizedBox(height: kSlotHeight),
                      if (!isLast) const SizedBox(height: kSlotGap),
                    ],
                  );
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
