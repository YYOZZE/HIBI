/// 画布上的单条元素：笔记、栏目、连线（Milanote 风格）
abstract class CanvasItem {
  const CanvasItem({required this.id});
  final String id;
  String get type;

  Map<String, dynamic> toJson();
  static CanvasItem fromJson(Map<String, dynamic> json) {
    final t = json['type'] as String?;
    if (t == 'note') return CanvasNote.fromJson(json);
    if (t == 'column') return CanvasColumn.fromJson(json);
    if (t == 'block') return CanvasBlock.fromJson(json);
    if (t == 'line') return CanvasLine.fromJson(json);
    throw ArgumentError('unknown type: $t');
  }
}

/// 方块标记圆点颜色：null/空/transparent 为不显示，red/blue/yellow 为对应颜色
String? blockDotColorFromJson(dynamic v) {
  if (v == null) return null;
  final s = v.toString();
  if (s.isEmpty || s == 'transparent') return null;
  if (s == 'red' || s == 'blue' || s == 'yellow') return s;
  return null;
}

/// 方块：白板上的长方形块，可记录文字，可拖动、边缘磁吸对齐；支持标记颜色、提醒、已完成
class CanvasBlock extends CanvasItem {
  CanvasBlock({
    required super.id,
    this.x = 0,
    this.y = 0,
    this.width = 220,
    this.height = 50,
    this.text = '',
    this.dotColor,
    this.reminderStartTimeMs,
    this.reminderEndTimeMs,
    this.completed = false,
  });

  double x;
  double y;
  double width;
  double height;
  String text;
  /// 文字前圆形标记颜色：null 为不显示，'red'/'blue'/'yellow' 为对应颜色
  String? dotColor;
  /// 提醒开始时间（毫秒时间戳），与日程同步；null 表示未设置
  int? reminderStartTimeMs;
  /// 提醒结束时间（毫秒时间戳），与日程同步；null 表示未设置
  int? reminderEndTimeMs;
  /// 已完成：文字变灰并删除线
  bool completed;

  @override
  String get type => 'block';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'x': x,
        'y': y,
        'w': width,
        'h': height,
        'text': text,
        if (dotColor != null && dotColor!.isNotEmpty) 'dotColor': dotColor,
        if (reminderStartTimeMs != null) 'reminderStartTimeMs': reminderStartTimeMs,
        if (reminderEndTimeMs != null) 'reminderEndTimeMs': reminderEndTimeMs,
        'completed': completed,
      };

  static CanvasBlock fromJson(Map<String, dynamic> json) {
    final dot = blockDotColorFromJson(json['dotColor']);
    final startMs = json['reminderStartTimeMs'];
    final endMs = json['reminderEndTimeMs'];
    return CanvasBlock(
      id: json['id'] as String,
      x: (json['x'] as num?)?.toDouble() ?? 0,
      y: (json['y'] as num?)?.toDouble() ?? 0,
      width: (json['w'] as num?)?.toDouble() ?? 220,
      height: (json['h'] as num?)?.toDouble() ?? 50,
      text: json['text'] as String? ?? '',
      dotColor: dot,
      reminderStartTimeMs: startMs is int ? startMs : (startMs as num?)?.toInt(),
      reminderEndTimeMs: endMs is int ? endMs : (endMs as num?)?.toInt(),
      completed: json['completed'] as bool? ?? false,
    );
  }

  CanvasBlock copyWith({
    double? x,
    double? y,
    double? width,
    double? height,
    String? text,
    String? dotColor,
    int? reminderStartTimeMs,
    int? reminderEndTimeMs,
    bool? completed,
  }) {
    return CanvasBlock(
      id: id,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      text: text ?? this.text,
      dotColor: dotColor ?? this.dotColor,
      reminderStartTimeMs: reminderStartTimeMs ?? this.reminderStartTimeMs,
      reminderEndTimeMs: reminderEndTimeMs ?? this.reminderEndTimeMs,
      completed: completed ?? this.completed,
    );
  }
}

/// 笔记卡片：可自由放置，可拖入栏目
class CanvasNote extends CanvasItem {
  CanvasNote({
    required super.id,
    this.x = 0,
    this.y = 0,
    this.width = 200,
    this.height = 80,
    this.text = '',
    this.parentId,
  });

  double x;
  double y;
  double width;
  double height;
  String text;
  /// 若在栏目内则为栏目 id，否则为 null 表示在画布根上
  String? parentId;

  @override
  String get type => 'note';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'x': x,
        'y': y,
        'w': width,
        'h': height,
        'text': text,
        'parentId': parentId,
      };

  static CanvasNote fromJson(Map<String, dynamic> json) => CanvasNote(
        id: json['id'] as String,
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? 0,
        width: (json['w'] as num?)?.toDouble() ?? 200,
        height: (json['h'] as num?)?.toDouble() ?? 80,
        text: json['text'] as String? ?? '',
        parentId: json['parentId'] as String?,
      );

  CanvasNote copyWith({double? x, double? y, double? width, double? height, String? text, String? parentId}) {
    return CanvasNote(
      id: id,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      text: text ?? this.text,
      parentId: parentId ?? this.parentId,
    );
  }
}

/// 栏目（框）：可容纳多个笔记，笔记可长按拖入
class CanvasColumn extends CanvasItem {
  CanvasColumn({
    required super.id,
    this.x = 0,
    this.y = 0,
    this.width = 280,
    this.height = 200,
    this.title = '新栏目',
    List<String>? childIds,
  }) : childIds = childIds ?? [];

  double x;
  double y;
  double width;
  double height;
  String title;
  List<String> childIds;

  @override
  String get type => 'column';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'x': x,
        'y': y,
        'w': width,
        'h': height,
        'title': title,
        'childIds': childIds,
      };

  static CanvasColumn fromJson(Map<String, dynamic> json) {
    final list = json['childIds'] as List<dynamic>?;
    return CanvasColumn(
      id: json['id'] as String,
      x: (json['x'] as num?)?.toDouble() ?? 0,
      y: (json['y'] as num?)?.toDouble() ?? 0,
      width: (json['w'] as num?)?.toDouble() ?? 280,
      height: (json['h'] as num?)?.toDouble() ?? 200,
      title: json['title'] as String? ?? '新栏目',
      childIds: list?.map((e) => e as String).toList() ?? [],
    );
  }
}

/// 连线：连接两个元素，或两端为自由坐标（不挂到方块）
class CanvasLine extends CanvasItem {
  CanvasLine({
    required super.id,
    this.fromId,
    this.toId,
    this.fromX,
    this.fromY,
    this.toX,
    this.toY,
    this.controlX,
    this.controlY,
    this.startArrow = false,
    this.endArrow = true,
    this.isDashed = false,
  });

  /// 起点挂到的元素 id；为 null 时用 fromX, fromY 作为自由端点
  String? fromId;
  /// 终点挂到的元素 id；为 null 时用 toX, toY 作为自由端点
  String? toId;
  double? fromX;
  double? fromY;
  double? toX;
  double? toY;
  double? controlX;
  double? controlY;
  /// 起点是否显示箭头
  bool startArrow;
  /// 终点是否显示箭头
  bool endArrow;
  /// 是否虚线
  bool isDashed;

  @override
  String get type => 'line';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'fromId': fromId,
        'toId': toId,
        'fromX': fromX,
        'fromY': fromY,
        'toX': toX,
        'toY': toY,
        'cx': controlX,
        'cy': controlY,
        'startArrow': startArrow,
        'endArrow': endArrow,
        'isDashed': isDashed,
      };

  static CanvasLine fromJson(Map<String, dynamic> json) => CanvasLine(
        id: json['id'] as String,
        fromId: json['fromId'] as String?,
        toId: json['toId'] as String?,
        fromX: (json['fromX'] as num?)?.toDouble(),
        fromY: (json['fromY'] as num?)?.toDouble(),
        toX: (json['toX'] as num?)?.toDouble(),
        toY: (json['toY'] as num?)?.toDouble(),
        controlX: (json['cx'] as num?)?.toDouble(),
        controlY: (json['cy'] as num?)?.toDouble(),
        startArrow: json['startArrow'] as bool? ?? false,
        endArrow: json['endArrow'] as bool? ?? true,
        isDashed: json['isDashed'] as bool? ?? false,
      );
}
