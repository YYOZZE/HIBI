import 'package:flutter/material.dart';

import '../../app/app_glass_styles.dart';
import '../../app/loading_page.dart';
import '../auth/services/user_sync_scheduler.dart';
import '../profile/value_added_page.dart';
import 'mind_canvas_page.dart';
import 'models/mind_node.dart';
import 'services/mind_repository.dart';
import 'services/mind_hbm_service.dart';

/// 思维节点 - 列表 + 详情（要义），风格与希比统一
class MindPage extends StatefulWidget {
  const MindPage({super.key});

  @override
  State<MindPage> createState() => _MindPageState();
}

class _MindPageState extends State<MindPage> {
  final MindRepository _repo = MindRepository();
  List<MindNode> _nodes = [];

  void _onSyncEpoch() {
    _repo.reloadFromDisk().then((_) {
      if (mounted) _refresh();
    });
  }

  @override
  void initState() {
    super.initState();
    UserSyncScheduler.syncEpoch.addListener(_onSyncEpoch);
    _repo.ensureLoaded().then((_) {
      if (!mounted) return;
      _refresh();
      WidgetsBinding.instance.addPostFrameCallback((_) => _importStartupFile());
    });
  }

  @override
  void dispose() {
    UserSyncScheduler.syncEpoch.removeListener(_onSyncEpoch);
    super.dispose();
  }

  void _refresh() {
    setState(() => _nodes = _repo.nodes);
  }

  Future<void> _importStartupFile() async {
    final path = MindHbmLaunchService.takePendingPath();
    if (path == null || path.isEmpty) return;
    try {
      final node = await MindHbmService.importPath(path, _repo);
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入「${node.title}」')),
      );
      await _openCanvas(node);
    } catch (e) {
      if (!mounted) return;
      await _showImportError(e);
    }
  }

  Future<void> _showImportError(Object error) async {
    final message = error is FormatException ? error.message : error.toString();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入失败'),
        content: Text(message.toString()),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('确定')),
        ],
      ),
    );
  }

  Future<void> _importProject() async {
    try {
      final node = await MindHbmService.pickAndImport(_repo);
      if (node == null || !mounted) return;
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入「${node.title}」')),
      );
      await _openCanvas(node);
    } catch (e) {
      if (mounted) await _showImportError(e);
    }
  }

  Future<void> _exportProject(MindNode node) async {
    try {
      final path = await MindHbmService.exportNode(node);
      if (path == null || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出「${node.title}」')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
  }

  Future<void> _showAddMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_box_outlined),
              title: const Text('新建思维节点'),
              subtitle: const Text('创建一个空白思维项目'),
              onTap: () => Navigator.pop(ctx, 'create'),
            ),
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('从本地导入'),
              subtitle: const Text('选择 .hbm 思维节点文件'),
              onTap: () => Navigator.pop(ctx, 'import'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'create') await _addProject();
    if (action == 'import') await _importProject();
  }

  void _openSubscriptionPage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ValueAddedPage()),
    );
  }

  /// AppBar 右侧「新建 / 订阅」统一尺寸（与助理页一致，略加大）
  ButtonStyle _appBarActionButtonStyle(BuildContext context) {
    final theme = Theme.of(context);
    return TextButton.styleFrom(
      visualDensity: const VisualDensity(horizontal: 0, vertical: -1),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      minimumSize: const Size(0, 40),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: theme.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
        fontSize: 14,
      ),
    );
  }

  Widget _buildSubscribeMiniButton(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: TextButton.icon(
        onPressed: _openSubscriptionPage,
        icon: const Icon(Icons.workspace_premium_outlined, size: 20),
        label: const Text('订阅'),
        style: _appBarActionButtonStyle(context),
      ),
    );
  }

  /// 思维页弹窗统一：高不透明度遮罩 + 实底对话框，避免背后列表/毛玻璃透视显得乱
  Future<void> _addProject() async {
    final title = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.78),
      barrierDismissible: true,
      builder: (ctx) {
        final c = TextEditingController();
        final theme = Theme.of(ctx);
        final colorScheme = theme.colorScheme;
        final dialogBg =
            theme.dialogTheme.backgroundColor ?? colorScheme.surface;
        final isLight = theme.brightness == Brightness.light;
        return AlertDialog(
          backgroundColor: dialogBg,
          surfaceTintColor: Colors.transparent,
          elevation: 12,
          shadowColor: Colors.black54,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('添加项目',
              style: theme.dialogTheme.titleTextStyle ??
                  TextStyle(color: colorScheme.onSurface)),
          content: TextField(
            controller: c,
            autofocus: true,
            style: TextStyle(color: colorScheme.onSurface),
            decoration: InputDecoration(
              hintText: '输入项目名',
              hintStyle: TextStyle(
                  color: colorScheme.onSurfaceVariant
                      .withOpacity(isLight ? 0.85 : 0.7)),
              filled: true,
              fillColor: isLight
                  ? colorScheme.surfaceContainerHighest.withOpacity(0.6)
                  : Colors.white.withOpacity(0.08),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    BorderSide(color: colorScheme.outline.withOpacity(0.35)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    BorderSide(color: colorScheme.outline.withOpacity(0.35)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                    color: colorScheme.primary.withOpacity(0.85), width: 1.2),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('取消', style: TextStyle(color: colorScheme.onSurface)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(c.text),
              child: const Text('创建'),
            ),
          ],
        );
      },
    );
    if (title != null) {
      await _repo.add(title);
      _refresh();
    }
  }

  Future<void> _openCanvas(MindNode project) async {
    if (!context.mounted) return;
    final navigator = Navigator.of(context);
    final loadingRoute = MaterialPageRoute<void>(
      builder: (_) => const LoadingPage(),
    );
    navigator.push(loadingRoute);
    try {
      await precacheImage(
        const AssetImage('xhb-image/3.png'),
        context,
      );
    } catch (_) {}
    if (!context.mounted) return;
    navigator.push(
      MaterialPageRoute<void>(
        builder: (context) => MindCanvasPage(
          project: project,
          repository: _repo,
          onSaved: _refresh,
          onLoadComplete: () {
            navigator.removeRoute(loadingRoute);
          },
        ),
      ),
    );
  }

  /// 长按后在右侧弹出的菜单：导出、重命名、标星置顶、删除
  Future<void> _showItemMenu(BuildContext itemContext, MindNode node) async {
    final box = itemContext.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;
    final screen = MediaQuery.sizeOf(itemContext);
    final menuPosition = RelativeRect.fromLTRB(
      pos.dx + size.width,
      pos.dy,
      8.0,
      screen.height - pos.dy - size.height,
    );
    final value = await showMenu<String>(
      context: itemContext,
      position: menuPosition,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      items: [
        const PopupMenuItem(
          value: 'export',
          child: ListTile(
            leading: Icon(Icons.file_download_outlined),
            title: Text('导出为 .hbm'),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 0),
          ),
        ),
        const PopupMenuItem(
          value: 'rename',
          child: ListTile(
            leading: Icon(Icons.edit_outlined),
            title: Text('重命名'),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 0),
          ),
        ),
        PopupMenuItem(
          value: 'star',
          child: ListTile(
            leading: Icon(node.isStarred ? Icons.star : Icons.star_border),
            title: Text(node.isStarred ? '取消置顶' : '标星置顶'),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: Icon(Icons.delete_outline, color: Colors.red),
            title: Text('删除', style: TextStyle(color: Colors.red)),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 0),
          ),
        ),
      ],
    );
    if (!itemContext.mounted) return;
    if (value == 'export') _exportProject(node);
    if (value == 'rename') _rename(node);
    if (value == 'star') _toggleStar(node);
    if (value == 'delete') _delete(node);
  }

  Future<void> _rename(MindNode node) async {
    final title = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.78),
      builder: (ctx) {
        final c = TextEditingController(text: node.title);
        final theme = Theme.of(ctx);
        final colorScheme = theme.colorScheme;
        final dialogBg =
            theme.dialogTheme.backgroundColor ?? colorScheme.surface;
        final isLight = theme.brightness == Brightness.light;
        return AlertDialog(
          backgroundColor: dialogBg,
          surfaceTintColor: Colors.transparent,
          elevation: 12,
          shadowColor: Colors.black54,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('重命名',
              style: theme.dialogTheme.titleTextStyle ??
                  TextStyle(color: colorScheme.onSurface)),
          content: TextField(
            controller: c,
            autofocus: true,
            style: TextStyle(color: colorScheme.onSurface),
            decoration: InputDecoration(
              hintText: '项目名称',
              hintStyle: TextStyle(
                  color: colorScheme.onSurfaceVariant
                      .withOpacity(isLight ? 0.85 : 0.7)),
              filled: true,
              fillColor: isLight
                  ? colorScheme.surfaceContainerHighest.withOpacity(0.6)
                  : Colors.white.withOpacity(0.08),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    BorderSide(color: colorScheme.outline.withOpacity(0.35)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    BorderSide(color: colorScheme.outline.withOpacity(0.35)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                    color: colorScheme.primary.withOpacity(0.85), width: 1.2),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child:
                    Text('取消', style: TextStyle(color: colorScheme.onSurface))),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(c.text),
                child: const Text('确定')),
          ],
        );
      },
    );
    if (title != null && title.trim().isNotEmpty) {
      node.title = title.trim();
      await _repo.update(node);
      _refresh();
    }
  }

  Future<void> _toggleStar(MindNode node) async {
    node.isStarred = !node.isStarred;
    await _repo.update(node);
    _refresh();
  }

  Future<void> _delete(MindNode node) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.78),
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final colorScheme = theme.colorScheme;
        final dialogBg =
            theme.dialogTheme.backgroundColor ?? colorScheme.surface;
        return AlertDialog(
          backgroundColor: dialogBg,
          surfaceTintColor: Colors.transparent,
          elevation: 12,
          shadowColor: Colors.black54,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('删除项目',
              style: theme.dialogTheme.titleTextStyle ??
                  TextStyle(color: colorScheme.onSurface)),
          content: Text('确定删除「${node.title}」？此操作不可恢复。',
              style: theme.dialogTheme.contentTextStyle ??
                  TextStyle(color: colorScheme.onSurface)),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child:
                    Text('取消', style: TextStyle(color: colorScheme.onSurface))),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('删除')),
          ],
        );
      },
    );
    if (ok == true) {
      await _repo.delete(node.id);
      _refresh();
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
        title: const Text('思维节点'),
        actions: [
          TextButton.icon(
            onPressed: _showAddMenu,
            icon: const Icon(Icons.note_add_outlined, size: 20),
            label: const Text('新建'),
            style: _appBarActionButtonStyle(context),
          ),
          _buildSubscribeMiniButton(context),
        ],
      ),
      body: _nodes.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.account_tree_outlined,
                    size: 64,
                    color: colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '暂无项目',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '点击标题栏“新建”，创建或导入思维节点',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _nodes.length,
              itemBuilder: (context, index) {
                final node = _nodes[index];
                return Builder(
                  builder: (itemContext) {
                    return AppGlassStyles.listCard(
                      context,
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: colorScheme.primaryContainer,
                          child: Icon(
                            node.isStarred ? Icons.star : Icons.edit_note,
                            color: colorScheme.onPrimaryContainer,
                            size: node.isStarred ? 20 : null,
                          ),
                        ),
                        title: Text(
                          node.title,
                          style: theme.textTheme.titleMedium,
                        ),
                        subtitle: Text(
                          '点击进入白板',
                          style: theme.textTheme.bodySmall,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (node.isStarred)
                              Icon(
                                Icons.star,
                                color: colorScheme.primary,
                                size: 20,
                              ),
                            if (node.isStarred) const SizedBox(width: 4),
                            Icon(
                              Icons.chevron_right,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                        onTap: () => _openCanvas(node),
                        onLongPress: () => _showItemMenu(itemContext, node),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}
