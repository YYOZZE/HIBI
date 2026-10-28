/// 助理工作台左侧项目。可绑定一块思维导图，绑定关系与导图内容分开保存。
class AssistantProject {
  AssistantProject({
    required this.id,
    required this.title,
    this.mindNodeId,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String title;
  /// 绑定的思维节点 id；空表示尚未创建或已解绑。
  String? mindNodeId;
  final DateTime createdAt;
  DateTime updatedAt;

  bool get isBound => mindNodeId != null && mindNodeId!.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        if (mindNodeId != null) 'mindNodeId': mindNodeId,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  static AssistantProject fromJson(Map<String, dynamic> json) {
    final rawMind = (json['mindNodeId'] as String?)?.trim();
    return AssistantProject(
      id: json['id'] as String,
      title: (json['title'] as String?)?.trim().isNotEmpty == true
          ? (json['title'] as String).trim()
          : '未命名项目',
      mindNodeId: (rawMind == null || rawMind.isEmpty) ? null : rawMind,
      createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()),
      updatedAt: DateTime.tryParse((json['updatedAt'] ?? '').toString()),
    );
  }
}
