/// 已发送消息上的附件引用（本地路径可打开；不落盘大图 base64）
class ChatMessageAttachment {
  const ChatMessageAttachment({
    required this.id,
    required this.name,
    required this.mime,
    required this.kind,
    this.path,
    this.previewText,
    this.generated = false,
    this.generatedLabel,
  });

  final String id;
  final String name;
  final String mime;
  /// 与 [ChatAttachmentKind.name] 对齐：image / textDoc / binaryDoc / video / unsupported
  final String kind;
  /// 本地可打开路径（持久化副本或原始选择路径）
  final String? path;
  /// 文档类缩略预览（前几行纯文本）
  final String? previewText;
  /// 是否为智能体生成并落盘的文件
  final bool generated;
  /// 生成物标签，如「文档」「视频脚本」
  final String? generatedLabel;

  bool get isImage => kind == 'image';
  bool get isVideo => kind == 'video';
  bool get isDoc => kind == 'textDoc' || kind == 'binaryDoc';
  bool get canOpen {
    final p = path?.trim() ?? '';
    return p.isNotEmpty;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mime': mime,
        'kind': kind,
        if (path != null && path!.isNotEmpty) 'path': path,
        if (previewText != null && previewText!.trim().isNotEmpty)
          'preview_text': previewText,
        if (generated) 'generated': true,
        if (generatedLabel != null && generatedLabel!.trim().isNotEmpty)
          'generated_label': generatedLabel,
      };

  static ChatMessageAttachment fromJson(Map<String, dynamic> json) {
    return ChatMessageAttachment(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? 'file').toString(),
      mime: (json['mime'] ?? 'application/octet-stream').toString(),
      kind: (json['kind'] ?? 'unsupported').toString(),
      path: (json['path'] as String?)?.trim(),
      previewText: (json['preview_text'] ?? json['previewText'])?.toString(),
      generated: json['generated'] == true,
      generatedLabel:
          (json['generated_label'] ?? json['generatedLabel'])?.toString(),
    );
  }
}

/// 单条对话消息（id 用于删除/多选持久化，旧数据无 id 时 fromJson 会补全）
class ChatMessage {
  ChatMessage({
    required this.role,
    required this.content,
    DateTime? timestamp,
    String? id,
    this.attachments = const [],
    this.topicLabel,
  })  : timestamp = timestamp ?? DateTime.now(),
        id = id ??
            'm_${DateTime.now().microsecondsSinceEpoch}_${content.hashCode.abs()}';

  final String id;
  final String role; // 'user' | 'assistant'
  /// 纯文本正文（新消息不含「[附件 …]」前缀；旧数据可能仍含）
  final String content;
  final DateTime timestamp;
  final List<ChatMessageAttachment> attachments;
  /// 话题引用展示名（可选）
  final String? topicLabel;

  bool get isUser => role == 'user';

  /// 写入 history / 兼容旧 UI 的纯文本（含引用与附件名摘要）
  String get historyContent {
    final buf = StringBuffer();
    final topic = topicLabel?.trim();
    if (topic != null && topic.isNotEmpty) {
      buf.writeln('[引用 $topic]');
    }
    if (attachments.isNotEmpty) {
      buf.writeln(
        '[附件 ${attachments.map((a) => a.name).join('、')}]',
      );
    }
    final text = content.trim();
    if (text.isNotEmpty) {
      if (buf.isNotEmpty) buf.writeln();
      buf.write(text);
    }
    final out = buf.toString().trim();
    return out.isEmpty ? content : out;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
        if (attachments.isNotEmpty)
          'attachments': attachments.map((a) => a.toJson()).toList(),
        if (topicLabel != null && topicLabel!.trim().isNotEmpty)
          'topic_label': topicLabel,
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
    final rawAtt = json['attachments'];
    final atts = <ChatMessageAttachment>[];
    if (rawAtt is List) {
      for (final e in rawAtt) {
        if (e is Map) {
          atts.add(
            ChatMessageAttachment.fromJson(Map<String, dynamic>.from(e)),
          );
        }
      }
    }
    return ChatMessage(
      role: role,
      content: content,
      timestamp: ts,
      id: id,
      attachments: atts,
      topicLabel: (json['topic_label'] ?? json['topicLabel'])?.toString(),
    );
  }
}
