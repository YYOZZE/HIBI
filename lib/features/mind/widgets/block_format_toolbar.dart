import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/canvas_item.dart';
import '../utils/block_text_format.dart';

/// 方块格式工具栏：对齐 / 字色 / 标注 / 加点 / 序号。
/// 选中方块即显示（不依赖文字编辑态）：
/// - 对齐/字色/标注为方块级样式，直接写 [CanvasBlock] 模型并经 [onChanged] 通知页面重建+持久化；
/// - 加点/序号经 [onApplyLineFormat] 交给页面路由：编辑态作用于当前行/选中行，预览态对全文逐行生效。
class BlockFormatToolbar extends StatelessWidget {
  const BlockFormatToolbar({
    super.key,
    required this.block,
    required this.onChanged,
    required this.onApplyLineFormat,
  });

  final CanvasBlock block;

  /// 方块级样式（对齐/字色/标注）变更后回调：页面负责 setState 重建与保存
  final VoidCallback onChanged;

  /// 加点（false）/ 序号（true）命令：由页面按编辑/预览态决定作用范围
  final ValueChanged<bool> onApplyLineFormat;

  @override
  Widget build(BuildContext context) {
    final centered = block.align == BlockStylePresets.alignCenter;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ToolbarIconButton(
          icon: centered ? Icons.format_align_center : Icons.format_align_left,
          label: '对齐',
          selected: centered,
          onTap: () {
            block.align = centered ? BlockStylePresets.alignLeft : BlockStylePresets.alignCenter;
            onChanged();
          },
        ),
        const SizedBox(height: 8),
        _StyleMenuButton(
          icon: Icons.format_color_text,
          label: '字色',
          currentKey: block.textColor ?? 'default',
          currentColor: BlockStylePresets.textColor(block.textColor),
          entries: [
            const (value: 'default', name: '默认', color: null),
            for (final e in BlockStylePresets.textColors.entries)
              (value: e.key, name: BlockStylePresets.textColorNames[e.key] ?? e.key, color: e.value),
          ],
          onSelected: (v) {
            block.textColor = v == 'default' ? null : v;
            onChanged();
          },
        ),
        const SizedBox(height: 8),
        _StyleMenuButton(
          icon: Icons.highlight,
          label: '标注',
          currentKey: block.highlight ?? 'none',
          currentColor: BlockStylePresets.highlightColor(block.highlight),
          entries: [
            const (value: 'none', name: '无', color: null),
            for (final e in BlockStylePresets.highlightColors.entries)
              (value: e.key, name: BlockStylePresets.highlightNames[e.key] ?? e.key, color: e.value),
          ],
          onSelected: (v) {
            block.highlight = v == 'none' ? null : v;
            onChanged();
          },
        ),
        const SizedBox(height: 8),
        _ToolbarIconButton(
          icon: Icons.format_list_bulleted,
          label: '加点',
          selected: false,
          onTap: () => onApplyLineFormat(false),
        ),
        const SizedBox(height: 8),
        _ToolbarIconButton(
          icon: Icons.format_list_numbered,
          label: '序号',
          selected: false,
          onTap: () => onApplyLineFormat(true),
        ),
      ],
    );
  }
}

/// 工具列图标按钮：外观与画布页左侧/线条工具列按钮一致
class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final selectedBg = selected ? colorScheme.primary.withOpacity(0.4) : Colors.transparent;
    final fg = selected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant;

    return Material(
      color: selectedBg,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 24, color: fg),
              const SizedBox(height: 4),
              Text(label, style: theme.textTheme.labelSmall?.copyWith(color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 字色/标注的小色板按钮：外观与 [_ToolbarIconButton] 一致，图标即时反映当前色。
/// 点击后用 showMenu + 手动 RelativeRect 定位（按按钮全局坐标算出，向按钮左侧弹出），
/// 不依赖 PopupMenuButton 的隐式定位，在画布 Transform 等复杂层级下位置依然可靠。
class _StyleMenuButton extends StatelessWidget {
  const _StyleMenuButton({
    required this.icon,
    required this.label,
    required this.currentKey,
    required this.currentColor,
    required this.entries,
    required this.onSelected,
  });

  final IconData icon;
  final String label;

  /// 当前生效的预设 key（无预设时用 entries 首项的哨兵值，如 default/none）
  final String currentKey;

  /// 当前预设对应颜色（用于图标着色），无预设为 null
  final Color? currentColor;
  final List<({String value, String name, Color? color})> entries;
  final ValueChanged<String> onSelected;

  /// 菜单预估宽度（含左右内边距），用于向按钮左侧翻折
  static const double _kMenuWidth = 160.0;

  Future<void> _openMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null || !box.hasSize || !overlay.hasSize) return;
    final buttonTopLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final buttonRect = buttonTopLeft & box.size;
    // 可用区域右缘 = 按钮左缘，菜单贴按钮左侧弹出；垂直方向空间不足时 showMenu 自动收拢进屏幕
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(
        math.max(0.0, buttonRect.left - _kMenuWidth),
        buttonRect.top,
        _kMenuWidth,
        buttonRect.height,
      ),
      Offset.zero & overlay.size,
    );
    final colorScheme = Theme.of(context).colorScheme;
    final selected = await showMenu<String>(
      context: context,
      position: position,
      items: [
        for (final e in entries)
          PopupMenuItem<String>(
            value: e.value,
            height: 36,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: e.color ?? Colors.transparent,
                    border: e.color == null
                        ? Border.all(color: colorScheme.onSurfaceVariant.withOpacity(0.7))
                        : null,
                  ),
                  child: e.color == null
                      ? Icon(Icons.format_clear, size: 11, color: colorScheme.onSurfaceVariant)
                      : null,
                ),
                const SizedBox(width: 8),
                Text(e.name),
                if (e.value == currentKey) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.check, size: 14, color: colorScheme.primary),
                ],
              ],
            ),
          ),
      ],
    );
    if (selected != null) onSelected(selected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Tooltip(
      message: label,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: () => _openMenu(context),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 24, color: currentColor ?? colorScheme.onSurfaceVariant),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
