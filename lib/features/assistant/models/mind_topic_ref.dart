/// 思维导图项目话题引用（从白板「助理」入口带入对话）
class MindTopicRef {
  const MindTopicRef({
    required this.projectId,
    required this.projectTitle,
  });

  final String projectId;
  final String projectTitle;

  String get displayLabel {
    final title = projectTitle.trim().isEmpty ? '未命名项目' : projectTitle.trim();
    return '思维导图 · $title';
  }

  /// 拼进用户消息前的寻址说明（模型可读）
  String toPromptPrefix() {
    final title = projectTitle.trim().isEmpty ? '未命名项目' : projectTitle.trim();
    return '【话题引用·思维导图项目】\n'
        'projectId: $projectId\n'
        'projectTitle: $title\n'
        '请针对上述思维导图项目进行操作与回答。\n\n';
  }

  Map<String, dynamic> toJson() => {
        'projectId': projectId,
        'projectTitle': projectTitle,
      };
}
