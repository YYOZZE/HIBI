/// 单条对话消息（id 用于删除/多选持久化，旧数据无 id 时 fromJson 会补全）
class ChatMessage {
  ChatMessage({
    required this.role,
    required this.content,
    DateTime? timestamp,
    String? id,
  })  : timestamp = timestamp ?? DateTime.now(),
        id = id ?? 'm_${DateTime.now().microsecondsSinceEpoch}_${content.hashCode.abs()}';

  final String id;
  final String role; // 'user' | 'assistant'
  final String content;
  final DateTime timestamp;

  bool get isUser => role == 'user';

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
      };

  static ChatMessage fromJson(Map<String, dynamic> json) {
    final role = json['role'] as String;
    final content = json['content'] as String;
    final ts = json['timestamp'] != null
        ? DateTime.tryParse(json['timestamp'] as String)
        : null;
    // 旧数据无 id：用时间戳+内容生成稳定 id，避免每次启动重新生成导致无法对齐删除
    final id = json['id'] as String? ??
        'legacy_${ts?.millisecondsSinceEpoch ?? 0}_${content.hashCode.abs()}';
    return ChatMessage(
      role: role,
      content: content,
      timestamp: ts,
      id: id,
    );
  }
}
