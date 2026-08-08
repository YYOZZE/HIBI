/// 智能体模型（可创建多个、自定义名称与职能；内置希比助手除外）
class Agent {
  Agent({
    required this.id,
    required this.name,
    this.role = '',
    DateTime? createdAt,
    this.isAutoCreated = false,
    this.mindNodeId,
    this.isBuiltIn = false,
    this.isPinned = false,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  String name;
  /// 智能体职能/角色描述
  String role;
  final DateTime createdAt;
  /// 是否为白板「助理」入口自动创建的项目助理
  final bool isAutoCreated;
  /// 绑定的思维节点（项目）id，仅 isAutoCreated 时有效
  final String? mindNodeId;
  /// 内置智能体（希比助手）：名称/职能写死，不可改删
  final bool isBuiltIn;
  /// 列表置顶（内置默认标星）
  final bool isPinned;

  bool get canEditName => !isBuiltIn;
  bool get canEditRole => !isBuiltIn;
  bool get canDelete => !isBuiltIn;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'role': role,
        'createdAt': createdAt.toIso8601String(),
        if (isAutoCreated) 'isAutoCreated': true,
        if (mindNodeId != null) 'mindNodeId': mindNodeId,
        if (isBuiltIn) 'isBuiltIn': true,
        if (isPinned) 'isPinned': true,
      };

  static Agent fromJson(Map<String, dynamic> json) => Agent(
        id: json['id'] as String,
        name: json['name'] as String,
        role: json['role'] as String? ?? '',
        createdAt: json['createdAt'] != null
            ? DateTime.tryParse(json['createdAt'] as String)
            : null,
        isAutoCreated: json['isAutoCreated'] == true,
        mindNodeId: json['mindNodeId'] as String?,
        isBuiltIn: json['isBuiltIn'] == true,
        isPinned: json['isPinned'] == true,
      );
}
