import 'package:flutter/material.dart';

import '../../app/app_glass_styles.dart';
import '../../app/frosted_background.dart';
import 'models/mind_node.dart';
import 'services/mind_repository.dart';

/// 思维节点详情：标题 + 要义编辑
class MindDetailPage extends StatefulWidget {
  const MindDetailPage({
    super.key,
    required this.node,
    required this.repository,
    required this.onSaved,
  });

  final MindNode node;
  final MindRepository repository;
  final VoidCallback onSaved;

  @override
  State<MindDetailPage> createState() => _MindDetailPageState();
}

class _MindDetailPageState extends State<MindDetailPage> {
  late TextEditingController _titleController;
  late TextEditingController _essenceController;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.node.title);
    _essenceController = TextEditingController(text: widget.node.essence);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _essenceController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    widget.node.title = _titleController.text.trim().isEmpty ? '未命名' : _titleController.text.trim();
    widget.node.essence = _essenceController.text;
    await widget.repository.update(widget.node);
    widget.onSaved();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          backgroundColor: theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          title: const Text('删除节点'),
        content: const Text('确定删除该思维节点？'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('删除'),
          ),
        ],
        );
      },
    );
    if (ok == true && mounted) {
      await widget.repository.delete(widget.node.id);
      widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('详情'),
        actions: [
          IconButton(icon: const Icon(Icons.delete_outline), onPressed: _confirmDelete, tooltip: '删除'),
          IconButton(icon: const Icon(Icons.check), onPressed: _save, tooltip: '保存'),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const SizedBox(height: 8),
              AppGlassStyles.section(
                context,
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('标题', style: theme.textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _titleController,
                        decoration: InputDecoration(
                          hintText: '输入标题',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                          filled: true,
                          fillColor: colorScheme.surfaceContainerHighest.withOpacity(0.5),
                        ),
                        style: theme.textTheme.titleMedium,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              AppGlassStyles.section(
                context,
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.lightbulb_outline, size: 20, color: colorScheme.primary),
                          const SizedBox(width: 8),
                          Text('要义', style: theme.textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _essenceController,
                        maxLines: 10,
                        minLines: 4,
                        decoration: InputDecoration(
                          hintText: '记录要点、要义…',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                          filled: true,
                          fillColor: colorScheme.surfaceContainerHighest.withOpacity(0.5),
                        ),
                        style: theme.textTheme.bodyLarge,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
