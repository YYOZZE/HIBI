import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_theme_extension.dart';
import '../../app/frosted_background.dart';
import '../../config/api_config.dart';
import '../auth/github_login_page.dart';
import '../auth/services/auth_repository.dart';
import '../assistant/agent_chat_page.dart';
import '../assistant/services/assistant_api.dart';
import '../assistant/services/assistant_repository.dart';
import '../assistant/services/http_assistant_api.dart';
import '../auth/services/user_sync_scheduler.dart';
import '../profile/payment_service.dart';
import '../profile/subscription_access_service.dart';
import '../profile/value_added_page.dart';
import '../schedule/models/schedule_event.dart';
import '../schedule/schedule_event_store.dart';
import 'models/canvas_item.dart';
import 'models/mind_node.dart';
import 'services/mind_repository.dart';
import 'utils/block_text_format.dart';
import 'widgets/block_content_preview.dart';
import 'widgets/block_format_toolbar.dart';

/// 方块默认单行高度（逻辑像素），多行时按文字自动增高
const double _kBlockMinHeight = 50.0;

/// 方块手动拉伸的宽度范围（逻辑像素）
const double _kBlockMinWidth = 140.0;
const double _kBlockMaxWidth = 900.0;

/// 方块手动拉伸的最大高度
const double _kBlockMaxHeight = 800.0;

/// 画布逻辑尺寸（约 20 倍于原 6000，网格按视口实时绘制）
const double kCanvasWidth = 120000.0;
const double kCanvasHeight = 120000.0;

/// 连线贴边时射线交点在方块内侧的缩进（deflate），使线头/箭头略伸入方块消除可见间隙
const double kLineEdgeInset = 1.5;

/// 射线从矩形内部出发沿 direction 方向与矩形边界的交点（连线贴边用）
Offset _rayExitRect(Rect rect, Offset origin, Offset direction) {
  final ox = origin.dx;
  final oy = origin.dy;
  final dx = direction.dx;
  final dy = direction.dy;
  if (dx == 0 && dy == 0) return origin;
  double? bestT;
  if (dx > 0) {
    final t = (rect.right - ox) / dx;
    final y = oy + t * dy;
    if (t > 0 && rect.top <= y && y <= rect.bottom && (bestT == null || t < bestT)) bestT = t;
  } else if (dx < 0) {
    final t = (rect.left - ox) / dx;
    final y = oy + t * dy;
    if (t > 0 && rect.top <= y && y <= rect.bottom && (bestT == null || t < bestT)) bestT = t;
  }
  if (dy > 0) {
    final t = (rect.bottom - oy) / dy;
    final x = ox + t * dx;
    if (t > 0 && rect.left <= x && x <= rect.right && (bestT == null || t < bestT)) bestT = t;
  } else if (dy < 0) {
    final t = (rect.top - oy) / dy;
    final x = ox + t * dx;
    if (t > 0 && rect.left <= x && x <= rect.right && (bestT == null || t < bestT)) bestT = t;
  }
  if (bestT != null) return Offset(ox + bestT * dx, oy + bestT * dy);
  return origin;
}

/// 方块提醒弹层结果：clear 为 true 表示清除提醒；否则 start/end 为设置的开始/结束时间
class _BlockReminderSheetResult {
  const _BlockReminderSheetResult({this.clear = false, this.start, this.end});
  final bool clear;
  final DateTime? start;
  final DateTime? end;
}

/// 无限白板画布（Milanote 风格）：Note、Column、Line、长按拖入合并
class MindCanvasPage extends StatefulWidget {
  const MindCanvasPage({
    super.key,
    required this.project,
    required this.repository,
    required this.onSaved,
    this.onLoadComplete,
  });

  final MindNode project;
  final MindRepository repository;
  final VoidCallback onSaved;
  /// 背景与元素完成两帧布局后回调，用于关闭加载页
  final VoidCallback? onLoadComplete;

  @override
  State<MindCanvasPage> createState() => _MindCanvasPageState();
}

class _MindCanvasPageState extends State<MindCanvasPage> {
  List<CanvasItem> _items = [];
  Offset _pan = Offset.zero;
  double _scale = 1.0;
  String? _tool; // null = pan, 'note', 'column', 'line', 'trash'
  String? _linkFromId;
  String? _selectedId;
  /// 颜色选择栏展开时等于当前选中方块 id，收起为 null（切换选中方块时重置）
  String? _blockColorPickerExpandedForId;
  /// 选中方块的编辑组件 key：随选中目标切换重建，用于加点/序号等文本格式命令
  GlobalKey<_BlockWidgetState>? _blockEditorKey;
  String? _blockEditorKeyForId;
  String? _draggingNoteId;
  Offset? _dragStartCanvas;
  final Map<String, GlobalKey> _itemKeys = {};
  String? _draggingLineId;
  int? _draggingLinePoint; // 0=start, 1=control, 2=end
  /// 正在手动拉伸的方块 id（拉伸期间暂停按文字自动增高）
  String? _resizingBlockId;
  Offset? _resizeStartCanvas;
  Size? _resizeStartSize;
  /// 仅当连线两端均未接方块时，拖拽线体可整体移动连线
  String? _draggingLineBodyId;
  Offset? _lineBodyDragStartCanvas;
  Offset? _lineDragFromOverride;
  Offset? _lineDragToOverride;
  final GlobalKey _viewportKey = GlobalKey();
  final GlobalKey _leftDeleteKey = GlobalKey();
  final GlobalKey _rightDeleteKey = GlobalKey();
  bool _isPanning = false;
  Offset _panStart = Offset.zero;
  Offset _panStartPan = Offset.zero;
  static const double _minScale = 0.25;
  static const double _maxScale = 3.0;
  static const double _canvasWidth = kCanvasWidth;
  static const double _canvasHeight = kCanvasHeight;
  bool _firstFrameDone = false;
  final Map<int, Offset> _activePointers = {};
  double? _twoFingerScaleStart;
  double? _twoFingerDistStart;
  Offset? _twoFingerPanStart;
  Offset? _twoFingerCenterStart;
  Offset? _singlePointerDownPos;
  /// 拖拽物是否正在视口内（用于网格高亮），由视口层 DragTarget 的 builder 更新
  bool _dragOverCanvas = false;
  /// 最近一次写盘的 Future，返回时 await 避免未落盘就退出导致笔记丢失
  Future<void>? _pendingSave;
  /// 本端最后一次保存时间，用于判断是否应用远端更新（避免覆盖未保存的编辑）
  DateTime? _lastLocalSaveTime;
  /// 画布页定时拉取云端，使手机端能实时看到电脑端操作
  Timer? _realtimePullTimer;
  /// 正在拖拽的方块 id（用于避免拖拽过程中被远端刷新覆盖）
  String? _draggingBlockId;
  /// 方块拖拽时记录“鼠标在方块内按下点”的偏移，确保按下点贴手跟随
  final Map<String, Offset> _blockDragPointerOffset = {};
  /// 最近一次本地交互时间；交互后短暂抑制远端覆盖，减少拖拽跳动
  DateTime? _lastUserInteractionAt;

  late final AssistantRepository _assistantRepo = AssistantRepository();
  late final AssistantApi _assistantApi = ApiConfig.isAssistantApiConfigured
      ? HttpAssistantApi(baseUrl: ApiConfig.assistantApiBaseUrl)
      : PlaceholderAssistantApi();

  /// 白板顶栏：数据服务 / 云端同步与剩余时间展示
  UserEntitlements? _canvasEntitlements;
  bool _canvasEntitlementsBusy = false;

  void _onSyncEpochRefreshEntitlements() {
    _refreshCanvasEntitlements(forceRefresh: false);
  }

  void _onUserChangedRefreshEntitlements() {
    _refreshCanvasEntitlements(forceRefresh: true);
  }

  Future<void> _refreshCanvasEntitlements({bool forceRefresh = false}) async {
    final user = AuthRepository.instance.currentUser;
    if (user == null ||
        user.token.startsWith('mock_') ||
        !ApiConfig.isAuthApiConfigured) {
      if (mounted) {
        setState(() {
          _canvasEntitlements = null;
          _canvasEntitlementsBusy = false;
        });
      }
      return;
    }
    if (mounted) setState(() => _canvasEntitlementsBusy = true);
    final e = await SubscriptionAccessService.fetchEntitlements(
      forceRefresh: forceRefresh,
    );
    if (!mounted) return;
    setState(() {
      _canvasEntitlements = e;
      _canvasEntitlementsBusy = false;
    });
  }

  static String _formatEntitlementSeconds(int? seconds) {
    if (seconds == null || seconds <= 0) return '0天';
    final days = seconds ~/ 86400;
    final hours = (seconds % 86400) ~/ 3600;
    if (days > 0) return '$days天$hours小时';
    final mins = (seconds % 3600) ~/ 60;
    if (hours > 0) return '$hours小时$mins分钟';
    return '$mins分钟';
  }

  static int? _proRemainingSeconds(UserEntitlements e) {
    final v = e.proValidUntil;
    if (v == null) return null;
    final nowSec = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final diff = (v - nowSec).floor();
    if (diff <= 0) return 0;
    return diff;
  }

  static String? _dataServiceRemainingLine(UserEntitlements e) {
    final ds = e.planStates[SubscriptionAccessService.dataServicePlanId];
    if (ds != null) {
      switch (ds.status) {
        case 'active':
        case 'included_by_pro':
          return '剩余 ${_formatEntitlementSeconds(ds.remainingSecondsForDisplay)}';
        case 'grace':
          return '续费宽限 · ${_formatEntitlementSeconds(ds.graceRemainingSeconds)}';
        case 'interrupted':
          return '订阅已中断，同步可能不可用';
        default:
          break;
      }
    }
    if (e.hasPro()) {
      final sec = _proRemainingSeconds(e);
      if (sec != null) {
        return 'PRO 剩余 ${_formatEntitlementSeconds(sec)}';
      }
    }
    return null;
  }

  void _openSubscriptionFromCanvas() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ValueAddedPage()),
    ).then((_) {
      if (mounted) _refreshCanvasEntitlements(forceRefresh: true);
    });
  }

  Widget _buildBottomSyncZoomPill(ThemeData theme) {
    final cs = theme.colorScheme;
    final user = AuthRepository.instance.currentUser;
    final noRealAccount = user == null ||
        user.token.startsWith('mock_') ||
        !ApiConfig.isAuthApiConfigured;

    String statusText;
    String? remainText;
    IconData icon;
    Color accent;
    bool showSubscribeCue = false;

    if (noRealAccount) {
      statusText = '仅本机';
      remainText = '登录后可云同步';
      icon = Icons.storage_outlined;
      accent = cs.outline;
    } else if (_canvasEntitlementsBusy && _canvasEntitlements == null) {
      statusText = '同步状态获取中';
      remainText = null;
      icon = Icons.cloud_queue_outlined;
      accent = cs.outline;
    } else {
      final e = _canvasEntitlements;
      final hasSync = e != null &&
          SubscriptionAccessService.hasPlanInEntitlements(
            e,
            SubscriptionAccessService.dataServicePlanId,
          );
      final ds = e?.planStates[SubscriptionAccessService.dataServicePlanId];
      if (!hasSync) {
        statusText = '未开通云同步';
        remainText = '数据仅本机';
        icon = Icons.cloud_off_outlined;
        accent = cs.tertiary;
        showSubscribeCue = true;
      } else if (ds?.status == 'interrupted') {
        statusText = '云同步异常';
        remainText = _dataServiceRemainingLine(e);
        icon = Icons.cloud_off_outlined;
        accent = cs.error;
        showSubscribeCue = true;
      } else if (ds?.status == 'grace') {
        statusText = '云同步宽限期';
        remainText = _dataServiceRemainingLine(e);
        icon = Icons.cloud_queue_outlined;
        accent = cs.primary;
      } else {
        statusText = '云同步已开启';
        remainText = _dataServiceRemainingLine(e);
        icon = Icons.cloud_done_outlined;
        accent = cs.secondary;
      }
    }

    return Material(
      color: Colors.black.withOpacity(0.3),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: accent),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Text(
                remainText == null ? statusText : '$statusText · $remainText',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: cs.onSurface,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 1,
              height: 14,
              color: cs.outline.withOpacity(0.5),
            ),
            const SizedBox(width: 10),
            Text(
              '${(_scale * 100).round()}%',
              style: theme.textTheme.labelLarge?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (showSubscribeCue)
              TextButton(
                onPressed: _openSubscriptionFromCanvas,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('订阅'),
              ),
          ],
        ),
      ),
    );

  }

  @override
  void initState() {
    super.initState();
    UserSyncScheduler.syncEpoch.addListener(_onSyncEpochRefreshEntitlements);
    AuthRepository.instance.currentUserNotifier
        .addListener(_onUserChangedRefreshEntitlements);
    _refreshCanvasEntitlements(forceRefresh: false);
    ScheduleEventStore.instance.ensureLoaded().then((_) {
      if (!mounted) return;
      setState(() => _loadItems());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _firstFrameDone = true);
      // 第二帧再居中：此时 Listener 已构建，能拿到视口尺寸，避免新建时看到左上角、放方块后点总览方块“消失”
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize) {
          setState(() {
            _pan = Offset(
              box.size.width / 2 - _scale * _canvasWidth / 2,
              box.size.height / 2 - _scale * _canvasHeight / 2,
            );
            _clampPan();
          });
        }
        // 背景与元素两帧布局完成，通知可关闭加载页（无论是否拿到视口尺寸都关闭，避免卡在加载页）
        widget.onLoadComplete?.call();
      });
    });
    // 白板近实时同步：每 500ms 拉取云端，若当前项目有更新则刷新画布
    _realtimePullTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _pullAndRefreshIfNewer());
  }

  @override
  void dispose() {
    UserSyncScheduler.syncEpoch.removeListener(_onSyncEpochRefreshEntitlements);
    AuthRepository.instance.currentUserNotifier
        .removeListener(_onUserChangedRefreshEntitlements);
    _realtimePullTimer?.cancel();
    super.dispose();
  }

  void _markUserInteracting() {
    _lastUserInteractionAt = DateTime.now();
  }

  bool get _hasActiveCanvasInteraction =>
      _draggingBlockId != null ||
      _draggingLineId != null ||
      _draggingLineBodyId != null ||
      _draggingNoteId != null ||
      _isPanning ||
      _activePointers.isNotEmpty;

  /// 拉取云端合并后若当前项目有更新（其他端保存过），则刷新 _items 并 setState
  Future<void> _pullAndRefreshIfNewer() async {
    if (_pendingSave != null) return;
    if (_hasActiveCanvasInteraction) return;
    final lastInteraction = _lastUserInteractionAt;
    if (lastInteraction != null &&
        DateTime.now().difference(lastInteraction) <
            const Duration(milliseconds: 700)) {
      return;
    }
    final now = DateTime.now();
    final pullInterval = (lastInteraction != null &&
            now.difference(lastInteraction) < const Duration(seconds: 6))
        ? const Duration(milliseconds: 500)
        : const Duration(seconds: 2);
    await UserSyncScheduler.pullForCanvasAndNotify(minInterval: pullInterval);
    if (!mounted) return;
    MindNode? freshNode;
    for (final n in widget.repository.nodes) {
      if (n.id == widget.project.id) {
        freshNode = n;
        break;
      }
    }
    if (freshNode == null) return;
    final newItems = freshNode.canvasItems
        .map((e) => CanvasItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final localJson = jsonEncode(_items.map((e) => e.toJson()).toList());
    final remoteJson = jsonEncode(freshNode.canvasItems);
    if (localJson == remoteJson) return;
    if (!mounted) return;
    _lastLocalSaveTime = freshNode.updatedAt;
    widget.project.updatedAt = freshNode.updatedAt;
    widget.project.canvasItems = freshNode.canvasItems;
    setState(() {
      _items = newItems;
      _pullBlockRemindersFromSchedule();
    });
  }

  void _loadItems() {
    _items = widget.project.canvasItems
        .map((e) => CanvasItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    _pullBlockRemindersFromSchedule();
    final changed = _clampAllItemsToCanvas();
    _syncBlockRemindersToSchedule();
    if (changed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _saveItems();
      });
    }
  }

  /// 加载或初始化时将所有元素限制在画布内，避免旧数据导致元素“跑出去”。返回是否有修改。
  bool _clampAllItemsToCanvas() {
    var changed = false;
    for (final item in _items) {
      if (item is CanvasBlock) {
        final c = _clampBlockToCanvas(item.x, item.y, item.width, item.height);
        if (c.dx != item.x || c.dy != item.y) {
          item.x = c.dx;
          item.y = c.dy;
          changed = true;
        }
      } else if (item is CanvasLine) {
        if (item.fromId == null && item.fromX != null && item.fromY != null) {
          final fx = (item.fromX!.clamp(0.0, _canvasWidth));
          final fy = (item.fromY!.clamp(0.0, _canvasHeight));
          if (item.fromX != fx || item.fromY != fy) {
            item.fromX = fx;
            item.fromY = fy;
            changed = true;
          }
        }
        if (item.toId == null && item.toX != null && item.toY != null) {
          final tx = (item.toX!.clamp(0.0, _canvasWidth));
          final ty = (item.toY!.clamp(0.0, _canvasHeight));
          if (item.toX != tx || item.toY != ty) {
            item.toX = tx;
            item.toY = ty;
            changed = true;
          }
        }
        if (item.controlX != null && item.controlY != null) {
          final cx = item.controlX!.clamp(0.0, _canvasWidth);
          final cy = item.controlY!.clamp(0.0, _canvasHeight);
          if (item.controlX != cx || item.controlY != cy) {
            item.controlX = cx;
            item.controlY = cy;
            changed = true;
          }
        }
      }
    }
    return changed;
  }

  /// 串行化保存：先等待上一次写盘完成，再写入当前 _items，避免并发写导致最后一条未落盘
  Future<void> _saveItems() async {
    await (_pendingSave ?? Future.value());
    widget.project.canvasItems = _items.map((e) => e.toJson()).toList();
    widget.project.updatedAt = DateTime.now();
    _lastLocalSaveTime = DateTime.now();
    _syncBlockRemindersToSchedule();
    widget.onSaved();
    final f = widget.repository.update(widget.project);
    _pendingSave = f;
    f.whenComplete(() {
      if (identical(_pendingSave, f)) _pendingSave = null;
    });
  }

  /// 加载画布时从日程存储回填方块提醒时间（在日程页修改后，再打开画布时方块时间与日程一致）
  void _pullBlockRemindersFromSchedule() {
    final store = ScheduleEventStore.instance;
    for (final item in _items) {
      if (item is! CanvasBlock) continue;
      final b = item;
      final eventId = ScheduleEventStore.mindBlockEventId(b.id);
      for (final e in store.events) {
        if (e.id == eventId) {
          b.reminderStartTimeMs = e.startTime.millisecondsSinceEpoch;
          b.reminderEndTimeMs = e.endTime.millisecondsSinceEpoch;
          break;
        }
      }
    }
  }

  /// 将带提醒的方块标题与时间同步到日程存储（保存时更新、加载画布时恢复日程）
  void _syncBlockRemindersToSchedule() {
    final store = ScheduleEventStore.instance;
    for (final item in _items) {
      if (item is! CanvasBlock) continue;
      final b = item;
      if (b.reminderStartTimeMs == null || b.reminderEndTimeMs == null) continue;
      store.addOrUpdate(
        ScheduleEvent(
          id: ScheduleEventStore.mindBlockEventId(b.id),
          title: b.text.isEmpty ? '（无标题）' : b.text,
          startTime: DateTime.fromMillisecondsSinceEpoch(b.reminderStartTimeMs!),
          endTime: DateTime.fromMillisecondsSinceEpoch(b.reminderEndTimeMs!),
        ),
      );
    }
  }

  static String _formatReminderTime(DateTime d) {
    return '${d.month}月${d.day}日 ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Future<_BlockReminderSheetResult?> _showBlockReminderSheet({
    required BuildContext context,
    required DateTime initialStart,
    required DateTime initialEnd,
  }) async {
    DateTime start = initialStart;
    DateTime end = initialEnd;
    if (end.isBefore(start)) end = start.add(const Duration(hours: 1));
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return showModalBottomSheet<_BlockReminderSheetResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: colorScheme.surface,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> pickStart() async {
              final date = await showDatePicker(
                context: ctx,
                initialDate: start,
                firstDate: DateTime(2020),
                lastDate: DateTime(2030),
              );
              if (date == null) return;
              final time = await showTimePicker(
                context: ctx,
                initialTime: TimeOfDay.fromDateTime(start),
              );
              if (time != null) {
                setSheetState(() {
                  start = DateTime(date.year, date.month, date.day, time.hour, time.minute);
                  if (end.isBefore(start)) end = start.add(const Duration(hours: 1));
                });
              }
            }
            Future<void> pickEnd() async {
              final date = await showDatePicker(
                context: ctx,
                initialDate: end.isBefore(start) ? start : end,
                firstDate: start,
                lastDate: DateTime(2030),
              );
              if (date == null) return;
              final time = await showTimePicker(
                context: ctx,
                initialTime: TimeOfDay.fromDateTime(end.isBefore(start) ? start.add(const Duration(hours: 1)) : end),
              );
              if (time != null) {
                setSheetState(() {
                  end = DateTime(date.year, date.month, date.day, time.hour, time.minute);
                });
              }
            }
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        '提醒时间',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                    Card(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: [
                          ListTile(
                            leading: Icon(Icons.access_time, color: colorScheme.onSurfaceVariant),
                            title: const Text('开始'),
                            subtitle: Text(
                              _formatReminderTime(start),
                              style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                            ),
                            trailing: Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
                            onTap: pickStart,
                          ),
                          ListTile(
                            leading: const SizedBox(width: 24, height: 24),
                            title: const Text('结束'),
                            subtitle: Text(
                              _formatReminderTime(end),
                              style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                            ),
                            trailing: Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
                            onTap: pickEnd,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, _BlockReminderSheetResult(clear: true)),
                            child: const Text('清除提醒'),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('取消'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, _BlockReminderSheetResult(start: start, end: end)),
                            child: const Text('确定'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Offset _screenToCanvas(Offset screen) {
    return Offset(
      (screen.dx - _pan.dx) / _scale,
      (screen.dy - _pan.dy) / _scale,
    );
  }

  Offset _canvasToScreen(Offset canvas) {
    return Offset(
      canvas.dx * _scale + _pan.dx,
      canvas.dy * _scale + _pan.dy,
    );
  }

  String _newId() => 'c_${DateTime.now().millisecondsSinceEpoch}';

  void _addBlockAt(Offset canvasPos) {
    const w = 220.0;
    final clamped = _clampBlockToCanvas(
      canvasPos.dx - w / 2,
      canvasPos.dy - _kBlockMinHeight / 2,
      w,
      _kBlockMinHeight,
    );
    setState(() {
      _items.add(CanvasBlock(
        id: _newId(),
        x: clamped.dx,
        y: clamped.dy,
        width: w,
        height: _kBlockMinHeight,
        text: '',
      ));
      _tool = null;
      _saveItems();
    });
  }

  void _moveBlockTo(String blockId, Offset canvasPos) {
    CanvasBlock? block;
    for (final item in _items) {
      if (item is CanvasBlock && item.id == blockId) {
        block = item;
        break;
      }
    }
    if (block == null) return;
    final proposedX = canvasPos.dx - block!.width / 2;
    final proposedY = canvasPos.dy - block.height / 2;
    final snapped = _snapBlockToOthers(blockId, proposedX, proposedY);
    final clamped = _clampBlockToCanvas(snapped.dx, snapped.dy, block.width, block.height);
    setState(() {
      block!.x = clamped.dx;
      block!.y = clamped.dy;
      _saveItems();
    });
  }

  /// 方块吸附后与相邻方块之间的间隙（0 表示贴边无隙）
  static const double _blockSnapGap = 0.0;

  /// 方块与方块不重叠：若有重叠则吸附到最近边，边与边中点对齐并留少量间隙
  Offset _snapBlockToOthers(String movingId, double proposedX, double proposedY) {
    CanvasBlock? block;
    for (final e in _items) {
      if (e is CanvasBlock && e.id == movingId) {
        block = e;
        break;
      }
    }
    if (block == null) return Offset(proposedX, proposedY);
    final w = block.width;
    final h = block.height;
    final proposed = Rect.fromLTWH(proposedX, proposedY, w, h);
    final candidates = <Offset>[];
    for (final item in _items) {
      if (item is! CanvasBlock || item.id == movingId) continue;
      final br = Rect.fromLTWH(item.x, item.y, item.width, item.height);
      if (proposed.intersect(br).isEmpty) continue;
      final bc = br.center;
      candidates.add(Offset(bc.dx - w / 2, br.top - _blockSnapGap - h));
      candidates.add(Offset(bc.dx - w / 2, br.bottom + _blockSnapGap));
      candidates.add(Offset(br.left - _blockSnapGap - w, bc.dy - h / 2));
      candidates.add(Offset(br.right + _blockSnapGap, bc.dy - h / 2));
    }
    Offset best = Offset(proposedX, proposedY);
    double bestDist = double.infinity;
    for (final c in candidates) {
      final r = Rect.fromLTWH(c.dx, c.dy, w, h);
      bool overlaps = false;
      for (final item in _items) {
        if (item is! CanvasBlock || item.id == movingId) continue;
        final br = Rect.fromLTWH(item.x, item.y, item.width, item.height);
        if (!r.intersect(br).isEmpty) {
          overlaps = true;
          break;
        }
      }
      if (overlaps) continue;
      final d = (c.dx - proposedX) * (c.dx - proposedX) + (c.dy - proposedY) * (c.dy - proposedY);
      if (d < bestDist) {
        bestDist = d;
        best = c;
      }
    }
    // 若仍与某块重叠（如多块挤在一起无合适吸附），反复沿重叠较小的轴推开直至无重叠
    Rect bestRect = Rect.fromLTWH(best.dx, best.dy, w, h);
    for (int iter = 0; iter < 20; iter++) {
      bool anyOverlap = false;
      for (final item in _items) {
        if (item is! CanvasBlock || item.id == movingId) continue;
        final br = Rect.fromLTWH(item.x, item.y, item.width, item.height);
        final inter = bestRect.intersect(br);
        if (inter.isEmpty) continue;
        anyOverlap = true;
        double dx = 0, dy = 0;
        if (inter.width <= inter.height) {
          dx = best.dx + w / 2 < br.left + item.width / 2 ? -inter.width : inter.width;
        } else {
          dy = best.dy + h / 2 < br.top + item.height / 2 ? -inter.height : inter.height;
        }
        best = Offset(best.dx + dx, best.dy + dy);
        bestRect = Rect.fromLTWH(best.dx, best.dy, w, h);
      }
      if (!anyOverlap) break;
    }
    // 取整避免亚像素间隙
    return Offset(best.dx.roundToDouble(), best.dy.roundToDouble());
  }

  void _addLine(String fromId, String toId) {
    final fromPos = _getItemCenter(fromId);
    final toPos = _getItemCenter(toId);
    if (fromPos == null || toPos == null) return;
    setState(() {
      _items.add(CanvasLine(
        id: _newId(),
        fromId: fromId,
        toId: toId,
        controlX: null,
        controlY: null,
      ));
      _linkFromId = null;
      _tool = null;
      _saveItems();
    });
  }

  /// 在画布指定位置放置一根连线（仅线，不带方块）；两端为自由端点，可拖拽吸附到方块；默认直线（控制点=两端中点）
  void _addLineAt(Offset canvasPos) {
    const length = 120.0;
    final lineId = _newId();
    final fromX = canvasPos.dx.clamp(0.0, _canvasWidth);
    final fromY = canvasPos.dy.clamp(0.0, _canvasHeight);
    final toX = (canvasPos.dx + length).clamp(0.0, _canvasWidth);
    final toY = canvasPos.dy.clamp(0.0, _canvasHeight);
    setState(() {
      _items.add(CanvasLine(
        id: lineId,
        fromId: null,
        toId: null,
        fromX: fromX,
        fromY: fromY,
        toX: toX,
        toY: toY,
        controlX: null,
        controlY: null,
      ));
      _tool = null;
      _saveItems();
    });
  }

  /// 将连线的控制点重置为两端中点（保持直线）；端点移动/方块移动时调用，绘制时 null 表示用中点
  void _resetLineControlToMidpoint(CanvasLine line) {
    line.controlX = null;
    line.controlY = null;
  }

  /// 方块移动后，仅当连线从未被拖过中点（仍为直线）时才重置控制点为中点；已通过中点改过形状的连线保持曲线
  void _resetConnectedLinesToStraight(String blockId) {
    for (final item in _items) {
      if (item is! CanvasLine || (item.fromId != blockId && item.toId != blockId)) continue;
      if (item.controlX == null && item.controlY == null) _resetLineControlToMidpoint(item);
    }
  }

  Offset _getLineFrom(CanvasLine line) {
    if (line.fromId != null) return _getItemCenter(line.fromId!) ?? Offset.zero;
    return Offset(line.fromX ?? 0, line.fromY ?? 0);
  }

  Offset _getLineTo(CanvasLine line) {
    if (line.toId != null) return _getItemCenter(line.toId!) ?? Offset.zero;
    return Offset(line.toX ?? 0, line.toY ?? 0);
  }

  Rect? _getBlockRect(String? id) {
    if (id == null) return null;
    for (final item in _items) {
      if (item is CanvasBlock && item.id == id) return Rect.fromLTWH(item.x, item.y, item.width, item.height);
    }
    return null;
  }

  void _deleteItem(String id) {
    setState(() {
      _items.removeWhere((e) => e.id == id);
      _items.removeWhere((e) => e is CanvasLine && (e.fromId == id || e.toId == id));
      for (final e in _items.whereType<CanvasColumn>()) e.childIds.remove(id);
      _blockColorPickerExpandedForId = null;
      _selectedId = null;
      _saveItems();
    });
  }

  void _moveNoteIntoColumn(String noteId, String columnId) {
    final note = _items.whereType<CanvasNote>().firstWhere((n) => n.id == noteId);
    final col = _items.whereType<CanvasColumn>().firstWhere((c) => c.id == columnId);
    setState(() {
      note.parentId = columnId;
      note.x = 8;
      note.y = 40 + col.childIds.length * 44;
      col.childIds.add(noteId);
      _draggingNoteId = null;
      _saveItems();
    });
  }

  void _moveNoteOutOfColumn(String noteId) {
    final note = _items.whereType<CanvasNote>().firstWhere((n) => n.id == noteId);
    final col = note.parentId == null ? null : _items.whereType<CanvasColumn>().cast<CanvasColumn?>().firstWhere((c) => c?.id == note.parentId, orElse: () => null);
    setState(() {
      if (col != null) col.childIds.remove(noteId);
      note.parentId = null;
      note.x = 100;
      note.y = 100;
      _draggingNoteId = null;
      _saveItems();
    });
  }

  Rect? _getItemBounds(CanvasItem item) {
    if (item is CanvasNote) return Rect.fromLTWH(item.x, item.y, item.width, item.height);
    if (item is CanvasColumn) return Rect.fromLTWH(item.x, item.y, item.width, item.height);
    return null;
  }

  String? _hitTest(Offset canvasPos) {
    CanvasBlock? hitBlock;
    CanvasColumn? hitColumn;
    CanvasNote? hitNote;
    for (final item in _items.reversed) {
      if (item is CanvasBlock) {
        final r = Rect.fromLTWH(item.x, item.y, item.width, item.height);
        if (r.contains(canvasPos)) hitBlock = item;
      }
      if (item is CanvasColumn) {
        final r = Rect.fromLTWH(item.x, item.y, item.width, item.height);
        if (r.contains(canvasPos)) hitColumn = item;
      }
      if (item is CanvasNote && item.parentId == null) {
        final r = Rect.fromLTWH(item.x, item.y, item.width, item.height);
        if (r.contains(canvasPos)) hitNote = item;
      }
    }
    if (hitBlock != null) return hitBlock.id;
    if (hitColumn != null) return hitColumn.id;
    if (hitNote != null) return hitNote.id;
    return null;
  }

  /// 吸附：取模块边缘/中心最近点
  Offset _snapToModule(Offset canvasPos, String moduleId) {
    for (final item in _items) {
      if (item.id != moduleId) continue;
      if (item is CanvasNote) {
        final cx = item.x + item.width / 2;
        final cy = item.y + item.height / 2;
        return Offset(cx, cy);
      }
      if (item is CanvasColumn) {
        final cx = item.x + item.width / 2;
        final cy = item.y + 24;
        return Offset(cx, cy);
      }
    }
    return canvasPos;
  }

  Offset? _getItemCenter(String id) {
    for (final item in _items) {
      if (item.id != id) continue;
      if (item is CanvasBlock) return Offset(item.x + item.width / 2, item.y + item.height / 2);
      if (item is CanvasNote) return Offset(item.x + item.width / 2, item.y + item.height / 2);
      if (item is CanvasColumn) return Offset(item.x + item.width / 2, item.y + 24);
    }
    return null;
  }

  /// 与绘制一致的连线贴边端点 (from, to)，给定当前 control，用于中点拖拽时让曲线中点跟手
  (Offset from, Offset to) _getLineEdgePointsForControl(CanvasLine line, Offset control) {
    final fromCenter = _getLineFrom(line);
    final toCenter = _getLineTo(line);
    final fromRect = _getBlockRect(line.fromId);
    final toRect = _getBlockRect(line.toId);
    final from = fromRect != null ? _rayExitRect(fromRect.deflate(kLineEdgeInset), fromCenter, control - fromCenter) : fromCenter;
    final to = toRect != null ? _rayExitRect(toRect.deflate(kLineEdgeInset), toCenter, control - toCenter) : toCenter;
    return (from, to);
  }

  /// 连线中点（用于拖拽删除的吸附区域）
  Offset _getLineMidpoint(CanvasLine line) {
    final from = _getLineFrom(line);
    final to = _getLineTo(line);
    final c = line.controlX != null && line.controlY != null
        ? Offset(line.controlX!, line.controlY!)
        : Offset((from.dx + to.dx) / 2, (from.dy + to.dy) / 2);
    return Offset(0.25 * from.dx + 0.5 * c.dx + 0.25 * to.dx, 0.25 * from.dy + 0.5 * c.dy + 0.25 * to.dy);
  }

  static const double _linePointHitRadius = 10.0;
  /// 点击连线线条的命中宽度（不限于三个点）
  static const double _lineStrokeHitRadius = 12.0;

  /// 命中连线整条线体（二次贝塞尔或直线），用于点击任意位置选中连线；采样使用贴边端点
  String? _hitTestLineStroke(Offset canvasPos) {
    for (final item in _items.reversed) {
      if (item is! CanvasLine) continue;
      final line = item;
      final fromCenter = _getLineFrom(line);
      final toCenter = _getLineTo(line);
      final c = line.controlX != null && line.controlY != null
          ? Offset(line.controlX!, line.controlY!)
          : Offset((fromCenter.dx + toCenter.dx) / 2, (fromCenter.dy + toCenter.dy) / 2);
      final fromRect = _getBlockRect(line.fromId);
      final toRect = _getBlockRect(line.toId);
      final from = fromRect != null ? _rayExitRect(fromRect.deflate(kLineEdgeInset), fromCenter, c - fromCenter) : fromCenter;
      final to = toRect != null ? _rayExitRect(toRect.deflate(kLineEdgeInset), toCenter, c - toCenter) : toCenter;
      const int samples = 32;
      for (int i = 0; i <= samples; i++) {
        final t = i / samples;
        final x = (1 - t) * (1 - t) * from.dx + 2 * (1 - t) * t * c.dx + t * t * to.dx;
        final y = (1 - t) * (1 - t) * from.dy + 2 * (1 - t) * t * c.dy + t * t * to.dy;
        final pt = Offset(x, y);
        if ((canvasPos - pt).distance <= _lineStrokeHitRadius) return line.id;
      }
    }
    return null;
  }

  ({String lineId, int point})? _hitTestLinePoint(Offset canvasPos) {
    for (final item in _items.reversed) {
      if (item is! CanvasLine) continue;
      final line = item;
      final fromCenter = _getLineFrom(line);
      final toCenter = _getLineTo(line);
      final c = line.controlX != null && line.controlY != null
          ? Offset(line.controlX!, line.controlY!)
          : Offset((fromCenter.dx + toCenter.dx) / 2, (fromCenter.dy + toCenter.dy) / 2);
      final fromRect = _getBlockRect(line.fromId);
      final toRect = _getBlockRect(line.toId);
      final from = fromRect != null ? _rayExitRect(fromRect.deflate(kLineEdgeInset), fromCenter, c - fromCenter) : fromCenter;
      final to = toRect != null ? _rayExitRect(toRect.deflate(kLineEdgeInset), toCenter, c - toCenter) : toCenter;
      final midOnCurve = Offset(0.25 * from.dx + 0.5 * c.dx + 0.25 * to.dx, 0.25 * from.dy + 0.5 * c.dy + 0.25 * to.dy);
      if ((canvasPos - midOnCurve).distance <= _linePointHitRadius) return (lineId: line.id, point: 1);
      if ((canvasPos - from).distance <= _linePointHitRadius) return (lineId: line.id, point: 0);
      if ((canvasPos - to).distance <= _linePointHitRadius) return (lineId: line.id, point: 2);
    }
    return null;
  }

  Rect _computeContentBounds() {
    Rect? bounds;
    for (final item in _items) {
      if (item is CanvasBlock) {
        final r = Rect.fromLTWH(item.x, item.y, item.width, item.height);
        bounds = bounds == null ? r : bounds.expandToInclude(r);
      }
      if (item is CanvasNote && item.parentId == null) {
        final r = Rect.fromLTWH(item.x, item.y, item.width, item.height);
        bounds = bounds == null ? r : bounds.expandToInclude(r);
      }
      if (item is CanvasColumn) {
        final r = Rect.fromLTWH(item.x, item.y, item.width, item.height);
        bounds = bounds == null ? r : bounds.expandToInclude(r);
      }
      if (item is CanvasLine) {
        final from = _getLineFrom(item);
        final to = _getLineTo(item);
        bounds = bounds == null ? Rect.fromCircle(center: from, radius: 1) : bounds.expandToInclude(Rect.fromCircle(center: from, radius: 1));
        bounds = bounds == null ? Rect.fromCircle(center: to, radius: 1) : bounds.expandToInclude(Rect.fromCircle(center: to, radius: 1));
      }
    }
    return bounds ?? Rect.zero;
  }

  /// 平移限制：使可见区域不超出画布 [0,_canvasWidth]x[0,_canvasHeight]，白板边界与可视区域一致
  void _clampPan() {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final w = box.size.width;
    final h = box.size.height;
    _pan = Offset(
      _pan.dx.clamp(w - _canvasWidth * _scale, 0.0),
      _pan.dy.clamp(h - _canvasHeight * _scale, 0.0),
    );
  }

  /// 将方块位置限制在画布内，避免拖出后无法控制
  Offset _clampBlockToCanvas(double x, double y, double width, double height) {
    return Offset(
      x.clamp(0.0, _canvasWidth - width),
      y.clamp(0.0, _canvasHeight - height),
    );
  }

  /// 选中方块的编辑组件 key（每个选中目标一份，切换方块时重建避免状态串扰）
  GlobalKey<_BlockWidgetState> _editorKeyFor(String blockId) {
    if (_blockEditorKeyForId != blockId || _blockEditorKey == null) {
      _blockEditorKeyForId = blockId;
      _blockEditorKey = GlobalKey<_BlockWidgetState>();
    }
    return _blockEditorKey!;
  }

  /// 加点/序号：编辑态作用于当前行/选中行；预览态对全文逐行生效。
  /// 编辑态以编辑组件的焦点/强制编辑标志为地面真值（isTextEditingActive），
  /// 不依赖页面侧缓存的编辑状态，避免焦点回调漏发导致的路由错乱。
  void _applyBlockLineFormat({required bool numbered}) {
    CanvasBlock? block;
    for (final e in _items) {
      if (e.id == _selectedId && e is CanvasBlock) {
        block = e;
        break;
      }
    }
    if (block == null) return;
    final state = _blockEditorKeyForId == block.id ? _blockEditorKey?.currentState : null;
    if (state != null && state.mounted) {
      if (state.isTextEditingActive) {
        if (numbered) {
          state.applyNumberedToggle();
        } else {
          state.applyBulletToggle();
        }
      } else {
        if (numbered) {
          state.applyNumberedToggleToAll();
        } else {
          state.applyBulletToggleToAll();
        }
      }
      return;
    }
    // 兜底：编辑组件不在树（时序边缘）时直接对模型做全文变换
    final r = numbered
        ? BlockTextFormat.toggleNumbered(block.text, 0, block.text.length)
        : BlockTextFormat.toggleBullet(block.text, 0, block.text.length);
    setState(() {
      block!.text = r.text;
      _saveItems();
    });
  }

  /// 选中方块：仅右下角一个缩放手柄（宽高同调）。
  /// 可视按钮贴在方框角上；周围大热区内按下即拖拽缩放（不触发方块拖动）。
  List<Widget> _buildBlockResizeHandles(CanvasBlock block) {
    // 屏幕约 26px 可视 / 约 112px 热区（随画布缩放换算）
    final grip = 26.0 / _scale;
    final hit = 112.0 / _scale;
    final strokeWidth = 2.0 / _scale;
    final colorScheme = Theme.of(context).colorScheme;
    // 中心落在方框右下角：按钮贴角，不外飘
    final cx = block.x + block.width;
    final cy = block.y + block.height;

    return [
      Positioned(
        left: cx - hit / 2,
        top: cy - hit / 2,
        width: hit,
        height: hit,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeDownRight,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => _onResizeStart(block),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => _onResizeStart(block),
              onPanUpdate: (d) => _onResizeUpdate(block, d),
              onPanEnd: (_) => _onResizeEnd(),
              onPanCancel: _onResizeEnd,
              child: Center(
                child: IgnorePointer(
                  child: CustomPaint(
                    size: Size(grip, grip),
                    painter: _ResizeGripPainter(
                      color: colorScheme.primary,
                      lineColor: colorScheme.onPrimary,
                      strokeWidth: strokeWidth,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  void _onResizeStart(CanvasBlock block) {
    _markUserInteracting();
    _resizingBlockId = block.id;
    _resizeStartSize = Size(block.width, block.height);
    // 以方框右下角为锚点，避免触点偏移造成跳变
    _resizeStartCanvas = Offset(block.x + block.width, block.y + block.height);
  }

  void _onResizeUpdate(CanvasBlock block, DragUpdateDetails d) {
    if (_resizingBlockId != block.id ||
        _resizeStartSize == null ||
        _resizeStartCanvas == null) {
      return;
    }
    _markUserInteracting();
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final canvasPos = _screenToCanvas(box.globalToLocal(d.globalPosition));
    final dx = canvasPos.dx - _resizeStartCanvas!.dx;
    final dy = canvasPos.dy - _resizeStartCanvas!.dy;
    final maxW = math.min(_kBlockMaxWidth, _canvasWidth - block.x);
    final maxH = math.min(_kBlockMaxHeight, _canvasHeight - block.y);
    setState(() {
      block.width =
          (_resizeStartSize!.width + dx).clamp(_kBlockMinWidth, maxW);
      block.height =
          (_resizeStartSize!.height + dy).clamp(_kBlockMinHeight, maxH);
      _resetConnectedLinesToStraight(block.id);
    });
  }

  void _onResizeEnd() {
    if (_resizingBlockId == null) return;
    _markUserInteracting();
    setState(() {
      _resizingBlockId = null;
      _resizeStartCanvas = null;
      _resizeStartSize = null;
    });
    _saveItems();
  }

  /// 总览：缩放 100%，并将聚焦位置移到画布中央
  void _fitOverview() {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      setState(() {
        _scale = 1.0;
        _clampPan();
      });
      return;
    }
    setState(() {
      _scale = 1.0;
      _pan = Offset(
        box.size.width / 2 - _canvasWidth / 2,
        box.size.height / 2 - _canvasHeight / 2,
      );
      _clampPan();
    });
  }

  /// 白板「助理」入口：查找或创建与当前项目同名的自动创建智能体，进入对话
  Future<void> _onAssistantTap() async {
    if (!AuthRepository.instance.canUseAssistant) {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const GitHubLoginPage(),
        ),
      );
      return;
    }
    final agent = await _assistantRepo.findOrCreateAgentForMindNode(
      widget.project.title,
      widget.project.id,
    );
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (ctx) => AgentChatPage(
          agent: agent,
          repository: _assistantRepo,
          api: _assistantApi,
          onAgentUpdated: () {},
          currentMindNodeId: widget.project.id,
        ),
      ),
    );
  }

  /// 判断全局落点是否在画布视口内（用于工具栏 Draggable.onDragEnd，不依赖画布内 DragTarget 命中）
  bool _isDropInViewport(Offset globalOffset) {
    final viewportBox = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) return false;
    final local = viewportBox.globalToLocal(globalOffset);
    return Rect.fromLTWH(0, 0, viewportBox.size.width, viewportBox.size.height).contains(local);
  }

  void _onDropFromTool(String? data, Offset globalOffset, BuildContext targetContext) {
    if (data == null) return;
    _markUserInteracting();
    // 用视口坐标转换，与指针事件一致，保证拖到已有方块上也能正确落点、可无限拖出多个
    final viewportBox = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    final box = viewportBox ?? targetContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    final viewportLocal = box.globalToLocal(globalOffset);
    final canvasPos = viewportBox != null ? _screenToCanvas(viewportLocal) : viewportLocal;
    if (data == 'block') {
      _addBlockAt(canvasPos);
    } else if (data == 'line') {
      _addLineAt(canvasPos);
    } else if (_items.any((e) => e.id == data)) {
      // 画布方块拖拽位置已在 onDragUpdate 实时更新，这里只做一次最终保存，避免松手瞬间再跳位。
      _saveItems();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_firstFrameDone) {
      return Scaffold(
        backgroundColor: const Color(0xFF1a1a2e),
        body: const Center(child: SizedBox.shrink()),
      );
    }
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    CanvasLine? selectedLine;
    CanvasBlock? selectedBlock;
    if (_selectedId != null) {
      for (final e in _items) {
        if (e.id != _selectedId) continue;
        if (e is CanvasLine) {
          selectedLine = e;
          break;
        }
        if (e is CanvasBlock) {
          selectedBlock = e;
          break;
        }
      }
    }

    final themeExt = Theme.of(context).extension<HibiThemeExtension>();
    final useImageBg = themeExt?.useImageBackground ?? true;
    final canvasBackgroundColor = themeExt?.solidBackgroundColor ?? const Color(0xFF1a1a2e);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (didPop) return;
        // 退出前先执行一次保存并等待落盘，避免最后新建的方块未写入
        _saveItems().then((_) => _pendingSave ?? Future.value()).then((_) {
          if (mounted) Navigator.of(context).pop();
        });
      },
      child: Scaffold(
      backgroundColor: canvasBackgroundColor,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 系统栏透明
          Positioned.fill(
            child: AnnotatedRegion<SystemUiOverlayStyle>(
              value: const SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: Brightness.light,
                systemNavigationBarColor: Colors.transparent,
                systemNavigationBarIconBrightness: Brightness.light,
              ),
              child: const SizedBox.expand(),
            ),
          ),
          // 与全局 FrostedBackground 统一：hibi 主题用图+虚化，暗色/亮色主题用纯色
          Positioned.fill(
            child: useImageBg
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.asset(
                        'xhb-image/3.png',
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => ColoredBox(color: canvasBackgroundColor),
                      ),
                      Positioned.fill(
                        child: ClipRect(
                          child: BackdropFilter(
                            filter: ui.ImageFilter.blur(
                              sigmaX: FrostedBackground.blurSigma,
                              sigmaY: FrostedBackground.blurSigma,
                            ),
                            child: Container(
                              color: Colors.black.withOpacity(0.25),
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : ColoredBox(color: canvasBackgroundColor),
          ),
          SafeArea(
            top: true,
            bottom: false,
            left: false,
            right: false,
            child: Stack(
              fit: StackFit.expand,
              children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 12, top: 8, bottom: 8),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: constraints.maxHeight),
                          child: Center(
                            child: Card(
                              color: Colors.transparent,
                              elevation: 0,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                              _ToolButton(
                                icon: Icons.fit_screen,
                                label: '总览',
                                selected: false,
                                onTap: _fitOverview,
                            ),
                            const SizedBox(height: 8),
                            _ToolButton(
                              icon: Icons.smart_toy_outlined,
                              label: '助理',
                              selected: false,
                              onTap: _onAssistantTap,
                            ),
                            const SizedBox(height: 8),
                            Draggable<String>(
                              data: 'block',
                              feedback: Material(
                                elevation: 8,
                                borderRadius: BorderRadius.circular(6),
                                color: Colors.black26,
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.square_outlined, size: 24),
                                      SizedBox(width: 8),
                                      Text('方块'),
                                    ],
                                  ),
                                ),
                              ),
                              onDragEnd: (details) {
                                if (_isDropInViewport(details.offset)) {
                                  _onDropFromTool('block', details.offset, context);
                                }
                              },
                              child: _ToolButton(
                                icon: Icons.square_outlined,
                                label: '方块',
                                selected: false,
                                onTap: () {},
                              ),
                            ),
                            const SizedBox(height: 8),
                            Draggable<String>(
                              data: 'line',
                              feedback: Material(
                                elevation: 8,
                                borderRadius: BorderRadius.circular(6),
                                color: Colors.black26,
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.timeline, size: 24),
                                      SizedBox(width: 8),
                                      Text('连线'),
                                    ],
                                  ),
                                ),
                              ),
                              onDragEnd: (details) {
                                if (_isDropInViewport(details.offset)) {
                                  _onDropFromTool('line', details.offset, context);
                                }
                              },
                              child: _ToolButton(
                                icon: Icons.timeline,
                                label: '连线',
                                selected: _tool == 'line',
                                onTap: () => setState(() { _tool = 'line'; _linkFromId = null; }),
                              ),
                            ),
                            const SizedBox(height: 8),
                            DragTarget<String>(
                              onWillAcceptWithDetails: (d) =>
                                  d.data != null &&
                                  d.data != 'note' &&
                                  d.data != 'column' &&
                                  d.data != 'block' &&
                                  d.data != 'line' &&
                                  _items.any((e) => e.id == d.data),
                              onAcceptWithDetails: (d) => _deleteItem(d.data!),
                              builder: (context, candidates, rejects) => KeyedSubtree(
                                key: _leftDeleteKey,
                                child: _ToolButton(
                                  icon: Icons.delete_outline,
                                  label: '删除',
                                  selected: _tool == 'trash' || candidates.isNotEmpty,
                                  color: candidates.isNotEmpty ? colorScheme.error : colorScheme.error,
                                  onTap: () => setState(() { _tool = 'trash'; _linkFromId = null; }),
                                ),
                              ),
                            ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
                  },
                ),
                ),  // 左工具栏 Padding
                // 白板区域：画布在上层（先命中方块/连线/平移），视口 DragTarget 在下层仅接住工具栏拖入
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned.fill(
                        child: DragTarget<String>(
                          hitTestBehavior: HitTestBehavior.translucent,
                          onWillAcceptWithDetails: (d) {
                            if (d.data == null || d.data == 'note' || d.data == 'column') return false;
                            // 工具栏拖出的 'block'/'line' 仅由 Draggable.onDragEnd 接住，避免与 DragTarget 双路重复添加
                            if (d.data == 'block' || d.data == 'line') return false;
                            return _items.any((e) => e.id == d.data);
                          },
                          onAcceptWithDetails: (d) => _onDropFromTool(d.data, d.offset, context),
                          builder: (context, candidates, rejects) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) setState(() => _dragOverCanvas = candidates.isNotEmpty);
                            });
                            return const SizedBox.expand();
                          },
                        ),
                      ),
                      Listener(
                        key: _viewportKey,
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: (e) {
                      _markUserInteracting();
                      _activePointers[e.pointer] = e.localPosition;
                      if (_activePointers.length == 1) _singlePointerDownPos = e.localPosition;
                      if (_activePointers.length >= 2) {
                        _isPanning = false;
                        final pts = _activePointers.values.toList();
                        _twoFingerCenterStart = Offset(
                          (pts[0].dx + pts[1].dx) / 2,
                          (pts[0].dy + pts[1].dy) / 2,
                        );
                        _twoFingerDistStart = (pts[0] - pts[1]).distance;
                        _twoFingerScaleStart = _scale;
                        _twoFingerPanStart = _pan;
                        return;
                      }
                      final canvasPos = _screenToCanvas(e.localPosition);
                      final lineHit = _hitTestLinePoint(canvasPos);
                      if (lineHit != null) {
                        setState(() {
                          _blockColorPickerExpandedForId = null;
                          _selectedId = lineHit.lineId;
                          _draggingLineId = lineHit.lineId;
                          _draggingLinePoint = lineHit.point;
                          if (lineHit.point == 0) _lineDragFromOverride = canvasPos;
                          if (lineHit.point == 2) _lineDragToOverride = canvasPos;
                        });
                      } else {
                        final lineStrokeHit = _hitTestLineStroke(canvasPos);
                        if (lineStrokeHit != null) {
                          CanvasLine? line;
                          for (final item in _items) {
                            if (item is CanvasLine && item.id == lineStrokeHit) {
                              line = item;
                              break;
                            }
                          }
                          final canDragBody = line != null && line.fromId == null && line.toId == null;
                          setState(() {
                            _blockColorPickerExpandedForId = null;
                            _selectedId = lineStrokeHit;
                            _draggingLineId = null;
                            _draggingLinePoint = null;
                            if (canDragBody) {
                              _draggingLineBodyId = lineStrokeHit;
                              _lineBodyDragStartCanvas = canvasPos;
                            } else {
                              _draggingLineBodyId = null;
                              _lineBodyDragStartCanvas = null;
                            }
                          });
                        } else if (_hitTest(canvasPos) == null) {
                          setState(() {
                            _blockColorPickerExpandedForId = null;
                            _selectedId = null;
                            _isPanning = true;
                            _panStart = e.localPosition;
                            _panStartPan = _pan;
                          });
                        }
                      }
                    },
                    onPointerMove: (e) {
                      _markUserInteracting();
                      _activePointers[e.pointer] = e.localPosition;
                      if (_activePointers.length >= 2 && _twoFingerScaleStart != null && _twoFingerDistStart != null && _twoFingerPanStart != null && _twoFingerCenterStart != null) {
                        final pts = _activePointers.values.toList();
                        final center = Offset((pts[0].dx + pts[1].dx) / 2, (pts[0].dy + pts[1].dy) / 2);
                        final dist = (pts[0] - pts[1]).distance;
                        final scaleFactor = _twoFingerDistStart! > 1 ? dist / _twoFingerDistStart! : 1.0;
                        setState(() {
                          _scale = (_twoFingerScaleStart! * scaleFactor).clamp(_minScale, _maxScale);
                          // 以双指中点为支点缩放：让手势开始时双指中点下的画布点，在缩放后仍停留在当前双指中点下
                          final canvasUnderFingers = (_twoFingerCenterStart! - _twoFingerPanStart!) / _twoFingerScaleStart!;
                          _pan = center - Offset(canvasUnderFingers.dx * _scale, canvasUnderFingers.dy * _scale);
                          _clampPan();
                        });
                        return;
                      }
                      if (_isPanning) {
                        setState(() {
                          _pan = _panStartPan + (e.localPosition - _panStart);
                          _clampPan();
                        });
                        return;
                      }
                      if (_draggingLineBodyId != null) {
                        final canvasPos = _screenToCanvas(e.localPosition);
                        final delta = canvasPos - _lineBodyDragStartCanvas!;
                        CanvasLine? line;
                        for (final item in _items) {
                          if (item is CanvasLine && item.id == _draggingLineBodyId) {
                            line = item;
                            break;
                          }
                        }
                        if (line != null) {
                          final l = line;
                          setState(() {
                            l.fromX = (l.fromX ?? 0) + delta.dx;
                            l.fromY = (l.fromY ?? 0) + delta.dy;
                            l.toX = (l.toX ?? 0) + delta.dx;
                            l.toY = (l.toY ?? 0) + delta.dy;
                            _resetLineControlToMidpoint(l);
                            l.fromX = (l.fromX ?? 0).clamp(0.0, _canvasWidth);
                            l.fromY = (l.fromY ?? 0).clamp(0.0, _canvasHeight);
                            l.toX = (l.toX ?? 0).clamp(0.0, _canvasWidth);
                            l.toY = (l.toY ?? 0).clamp(0.0, _canvasHeight);
                            _lineBodyDragStartCanvas = canvasPos;
                            _saveItems();
                          });
                        }
                        return;
                      }
                      if (_draggingLineId == null || _draggingLinePoint == null) return;
                      final canvasPos = _screenToCanvas(e.localPosition);
                      setState(() {
                        if (_draggingLinePoint == 0) {
                          _lineDragFromOverride = canvasPos;
                        } else if (_draggingLinePoint == 2) {
                          _lineDragToOverride = canvasPos;
                        } else if (_draggingLinePoint == 1) {
                          CanvasLine? line;
                          for (final item in _items) {
                            if (item is CanvasLine && item.id == _draggingLineId) {
                              line = item;
                              break;
                            }
                          }
                          if (line != null) {
                            final c = line.controlX != null && line.controlY != null
                                ? Offset(line.controlX!, line.controlY!)
                                : Offset(
                                    (_getLineFrom(line).dx + _getLineTo(line).dx) / 2,
                                    (_getLineFrom(line).dy + _getLineTo(line).dy) / 2,
                                  );
                            final edge = _getLineEdgePointsForControl(line, c);
                            // 用与绘制相同的贴边端点，使曲线 t=0.5 中点精确落在鼠标位置，跟手
                            line.controlX = (2 * canvasPos.dx - 0.5 * edge.$1.dx - 0.5 * edge.$2.dx).clamp(0.0, _canvasWidth);
                            line.controlY = (2 * canvasPos.dy - 0.5 * edge.$1.dy - 0.5 * edge.$2.dy).clamp(0.0, _canvasHeight);
                            _saveItems();
                          }
                        }
                      });
                    },
                    onPointerUp: (e) {
                      _markUserInteracting();
                      final wasSingleTap = _activePointers.length == 1 &&
                          _singlePointerDownPos != null &&
                          !_isPanning &&
                          _draggingLineId == null &&
                          _draggingLineBodyId == null &&
                          (e.localPosition - _singlePointerDownPos!).distance < 8;
                      final tapCanvasPos = wasSingleTap ? _screenToCanvas(e.localPosition) : null;
                      _activePointers.remove(e.pointer);
                      _singlePointerDownPos = null;
                      if (_activePointers.length < 2) {
                        _twoFingerScaleStart = null;
                        _twoFingerDistStart = null;
                        _twoFingerPanStart = null;
                        _twoFingerCenterStart = null;
                      }
                      if (_isPanning) setState(() => _isPanning = false);
                      if (_draggingLineBodyId != null) {
                        final globalPos = e.position;
                        bool overDelete = false;
                        final leftBox = _leftDeleteKey.currentContext?.findRenderObject() as RenderBox?;
                        if (leftBox != null && leftBox.hasSize) {
                          final local = leftBox.globalToLocal(globalPos);
                          if (Rect.fromLTWH(0, 0, leftBox.size.width, leftBox.size.height).contains(local)) overDelete = true;
                        }
                        if (!overDelete) {
                          final rightBox = _rightDeleteKey.currentContext?.findRenderObject() as RenderBox?;
                          if (rightBox != null && rightBox.hasSize) {
                            final local = rightBox.globalToLocal(globalPos);
                            if (Rect.fromLTWH(0, 0, rightBox.size.width, rightBox.size.height).contains(local)) overDelete = true;
                          }
                        }
                        if (overDelete) {
                          final lineId = _draggingLineBodyId!;
                          setState(() {
                            _blockColorPickerExpandedForId = null;
                            _draggingLineBodyId = null;
                            _lineBodyDragStartCanvas = null;
                            _selectedId = _selectedId == lineId ? null : _selectedId;
                          });
                          _deleteItem(lineId);
                        } else {
                          setState(() {
                            _draggingLineBodyId = null;
                            _lineBodyDragStartCanvas = null;
                          });
                        }
                      }
                      if (wasSingleTap && tapCanvasPos != null) {
                        if (_tool == 'line') {
                          final id = _hitTest(tapCanvasPos);
                          if (id != null) {
                            if (_linkFromId == null) {
                              setState(() => _linkFromId = id);
                            } else if (_linkFromId != id) {
                              _addLine(_linkFromId!, id);
                            }
                          }
                        } else if (_tool == 'trash') {
                          final id = _hitTest(tapCanvasPos);
                          if (id != null) _deleteItem(id);
                        }
                      }
                      if (_draggingLineId != null && _draggingLinePoint != null) {
                        final globalPos = e.position;
                        bool overDelete = false;
                        final leftBox = _leftDeleteKey.currentContext?.findRenderObject() as RenderBox?;
                        if (leftBox != null && leftBox.hasSize) {
                          final local = leftBox.globalToLocal(globalPos);
                          if (Rect.fromLTWH(0, 0, leftBox.size.width, leftBox.size.height).contains(local)) overDelete = true;
                        }
                        if (!overDelete) {
                          final rightBox = _rightDeleteKey.currentContext?.findRenderObject() as RenderBox?;
                          if (rightBox != null && rightBox.hasSize) {
                            final local = rightBox.globalToLocal(globalPos);
                            if (Rect.fromLTWH(0, 0, rightBox.size.width, rightBox.size.height).contains(local)) overDelete = true;
                          }
                        }
                        if (overDelete) {
                          final lineId = _draggingLineId!;
                          setState(() {
                            _blockColorPickerExpandedForId = null;
                            _draggingLineId = null;
                            _draggingLinePoint = null;
                            _lineDragFromOverride = null;
                            _lineDragToOverride = null;
                            _selectedId = _selectedId == lineId ? null : _selectedId;
                          });
                          _deleteItem(lineId);
                          return;
                        }
                        final canvasPos = _screenToCanvas(e.localPosition);
                        CanvasLine? line;
                        for (final item in _items) {
                          if (item is CanvasLine && item.id == _draggingLineId) {
                            line = item;
                            break;
                          }
                        }
                        if (line != null) {
                          if (_draggingLinePoint == 0) {
                            final id = _hitTest(canvasPos);
                            if (id != null) {
                              line.fromId = id;
                              line.fromX = null;
                              line.fromY = null;
                              _resetLineControlToMidpoint(line);
                              _saveItems();
                            } else {
                              line.fromId = null;
                              line.fromX = canvasPos.dx.clamp(0.0, _canvasWidth);
                              line.fromY = canvasPos.dy.clamp(0.0, _canvasHeight);
                              _resetLineControlToMidpoint(line);
                              _saveItems();
                            }
                          } else if (_draggingLinePoint == 2) {
                            final id = _hitTest(canvasPos);
                            if (id != null) {
                              line.toId = id;
                              line.toX = null;
                              line.toY = null;
                              _resetLineControlToMidpoint(line);
                              _saveItems();
                            } else {
                              line.toId = null;
                              line.toX = canvasPos.dx.clamp(0.0, _canvasWidth);
                              line.toY = canvasPos.dy.clamp(0.0, _canvasHeight);
                              _resetLineControlToMidpoint(line);
                              _saveItems();
                            }
                          }
                        }
                        setState(() {
                          _draggingLineId = null;
                          _draggingLinePoint = null;
                          _lineDragFromOverride = null;
                          _lineDragToOverride = null;
                        });
                      }
                    },
                        onPointerSignal: (e) {
                          if (e is PointerScrollEvent) {
                            setState(() {
                              final delta = e.scrollDelta.dy;
                              final newScale = (_scale - delta * 0.001).clamp(_minScale, _maxScale);
                              final anchorCanvas = _screenToCanvas(e.localPosition);
                              _pan = e.localPosition - Offset(anchorCanvas.dx * newScale, anchorCanvas.dy * newScale);
                              _scale = newScale;
                              _clampPan();
                            });
                          }
                        },
                        child: SizedBox.expand(
                          child: ClipRect(
                            child: OverflowBox(
                              minWidth: _canvasWidth,
                              maxWidth: _canvasWidth,
                              minHeight: _canvasHeight,
                              maxHeight: _canvasHeight,
                              alignment: Alignment.topLeft,
                              child: Transform(
                                transform: Matrix4.identity()
                                  ..translate(_pan.dx, _pan.dy)
                                  ..scale(_scale),
                                alignment: Alignment.topLeft,
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    // 画布为 120000×120000，视口尺寸用 _viewportKey 取，用于网格可见区域
                                    // 未布局时用屏幕尺寸作回退，避免 constraints(120000) 导致网格绘制数百万点卡死
                                    final viewportBox = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
                                    final screenSize = MediaQuery.sizeOf(context);
                                    final vw = (viewportBox != null && viewportBox.hasSize)
                                        ? viewportBox.size.width
                                        : screenSize.width;
                                    final vh = (viewportBox != null && viewportBox.hasSize)
                                        ? viewportBox.size.height
                                        : screenSize.height;
                                    final viewRect = Rect.fromLTWH(
                                      -_pan.dx / _scale,
                                      -_pan.dy / _scale,
                                      vw / _scale,
                                      vh / _scale,
                                    ).inflate(800);
                                    final visibleRect = viewRect.intersect(Rect.fromLTWH(0, 0, _canvasWidth, _canvasHeight)) ?? Rect.zero;
                                    return SizedBox(
                                      width: _canvasWidth,
                                      height: _canvasHeight,
                                      child: Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          // 0. 白板：画布尺寸（透明，透出整页背景）
                                          SizedBox(width: _canvasWidth, height: _canvasHeight),
                                          // 1. 网格：按视口可见区域绘制，高亮由 _dragOverCanvas 驱动；亮色主题用深色网格线
                                          Positioned.fill(
                                            child: IgnorePointer(
                                              child: CustomPaint(
                                                painter: _GridPainter(
                                                  color: _dragOverCanvas
                                                      ? colorScheme.primary.withOpacity(theme.brightness == Brightness.light ? 0.38 : 0.32)
                                                      : (theme.brightness == Brightness.light
                                                          ? colorScheme.onSurface.withOpacity(0.22)
                                                          : colorScheme.outline.withOpacity(0.26)),
                                                  visibleRect: visibleRect,
                                                  canvasWidth: _canvasWidth,
                                                  canvasHeight: _canvasHeight,
                                                ),
                                                size: Size(_canvasWidth, _canvasHeight),
                                              ),
                                            ),
                                          ),
                                    // 2. 连线（中间层）：仅绘制不参与命中，三点点拖拽由外层 Listener + _hitTestLinePoint 处理；亮色主题用深色线
                                    ..._items.whereType<CanvasLine>().map((line) => _LineWidget(
                                      line: line,
                                      items: _items,
                                      scale: 1,
                                      selectedLineId: _selectedId,
                                      fromOverride: _draggingLineId == line.id ? _lineDragFromOverride : (line.fromId == null ? Offset(line.fromX ?? 0, line.fromY ?? 0) : null),
                                      toOverride: _draggingLineId == line.id ? _lineDragToOverride : (line.toId == null ? Offset(line.toX ?? 0, line.toY ?? 0) : null),
                                      lineColor: theme.brightness == Brightness.light
                                          ? colorScheme.onSurface.withOpacity(0.88)
                                          : Colors.white.withOpacity(0.92),
                                    )),
                                    // 3. 连线中点可长按拖到删除键删除
                                    ..._items.whereType<CanvasLine>().map((line) {
                                      final mid = _getLineMidpoint(line);
                                      const size = 48.0;
                                      return Positioned(
                                        left: mid.dx - size / 2,
                                        top: mid.dy - size / 2,
                                        width: size,
                                        height: size,
                                        child: LongPressDraggable<String>(
                                          data: line.id,
                                          feedback: Material(
                                            elevation: 8,
                                            borderRadius: BorderRadius.circular(6),
                                            color: Colors.black26,
                                            child: const Padding(
                                              padding: EdgeInsets.all(12),
                                              child: Icon(Icons.timeline, size: 28),
                                            ),
                                          ),
                                          child: const SizedBox.expand(),
                                        ),
                                      );
                                    }),
                                    // 4. 方块（最上）：点击即拖，保证优先命中、即时拖动
                                    ..._items.whereType<CanvasBlock>().map((block) {
                                      Widget blockWidget() => _BlockWidget(
                                        key: _selectedId == block.id ? _editorKeyFor(block.id) : null,
                                        block: block,
                                        selected: _selectedId == block.id,
                                        resizing: _resizingBlockId == block.id,
                                        onTap: () {
                                          if (_tool == 'trash') _deleteItem(block.id);
                                          else if (_tool == 'line' && _linkFromId != null && _linkFromId != block.id) _addLine(_linkFromId!, block.id);
                                          else setState(() {
                                          _selectedId = _selectedId == block.id ? null : block.id;
                                          _blockColorPickerExpandedForId = null;
                                        });
                                        },
                                        onUpdate: (b) {
                                          _markUserInteracting();
                                          final i = _items.indexWhere((e) => e.id == b.id);
                                          if (i >= 0) { _items[i] = b; _saveItems(); setState(() {}); }
                                        },
                                      );
                                      void onDragUpdate(DragUpdateDetails details) {
                                        _markUserInteracting();
                                        final viewportBox = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
                                        if (viewportBox != null && viewportBox.hasSize) {
                                          final local = viewportBox.globalToLocal(details.globalPosition);
                                          final canvasPos = _screenToCanvas(local);
                                          final pointerOffset = _blockDragPointerOffset[block.id] ??
                                              Offset(block.width / 2, block.height / 2);
                                          final raw = _clampBlockToCanvas(
                                            canvasPos.dx - pointerOffset.dx,
                                            canvasPos.dy - pointerOffset.dy,
                                            block.width,
                                            block.height,
                                          );
                                          final snapped = _snapBlockToOthers(block.id, raw.dx, raw.dy);
                                          final snappedClamped = _clampBlockToCanvas(snapped.dx, snapped.dy, block.width, block.height);
                                          setState(() {
                                            block.x = snappedClamped.dx;
                                            block.y = snappedClamped.dy;
                                            _resetConnectedLinesToStraight(block.id);
                                          });
                                        }
                                      }
                                      void onDragEnd(DraggableDetails _) {
                                        _markUserInteracting();
                                        setState(() {});
                                        _draggingBlockId = null;
                                        _blockDragPointerOffset.remove(block.id);
                                        _saveItems();
                                      }
                                      final resizingThis =
                                          _resizingBlockId == block.id;
                                      final draggable = Draggable<String>(
                                        data: block.id,
                                        // 缩放中禁止拖动方块，避免与角手柄抢手势
                                        maxSimultaneousDrags:
                                            (_resizingBlockId != null) ? 0 : 1,
                                        feedback: const SizedBox.shrink(),
                                        dragAnchorStrategy: pointerDragAnchorStrategy,
                                        childWhenDragging: blockWidget(),
                                        onDragStarted: () {
                                          if (_resizingBlockId != null) return;
                                          _markUserInteracting();
                                          _draggingBlockId = block.id;
                                        },
                                        onDragUpdate: resizingThis
                                            ? null
                                            : onDragUpdate,
                                        onDragEnd: onDragEnd,
                                        child: Listener(
                                          behavior: HitTestBehavior.translucent,
                                          onPointerDown: (e) {
                                            if (_resizingBlockId != null) return;
                                            _markUserInteracting();
                                            _blockDragPointerOffset[block.id] =
                                                e.localPosition;
                                          },
                                          child: blockWidget(),
                                        ),
                                      );
                                      return Positioned(
                                        left: block.x,
                                        top: block.y,
                                        width: block.width,
                                        height: block.height,
                                        child: draggable,
                                      );
                                    }),
                                    // 5. 选中方块的右下角缩放手柄（置顶于方块之上，避免与方块拖动冲突）
                                    if (selectedBlock != null)
                                      ..._buildBlockResizeHandles(selectedBlock!),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                    ),  // Listener
                  ],  // canvas Stack children
                ),  // canvas Stack
              ),  // Expanded
              if (selectedLine != null)
                Padding(
                    padding: const EdgeInsets.only(right: 12, top: 8, bottom: 8),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return SingleChildScrollView(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minHeight: constraints.maxHeight),
                            child: Center(
                              child: Card(
                                color: Colors.transparent,
                                elevation: 0,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                              _ToolButton(
                                icon: Icons.arrow_back,
                                label: '左箭头',
                                selected: selectedLine!.startArrow,
                                onTap: () {
                                  setState(() {
                                    selectedLine!.startArrow = !selectedLine!.startArrow;
                                    _saveItems();
                                  });
                                },
                              ),
                              const SizedBox(height: 8),
                              _ToolButton(
                                icon: Icons.grain,
                                label: '虚线',
                                selected: selectedLine!.isDashed,
                                onTap: () {
                                  setState(() {
                                    selectedLine!.isDashed = !selectedLine!.isDashed;
                                    _saveItems();
                                  });
                                },
                              ),
                              const SizedBox(height: 8),
                              _ToolButton(
                                icon: Icons.arrow_forward,
                                label: '右箭头',
                                selected: selectedLine!.endArrow,
                                onTap: () {
                                  setState(() {
                                    selectedLine!.endArrow = !selectedLine!.endArrow;
                                    _saveItems();
                                  });
                                },
                              ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              if (selectedBlock != null)
                Padding(
                  padding: const EdgeInsets.only(right: 12, top: 8, bottom: 8),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: constraints.maxHeight),
                          child: Center(
                            child: Card(
                              color: Colors.transparent,
                              elevation: 0,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                              _BlockColorRow(
                              current: selectedBlock!.dotColor,
                              expanded: _blockColorPickerExpandedForId == selectedBlock!.id,
                              onToggleExpand: () {
                                setState(() {
                                  _blockColorPickerExpandedForId =
                                      _blockColorPickerExpandedForId == selectedBlock!.id ? null : selectedBlock!.id;
                                });
                              },
                              onColorChanged: (v) {
                                setState(() {
                                  selectedBlock!.dotColor = v;
                                  _saveItems();
                                });
                              },
                            ),
                            const SizedBox(height: 8),
                            _ToolButton(
                              icon: Icons.notifications_outlined,
                              label: '提醒',
                              selected: selectedBlock!.reminderStartTimeMs != null,
                              onTap: () async {
                                final block = selectedBlock!;
                                final startMs = block.reminderStartTimeMs;
                                final endMs = block.reminderEndTimeMs;
                                final now = DateTime.now();
                                DateTime start = startMs != null
                                    ? DateTime.fromMillisecondsSinceEpoch(startMs)
                                    : DateTime(now.year, now.month, now.day, 9, 0);
                                DateTime end = endMs != null
                                    ? DateTime.fromMillisecondsSinceEpoch(endMs)
                                    : start.add(const Duration(hours: 1));
                                if (end.isBefore(start) || end.isAtSameMomentAs(start)) {
                                  end = start.add(const Duration(hours: 1));
                                }
                                final result = await _showBlockReminderSheet(
                                  context: context,
                                  initialStart: start,
                                  initialEnd: end,
                                );
                                if (result == null || selectedBlock == null) return;
                                if (result.clear) {
                                  setState(() {
                                    selectedBlock!.reminderStartTimeMs = null;
                                    selectedBlock!.reminderEndTimeMs = null;
                                    _saveItems();
                                    ScheduleEventStore.instance.removeById(
                                      ScheduleEventStore.mindBlockEventId(selectedBlock!.id),
                                    );
                                  });
                                  return;
                                }
                                setState(() {
                                  selectedBlock!.reminderStartTimeMs = result.start!.millisecondsSinceEpoch;
                                  selectedBlock!.reminderEndTimeMs = result.end!.millisecondsSinceEpoch;
                                  _saveItems();
                                  ScheduleEventStore.instance.addOrUpdate(
                                    ScheduleEvent(
                                      id: ScheduleEventStore.mindBlockEventId(selectedBlock!.id),
                                      title: selectedBlock!.text.isEmpty ? '（无标题）' : selectedBlock!.text,
                                      startTime: result.start!,
                                      endTime: result.end!,
                                    ),
                                  );
                                });
                              },
                            ),
                            const SizedBox(height: 8),
                              _ToolButton(
                                icon: Icons.check_circle_outline,
                                label: '已完成',
                                selected: selectedBlock!.completed,
                                onTap: () {
                                  setState(() {
                                    selectedBlock!.completed = !selectedBlock!.completed;
                                    _saveItems();
                                  });
                                },
                              ),
                              const SizedBox(height: 8),
                              _ToolButton(
                                icon: Icons.copy_outlined,
                                label: '复制',
                                selected: false,
                                onTap: () async {
                                  final b = selectedBlock!;
                                  if (b.text.isEmpty) return;
                                  await Clipboard.setData(ClipboardData(text: b.text));
                                  if (!context.mounted) return;
                                  final messenger = ScaffoldMessenger.maybeOf(context);
                                  messenger?.hideCurrentSnackBar();
                                  messenger?.showSnackBar(const SnackBar(
                                    content: Text('方块内容已复制'),
                                    duration: Duration(seconds: 2),
                                  ));
                                },
                              ),
                              const SizedBox(height: 8),
                              // 格式工具组（对齐/字色/标注/加点/序号）：选中方块即显示，不依赖文字编辑态
                              BlockFormatToolbar(
                                block: selectedBlock!,
                                onChanged: () {
                                  setState(() {});
                                  _saveItems();
                                },
                                onApplyLineFormat: (numbered) =>
                                    _applyBlockLineFormat(numbered: numbered),
                              ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            if (_linkFromId != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 48,
                child: IgnorePointer(
                  child: Center(
                    child: Card(
                      color: Colors.transparent,
                      elevation: 0,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Text('点击目标元素完成连线', style: theme.textTheme.bodySmall),
                      ),
                    ),
                  ),
                ),
              ),
            // 屏幕下方中间显示「同步状态 + 订阅剩余 + 缩放比例」
            Positioned(
              left: 0,
              right: 0,
              bottom: 12,
              child: Center(
                child: _buildBottomSyncZoomPill(theme),
              ),
            ),
          ],
            ),
          ),
          // 顶部无栏高：仅浮动返回键与项目名
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              top: true,
              bottom: false,
              left: false,
              right: false,
              child: Padding(
                padding: const EdgeInsets.only(left: 4, right: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () {
                            _saveItems().then((_) => _pendingSave ?? Future.value()).then((_) {
                              if (mounted) Navigator.of(context).pop();
                            });
                          },
                        ),
                        Expanded(
                          child: Text(
                            widget.project.title,
                            style: theme.textTheme.titleLarge,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          ],
        ),
      ),
    );
  }
}

/// 右侧方块栏：默认只显示「颜色」按钮，点击后在旁边展开四色圆点选择栏
class _BlockColorRow extends StatelessWidget {
  const _BlockColorRow({
    required this.current,
    required this.expanded,
    required this.onToggleExpand,
    required this.onColorChanged,
  });

  final String? current;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final ValueChanged<String?> onColorChanged;

  static Color? _dotColorToColor(String? v) {
    if (v == null || v.isEmpty) return null;
    switch (v) {
      case 'red': return Colors.red;
      case 'blue': return Colors.blue;
      case 'yellow': return Colors.amber;
      default: return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    const dotSize = 18.0;
    const gap = 4.0;
    const choices = [null, 'red', 'blue', 'yellow'];

    final colorButton = Material(
      color: expanded ? colorScheme.primary.withOpacity(0.4) : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onToggleExpand,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.circle,
                size: 24,
                color: expanded ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 4),
              Text(
                '颜色',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: expanded ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (!expanded) {
      return colorButton;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: choices.map((value) {
              final isSelected = (value == null && (current == null || current!.isEmpty)) || (value != null && value == current);
              final fillColor = value == null ? null : _dotColorToColor(value);
              return Padding(
                padding: EdgeInsets.only(bottom: value == 'yellow' ? 0 : gap),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => onColorChanged(value),
                    borderRadius: BorderRadius.circular(dotSize / 2),
                    child: Container(
                      width: dotSize,
                      height: dotSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: fillColor,
                        border: value == null
                            ? Border.all(
                                color: isSelected ? colorScheme.primary : colorScheme.outline.withOpacity(0.6),
                                width: isSelected ? 2 : 1.5,
                              )
                            : (isSelected ? Border.all(color: colorScheme.onSurface, width: 2) : null),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          colorButton,
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final c = color ?? colorScheme.primary;
    // 选中态：背景与图标/文字提高对比度，避免看不清
    final selectedBg = selected ? c.withOpacity(0.4) : Colors.transparent;
    final selectedFg = selected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant;

    return Material(
      color: selectedBg,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 24, color: selected ? selectedFg : colorScheme.onSurfaceVariant),
              const SizedBox(height: 4),
              Text(label, style: theme.textTheme.labelSmall?.copyWith(color: selected ? selectedFg : colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 白板点状网格：按可见区域实时绘制，只画视口内及边距内的点，保证大画布下流畅
class _GridPainter extends CustomPainter {
  _GridPainter({required this.color, required this.visibleRect, required this.canvasWidth, required this.canvasHeight});
  final Color color;
  final Rect visibleRect;
  final double canvasWidth;
  final double canvasHeight;

  @override
  void paint(Canvas canvas, Size size) {
    const step = 24.0;
    const dotRadius = 2.0;
    final paint = Paint()..color = color..style = PaintingStyle.fill;
    final left = (visibleRect.left / step).floor() * step;
    final top = (visibleRect.top / step).floor() * step;
    final right = (visibleRect.right / step).ceil() * step;
    final bottom = (visibleRect.bottom / step).ceil() * step;
    for (var x = left; x <= right && x <= canvasWidth; x += step) {
      if (x < 0) continue;
      for (var y = top; y <= bottom && y <= canvasHeight; y += step) {
        if (y < 0) continue;
        canvas.drawCircle(Offset(x, y), dotRadius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.visibleRect != visibleRect || old.color != color;
}

class _LineWidget extends StatelessWidget {
  const _LineWidget({
    required this.line,
    required this.items,
    required this.scale,
    this.selectedLineId,
    this.fromOverride,
    this.toOverride,
    required this.lineColor,
  });

  final CanvasLine line;
  final List<CanvasItem> items;
  final double scale;
  final String? selectedLineId;
  final Offset? fromOverride;
  final Offset? toOverride;
  final Color lineColor;

  Offset _pos(String id) {
    for (final item in items) {
      if (item is CanvasBlock && item.id == id) return Offset(item.x + item.width / 2, item.y + item.height / 2);
      if (item is CanvasNote && item.id == id) return Offset(item.x + item.width / 2, item.y + item.height / 2);
      if (item is CanvasColumn && item.id == id) return Offset(item.x + item.width / 2, item.y + 24);
    }
    return Offset.zero;
  }

  Rect? _blockRect(String? id) {
    if (id == null) return null;
    for (final item in items) {
      if (item is CanvasBlock && item.id == id) return Rect.fromLTWH(item.x, item.y, item.width, item.height);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    var fromCenter = fromOverride ?? (line.fromId != null ? _pos(line.fromId!) : Offset(line.fromX ?? 0, line.fromY ?? 0));
    var toCenter = toOverride ?? (line.toId != null ? _pos(line.toId!) : Offset(line.toX ?? 0, line.toY ?? 0));
    if ((fromCenter - toCenter).distance < 2.0) toCenter = fromCenter + const Offset(360, 0);
    final control = line.controlX != null && line.controlY != null
        ? Offset(line.controlX!, line.controlY!)
        : Offset((fromCenter.dx + toCenter.dx) / 2, (fromCenter.dy + toCenter.dy) / 2);
    final fromRect = fromOverride == null ? _blockRect(line.fromId) : null;
    final toRect = toOverride == null ? _blockRect(line.toId) : null;
    // 贴边：射线交点在方块内侧，线头/箭头略伸入方块边界，消除与圆角边的可见间隙
    final from = fromRect != null
        ? _rayExitRect(fromRect!.deflate(kLineEdgeInset), fromCenter, control - fromCenter)
        : fromCenter;
    final to = toRect != null
        ? _rayExitRect(toRect!.deflate(kLineEdgeInset), toCenter, control - toCenter)
        : toCenter;
    final drawHandles = selectedLineId == line.id;
    return Positioned(
      left: 0,
      top: 0,
      width: kCanvasWidth,
      height: kCanvasHeight,
      child: IgnorePointer(
        child: CustomPaint(
          painter: _LinePainter(
            from: from,
            to: to,
            control: control,
            drawHandles: drawHandles,
            startArrow: line.startArrow,
            endArrow: line.endArrow,
            isDashed: line.isDashed,
            lineColor: lineColor,
          ),
          size: const Size(kCanvasWidth, kCanvasHeight),
        ),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.from,
    required this.to,
    this.control,
    this.drawHandles = false,
    this.startArrow = true,
    this.endArrow = true,
    this.isDashed = false,
    required this.lineColor,
  });

  final Offset from;
  final Offset to;
  final Offset? control;
  final bool drawHandles;
  final bool startArrow;
  final bool endArrow;
  final bool isDashed;
  final Color lineColor;

  /// 箭头与线端留白略短于旧版，视觉更细巧
  static const double _arrowLen = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.35
      ..style = PaintingStyle.stroke;
    final c = control ?? Offset((from.dx + to.dx) / 2, (from.dy + to.dy) / 2);
    // 箭头端：线体在箭头根部结束，避免线头比箭头突出
    Offset pathStart = from;
    Offset pathEnd = to;
    if (startArrow) {
      final d = from - c;
      final len = d.distance;
      if (len > 1) pathStart = from + d * (_arrowLen / len);
    }
    if (endArrow) {
      final d = to - c;
      final len = d.distance;
      if (len > 1) pathEnd = to - d * (_arrowLen / len);
    }
    final path = control != null
        ? (Path()..moveTo(pathStart.dx, pathStart.dy)..quadraticBezierTo(c.dx, c.dy, pathEnd.dx, pathEnd.dy))
        : (Path()..moveTo(pathStart.dx, pathStart.dy)..lineTo(pathEnd.dx, pathEnd.dy));
    if (isDashed) {
      const dashLen = 6.0;
      const gapLen = 3.0;
      for (final metric in path.computeMetrics()) {
        double d = 0;
        while (d < metric.length) {
          final end = (d + dashLen).clamp(0.0, metric.length);
          if (end > d) canvas.drawPath(metric.extractPath(d, end), paint);
          d = end + gapLen;
        }
      }
    } else {
      canvas.drawPath(path, paint);
    }
    if (endArrow) {
      final angle = (to - c).direction;
      _drawArrow(canvas, to, angle, paint);
    }
    if (startArrow) {
      final angle = (from - c).direction;
      _drawArrow(canvas, from, angle, paint);
    }
    if (drawHandles) {
      final handlePaint = Paint()
        ..color = lineColor
        ..style = PaintingStyle.fill;
      final strokePaint = Paint()
        ..color = lineColor.withOpacity(0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      const r = 3.0;
      // 三把手：起点、曲线上 t=0.5 中点、终点；中点必须在连线上
      final midOnCurve = Offset(0.25 * from.dx + 0.5 * c.dx + 0.25 * to.dx, 0.25 * from.dy + 0.5 * c.dy + 0.25 * to.dy);
      for (final pt in [from, midOnCurve, to]) {
        canvas.drawCircle(pt, r, handlePaint);
        canvas.drawCircle(pt, r, strokePaint);
      }
    }
  }

  void _drawArrow(Canvas canvas, Offset tip, double angle, Paint paint) {
    const arrowLen = 8.0;
    const halfAngle = 0.32;
    final a1 = tip + Offset(-arrowLen * math.cos(angle - halfAngle), -arrowLen * math.sin(angle - halfAngle));
    final a2 = tip + Offset(-arrowLen * math.cos(angle + halfAngle), -arrowLen * math.sin(angle + halfAngle));
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(a1.dx, a1.dy)
      ..lineTo(a2.dx, a2.dy)
      ..close();
    final fillPaint = Paint()..color = paint.color..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);
    final strokePaint = Paint()
      ..color = lineColor.withOpacity(0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9;
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) =>
      old.from != from || old.to != to || old.control != control || old.drawHandles != drawHandles ||
      old.startArrow != startArrow || old.endArrow != endArrow || old.isDashed != isDashed || old.lineColor != lineColor;
}

class _BlockWidget extends StatefulWidget {
  const _BlockWidget({
    super.key,
    required this.block,
    required this.selected,
    required this.onTap,
    required this.onUpdate,
    this.resizing = false,
  });

  final CanvasBlock block;
  final bool selected;
  final VoidCallback onTap;
  final void Function(CanvasBlock) onUpdate;
  /// 正在手动拉伸：暂停按内容自动增高，避免与用户拖拽打架
  final bool resizing;

  @override
  State<_BlockWidget> createState() => _BlockWidgetState();
}

class _BlockWidgetState extends State<_BlockWidget> {
  late TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  /// 预览态点击后强制进入编辑（等焦点真正挂上后再恢复）
  bool _forceEdit = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.block.text);
    _focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    // 焦点真正到手后才解除强制编辑态：避免「先恢复预览、焦点尚未挂上」的竞态把方块弹回预览
    if (_focusNode.hasFocus && _forceEdit) _forceEdit = false;
    if (mounted) setState(() {});
    // 失焦回到预览态时，若渲染内容比方块高则自动增高一档
    if (!_focusNode.hasFocus) _growToFitPreview();
  }

  /// 文字编辑是否激活（聚焦或正在进入编辑）：页面据此决定加点/序号作用于当前行还是全文
  bool get isTextEditingActive => _forceEdit || _focusNode.hasFocus;

  /// 预览态进入编辑：先强制切出预览，焦点确认后再恢复标志；两帧内仍未聚焦则回退预览
  void _enterEditMode() {
    if (_focusNode.hasFocus) return;
    if (!_forceEdit) setState(() => _forceEdit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // 兜底：焦点始终未挂上（极端时序）时解除强制标志，避免卡在非预览非编辑的中间态
        if (mounted && !_focusNode.hasFocus && _forceEdit) {
          setState(() => _forceEdit = false);
        }
      });
    });
  }

  /// 编辑态切换无序列表（加点）：对当前行/选中行行首加或去「• 」前缀
  void applyBulletToggle() {
    final sel = _controller.selection;
    if (!sel.isValid) return;
    _applyTransform(BlockTextFormat.toggleBullet, sel.start, sel.end);
  }

  /// 编辑态切换有序列表（序号）：对当前行/选中行加或去递增编号
  void applyNumberedToggle() {
    final sel = _controller.selection;
    if (!sel.isValid) return;
    _applyTransform(BlockTextFormat.toggleNumbered, sel.start, sel.end);
  }

  /// 预览态加点：以模型文本为准，对全文逐行加/去「• 」前缀
  void applyBulletToggleToAll() =>
      _applyWholeTextTransform(BlockTextFormat.toggleBullet);

  /// 预览态序号：以模型文本为准，对全文逐行加/去递增编号
  void applyNumberedToggleToAll() =>
      _applyWholeTextTransform(BlockTextFormat.toggleNumbered);

  void _applyWholeTextTransform(
      TextTransformResult Function(String text, int start, int end) transform) {
    // 预览态下页面可能直接改过 block.text（模型为准），先同步进控制器再变换
    final source = widget.block.text;
    if (_controller.text != source) _controller.text = source;
    _applyTransform(transform, 0, source.length);
  }

  void _applyTransform(
      TextTransformResult Function(String text, int start, int end) transform,
      int start,
      int end) {
    final result = transform(_controller.text, start, end);
    _controller.value = TextEditingValue(
      text: result.text,
      selection: TextSelection(
        baseOffset: result.selectionStart,
        extentOffset: result.selectionEnd,
      ),
    );
    final block = widget.block;
    block.text = result.text;
    final baseTextStyle = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final maxWidth = block.width - 16 - (block.dotColor != null ? 20 : 0);
    _updateBlockHeight(block, result.text, baseTextStyle, maxWidth);
    widget.onUpdate(block);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  static Color? _dotColorToColor(String? dotColor) {
    if (dotColor == null || dotColor.isEmpty) return null;
    switch (dotColor) {
      case 'red': return Colors.red;
      case 'blue': return Colors.blue;
      case 'yellow': return Colors.amber;
      default: return null;
    }
  }

  @override
  void didUpdateWidget(_BlockWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.block.id != widget.block.id || oldWidget.block.text != widget.block.text) {
      _controller.text = widget.block.text;
      _controller.selection = TextSelection.collapsed(offset: widget.block.text.length);
    }
  }

  /// 按当前文字与宽度计算所需高度（至少单行），并写回 block.height；富文本按渲染估算
  void _updateBlockHeight(CanvasBlock block, String text, TextStyle style, double maxWidth) {
    final double contentHeight;
    if (BlockContentPreview.hasRichContent(text)) {
      contentHeight = BlockContentPreview.estimateHeight(text, maxWidth, style);
    } else {
      final painter = TextPainter(
        text: TextSpan(text: text.isEmpty ? ' ' : text, style: style),
        maxLines: null,
        textDirection: TextDirection.ltr,
      );
      painter.layout(maxWidth: maxWidth);
      contentHeight = painter.height;
    }
    const padding = 16.0; // 上下各 8
    final newHeight = (padding + contentHeight).clamp(_kBlockMinHeight, _kBlockMaxHeight);
    if (block.height != newHeight) {
      block.height = newHeight;
      widget.onUpdate(block);
    }
  }

  /// 预览态下若渲染内容比方块高则自动增高（只增不缩，尊重手动拉伸的结果）
  void _growToFitPreview() {
    final block = widget.block;
    if (widget.resizing) return;
    if (!BlockContentPreview.hasRichContent(block.text)) return;
    final baseStyle = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final maxWidth = block.width - 16 - (block.dotColor != null ? 20 : 0);
    final need = BlockContentPreview.estimateHeight(block.text, maxWidth, baseStyle) + 16;
    if (need > block.height + 2 && need <= _kBlockMaxHeight) {
      block.height = need;
      widget.onUpdate(block);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final block = widget.block;
    // 方块背景：轻微毛玻璃（BackdropFilter）+ 半透明底色，透出画布网格
    const blockTint = Color(0xFF2a2a3e);
    // 颜色标注（荧光笔）：低透明度叠加在磨砂底色上，两态（编辑/预览）一致
    final highlightColor = BlockStylePresets.highlightColor(block.highlight);
    final blockBgColor = highlightColor != null
        ? Color.alphaBlend(
            highlightColor.withOpacity(BlockStylePresets.highlightOpacity),
            blockTint.withOpacity(0.42),
          )
        : blockTint.withOpacity(0.42);
    final presetTextColor = BlockStylePresets.textColor(block.textColor);
    final borderAccent = BlockStylePresets.borderAccentColor(
      highlightKey: block.highlight,
      textColorKey: block.textColor,
    );
    final baseTextStyle = theme.textTheme.bodyMedium ?? const TextStyle();
    final textStyle = baseTextStyle.copyWith(
      color: block.completed
          ? colorScheme.onSurface.withOpacity(0.5)
          : (presetTextColor ?? colorScheme.onSurface),
      decoration: block.completed ? TextDecoration.lineThrough : null,
      decorationColor: colorScheme.onSurface.withOpacity(0.5),
    );
    final blockTextAlign = BlockStylePresets.textAlignOf(block.align);
    final dotColor = _dotColorToColor(block.dotColor);
    final contentWidth = block.width - 16 - (dotColor != null ? 20 : 0);
    final showPreview = !_forceEdit &&
        !_focusNode.hasFocus &&
        BlockContentPreview.hasRichContent(block.text);
    if (showPreview) {
      // 预览态内容可能比想象高（代码块有头/边距），按需自动增高
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _growToFitPreview();
      });
    }

    return GestureDetector(
      onTap: widget.onTap,
      child: Material(
        elevation: widget.selected ? 4 : 0,
        shadowColor: Colors.black45,
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: blockBgColor,
                borderRadius: BorderRadius.circular(6),
                // 边框取色：设置了颜色标注/文字颜色时用该颜色（highlight > textColor），
                // 让颜色区分在方块轮廓上一眼可辨；未设置时回退主题 outline 派生色
                // （以主题 outline 为底混入少量 onSurface，亮/暗主题下都清晰可见）
                border: Border.all(
                  color: widget.selected
                      ? (borderAccent ?? colorScheme.primary)
                      : (borderAccent ??
                          Color.alphaBlend(
                            colorScheme.onSurface.withOpacity(0.18),
                            colorScheme.outline,
                          )),
                  width: widget.selected ? 2.5 : 1.5,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: SizedBox(
                  height: block.height - 16,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                if (dotColor != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
                Expanded(
                  child: showPreview
                      ? GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            if (!widget.selected) {
                              widget.onTap(); // 首次点击：选中方块
                              return;
                            }
                            // 已选中再次点击：进入编辑（焦点确认前保持强制编辑态，避免弹回预览）
                            _enterEditMode();
                          },
                          child: SingleChildScrollView(
                            physics: const ClampingScrollPhysics(),
                            child: BlockContentPreview(
                              text: block.text,
                              maxWidth: contentWidth,
                              baseStyle: textStyle,
                              completed: block.completed,
                              textAlign: blockTextAlign,
                            ),
                          ),
                        )
                      : TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    cursorColor: colorScheme.primary,
                    onChanged: (v) {
                      block.text = v;
                      _updateBlockHeight(block, v, textStyle, contentWidth);
                      widget.onUpdate(block);
                    },
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      isDense: true,
                      filled: false,
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      hintText: _focusNode.hasFocus ? null : '记录文字…',
                      hintStyle: TextStyle(color: colorScheme.onSurfaceVariant.withOpacity(0.65)),
                    ),
                    maxLines: null,
                    style: textStyle,
                    textAlign: blockTextAlign,
                    textAlignVertical: TextAlignVertical.center,
                  ),
                ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NoteWidget extends StatefulWidget {
  const _NoteWidget({
    required this.note,
    required this.selected,
    required this.scale,
    required this.onTap,
    required this.onUpdate,
  });

  final CanvasNote note;
  final bool selected;
  final double scale;
  final VoidCallback onTap;
  final void Function(CanvasNote) onUpdate;

  @override
  State<_NoteWidget> createState() => _NoteWidgetState();
}

class _NoteWidgetState extends State<_NoteWidget> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.note.text);
  }

  @override
  void didUpdateWidget(_NoteWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.note.id != widget.note.id || oldWidget.note.text != widget.note.text) {
      _controller.text = widget.note.text;
      _controller.selection = TextSelection.collapsed(offset: widget.note.text.length);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final note = widget.note;

    return Positioned(
      left: note.x,
      top: note.y,
      width: note.width,
      height: note.height,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Card(
          elevation: widget.selected ? 8 : 2,
          color: colorScheme.surfaceContainerHighest.withOpacity(0.9),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: widget.selected ? BorderSide(color: colorScheme.primary, width: 2) : BorderSide.none,
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _controller,
              onChanged: (v) {
                note.text = v;
                widget.onUpdate(note);
              },
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              maxLines: 3,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ),
      ),
    );
  }
}

class _ColumnWidget extends StatelessWidget {
  const _ColumnWidget({
    required this.column,
    required this.notes,
    required this.selected,
    required this.onTap,
    this.highlighted = false,
  });

  final CanvasColumn column;
  final List<CanvasNote> notes;
  final bool selected;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Positioned(
      left: column.x,
      top: column.y,
      width: column.width,
      height: column.height,
      child: GestureDetector(
        onTap: onTap,
        child: Card(
          elevation: selected ? 8 : 2,
          color: colorScheme.surfaceContainerHighest.withOpacity(0.85),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: BorderSide(
              color: highlighted ? colorScheme.primary : (selected ? colorScheme.primary : Colors.transparent),
              width: (highlighted || selected) ? 2 : 0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  column.title,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: notes.length,
                  itemBuilder: (context, index) {
                    final note = notes[index];
                    return Padding(
                      key: ValueKey(note.id),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: colorScheme.surface.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(note.text.isEmpty ? '…' : note.text, style: theme.textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 右下角缩放手柄可视：圆角小方块 + ⌟ 角标。
/// 描边与内部线条用 [lineColor]（通常为主题 onPrimary），
/// 保证 primary 偏暗时在深色画布上仍醒目。
class _ResizeGripPainter extends CustomPainter {
  const _ResizeGripPainter({
    required this.color,
    required this.lineColor,
    required this.strokeWidth,
  });

  final Color color;
  final Color lineColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = color;
    final r = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.width * 0.28),
    );
    canvas.drawRRect(r, bg);

    final ring = Paint()
      ..color = lineColor
      ..strokeWidth = strokeWidth * 0.8
      ..style = PaintingStyle.stroke;
    canvas.drawRRect(r.deflate(strokeWidth * 0.4), ring);

    final line = Paint()
      ..color = lineColor
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final w = size.width;
    final h = size.height;
    final pad = w * 0.26;
    final path = Path()
      ..moveTo(w - pad, pad)
      ..lineTo(w - pad, h - pad)
      ..lineTo(pad, h - pad);
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(_ResizeGripPainter old) =>
      old.color != color ||
      old.lineColor != lineColor ||
      old.strokeWidth != strokeWidth;
}
