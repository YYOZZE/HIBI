import 'dart:convert';
import 'dart:io';

import '../models/chat_message.dart';
import '../models/composer_tool_mode.dart';
import 'generated_content_save_path.dart';

/// 从模型回复中解析并落盘「完整文档」；供写作 / 视频分镜等工具模式使用。
class GeneratedDocumentService {
  GeneratedDocumentService._();

  static const _docStart = '<<<HIBI_DOC';
  static const _docEnd = '<<<END_HIBI_DOC>>>';

  static String systemExtraFor(ComposerToolMode mode) {
    switch (mode) {
      case ComposerToolMode.writeDoc:
        return '''
【文档生成模式】请生成一份结构完整、可直接交付的文档（含标题层级、正文、必要列表/表格）。
输出时必须用以下标记包裹正文（标记行单独成行）：
$_docStart title="文档标题"
（此处为完整 Markdown 正文）
$_docEnd
标记外可写一两句简短说明；正文只放在标记内。''';
      case ComposerToolMode.videoGen:
        return '''
【视频脚本模式】当前按「可保存的分镜脚本文档」交付（含标题、时长建议、分镜表、旁白/字幕、BGM 建议）。
输出时必须用以下标记包裹：
$_docStart title="视频脚本标题"
（完整 Markdown 分镜脚本）
$_docEnd
标记外可写简短说明。''';
      case ComposerToolMode.imageGen:
        return '''
【图像提示词模式】当前对话模型若无文生图接口，请交付「可直接用于文生图」的完整提示词文档。
必须用以下标记包裹：
$_docStart title="图像提示词标题"
（Markdown：含中文提示词、英文 Prompt、负面提示、画幅建议、风格关键词）
$_docEnd
标记外可写一两句说明。''';
      case ComposerToolMode.none:
        return '';
    }
  }

  static String userPrefixFor(ComposerToolMode mode, String userText) {
    final t = userText.trim();
    switch (mode) {
      case ComposerToolMode.writeDoc:
        return '请按文档生成模式，根据以下需求写出完整文档：\n$t';
      case ComposerToolMode.videoGen:
        return '请按视频脚本模式，根据以下需求写出完整分镜脚本：\n$t';
      case ComposerToolMode.imageGen:
        return '请按图像提示词模式，根据以下描述写出完整可复用文生图提示词文档：\n$t';
      case ComposerToolMode.none:
        return t;
    }
  }

  static String _kindSuffix(ComposerToolMode mode) {
    switch (mode) {
      case ComposerToolMode.videoGen:
        return '视频脚本';
      case ComposerToolMode.imageGen:
        return '图像提示';
      case ComposerToolMode.writeDoc:
      case ComposerToolMode.none:
        return '文档';
    }
  }

  /// 解析回复：若含文档标记则落盘并返回附件；显示文本去掉大段正文（保留说明）。
  static Future<({String content, List<ChatMessageAttachment> attachments})>
      materializeFromReply(
    String reply, {
    ComposerToolMode mode = ComposerToolMode.none,
  }) async {
    final parsed = _extractDoc(reply);
    if (parsed == null) {
      // 写作/图像/视频模式下若模型未按标记输出，仍将整段 Markdown 落盘
      if (mode == ComposerToolMode.writeDoc ||
          mode == ComposerToolMode.videoGen ||
          mode == ComposerToolMode.imageGen) {
        final title = _guessTitle(reply, mode);
        final att = await _saveMarkdown(
          title: title,
          body: reply.trim(),
          kindSuffix: _kindSuffix(mode),
        );
        if (att != null) {
          return (
            content: '已生成「${att.name}」，可在下方卡片预览或打开。',
            attachments: [att],
          );
        }
      }
      return (content: reply, attachments: const <ChatMessageAttachment>[]);
    }

    final att = await _saveMarkdown(
      title: parsed.title,
      body: parsed.body,
      kindSuffix: _kindSuffix(mode),
    );
    final note = _stripDocBlock(reply).trim();
    final content = note.isEmpty
        ? '已生成「${parsed.title}」，可在下方卡片预览、打开或另存。'
        : note;
    return (
      content: content,
      attachments: att == null ? const <ChatMessageAttachment>[] : [att],
    );
  }

  static ({String title, String body})? _extractDoc(String reply) {
    final startIdx = reply.indexOf(_docStart);
    final endIdx = reply.indexOf(_docEnd);
    if (startIdx < 0 || endIdx < 0 || endIdx <= startIdx) return null;
    final headerLineEnd = reply.indexOf('\n', startIdx);
    if (headerLineEnd < 0 || headerLineEnd >= endIdx) return null;
    final header = reply.substring(startIdx, headerLineEnd);
    var title = '未命名文档';
    final m = RegExp(r'title\s*=\s*"([^"]+)"').firstMatch(header) ??
        RegExp(r"title\s*=\s*'([^']+)'").firstMatch(header);
    if (m != null && m.group(1)!.trim().isNotEmpty) {
      title = m.group(1)!.trim();
    }
    final body = reply.substring(headerLineEnd + 1, endIdx).trim();
    if (body.isEmpty) return null;
    return (title: title, body: body);
  }

  static String _stripDocBlock(String reply) {
    final startIdx = reply.indexOf(_docStart);
    final endIdx = reply.indexOf(_docEnd);
    if (startIdx < 0 || endIdx < 0 || endIdx <= startIdx) return reply;
    final before = reply.substring(0, startIdx).trim();
    final after = reply.substring(endIdx + _docEnd.length).trim();
    return [before, after].where((s) => s.isNotEmpty).join('\n\n');
  }

  static String _guessTitle(String reply, ComposerToolMode mode) {
    final heading = RegExp(r'^#\s+(.+)$', multiLine: true).firstMatch(reply);
    if (heading != null && heading.group(1)!.trim().isNotEmpty) {
      return heading.group(1)!.trim();
    }
    final first = reply
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .firstWhere((e) => e.isNotEmpty, orElse: () => '');
    if (first.isNotEmpty && first.length <= 40) return first.replaceAll('#', '').trim();
    switch (mode) {
      case ComposerToolMode.videoGen:
        return '视频脚本';
      case ComposerToolMode.imageGen:
        return '图像提示词';
      case ComposerToolMode.writeDoc:
      case ComposerToolMode.none:
        return '生成文档';
    }
  }

  static Future<ChatMessageAttachment?> _saveMarkdown({
    required String title,
    required String body,
    required String kindSuffix,
  }) async {
    try {
      final dir = await GeneratedContentSavePath.getSaveDirectory();
      final safe = _safeFileName(title);
      final stamp = DateTime.now();
      final fileName =
          '${safe}_${stamp.year}${_pad2(stamp.month)}${_pad2(stamp.day)}_'
          '${_pad2(stamp.hour)}${_pad2(stamp.minute)}${_pad2(stamp.second)}.md';
      final file = File('${dir.path}${Platform.pathSeparator}$fileName');
      final header = '# $title\n\n';
      final content =
          body.trimLeft().startsWith('#') ? body.trim() : '$header${body.trim()}\n';
      await file.writeAsString(content, encoding: utf8);
      final preview = _previewSnippet(body);
      return ChatMessageAttachment(
        id: 'gen_${stamp.microsecondsSinceEpoch}',
        name: '$title.md',
        mime: 'text/markdown',
        kind: 'textDoc',
        path: file.path,
        previewText: preview,
        generated: true,
        generatedLabel: kindSuffix,
      );
    } catch (_) {
      return null;
    }
  }

  static String _previewSnippet(String body) {
    final lines = body
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && !e.startsWith('```'))
        .take(8)
        .toList();
    return lines.join('\n');
  }

  static String _safeFileName(String title) {
    var s = title.trim();
    if (s.isEmpty) s = 'document';
    s = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    if (s.length > 48) s = s.substring(0, 48);
    return s;
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');
}
