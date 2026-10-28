/// 某个助理项目下的一间群聊。成员只能是固定编制里的人。
class ProjectGroup {
  ProjectGroup({
    required this.id,
    required this.projectId,
    required this.title,
    required this.purpose,
    required this.memberIds,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String projectId;
  String title;
  String purpose;
  final List<String> memberIds;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'title': title,
        'purpose': purpose,
        'memberIds': memberIds,
        'createdAt': createdAt.toIso8601String(),
      };

  static ProjectGroup fromJson(Map<String, dynamic> json) {
    final raw = json['memberIds'];
    final members = raw is List
        ? raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : <String>[];
    return ProjectGroup(
      id: json['id'] as String,
      projectId: (json['projectId'] ?? '').toString(),
      title: (json['title'] ?? '未命名群聊').toString(),
      purpose: (json['purpose'] ?? '').toString(),
      memberIds: members,
      createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()),
    );
  }
}

class GroupMessage {
  GroupMessage({
    required this.id,
    required this.at,
    required this.speakerId,
    required this.speakerName,
    required this.content,
  });

  final String id;
  final DateTime at;
  final String speakerId;
  final String speakerName;
  final String content;

  bool get isUser => speakerId == 'user';

  Map<String, dynamic> toJson() => {
        'id': id,
        'at': at.toIso8601String(),
        'speakerId': speakerId,
        'speakerName': speakerName,
        'content': content,
      };

  static GroupMessage fromJson(Map<String, dynamic> json) => GroupMessage(
        id: (json['id'] ?? '').toString(),
        at: DateTime.tryParse((json['at'] ?? '').toString()) ?? DateTime.now(),
        speakerId: (json['speakerId'] ?? '').toString(),
        speakerName: (json['speakerName'] ?? '').toString(),
        content: (json['content'] ?? '').toString(),
      );
}
