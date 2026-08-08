import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../models/chat_attachment.dart';

/// 从相册 / 相机 / 文件选择器收集聊天附件，并做本地文本预抽取
class ChatAttachmentPicker {
  ChatAttachmentPicker({ImagePicker? imagePicker})
      : _imagePicker = imagePicker ?? ImagePicker();

  final ImagePicker _imagePicker;
  static const int maxFileBytes = 8 * 1024 * 1024;
  static const int maxAttachments = 6;

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<List<ChatAttachment>> pickFromGallery() async {
    if (_isMobile) {
      final files = await _imagePicker.pickMultiImage(imageQuality: 85);
      final out = <ChatAttachment>[];
      for (final f in files) {
        final a = await _fromPath(f.path, preferredMime: f.mimeType);
        if (a != null) out.add(a);
      }
      return out;
    }
    return pickDocuments(imagesOnly: true);
  }

  Future<ChatAttachment?> takePhoto() async {
    if (!_isMobile) {
      final list = await pickDocuments(imagesOnly: true);
      return list.isEmpty ? null : list.first;
    }
    final f = await _imagePicker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );
    if (f == null) return null;
    return _fromPath(f.path, preferredMime: f.mimeType ?? 'image/jpeg');
  }

  Future<ChatAttachment?> takeVideo() async {
    if (!_isMobile) {
      final list = await pickDocuments(videosOnly: true);
      return list.isEmpty ? null : list.first;
    }
    final f = await _imagePicker.pickVideo(source: ImageSource.camera);
    if (f == null) return null;
    return _fromPath(f.path, preferredMime: f.mimeType ?? 'video/mp4');
  }

  Future<List<ChatAttachment>> pickDocuments({
    bool imagesOnly = false,
    bool videosOnly = false,
  }) async {
    final exts = imagesOnly
        ? ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp']
        : videosOnly
            ? ['mp4', 'mov', 'mkv', 'webm', 'avi']
            : [
                'pdf',
                'md',
                'markdown',
                'txt',
                'doc',
                'docx',
                'xls',
                'xlsx',
                'csv',
                'jpg',
                'jpeg',
                'png',
                'gif',
                'webp',
                'bmp',
                'mp4',
                'mov',
                'mkv',
                'webm',
              ];
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: !imagesOnly && !videosOnly,
      type: FileType.custom,
      allowedExtensions: exts,
      withData: true,
    );
    if (result == null) return [];
    final out = <ChatAttachment>[];
    for (final f in result.files) {
      final path = f.path;
      Uint8List? bytes = f.bytes;
      if ((bytes == null || bytes.isEmpty) && path != null) {
        try {
          bytes = await File(path).readAsBytes();
        } catch (_) {}
      }
      final a = await _fromBytes(
        name: f.name,
        bytes: bytes,
        path: path,
      );
      if (a != null) out.add(a);
    }
    return out;
  }

  Future<ChatAttachment?> _fromPath(String path, {String? preferredMime}) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return _fromBytes(
        name: path.split(RegExp(r'[/\\]')).last,
        bytes: bytes,
        path: path,
        preferredMime: preferredMime,
      );
    } catch (_) {
      return null;
    }
  }

  Future<ChatAttachment?> _fromBytes({
    required String name,
    required Uint8List? bytes,
    String? path,
    String? preferredMime,
  }) async {
    if (bytes == null || bytes.isEmpty) return null;
    if (bytes.length > maxFileBytes) {
      return ChatAttachment(
        id: _id(),
        name: name,
        mime: preferredMime ?? _guessMime(name),
        kind: ChatAttachmentKind.unsupported,
        path: path,
        previewHint: '文件过大（上限 ${maxFileBytes ~/ (1024 * 1024)}MB），未加入发送',
      );
    }
    final mime = preferredMime ?? _guessMime(name);
    final kind = _classify(name, mime);
    String? text;
    String? hint;
    switch (kind) {
      case ChatAttachmentKind.textDoc:
        text = _decodeText(bytes);
        if (text == null || text.trim().isEmpty) {
          hint = '未能读取文本内容';
        }
        break;
      case ChatAttachmentKind.binaryDoc:
        hint = '文档将交由服务端抽取文本后进入上下文';
        break;
      case ChatAttachmentKind.image:
        break;
      case ChatAttachmentKind.video:
        hint = '视频可附在消息中展示；当前模型暂不解析视频内容';
        break;
      case ChatAttachmentKind.unsupported:
        hint = '暂不支持该类型，不会发送给模型';
        break;
    }
    return ChatAttachment(
      id: _id(),
      name: name,
      mime: mime,
      kind: kind,
      path: path,
      bytes: kind == ChatAttachmentKind.video ||
              kind == ChatAttachmentKind.unsupported
          ? null
          : bytes,
      extractedText: text,
      previewHint: hint,
    );
  }

  static String _id() =>
      'att_${DateTime.now().microsecondsSinceEpoch}_${identityHashCode(Object())}';

  static String _guessMime(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
      return 'text/markdown';
    }
    if (lower.endsWith('.txt')) return 'text/plain';
    if (lower.endsWith('.csv')) return 'text/csv';
    if (lower.endsWith('.doc')) return 'application/msword';
    if (lower.endsWith('.docx')) {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (lower.endsWith('.xls')) return 'application/vnd.ms-excel';
    if (lower.endsWith('.xlsx')) {
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    }
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    return 'application/octet-stream';
  }

  static ChatAttachmentKind _classify(String name, String mime) {
    final lower = name.toLowerCase();
    final m = mime.toLowerCase();
    if (m.startsWith('image/') ||
        lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp')) {
      return ChatAttachmentKind.image;
    }
    if (m.startsWith('video/') ||
        lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.avi')) {
      return ChatAttachmentKind.video;
    }
    if (lower.endsWith('.md') ||
        lower.endsWith('.markdown') ||
        lower.endsWith('.txt') ||
        lower.endsWith('.csv') ||
        m.startsWith('text/')) {
      return ChatAttachmentKind.textDoc;
    }
    if (lower.endsWith('.pdf') ||
        lower.endsWith('.doc') ||
        lower.endsWith('.docx') ||
        lower.endsWith('.xls') ||
        lower.endsWith('.xlsx')) {
      return ChatAttachmentKind.binaryDoc;
    }
    return ChatAttachmentKind.unsupported;
  }

  static String? _decodeText(Uint8List bytes) {
    try {
      return const Utf8Decoder(allowMalformed: true).convert(bytes);
    } catch (_) {
      return null;
    }
  }
}
