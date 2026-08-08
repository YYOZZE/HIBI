import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jideshi_hibi/features/mind/models/canvas_item.dart';
import 'package:jideshi_hibi/features/mind/utils/block_text_format.dart';
import 'package:jideshi_hibi/features/mind/widgets/block_format_toolbar.dart';

/// 包一层有状态宿主，模拟页面侧行为：onChanged 触发 setState 重建 + 计数持久化回调，
/// onApplyLineFormat 按「预览态全文逐行」路由（与画布页预览路径调用约定一致）。
class _ToolbarHost extends StatefulWidget {
  const _ToolbarHost({required this.block, required this.onPersisted});

  final CanvasBlock block;
  final VoidCallback onPersisted;

  @override
  State<_ToolbarHost> createState() => _ToolbarHostState();
}

class _ToolbarHostState extends State<_ToolbarHost> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: BlockFormatToolbar(
            block: widget.block,
            onChanged: () {
              setState(() {});
              widget.onPersisted();
            },
            onApplyLineFormat: (numbered) {
              // 预览态路由：对全文逐行生效（同画布页 _applyBlockLineFormat 的非编辑分支）
              final r = numbered
                  ? BlockTextFormat.toggleNumbered(widget.block.text, 0, widget.block.text.length)
                  : BlockTextFormat.toggleBullet(widget.block.text, 0, widget.block.text.length);
              setState(() {
                widget.block.text = r.text;
              });
              widget.onPersisted();
            },
          ),
        ),
      ),
    );
  }
}

void main() {
  group('BlockFormatToolbar 预览态格式操作', () {
    testWidgets('点对齐：模型变更为居中且按钮图标重建为居中图标', (tester) async {
      final block = CanvasBlock(id: 'b1')..text = '对齐我';
      var persisted = 0;
      await tester.pumpWidget(_ToolbarHost(block: block, onPersisted: () => persisted++));

      // 初始为左对齐图标
      expect(find.byIcon(Icons.format_align_left), findsOneWidget);
      expect(find.byIcon(Icons.format_align_center), findsNothing);

      await tester.tap(find.byIcon(Icons.format_align_left));
      await tester.pump();

      expect(block.align, BlockStylePresets.alignCenter);
      expect(persisted, 1);
      // UI 已重建为居中图标
      expect(find.byIcon(Icons.format_align_center), findsOneWidget);
      expect(find.byIcon(Icons.format_align_left), findsNothing);

      // 再点一次切回左对齐
      await tester.tap(find.byIcon(Icons.format_align_center));
      await tester.pump();
      expect(block.align, BlockStylePresets.alignLeft);
      expect(find.byIcon(Icons.format_align_left), findsOneWidget);
    });

    testWidgets('预览态加点：对全文逐行加「• 」前缀，再点整体移除', (tester) async {
      final block = CanvasBlock(id: 'b1')..text = '第一行\n第二行\n第三行';
      await tester.pumpWidget(_ToolbarHost(block: block, onPersisted: () {}));

      await tester.tap(find.byIcon(Icons.format_list_bulleted));
      await tester.pump();
      expect(block.text, '• 第一行\n• 第二行\n• 第三行');

      await tester.tap(find.byIcon(Icons.format_list_bulleted));
      await tester.pump();
      expect(block.text, '第一行\n第二行\n第三行');
    });

    testWidgets('预览态序号：全文逐行递增编号', (tester) async {
      final block = CanvasBlock(id: 'b1')..text = '苹果\n香蕉';
      await tester.pumpWidget(_ToolbarHost(block: block, onPersisted: () {}));

      await tester.tap(find.byIcon(Icons.format_list_numbered));
      await tester.pump();
      expect(block.text, '1. 苹果\n2. 香蕉');
    });

    testWidgets('字色：色板弹出且选择后 textColor 写入模型并触发持久化', (tester) async {
      final block = CanvasBlock(id: 'b1')..text = '染色';
      var persisted = 0;
      await tester.pumpWidget(_ToolbarHost(block: block, onPersisted: () => persisted++));

      await tester.tap(find.byIcon(Icons.format_color_text));
      await tester.pumpAndSettle();
      // 色板菜单弹出（含默认项与全部预设色名）
      expect(find.text('默认'), findsOneWidget);
      expect(find.text('朱红'), findsOneWidget);

      await tester.tap(find.text('朱红'));
      await tester.pumpAndSettle();

      expect(block.textColor, 'red');
      expect(persisted, 1);
      // 按钮图标即时反映当前色
      final icon = tester.widget<Icon>(find.byIcon(Icons.format_color_text));
      expect(icon.color, BlockStylePresets.textColors['red']);

      // 选回默认：textColor 清除为 null
      await tester.tap(find.byIcon(Icons.format_color_text));
      await tester.pumpAndSettle();
      await tester.tap(find.text('默认'));
      await tester.pumpAndSettle();
      expect(block.textColor, isNull);
    });

    testWidgets('标注：选择鹅黄后 highlight 写入模型，选「无」清除', (tester) async {
      final block = CanvasBlock(id: 'b1')..text = '高亮';
      await tester.pumpWidget(_ToolbarHost(block: block, onPersisted: () {}));

      await tester.tap(find.byIcon(Icons.highlight));
      await tester.pumpAndSettle();
      expect(find.text('鹅黄'), findsOneWidget);

      await tester.tap(find.text('鹅黄'));
      await tester.pumpAndSettle();
      expect(block.highlight, 'yellow');

      await tester.tap(find.byIcon(Icons.highlight));
      await tester.pumpAndSettle();
      await tester.tap(find.text('无'));
      await tester.pumpAndSettle();
      expect(block.highlight, isNull);
    });

    testWidgets('色板选择结果可序列化往返（持久化链路完整）', (tester) async {
      final block = CanvasBlock(id: 'b1')..text = '持久化';
      await tester.pumpWidget(_ToolbarHost(block: block, onPersisted: () {}));

      await tester.tap(find.byIcon(Icons.format_color_text));
      await tester.pumpAndSettle();
      await tester.tap(find.text('雾蓝'));
      await tester.pumpAndSettle();
      expect(block.textColor, 'blue');

      final restored = CanvasBlock.fromJson(block.toJson());
      expect(restored.textColor, 'blue');
    });
  });
}
