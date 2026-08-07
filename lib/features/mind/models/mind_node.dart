/// 思维节点 = 项目：点击进入无限白板画布
class MindNode {
  MindNode({
    required this.id,
    required this.title,
    this.essence = '',
    this.isStarred = false,
    List<Map<String, dynamic>>? canvasItems,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        canvasItems = canvasItems ?? [];

  final String id;
  String title;
  String essence;
  bool isStarred;
  /// 画布元素（note/column/line）JSON 列表，用于无限白板
  List<Map<String, dynamic>> canvasItems;
  final DateTime createdAt;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'essence': essence,
        'isStarred': isStarred,
        'canvasItems': canvasItems,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  static MindNode fromJson(Map<String, dynamic> json) {
    final list = json['canvasItems'] as List<dynamic>?;
    return MindNode(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      essence: json['essence'] as String? ?? '',
      isStarred: json['isStarred'] as bool? ?? false,
      canvasItems: list?.map((e) => e as Map<String, dynamic>).toList(),
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String)
          : null,
      updatedAt: json['updatedAt'] != null
          ? DateTime.tryParse(json['updatedAt'] as String)
          : null,
    );
  }
}
