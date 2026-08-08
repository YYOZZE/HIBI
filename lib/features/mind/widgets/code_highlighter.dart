import 'package:flutter/material.dart';

/// 轻量级代码语法高亮（无第三方依赖）：
/// 覆盖注释 / 字符串 / 数字 / 关键字 / JSON·YAML 键名，满足白板代码块的基础高亮需求。
class CodeHighlighter {
  CodeHighlighter._();

  /// 深色代码底配色（VS Code Dark+ 风格的柔和变体）
  static const Color baseColor = Color(0xFFE4E6EB);
  static const Color keywordColor = Color(0xFF7AB3FF);
  static const Color stringColor = Color(0xFF9ED18B);
  static const Color commentColor = Color(0xFF8A8F98);
  static const Color numberColor = Color(0xFFE8C07D);
  static const Color attrColor = Color(0xFF8AD4FF);

  /// 等宽基础样式（深色底上使用）
  static TextStyle baseStyle({double fontSize = 12.5, double height = 1.45}) {
    return TextStyle(
      color: baseColor,
      fontSize: fontSize,
      height: height,
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Consolas', 'Courier New'],
    );
  }

  static const Set<String> _keywords = {
    // 通用控制流 / 声明
    'if', 'else', 'for', 'while', 'do', 'switch', 'case', 'default', 'break',
    'continue', 'return', 'try', 'catch', 'finally', 'throw', 'throws', 'raise',
    'except', 'new', 'delete', 'this', 'self', 'super', 'null', 'true', 'false',
    'and', 'or', 'not', 'in', 'is', 'as', 'of', 'with', 'yield', 'await', 'async',
    'class', 'interface', 'enum', 'struct', 'extends', 'implements', 'import',
    'from', 'export', 'package', 'namespace', 'using', 'public', 'private',
    'protected', 'static', 'final', 'const', 'var', 'let', 'def', 'fun',
    'function', 'fn', 'void', 'int', 'double', 'float', 'bool', 'boolean',
    'string', 'char', 'long', 'short', 'byte', 'type', 'abstract', 'override',
    'virtual', 'get', 'set', 'late', 'required', 'lambda', 'pass', 'elif',
    'None', 'True', 'False', 'print', 'len', 'range', 'echo', 'then', 'fi',
    'done', 'esac', 'foreach', 'when', 'where', 'select', 'SELECT', 'FROM',
    'WHERE', 'INSERT', 'UPDATE', 'DELETE', 'CREATE', 'TABLE', 'JOIN', 'GROUP',
    'ORDER', 'BY', 'LIMIT', 'VALUES', 'INTO', 'SET', 'AND', 'OR', 'NOT', 'NULL',
  };

  /// 语言归一化：围栏标记（```dart 等）映射到注释/键名规则
  static String _normalizeLang(String? lang) {
    final l = (lang ?? '').trim().toLowerCase();
    if (l == 'js' || l == 'jsx' || l == 'javascript') return 'javascript';
    if (l == 'ts' || l == 'tsx' || l == 'typescript') return 'typescript';
    if (l == 'py' || l == 'python3') return 'python';
    if (l == 'sh' || l == 'shell' || l == 'zsh') return 'bash';
    if (l == 'yml') return 'yaml';
    if (l == 'kt' || l == 'kts') return 'kotlin';
    if (l == 'c++' || l == 'cc' || l == 'cxx') return 'cpp';
    if (l == 'cs' || l == 'csharp') return 'csharp';
    if (l == 'vue' || l == 'htm') return 'html';
    return l;
  }

  static bool _hashComment(String lang) =>
      lang == 'python' || lang == 'bash' || lang == 'yaml' || lang == 'ruby' || lang == 'toml';
  static bool _slashComment(String lang) => !(_hashComment(lang) ||
      lang == 'sql' || lang == 'html' || lang == 'xml' || lang == 'css');
  static bool _sqlComment(String lang) => lang == 'sql';
  static bool _keyAttr(String lang) => lang == 'json' || lang == 'yaml';

  /// 将代码切分为带配色的 TextSpan 列表
  static List<TextSpan> highlight(String code, String? lang, TextStyle base) {
    final l = _normalizeLang(lang);
    final spans = <TextSpan>[];
    final buf = StringBuffer();
    var i = 0;

    void flush() {
      if (buf.isEmpty) return;
      spans.add(TextSpan(text: buf.toString(), style: base));
      buf.clear();
    }

    void push(String text, TextStyle style) {
      flush();
      spans.add(TextSpan(text: text, style: style));
    }

    bool isIdentChar(int c) =>
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 36;

    final kwStyle = base.copyWith(color: keywordColor);
    final strStyle = base.copyWith(color: stringColor);
    final cmtStyle = base.copyWith(color: commentColor, fontStyle: FontStyle.italic);
    final numStyle = base.copyWith(color: numberColor);
    final attrStyle = base.copyWith(color: attrColor);

    while (i < code.length) {
      final ch = code[i];
      final two = i + 1 < code.length ? code.substring(i, i + 2) : '';

      // 行注释
      final isLineComment = (two == '//' && _slashComment(l)) ||
          (ch == '#' && _hashComment(l)) ||
          (two == '--' && _sqlComment(l));
      if (isLineComment) {
        var j = code.indexOf('\n', i);
        if (j < 0) j = code.length;
        push(code.substring(i, j), cmtStyle);
        i = j;
        continue;
      }
      // 块注释 /* */
      if (two == '/*' && l != 'python') {
        var j = code.indexOf('*/', i + 2);
        j = j < 0 ? code.length : j + 2;
        push(code.substring(i, j), cmtStyle);
        i = j;
        continue;
      }
      // HTML 注释
      if (code.startsWith('<!--', i)) {
        var j = code.indexOf('-->', i + 4);
        j = j < 0 ? code.length : j + 3;
        push(code.substring(i, j), cmtStyle);
        i = j;
        continue;
      }
      // 字符串（JSON/YAML 中后面紧跟冒号的为键名，用属性色）
      if (ch == '"' || ch == "'" || ch == '`') {
        var j = i + 1;
        while (j < code.length) {
          if (code[j] == '\\') {
            j += 2;
            continue;
          }
          if (code[j] == ch) {
            j++;
            break;
          }
          j++;
        }
        if (j > code.length) j = code.length;
        var isKey = false;
        if (_keyAttr(l)) {
          var k = j;
          while (k < code.length && (code[k] == ' ' || code[k] == '\t')) {
            k++;
          }
          isKey = k < code.length && code[k] == ':';
        }
        push(code.substring(i, j), isKey ? attrStyle : strStyle);
        i = j;
        continue;
      }
      // 数字
      if (_isDigit(ch.codeUnitAt(0)) &&
          (i == 0 || !isIdentChar(code.codeUnitAt(i - 1)))) {
        var j = i;
        while (j < code.length) {
          final c = code.codeUnitAt(j);
          final ok = _isDigit(c) ||
              code[j] == '.' ||
              (c >= 65 && c <= 70) || // A-F
              (c >= 97 && c <= 102) || // a-f
              code[j] == 'x' || code[j] == 'X' || code[j] == '_';
          if (!ok) break;
          j++;
        }
        push(code.substring(i, j), numStyle);
        i = j;
        continue;
      }
      // 标识符 / 关键字 / JSON·YAML 键名
      if (isIdentChar(ch.codeUnitAt(0)) && !_isDigit(ch.codeUnitAt(0))) {
        var j = i;
        while (j < code.length && isIdentChar(code.codeUnitAt(j))) {
          j++;
        }
        final word = code.substring(i, j);
        if (_keywords.contains(word)) {
          push(word, kwStyle);
        } else if (_keyAttr(l)) {
          // 键名：后面紧跟可选空白 + 冒号
          var k = j;
          while (k < code.length && (code[k] == ' ' || code[k] == '\t')) {
            k++;
          }
          if (k < code.length && code[k] == ':') {
            push(word, attrStyle);
          } else {
            buf.write(word);
          }
        } else {
          buf.write(word);
        }
        i = j;
        continue;
      }
      buf.write(ch);
      i++;
    }
    flush();
    return spans;
  }

  static bool _isDigit(int c) => c >= 48 && c <= 57;
}
