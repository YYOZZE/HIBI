/// 项目监视器里的一条工作记录。
class WorkLogEntry {
  WorkLogEntry({
    required this.id,
    required this.at,
    required this.kind,
    required this.title,
    this.body = '',
    this.agentId,
    this.agentName,
  });

  final String id;
  final DateTime at;
  /// system / chat / note
  final String kind;
  final String title;
  final String body;
  final String? agentId;
  final String? agentName;

  Map<String, dynamic> toJson() => {
        'id': id,
        'at': at.toIso8601String(),
        'kind': kind,
        'title': title,
        'body': body,
        if (agentId != null) 'agentId': agentId,
        if (agentName != null) 'agentName': agentName,
      };

  static WorkLogEntry fromJson(Map<String, dynamic> json) => WorkLogEntry(
        id: (json['id'] ?? '').toString(),
        at: DateTime.tryParse((json['at'] ?? '').toString()) ?? DateTime.now(),
        kind: (json['kind'] ?? 'system').toString(),
        title: (json['title'] ?? '').toString(),
        body: (json['body'] ?? '').toString(),
        agentId: json['agentId'] as String?,
        agentName: json['agentName'] as String?,
      );
}
