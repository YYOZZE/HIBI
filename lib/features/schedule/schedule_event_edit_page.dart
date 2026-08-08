import 'package:flutter/material.dart';

import '../../app/frosted_background.dart';
import '../auth/auth_form_styles.dart';
import 'models/schedule_event.dart';

/// 创建/编辑日程（仿飞书：标题、时间、重复、地点、提醒；不含协作）
/// 视觉与主壳 FrostedBackground + 毛玻璃卡片统一；编辑态提供删除
class ScheduleEventEditPage extends StatefulWidget {
  const ScheduleEventEditPage({
    super.key,
    this.event,
    this.initialDate,
  });

  final ScheduleEvent? event;
  final DateTime? initialDate;

  @override
  State<ScheduleEventEditPage> createState() => _ScheduleEventEditPageState();
}

class _ScheduleEventEditPageState extends State<ScheduleEventEditPage> {
  late final TextEditingController _titleController;
  late DateTime _startTime;
  late DateTime _endTime;
  late bool _isAllDay;
  late ScheduleRecurrence _recurrence;
  DateTime? _recurrenceEndDate;
  final TextEditingController _locationController = TextEditingController();
  final TextEditingController _essenceController = TextEditingController();
  int? _reminderMinutes;

  static const double _sectionRadius = 16;

  @override
  void initState() {
    super.initState();
    if (widget.event != null) {
      final e = widget.event!;
      _titleController = TextEditingController(text: e.title);
      _startTime = e.startTime;
      _endTime = e.endTime;
      _isAllDay = e.isAllDay;
      _recurrence = e.recurrence;
      _recurrenceEndDate = e.recurrenceEndDate;
      _reminderMinutes = e.reminderMinutes;
      _locationController.text = e.location ?? '';
      _essenceController.text = e.essence ?? '';
    } else {
      final base = widget.initialDate ?? DateTime.now();
      _titleController = TextEditingController();
      _startTime = DateTime(base.year, base.month, base.day, 9, 0);
      _endTime = _startTime.add(const Duration(hours: 1));
      _isAllDay = false;
      _recurrence = ScheduleRecurrence.none;
      // 与飞书/常见日历一致：新建日程默认提前 15 分钟提醒（可改为「不提醒」）
      _reminderMinutes = 15;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _essenceController.dispose();
    super.dispose();
  }

  void _save() {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入标题')),
      );
      return;
    }
    if (_endTime.isBefore(_startTime) && !_isAllDay) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('结束时间不能早于开始时间')),
      );
      return;
    }
    final loc = _locationController.text.trim().isEmpty ? null : _locationController.text.trim();
    final ess = _essenceController.text.trim().isEmpty ? null : _essenceController.text.trim();
    final event = widget.event?.copyWith(
          title: title,
          startTime: _startTime,
          endTime: _endTime,
          isAllDay: _isAllDay,
          location: loc,
          recurrence: _recurrence,
          reminderMinutes: _reminderMinutes,
          recurrenceEndDate: _recurrenceEndDate,
          essence: ess,
        ) ??
        ScheduleEvent(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          title: title,
          startTime: _startTime,
          endTime: _endTime,
          isAllDay: _isAllDay,
          location: loc,
          recurrence: _recurrence,
          reminderMinutes: _reminderMinutes,
          recurrenceEndDate: _recurrenceEndDate,
          essence: ess,
        );
    Navigator.of(context).pop(event);
  }

  Future<void> _confirmDelete() async {
    if (widget.event == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerHigh,
        title: const Text('删除日程'),
        content: const Text('确定删除此日程？删除后不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _pickStartTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _startTime,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (date == null) return;
    if (!mounted) return;
    if (_isAllDay) {
      setState(() {
        _startTime = DateTime(date.year, date.month, date.day);
        _endTime = DateTime(date.year, date.month, date.day);
      });
      return;
    }
    if (!mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_startTime),
    );
    if (time != null) {
      setState(() {
        _startTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);
        if (_endTime.isBefore(_startTime)) _endTime = _startTime.add(const Duration(hours: 1));
      });
    }
  }

  Future<void> _pickEndTime() async {
    if (_isAllDay) return;
    final date = await showDatePicker(
      context: context,
      initialDate: _endTime.isBefore(_startTime) ? _startTime : _endTime,
      firstDate: _startTime,
      lastDate: DateTime(2030),
    );
    if (date == null) return;
    if (!mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_endTime.isBefore(_startTime) ? _startTime.add(const Duration(hours: 1)) : _endTime),
    );
    if (time != null) {
      setState(() {
        _endTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);
      });
    }
  }

  String get _recurrenceLabel {
    switch (_recurrence) {
      case ScheduleRecurrence.none:
        return '不重复';
      case ScheduleRecurrence.daily:
        return '每天';
      case ScheduleRecurrence.weekly:
        return '每周';
      case ScheduleRecurrence.monthly:
        return '每月';
    }
  }

  String _formatTime(DateTime d) {
    if (_isAllDay) return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return '${d.month}月${d.day}日 ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  /// 单块毛玻璃区域，替代默认 Card 实底
  Widget _glassSection({required Widget child}) {
    return DecoratedBox(
      decoration: AuthFormStyles.glassPanel(context).copyWith(
        borderRadius: BorderRadius.circular(_sectionRadius),
      ),
      child: Material(
        color: Colors.transparent,
        child: child,
      ),
    );
  }

  InputDecoration _fieldDecoration(String hint) {
    final colorScheme = Theme.of(context).colorScheme;
    return InputDecoration(
      hintText: hint,
      filled: true,
      fillColor: Colors.white.withOpacity(0.04),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      hintStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant.withOpacity(0.6)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colorScheme.outline.withOpacity(0.25)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colorScheme.outline.withOpacity(0.25)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colorScheme.primary.withOpacity(0.7), width: 1.2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isEditing = widget.event != null;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        toolbarHeight: 56,
        title: Row(
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('取消', style: TextStyle(color: colorScheme.onSurface)),
            ),
            Expanded(
              child: Text(
                isEditing ? '编辑日程' : '新建日程',
                textAlign: TextAlign.center,
              ),
            ),
            TextButton(
              onPressed: _save,
              child: Text('保存', style: TextStyle(color: colorScheme.onSurface)),
            ),
          ],
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          Positioned.fill(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                _glassSection(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '标题',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _titleController,
                          decoration: _fieldDecoration('添加标题'),
                          style: theme.textTheme.titleLarge,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _glassSection(
                  child: Column(
                    children: [
                      Theme(
                        data: theme.copyWith(
                          switchTheme: SwitchThemeData(
                            thumbColor: WidgetStateProperty.resolveWith((states) {
                              if (states.contains(WidgetState.selected)) {
                                return colorScheme.primary;
                              }
                              return colorScheme.onSurface;
                            }),
                            trackColor: WidgetStateProperty.resolveWith((states) {
                              if (states.contains(WidgetState.selected)) {
                                return colorScheme.primary.withOpacity(0.5);
                              }
                              return colorScheme.onSurface.withOpacity(0.25);
                            }),
                          ),
                        ),
                        child: SwitchListTile(
                          title: Text(
                            '全天',
                            style: theme.textTheme.titleMedium,
                          ),
                          value: _isAllDay,
                          onChanged: (v) => setState(() => _isAllDay = v),
                        ),
                      ),
                      Divider(height: 1, color: colorScheme.outline.withOpacity(0.2)),
                      ListTile(
                        leading: Icon(Icons.access_time, color: colorScheme.onSurfaceVariant),
                        title: Text(
                          '开始',
                          style: theme.textTheme.titleMedium,
                        ),
                        subtitle: Text(
                          _formatTime(_startTime),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
                        onTap: _pickStartTime,
                      ),
                      ListTile(
                        leading: const SizedBox(width: 24),
                        title: Text(
                          '结束',
                          style: theme.textTheme.titleMedium,
                        ),
                        subtitle: Text(
                          _formatTime(_endTime),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
                        onTap: _isAllDay ? null : _pickEndTime,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _glassSection(
                  child: ListTile(
                    leading: Icon(Icons.repeat, color: colorScheme.onSurfaceVariant),
                    title: Text('重复', style: theme.textTheme.titleMedium),
                    subtitle: Text(
                      _recurrenceLabel,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
                    onTap: () async {
                      final r = await showModalBottomSheet<ScheduleRecurrence>(
                        context: context,
                        backgroundColor: colorScheme.surfaceContainerHigh,
                        builder: (ctx) => SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: ScheduleRecurrence.values
                                .map((r) => ListTile(
                                      title: Text(r == ScheduleRecurrence.none ? '不重复' : r == ScheduleRecurrence.daily ? '每天' : r == ScheduleRecurrence.weekly ? '每周' : '每月'),
                                      onTap: () => Navigator.pop(ctx, r),
                                    ))
                                .toList(),
                          ),
                        ),
                      );
                      if (r != null) setState(() => _recurrence = r);
                    },
                  ),
                ),
                const SizedBox(height: 12),
                _glassSection(
                  child: ListTile(
                    leading: Icon(Icons.location_on_outlined, color: colorScheme.onSurfaceVariant),
                    title: Text('地点', style: theme.textTheme.titleMedium),
                    subtitle: Text(
                      _locationController.text.isEmpty ? '添加地点' : _locationController.text,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
                    onTap: () async {
                      final text = await showDialog<String>(
                        context: context,
                        builder: (ctx) {
                          final c = TextEditingController(text: _locationController.text);
                          return AlertDialog(
                            backgroundColor: colorScheme.surfaceContainerHigh,
                            title: const Text('地点'),
                            content: TextField(
                              controller: c,
                              decoration: const InputDecoration(hintText: '输入地点'),
                              autofocus: true,
                            ),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                              FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('确定')),
                            ],
                          );
                        },
                      );
                      if (text != null) {
                        _locationController.text = text;
                        setState(() {});
                      }
                    },
                  ),
                ),
                const SizedBox(height: 12),
                _glassSection(
                  child: ListTile(
                    leading: Icon(Icons.notifications_outlined, color: colorScheme.onSurfaceVariant),
                    title: Text('提醒', style: theme.textTheme.titleMedium),
                    subtitle: Text(
                      _reminderMinutes == null ? '不提醒' : '提前$_reminderMinutes分钟',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
                    onTap: () async {
                      final choices = [null, 0, 15, 30, 60, 1440];
                      final labels = ['不提醒', '准时', '15分钟', '30分钟', '1小时', '1天'];
                      final i = await showModalBottomSheet<int>(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: colorScheme.surfaceContainerHigh,
                        builder: (ctx) => SafeArea(
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: choices.length,
                            itemBuilder: (ctx, index) {
                              return ListTile(
                                title: Text(labels[index]),
                                onTap: () => Navigator.pop(ctx, index),
                              );
                            },
                          ),
                        ),
                      );
                      if (i != null) setState(() => _reminderMinutes = choices[i]);
                    },
                  ),
                ),
                const SizedBox(height: 12),
                _glassSection(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.lightbulb_outline, size: 20, color: colorScheme.primary),
                            const SizedBox(width: 8),
                            Text(
                              '要义',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _essenceController,
                          maxLines: 5,
                          minLines: 2,
                          decoration: _fieldDecoration('记录要点、要义…'),
                          style: theme.textTheme.bodyLarge?.copyWith(color: colorScheme.onSurface),
                        ),
                      ],
                    ),
                  ),
                ),
                if (isEditing) ...[
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _confirmDelete,
                      icon: Icon(Icons.delete_outline, color: colorScheme.error),
                      label: Text('删除日程', style: TextStyle(color: colorScheme.error)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(color: colorScheme.error.withOpacity(0.6)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_sectionRadius)),
                        backgroundColor: colorScheme.error.withOpacity(0.08),
                      ),
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
