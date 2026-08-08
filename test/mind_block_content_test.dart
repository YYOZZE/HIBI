import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jideshi_hibi/features/mind/widgets/block_content_preview.dart';
import 'package:jideshi_hibi/features/mind/widgets/code_highlighter.dart';

void main() {
  group('CodeHighlighter 语法高亮', () {
    final base = CodeHighlighter.baseStyle();

    List<TextSpan> spansOf(String code, String lang) =>
        CodeHighlighter.highlight(code, lang, base);

    test('关键字使用关键字配色', () {
      final spans = spansOf('return 42;', 'dart');
      final kw = spans.firstWhere((s) => s.text == 'return');
      expect(kw.style?.color, CodeHighlighter.keywordColor);
    });

    test('字符串与注释配色正确', () {
      final spans = spansOf('// hi\nvar s = "abc";', 'dart');
      final cmt = spans.firstWhere((s) => (s.text ?? '').startsWith('//'));
      expect(cmt.style?.color, CodeHighlighter.commentColor);
      final str = spans.firstWhere((s) => s.text == '"abc"');
      expect(str.style?.color, CodeHighlighter.stringColor);
    });

    test('数字配色', () {
      final spans = spansOf('x = 3.14', 'python');
      final num = spans.firstWhere((s) => s.text == '3.14');
      expect(num.style?.color, CodeHighlighter.numberColor);
    });

    test('python 使用 # 行注释，// 不会被误判', () {
      final spans = spansOf('# note\na = 1 // 2', 'python');
      final cmt = spans.firstWhere((s) => (s.text ?? '').startsWith('#'));
      expect(cmt.style?.color, CodeHighlighter.commentColor);
      // python 中 // 不是注释，不应整行变注释色
      final hasSlashComment = spans.any(
          (s) => (s.text ?? '').contains('// 2') && s.style?.color == CodeHighlighter.commentColor);
      expect(hasSlashComment, isFalse);
    });

    test('JSON 键名高亮为属性色，值仍为字符串色', () {
      final spans = spansOf('{"name": "hibi"}', 'json');
      final key = spans.firstWhere((s) => s.text == '"name"');
      expect(key.style?.color, CodeHighlighter.attrColor);
      final value = spans.firstWhere((s) => s.text == '"hibi"');
      expect(value.style?.color, CodeHighlighter.stringColor);
    });

    test('转义引号不会提前结束字符串', () {
      final spans = spansOf(r'var s = "a\"b"; return', 'dart');
      final str = spans.firstWhere((s) => (s.text ?? '').contains(r'a\"b'));
      expect(str.style?.color, CodeHighlighter.stringColor);
      final kw = spans.firstWhere((s) => s.text == 'return');
      expect(kw.style?.color, CodeHighlighter.keywordColor);
    });

    test('拼接结果与原文一致（不丢字符）', () {
      const code = 'class A {\n  // c\n  final x = "s" + 1;\n}';
      final joined = spansOf(code, 'dart').map((s) => s.text ?? '').join();
      expect(joined, code);
    });
  });

  group('BlockContentPreview 富文本侦测', () {
    test('普通文字不进入富文本模式', () {
      expect(BlockContentPreview.hasRichContent('今天天气不错'), isFalse);
      expect(BlockContentPreview.hasRichContent(''), isFalse);
    });

    test('代码围栏 / 标题 / 列表 / 加粗 / 行内代码均触发', () {
      expect(BlockContentPreview.hasRichContent('```dart\nvar a=1;\n```'), isTrue);
      expect(BlockContentPreview.hasRichContent('# 标题'), isTrue);
      expect(BlockContentPreview.hasRichContent('第一行\n- 列表项'), isTrue);
      expect(BlockContentPreview.hasRichContent('这是**重点**内容'), isTrue);
      expect(BlockContentPreview.hasRichContent('调用 `print()` 函数'), isTrue);
    });
  });

  group('BlockContentPreview 高度估算', () {
    const style = TextStyle(fontSize: 15, height: 1.2);

    test('空文本有基础高度', () {
      expect(BlockContentPreview.estimateHeight('', 200, style), greaterThan(0));
    });

    test('含代码块比同长度纯文本更高（代码段有头与边距）', () {
      const plain = 'var a = 1;';
      const withCode = '```dart\nvar a = 1;\n```';
      final hPlain = BlockContentPreview.estimateHeight(plain, 200, style);
      final hCode = BlockContentPreview.estimateHeight(withCode, 200, style);
      expect(hCode, greaterThan(hPlain));
    });

    test('宽度越窄估算越高（换行增多）', () {
      const text = '这是一段比较长比较长比较长的文字内容，用于验证窄宽度下换行后高度增加';
      final hWide = BlockContentPreview.estimateHeight(text, 400, style);
      final hNarrow = BlockContentPreview.estimateHeight(text, 120, style);
      expect(hNarrow, greaterThan(hWide));
    });
  });
}
