import 'package:flutter_test/flutter_test.dart';
import 'package:jideshi_hibi/features/mind/models/canvas_item.dart';
import 'package:jideshi_hibi/features/mind/utils/block_text_format.dart';

void main() {
  group('BlockTextFormat 加点（无序列表）', () {
    test('光标所在行加「• 」前缀', () {
      final r = BlockTextFormat.toggleBullet('你好', 0, 0);
      expect(r.text, '• 你好');
      expect(r.selectionStart, 2);
      expect(r.selectionEnd, 2);
    });

    test('行首光标随内容平移到前缀之后', () {
      final r = BlockTextFormat.toggleBullet('abc', 0, 0);
      expect(r.selectionStart, 2);
    });

    test('再次切换则移除前缀', () {
      final added = BlockTextFormat.toggleBullet('你好', 1, 1);
      final removed = BlockTextFormat.toggleBullet(added.text, added.selectionStart, added.selectionEnd);
      expect(removed.text, '你好');
      expect(removed.selectionStart, 1);
    });

    test('选中多行时逐行加前缀', () {
      const text = '第一行\n第二行\n第三行';
      final r = BlockTextFormat.toggleBullet(text, 0, text.length);
      expect(r.text, '• 第一行\n• 第二行\n• 第三行');
    });

    test('全部已加点时整体移除', () {
      const text = '• 甲\n• 乙';
      final r = BlockTextFormat.toggleBullet(text, 0, text.length);
      expect(r.text, '甲\n乙');
    });

    test('部分已加点时补齐而非移除', () {
      const text = '• 甲\n乙';
      final r = BlockTextFormat.toggleBullet(text, 0, text.length);
      expect(r.text, '• 甲\n• 乙');
    });

    test('选区末端恰好在行首时该行不受影响', () {
      const text = '甲\n乙';
      // 选区覆盖「甲\n」（end 在第二行行首）
      final r = BlockTextFormat.toggleBullet(text, 0, 2);
      expect(r.text, '• 甲\n乙');
    });

    test('空文本加点后光标在前缀之后', () {
      final r = BlockTextFormat.toggleBullet('', 0, 0);
      expect(r.text, '• ');
      expect(r.selectionStart, 2);
    });
  });

  group('BlockTextFormat 序号（有序列表）', () {
    test('多行自动递增编号', () {
      const text = '苹果\n香蕉\n橘子';
      final r = BlockTextFormat.toggleNumbered(text, 0, text.length);
      expect(r.text, '1. 苹果\n2. 香蕉\n3. 橘子');
    });

    test('部分行有旧编号时先清除再按行递增重排', () {
      const text = '3. 苹果\n香蕉';
      final r = BlockTextFormat.toggleNumbered(text, 0, text.length);
      expect(r.text, '1. 苹果\n2. 香蕉');
    });

    test('全部已有编号时移除编号', () {
      const text = '1. 苹果\n2. 香蕉';
      final r = BlockTextFormat.toggleNumbered(text, 0, text.length);
      expect(r.text, '苹果\n香蕉');
    });

    test('空行不编号也不占位', () {
      const text = '苹果\n\n香蕉';
      final r = BlockTextFormat.toggleNumbered(text, 0, text.length);
      expect(r.text, '1. 苹果\n\n2. 香蕉');
    });

    test('加点与序号互不干扰：序号会替换行首编号而不动「• 」', () {
      const text = '• 项目';
      final r = BlockTextFormat.toggleNumbered(text, 0, text.length);
      expect(r.text, '1. • 项目');
    });
  });

  group('CanvasBlock 序列化向后兼容', () {
    test('旧版 JSON（无新字段）加载为默认值', () {
      final block = CanvasBlock.fromJson(const {
        'id': 'b1',
        'type': 'block',
        'x': 10,
        'y': 20,
        'w': 220,
        'h': 50,
        'text': '旧数据',
        'completed': false,
      });
      expect(block.align, BlockStylePresets.alignLeft);
      expect(block.textColor, isNull);
      expect(block.highlight, isNull);
    });

    test('未知预设值回退默认，不产生脏数据', () {
      final block = CanvasBlock.fromJson(const {
        'id': 'b1',
        'type': 'block',
        'align': 'right',
        'textColor': 'neon',
        'highlight': 'rainbow',
      });
      expect(block.align, BlockStylePresets.alignLeft);
      expect(block.textColor, isNull);
      expect(block.highlight, isNull);
    });

    test('默认值的 toJson 不写入新字段（旧版本可正常读取）', () {
      final block = CanvasBlock(id: 'b1');
      final json = block.toJson();
      expect(json.containsKey('align'), isFalse);
      expect(json.containsKey('textColor'), isFalse);
      expect(json.containsKey('highlight'), isFalse);
    });

    test('非默认值序列化后可完整往返', () {
      final block = CanvasBlock(id: 'b1')
        ..align = BlockStylePresets.alignCenter
        ..textColor = 'red'
        ..highlight = 'yellow';
      final restored = CanvasBlock.fromJson(block.toJson());
      expect(restored.align, BlockStylePresets.alignCenter);
      expect(restored.textColor, 'red');
      expect(restored.highlight, 'yellow');
    });

    test('copyWith 覆盖新字段', () {
      final block = CanvasBlock(id: 'b1');
      final copied = block.copyWith(align: BlockStylePresets.alignCenter, textColor: 'blue', highlight: 'pink');
      expect(copied.align, BlockStylePresets.alignCenter);
      expect(copied.textColor, 'blue');
      expect(copied.highlight, 'pink');
      // 原对象不受影响
      expect(block.align, BlockStylePresets.alignLeft);
    });
  });

  group('BlockStylePresets.borderAccentColor 边框取色优先级', () {
    test('均未设置时返回 null，由调用方回退主题 outline 派生色', () {
      expect(BlockStylePresets.borderAccentColor(), isNull);
      expect(
        BlockStylePresets.borderAccentColor(highlightKey: null, textColorKey: null),
        isNull,
      );
    });

    test('仅设置文字颜色时取文字颜色', () {
      expect(
        BlockStylePresets.borderAccentColor(textColorKey: 'red'),
        BlockStylePresets.textColors['red'],
      );
    });

    test('仅设置颜色标注时取标注色', () {
      expect(
        BlockStylePresets.borderAccentColor(highlightKey: 'yellow'),
        BlockStylePresets.highlightColors['yellow'],
      );
    });

    test('两者都设置时 highlight 优先于 textColor', () {
      expect(
        BlockStylePresets.borderAccentColor(highlightKey: 'pink', textColorKey: 'blue'),
        BlockStylePresets.highlightColors['pink'],
      );
    });

    test('未知 key 回退 null，不产生脏数据', () {
      expect(
        BlockStylePresets.borderAccentColor(highlightKey: 'rainbow', textColorKey: 'neon'),
        isNull,
      );
    });
  });
}
