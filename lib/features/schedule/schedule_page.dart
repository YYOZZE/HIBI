import 'package:flutter/material.dart';

import '../../app/frosted_background.dart';
import 'models/schedule_event.dart';
import 'schedule_event_edit_page.dart';
import 'schedule_event_store.dart';
import 'widgets/calendar_month_grid.dart';

/// 日程管理 - 仿飞书：月历、选中日日程列表、新建/编辑（不含协作）
class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key});

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  late DateTime _viewMonth;
  late DateTime _selectedDate;

  /// 是否展开当日详情（图二：周条 + 日程列表）；收起时仅显示月历总览
  bool _dayDetailExpanded = false;
  final ScheduleEventStore _store = ScheduleEventStore.instance;
  bool _storeLoaded = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _viewMonth = DateTime(now.year, now.month);
    _selectedDate = now;
    _store.eventsNotifier.addListener(_onStoreChanged);
    _store.ensureLoaded().then((_) {
      if (mounted) setState(() => _storeLoaded = true);
    });
  }

  @override
  void dispose() {
    _store.eventsNotifier.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  List<ScheduleEvent> _eventsInMonth() {
    final events = _store.events;
    final lastDay = DateTime(_viewMonth.year, _viewMonth.month + 1, 0).day;
    return events.where((e) {
      for (var day = 1; day <= lastDay; day++) {
        if (e.occursOn(DateTime(_viewMonth.year, _viewMonth.month, day)))
          return true;
      }
      return false;
    }).toList();
  }

  List<ScheduleEvent> _eventsOnSelectedDay() {
    return _store.events.where((e) => e.occursOn(_selectedDate)).toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  void _onSelectDate(DateTime date) {
    setState(() {
      _selectedDate = date;
      _viewMonth = DateTime(date.year, date.month);
      _dayDetailExpanded = true;
    });
  }

  void _onAddEvent() async {
    final event = await Navigator.of(context).push<ScheduleEvent>(
      MaterialPageRoute(
        builder: (context) => ScheduleEventEditPage(initialDate: _selectedDate),
      ),
    );
    if (event != null) {
      _store.add(event);
    }
  }

  /// 编辑页返回 null 表示取消；返回 ScheduleEvent 表示保存；返回 true 表示已删除
  void _onEditEvent(ScheduleEvent event) async {
    final result = await Navigator.of(context).push<Object?>(
      MaterialPageRoute(
        builder: (context) => ScheduleEventEditPage(event: event),
      ),
    );
    if (result == null) return;
    if (result is ScheduleEvent) {
      _store.addOrUpdate(result);
      return;
    }
    if (result == true) {
      _store.removeById(event.id);
    }
  }

  String _monthYearLabel() {
    return '${_viewMonth.year}年${_viewMonth.month}月';
  }

  /// 插入在选中日所在周下方的当日详情（飞书式：从日历中间劈开，不再重复当周条）
  Widget _buildDetailInset(List<ScheduleEvent> dayEvents) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => setState(() => _dayDetailExpanded = false),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.keyboard_arrow_up,
                    color: colorScheme.onSurfaceVariant,
                    size: 24,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '收起看总览',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56, maxHeight: 200),
          child: dayEvents.isEmpty
              ? _EmptyDayContent(
                  onTap: _onAddEvent,
                  selectedDate: _selectedDate,
                )
              : ListView.builder(
                  shrinkWrap: true,
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  itemCount: dayEvents.length,
                  itemBuilder: (context, i) {
                    final e = dayEvents[i];
                    return _DayEventTile(
                      event: e,
                      onTap: () => _onEditEvent(e),
                    );
                  },
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final eventsForMonth = _eventsInMonth();
    final dayEvents = _eventsOnSelectedDay();

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _monthYearLabel(),
                style: theme.textTheme.titleLarge?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_drop_down),
              onPressed: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: _viewMonth,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2030),
                );
                if (date != null) {
                  setState(() {
                    _viewMonth = DateTime(date.year, date.month);
                  });
                }
              },
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () {
              setState(() {
                if (_viewMonth.month == 1) {
                  _viewMonth = DateTime(_viewMonth.year - 1, 12);
                } else {
                  _viewMonth = DateTime(_viewMonth.year, _viewMonth.month - 1);
                }
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () {
              setState(() {
                if (_viewMonth.month == 12) {
                  _viewMonth = DateTime(_viewMonth.year + 1, 1);
                } else {
                  _viewMonth = DateTime(_viewMonth.year, _viewMonth.month + 1);
                }
              });
            },
          ),
          IconButton(
            onPressed: _onAddEvent,
            icon: const Icon(Icons.event_available_outlined, size: 19),
            tooltip: '新建日程',
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          Positioned.fill(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 20),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: CalendarMonthGrid(
                  year: _viewMonth.year,
                  month: _viewMonth.month,
                  selectedDate: _selectedDate,
                  onSelectDate: _onSelectDate,
                  eventsForMonth: eventsForMonth,
                  detailWidget:
                      _dayDetailExpanded ? _buildDetailInset(dayEvents) : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 当周条（仿图二：选中日所在周的 7 天，点击可切换日）
class _WeekStrip extends StatelessWidget {
  const _WeekStrip({
    required this.selectedDate,
    required this.onSelectDate,
  });

  final DateTime selectedDate;
  final ValueChanged<DateTime> onSelectDate;

  static const List<String> _weekdays = ['日', '一', '二', '三', '四', '五', '六'];

  DateTime get _sundayOfWeek {
    final w = selectedDate.weekday % 7;
    return selectedDate.subtract(Duration(days: w));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final sun = _sundayOfWeek;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: List.generate(7, (i) {
            final date = sun.add(Duration(days: i));
            final isSelected = date.year == selectedDate.year &&
                date.month == selectedDate.month &&
                date.day == selectedDate.day;
            return Expanded(
              child: InkWell(
                onTap: () => onSelectDate(date),
                borderRadius: BorderRadius.circular(6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _weekdays[i],
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isSelected ? colorScheme.primary : null,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${date.day}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: isSelected
                              ? colorScheme.onPrimary
                              : colorScheme.onSurface,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
      ],
    );
  }
}

/// 当日无日程时展示（紧凑：文案 + 点击创建；加号由 FAB 提供）
class _EmptyDayContent extends StatelessWidget {
  const _EmptyDayContent({required this.onTap, required this.selectedDate});

  final VoidCallback onTap;
  final DateTime selectedDate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Text(
            '无日程，点击创建',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _DayEventTile extends StatelessWidget {
  const _DayEventTile({required this.event, required this.onTap});

  final ScheduleEvent event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 4,
        height: 40,
        decoration: BoxDecoration(
          color: colorScheme.primary,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      title: Text(
        event.title,
        style: theme.textTheme.titleMedium?.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w500,
          fontSize: 16,
        ),
      ),
      subtitle: Text(
        event.isAllDay
            ? '全天'
            : '${event.startTime.hour.toString().padLeft(2, '0')}:${event.startTime.minute.toString().padLeft(2, '0')} - ${event.endTime.hour.toString().padLeft(2, '0')}:${event.endTime.minute.toString().padLeft(2, '0')}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
          fontSize: 14,
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}
