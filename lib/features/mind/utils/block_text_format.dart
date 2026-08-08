import 'package:flutter/material.dart';

/// 方块文字格式工具：行首前缀（加点/序号）变换与对齐/文字颜色/背景标注预设。
/// 前缀变换是纯文本操作，预览态按原样或 markdown-lite 渲染，编辑/预览保持一致。

/// 一次文本变换的结果：新文本 + 变换后应恢复的选区（光标）范围
class TextTransformResult {
  const TextTransformResult(this.text, this.selectionStart, this.selectionEnd);

  final String text;
  final int selectionStart;
  final int selectionEnd;
}

/// 行首前缀变换：无序列表「• 」与有序列表「1. 2. …」
class BlockTextFormat {
  BlockTextFormat._();

  static const String bulletPrefix = '• ';
  static final RegExp _numberedRe = RegExp(r'^\d+\.\s');

  /// 切换无序列表：受选区影响的行全部已加「• 」时移除，否则逐行补上
  static TextTransformResult toggleBullet(String text, int selectionStart, int selectionEnd) {
    return _transform(text, selectionStart, selectionEnd, numbered: false);
  }

  /// 切换有序列表：受选区影响的行全部已有编号时移除，否则按行递增重新编号
  static TextTransformResult toggleNumbered(String text, int selectionStart, int selectionEnd) {
    return _transform(text, selectionStart, selectionEnd, numbered: true);
  }

  static TextTransformResult _transform(String text, int start, int end, {required bool numbered}) {
    start = start.clamp(0, text.length);
    end = end.clamp(0, text.length);
    if (start > end) {
      final t = start;
      start = end;
      end = t;
    }

    final lines = text.split('\n');
    final starts = <int>[];
    var offset = 0;
    for (final line in lines) {
      starts.add(offset);
      offset += line.length + 1; // +1 为换行符
    }

    int lineOf(int pos) {
      var idx = 0;
      for (var i = 0; i < starts.length; i++) {
        if (starts[i] <= pos) idx = i;
      }
      return idx;
    }

    var first = lineOf(start);
    var last = lineOf(end);
    // 选区末端恰好在行首时，该行不算被选中（与常见编辑器一致）
    if (end > start && starts[last] == end && last > first) last--;
    if (first > last) {
      final t = first;
      first = last;
      last = t;
    }

    bool hasPrefix(String line) =>
        numbered ? _numberedRe.hasMatch(line) : line.startsWith(bulletPrefix);

    final affected = lines.sublist(first, last + 1);
    final nonEmpty = affected.where((l) => l.isNotEmpty).toList();
    final allMarked = nonEmpty.isNotEmpty && nonEmpty.every(hasPrefix);

    // 计算每行的新内容与前缀变化（removed > 0 表示从行首删除的字符数；added > 0 表示行首新增的字符数）
    final newLines = List<String>.of(lines);
    final removed = List<int>.filled(lines.length, 0);
    final added = List<int>.filled(lines.length, 0);

    if (allMarked) {
      for (var i = first; i <= last; i++) {
        final line = lines[i];
        if (line.isEmpty) continue;
        final len = numbered ? (_numberedRe.firstMatch(line)?.end ?? 0) : bulletPrefix.length;
        if (len <= 0) continue;
        newLines[i] = line.substring(len);
        removed[i] = len;
      }
    } else if (numbered) {
      var counter = 1;
      for (var i = first; i <= last; i++) {
        var line = lines[i];
        final existing = _numberedRe.firstMatch(line);
        if (existing != null) {
          line = line.substring(existing.end);
          removed[i] = existing.end;
        }
        if (line.isEmpty) {
          newLines[i] = line;
          continue;
        }
        final prefix = '${counter++}. ';
        newLines[i] = prefix + line;
        added[i] = prefix.length;
      }
    } else {
      for (var i = first; i <= last; i++) {
        final line = lines[i];
        if (line.startsWith(bulletPrefix)) continue;
        newLines[i] = bulletPrefix + line;
        added[i] = bulletPrefix.length;
      }
    }

    // 将旧光标位置映射到新文本：行内位置随前缀增删平移，处于被删前缀内的位置收拢到行首
    int mapPos(int pos) {
      final idx = lineOf(pos);
      var delta = 0;
      for (var i = 0; i < idx; i++) {
        delta += added[i] - removed[i];
      }
      final lineStart = starts[idx];
      final inside = pos - lineStart;
      if (removed[idx] > 0) {
        final shift = inside <= removed[idx] ? -inside : added[idx] - removed[idx];
        return pos + delta + shift;
      }
      return pos + delta + added[idx];
    }

    return TextTransformResult(newLines.join('\n'), mapPos(start), mapPos(end));
  }
}

/// 方块样式预设：文字颜色 / 背景标注（荧光笔）/ 对齐方式的存储键与解析。
/// 序列化仅存 key，颜色在此统一定义，未知 key 一律回退默认，保证旧文件兼容。
class BlockStylePresets {
  BlockStylePresets._();

  /// 对齐方式存储值
  static const String alignLeft = 'left';
  static const String alignCenter = 'center';

  /// 文字颜色预设（默认 null 表示跟随主题 onSurface）
  static const Map<String, Color> textColors = {
    'graphite': Color(0xFF8A8F98),
    'red': Color(0xFFE57373),
    'orange': Color(0xFFFFB74D),
    'blue': Color(0xFF64B5F6),
    'green': Color(0xFF81C784),
    'purple': Color(0xFFBA93E0),
  };

  static const Map<String, String> textColorNames = {
    'default': '默认',
    'graphite': '石墨灰',
    'red': '朱红',
    'orange': '暖橙',
    'blue': '雾蓝',
    'green': '竹绿',
    'purple': '黛紫',
  };

  /// 背景标注预设（荧光笔底色，使用时以低透明度叠加在方块底色上）
  static const Map<String, Color> highlightColors = {
    'yellow': Color(0xFFF9D65C),
    'pink': Color(0xFFF48FB1),
    'blue': Color(0xFF64B5F6),
    'green': Color(0xFF81C784),
    'purple': Color(0xFFBA93E0),
  };

  static const Map<String, String> highlightNames = {
    'none': '无',
    'yellow': '鹅黄',
    'pink': '樱粉',
    'blue': '雾蓝',
    'green': '竹绿',
    'purple': '烟紫',
  };

  /// 标注色叠加到方块底色时的透明度（低透明，类似荧光笔）
  static const double highlightOpacity = 0.30;

  static String normalizeAlign(dynamic v) => v == alignCenter ? alignCenter : alignLeft;

  static String? normalizeTextColorKey(dynamic v) {
    if (v is String && textColors.containsKey(v)) return v;
    return null;
  }

  static String? normalizeHighlightKey(dynamic v) {
    if (v is String && highlightColors.containsKey(v)) return v;
    return null;
  }

  /// 解析文字颜色；key 为 null（默认）时返回 null，由调用方回退到主题色
  static Color? textColor(String? key) => key == null ? null : textColors[key];

  /// 解析标注底色；key 为 null（无标注）时返回 null
  static Color? highlightColor(String? key) => key == null ? null : highlightColors[key];

  /// 方块边框强调色：设置了颜色标注或文字颜色时取对应颜色，
  /// 优先级 highlight > textColor；均未设置时返回 null，由调用方回退到主题 outline 派生色。
  static Color? borderAccentColor({String? highlightKey, String? textColorKey}) {
    return highlightColor(highlightKey) ?? textColor(textColorKey);
  }

  static TextAlign textAlignOf(String align) =>
      align == alignCenter ? TextAlign.center : TextAlign.left;
}
