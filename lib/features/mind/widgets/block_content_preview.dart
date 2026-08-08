import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'code_highlighter.dart';

/// 方块富文本预览：未聚焦编辑时以渲染态展示
/// - 基础文档格式：# / ## / ### 标题、- 或 * 列表、- [ ]/- [x] 待办、**加粗**、`行内代码`
/// - ```lang 围栏代码块：深色底 + 等宽 + 基础语法高亮 + 一键复制整段代码
class BlockContentPreview extends StatelessWidget {
  const BlockContentPreview({
    super.key,
    required this.text,
    required this.maxWidth,
    required this.baseStyle,
    required this.completed,
    this.textAlign = TextAlign.start,
  });

  final String text;
  final double maxWidth;
  final TextStyle baseStyle;
  final bool completed;
  /// 整段文字对齐（与编辑态 TextField 的 textAlign 保持一致）
  final TextAlign textAlign;

  // ---------- 富文本侦测 ----------

  static final RegExp _fenceRe = RegExp(r'(^|\n)\s*```');
  static final RegExp _headingRe = RegExp(r'(^|\n)\s{0,3}#{1,3}\s+\S');
  static final RegExp _bulletRe = RegExp(r'(^|\n)\s{0,3}[-*]\s+\S');
  static final RegExp _boldRe = RegExp(r'\*\*[^*\n]+\*\*');
  static final RegExp _inlineCodeRe = RegExp(r'`[^`\n]+`');

  /// 文本是否包含可渲染的富文本内容（代码围栏 / 标题 / 列表 / 加粗 / 行内代码）
  static bool hasRichContent(String text) {
    if (text.isEmpty) return false;
    return _fenceRe.hasMatch(text) ||
        _headingRe.hasMatch(text) ||
        _bulletRe.hasMatch(text) ||
        _boldRe.hasMatch(text) ||
        _inlineCodeRe.hasMatch(text);
  }

  // ---------- 解析 ----------

  static final RegExp _headingLine = RegExp(r'^\s{0,3}(#{1,3})\s+(.*)$');
  static final RegExp _bulletLine = RegExp(r'^(\s*)[-*]\s+(.*)$');
  static final RegExp _taskLine = RegExp(r'^\[( |x|X)\]\s+(.*)$');

  /// 将文本切分为「文本行组」与「代码段」，保持原有顺序
  static List<_Segment> _parse(String text) {
    final segments = <_Segment>[];
    final lines = text.split('\n');
    final textBuf = <String>[];
    final codeBuf = <String>[];
    var inCode = false;
    var codeLang = '';

    void flushText() {
      if (textBuf.isEmpty) return;
      segments.add(_Segment.text(textBuf.join('\n')));
      textBuf.clear();
    }

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('```')) {
        if (inCode) {
          segments.add(_Segment.code(codeLang, codeBuf.join('\n')));
          codeBuf.clear();
          codeLang = '';
          inCode = false;
        } else {
          flushText();
          codeLang = trimmed.substring(3).trim();
          inCode = true;
        }
        continue;
      }
      if (inCode) {
        codeBuf.add(line);
      } else {
        textBuf.add(line);
      }
    }
    if (inCode) segments.add(_Segment.code(codeLang, codeBuf.join('\n')));
    flushText();
    return segments;
  }

  /// 行内格式：**加粗**、`行内代码`
  static List<InlineSpan> _inlineSpans(String line, TextStyle style, Color codeBg) {
    final spans = <InlineSpan>[];
    final re = RegExp(r'(\*\*[^*\n]+\*\*|`[^`\n]+`)');
    var i = 0;
    for (final m in re.allMatches(line)) {
      if (m.start > i) spans.add(TextSpan(text: line.substring(i, m.start), style: style));
      final token = m.group(0)!;
      if (token.startsWith('**')) {
        spans.add(TextSpan(
          text: token.substring(2, token.length - 2),
          style: style.copyWith(fontWeight: FontWeight.w600),
        ));
      } else {
        spans.add(TextSpan(
          text: token.substring(1, token.length - 1),
          style: style.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: const ['Consolas', 'Courier New'],
            fontSize: (style.fontSize ?? 14) - 1.5,
            backgroundColor: codeBg,
          ),
        ));
      }
      i = m.end;
    }
    if (i < line.length) spans.add(TextSpan(text: line.substring(i), style: style));
    return spans;
  }

  // ---------- 渲染 ----------

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final segments = _parse(text);
    final inlineCodeBg = colorScheme.onSurface.withOpacity(0.10);
    final children = <Widget>[];

    for (final seg in segments) {
      if (seg.isCode) {
        children.add(_CodeSection(lang: seg.lang, code: seg.content));
      } else {
        children.add(_buildTextSection(seg.content, inlineCodeBg));
      }
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _buildTextSection(String section, Color inlineCodeBg) {
    final lines = section.split('\n');
    final spans = <InlineSpan>[];
    for (var idx = 0; idx < lines.length; idx++) {
      final line = lines[idx];
      if (idx > 0) spans.add(TextSpan(text: '\n', style: baseStyle));

      final heading = _headingLine.firstMatch(line);
      if (heading != null) {
        final level = heading.group(1)!.length;
        final size = (baseStyle.fontSize ?? 14) + (level == 1 ? 5.0 : level == 2 ? 3.0 : 1.5);
        spans.addAll(_inlineSpans(
          heading.group(2)!,
          baseStyle.copyWith(fontWeight: FontWeight.w600, fontSize: size, height: 1.5),
          inlineCodeBg,
        ));
        continue;
      }

      final bullet = _bulletLine.firstMatch(line);
      if (bullet != null) {
        final indent = ((bullet.group(1)!.length / 2).floor()).clamp(0, 3) * 12.0;
        final body = bullet.group(2)!;
        final task = _taskLine.firstMatch(body);
        final prefix = indent > 0 ? (' ' * (indent ~/ 3)) : '';
        if (task != null) {
          final done = task.group(1)!.toLowerCase() == 'x';
          spans.add(TextSpan(text: '$prefix${done ? '☑' : '☐'} ', style: baseStyle));
          spans.addAll(_inlineSpans(task.group(2)!, baseStyle, inlineCodeBg));
        } else {
          spans.add(TextSpan(text: '$prefix• ', style: baseStyle));
          spans.addAll(_inlineSpans(body, baseStyle, inlineCodeBg));
        }
        continue;
      }

      spans.addAll(_inlineSpans(line, baseStyle, inlineCodeBg));
    }
    return Text.rich(
      TextSpan(children: spans),
      softWrap: true,
      textAlign: textAlign,
    );
  }

  // ---------- 高度估算（与渲染保持同一套样式/间距） ----------

  /// 估算渲染内容在 [maxWidth] 下的自然高度（不含方块自身 padding）
  static double estimateHeight(String text, double maxWidth, TextStyle baseStyle) {
    final segments = _parse(text);
    var total = 0.0;
    for (final seg in segments) {
      if (seg.isCode) {
        total += _CodeSection.estimateHeight(seg.content, maxWidth);
      } else {
        // 文本段：逐行用 TextPainter 估算（标题更高）
        total += _estimateTextSection(seg.content, maxWidth, baseStyle);
      }
    }
    return total;
  }

  static double _estimateTextSection(String section, double maxWidth, TextStyle baseStyle) {
    final lines = section.split('\n');
    var total = 0.0;
    for (final line in lines) {
      final heading = _headingLine.firstMatch(line);
      final style = heading != null
          ? baseStyle.copyWith(
              fontWeight: FontWeight.w600,
              fontSize: (baseStyle.fontSize ?? 14) +
                  (heading.group(1)!.length == 1 ? 5.0 : heading.group(1)!.length == 2 ? 3.0 : 1.5),
              height: 1.5,
            )
          : baseStyle;
      final content = heading != null ? heading.group(2)! : line;
      final painter = TextPainter(
        text: TextSpan(text: content.isEmpty ? ' ' : _stripInlineMarks(content), style: style),
        maxLines: null,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxWidth);
      total += painter.height;
    }
    return total;
  }

  /// 去掉行内标记用于测量（测量允许轻微误差）
  static String _stripInlineMarks(String s) {
    return s
        .replaceAllMapped(RegExp(r'\*\*([^*\n]+)\*\*'), (m) => m.group(1)!)
        .replaceAllMapped(RegExp(r'`([^`\n]+)`'), (m) => m.group(1)!);
  }
}

/// 文本/代码段
class _Segment {
  _Segment.text(this.content) : isCode = false, lang = '';
  _Segment.code(this.lang, this.content) : isCode = true;
  final bool isCode;
  final String lang;
  final String content;
}

/// 代码段：深色底 + 等宽高亮 + 语言标签 + 复制整段
class _CodeSection extends StatelessWidget {
  const _CodeSection({required this.lang, required this.code});

  final String lang;
  final String code;

  static const double _fontSize = 12.5;
  static const double _hPad = 10;
  static const double _headerH = 22;
  static const double _vMargins = 8; // 上下各 4

  static double estimateHeight(String code, double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(
        text: code.isEmpty ? ' ' : code,
        style: CodeHighlighter.baseStyle(fontSize: _fontSize),
      ),
      maxLines: null,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: (maxWidth - _hPad * 2).clamp(40.0, double.infinity));
    return painter.height + _headerH + 16 + _vMargins;
  }

  @override
  Widget build(BuildContext context) {
    final codeStyle = CodeHighlighter.baseStyle(fontSize: _fontSize);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1F2430),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: _headerH,
            child: Padding(
              padding: const EdgeInsets.only(left: _hPad, right: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      lang.isEmpty ? 'code' : lang,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF8A8F98),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () async {
                      final messenger = ScaffoldMessenger.maybeOf(context);
                      await Clipboard.setData(ClipboardData(text: code));
                      messenger?.hideCurrentSnackBar();
                      messenger?.showSnackBar(const SnackBar(
                        content: Text('代码已复制'),
                        duration: Duration(seconds: 2),
                      ));
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.copy_rounded, size: 12, color: Color(0xFF8A8F98)),
                          SizedBox(width: 3),
                          Text('复制', style: TextStyle(color: Color(0xFF8A8F98), fontSize: 10.5)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(height: 0.5, color: Colors.white.withOpacity(0.08)),
          Padding(
            padding: const EdgeInsets.fromLTRB(_hPad, 6, _hPad, 8),
            child: Text.rich(
              TextSpan(children: CodeHighlighter.highlight(code, lang, codeStyle)),
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }
}
