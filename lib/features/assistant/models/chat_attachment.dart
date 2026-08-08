import 'dart:convert';
import 'dart:typed_data';

/// 对话附件种类
enum ChatAttachmentKind {
  image,
  textDoc,
  binaryDoc,
  video,
  unsupported,
}

/// 待发送的聊天附件（输入区预览 + 发送载荷）
class ChatAttachment {
  ChatAttachment({
    required this.id,
    required this.name,
    required this.mime,
    required this.kind,
    this.path,
    this.bytes,
    this.extractedText,
    this.previewHint,
  });

  final String id;
  final String name;
  final String mime;
  final ChatAttachmentKind kind;
  final String? path;
  final Uint8List? bytes;
  /// 文本类已抽取内容（md/txt 等）；二进制文档可由后端再抽
  final String? extractedText;
  /// UI 提示（如「视频仅上传展示，模型暂不解析」）
  final String? previewHint;

  bool get isImage => kind == ChatAttachmentKind.image;
  bool get isVideo => kind == ChatAttachmentKind.video;
  bool get canSendToModel =>
      kind == ChatAttachmentKind.image ||
      kind == ChatAttachmentKind.textDoc ||
      kind == ChatAttachmentKind.binaryDoc;

  ChatAttachment copyWith({
    String? extractedText,
    String? previewHint,
    Uint8List? bytes,
  }) {
    return ChatAttachment(
      id: id,
      name: name,
      mime: mime,
      kind: kind,
      path: path,
      bytes: bytes ?? this.bytes,
      extractedText: extractedText ?? this.extractedText,
      previewHint: previewHint ?? this.previewHint,
    );
  }

  /// 发给后端 / 直连的 JSON 载荷
  Map<String, dynamic> toApiPayload({int maxBase64Bytes = 4 * 1024 * 1024}) {
    final map = <String, dynamic>{
      'name': name,
      'mime': mime,
      'kind': kind.name,
    };
    final text = extractedText?.trim();
    if (text != null && text.isNotEmpty) {
      map['text'] =
          text.length > 80000 ? '${text.substring(0, 80000)}\n…(已截断)' : text;
    }
    if (bytes != null && bytes!.isNotEmpty && bytes!.length <= maxBase64Bytes) {
      map['data_base64'] = base64Encode(bytes!);
    }
    if (previewHint != null && previewHint!.isNotEmpty) {
      map['note'] = previewHint;
    }
    return map;
  }
}
