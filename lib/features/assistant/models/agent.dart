/// 智能体模型（可创建多个、自定义名称与职能）
class Agent {
  Agent({
    required this.id,
    required this.name,
    this.role = '',
    DateTime? createdAt,
    this.isAutoCreated = false,
    this.mindNodeId,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  String name;
  /// 智能体职能/角色描述
  String role;
  final DateTime createdAt;
  /// 是否为白板「助理」入口自动创建的项目助理（列表展示与 mindNodeId 绑定；与是否启用工具无必然关系，登录后任意智能体均可走后端工具链路）
  final bool isAutoCreated;
  /// 绑定的思维节点（项目）id，仅 isAutoCreated 时有效
  final String? mindNodeId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'role': role,
        'createdAt': createdAt.toIso8601String(),
        if (isAutoCreated) 'isAutoCreated': true,
        if (mindNodeId != null) 'mindNodeId': mindNodeId,
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
      );
}
