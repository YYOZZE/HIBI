import 'dart:io';

import 'package:flutter/material.dart';

import 'transfer_file_actions.dart';
import 'transfer_save_path.dart';

class _BrowserEntry {
  _BrowserEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size,
    this.modified,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int? size;
  final DateTime? modified;
}

enum _BrowserSort { name, modified, size }

/// 内置文件管理器：浏览接收目录及子文件夹，支持打开/删除常见文件。
class TransferFileBrowserPage extends StatefulWidget {
  const TransferFileBrowserPage({
    super.key,
    this.initialDirectory,
    this.highlightFile,
  });

  final String? initialDirectory;
  final String? highlightFile;

  @override
  State<TransferFileBrowserPage> createState() =>
      _TransferFileBrowserPageState();
}

class _TransferFileBrowserPageState extends State<TransferFileBrowserPage> {
  late String _currentDir;
  List<_BrowserEntry> _entries = [];
  bool _loading = true;
  String? _error;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  _BrowserSort _sort = _BrowserSort.name;
  bool _descending = false;

  @override
  void initState() {
    super.initState();
    _currentDir = widget.initialDirectory ?? '';
    _loadRoot();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  List<_BrowserEntry> get _visibleEntries {
    final query = _searchController.text.trim().toLowerCase();
    final visible = query.isEmpty
        ? List<_BrowserEntry>.from(_entries)
        : _entries
            .where((entry) => entry.name.toLowerCase().contains(query))
            .toList();
    visible.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      int result;
      switch (_sort) {
        case _BrowserSort.modified:
          result = (a.modified ?? DateTime.fromMillisecondsSinceEpoch(0))
              .compareTo(b.modified ?? DateTime.fromMillisecondsSinceEpoch(0));
          break;
        case _BrowserSort.size:
          result = (a.size ?? 0).compareTo(b.size ?? 0);
          break;
        case _BrowserSort.name:
          result = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
      }
      return _descending ? -result : result;
    });
    return visible;
  }

  Future<void> _loadRoot() async {
    if (_currentDir.isEmpty) {
      final dir = await TransferSavePath.getSaveDirectory();
      _currentDir = dir.path;
    }
    await _loadDirectory(_currentDir);
  }

  Future<void> _loadDirectory(String path) async {
    setState(() {
      _loading = true;
      _error = null;
      _currentDir = path;
    });
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        setState(() {
          _entries = [];
          _loading = false;
          _error = '目录不存在';
        });
        return;
      }
      final raw = <_BrowserEntry>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Directory) {
          raw.add(_BrowserEntry(
            name: entity.path.split(RegExp(r'[/\\]')).last,
            path: entity.path,
            isDirectory: true,
          ));
        } else if (entity is File) {
          final stat = await entity.stat();
          raw.add(_BrowserEntry(
            name: entity.path.split(RegExp(r'[/\\]')).last,
            path: entity.path,
            isDirectory: false,
            size: stat.size,
            modified: stat.modified,
          ));
        }
      }
      if (!mounted) return;
      setState(() {
        _entries = raw;
        _loading = false;
      });
      _scrollToHighlight();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _entries = [];
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _scrollToHighlight() {
    final target = widget.highlightFile;
    if (target == null || target.isEmpty) return;
    final idx = _entries.indexWhere((e) => e.path == target);
    if (idx < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final offset =
          (idx * 72.0).clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _goUp() async {
    final parent = Directory(_currentDir).parent;
    if (parent.path == _currentDir) return;
    await _loadDirectory(parent.path);
  }

  Future<void> _onTapEntry(_BrowserEntry entry) async {
    if (entry.isDirectory) {
      await _loadDirectory(entry.path);
      return;
    }
    if (!mounted) return;
    await TransferFileActions.openFile(context, entry.path);
  }

  Future<void> _deleteEntry(_BrowserEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除${entry.isDirectory ? '文件夹' : '文件'}'),
        content: Text('确定删除「${entry.name}」？此操作不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (entry.isDirectory) {
        await Directory(entry.path).delete(recursive: true);
      } else {
        await File(entry.path).delete();
      }
      await _loadDirectory(_currentDir);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已删除')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
    }
  }

  Future<String?> _askForName(
      {required String title, String initialValue = ''}) async {
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '名称'),
          onSubmitted: (value) => Navigator.pop(ctx, value.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  String? _validateName(String name) {
    if (name.isEmpty) return '名称不能为空';
    if (name == '.' || name == '..' || name.contains(RegExp(r'[\\/:*?"<>|]'))) {
      return '名称包含无效字符';
    }
    return null;
  }

  Future<void> _createFolder() async {
    final name = await _askForName(title: '新建文件夹');
    if (name == null) return;
    final invalid = _validateName(name);
    if (invalid != null) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(invalid)));
      return;
    }
    try {
      final target = Directory('$_currentDir${Platform.pathSeparator}$name');
      if (await target.exists() || await File(target.path).exists())
        throw const FileSystemException('名称已存在');
      await target.create();
      await _loadDirectory(_currentDir);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('新建失败：$e')));
    }
  }

  Future<void> _renameEntry(_BrowserEntry entry) async {
    final name = await _askForName(title: '重命名', initialValue: entry.name);
    if (name == null || name == entry.name) return;
    final invalid = _validateName(name);
    if (invalid != null) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(invalid)));
      return;
    }
    try {
      final target = '$_currentDir${Platform.pathSeparator}$name';
      if (await File(target).exists() || await Directory(target).exists())
        throw const FileSystemException('名称已存在');
      if (entry.isDirectory) {
        await Directory(entry.path).rename(target);
      } else {
        await File(entry.path).rename(target);
      }
      await _loadDirectory(_currentDir);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('重命名失败：$e')));
    }
  }

  Future<void> _showDetails(_BrowserEntry entry) async {
    final stat = await FileStat.stat(entry.path);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: SelectableText([
          '类型：${entry.isDirectory ? '文件夹' : '文件'}',
          if (!entry.isDirectory)
            '大小：${TransferFileActions.formatSize(stat.size)}',
          '修改时间：${stat.modified}',
          '路径：${entry.path}',
        ].join('\n')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final highlight = widget.highlightFile;
    final canGoUp = Directory(_currentDir).parent.path != _currentDir;
    final visibleEntries = _visibleEntries;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('接收文件'),
            Text(
              _currentDir.split(RegExp(r'[/\\]')).last,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: colorScheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: '新建文件夹',
            onPressed: _loading ? null : _createFolder,
          ),
          PopupMenuButton<String>(
            tooltip: '排序',
            icon: const Icon(Icons.sort),
            onSelected: (value) {
              setState(() {
                if (value == 'direction') {
                  _descending = !_descending;
                } else {
                  _sort = _BrowserSort.values
                      .firstWhere((sort) => sort.name == value);
                }
              });
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'name', child: Text('按名称排序')),
              const PopupMenuItem(value: 'modified', child: Text('按修改时间排序')),
              const PopupMenuItem(value: 'size', child: Text('按大小排序')),
              PopupMenuItem(
                  value: 'direction',
                  child: Text(_descending ? '改为升序' : '改为降序')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loading ? null : () => _loadDirectory(_currentDir),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child:
                      Text(_error!, style: TextStyle(color: colorScheme.error)))
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: TextField(
                        controller: _searchController,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: '搜索当前文件夹',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _searchController.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.clear),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {});
                                  },
                                ),
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    if (canGoUp)
                      ListTile(
                        leading: const Icon(Icons.arrow_upward),
                        title: const Text('上一级'),
                        onTap: _goUp,
                      ),
                    Expanded(
                      child: visibleEntries.isEmpty
                          ? Center(
                              child: Text(
                                _searchController.text.isEmpty
                                    ? '此文件夹为空'
                                    : '没有匹配的文件',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          : ListView.builder(
                              controller: _scrollController,
                              itemCount: visibleEntries.length,
                              itemBuilder: (context, index) {
                                final e = visibleEntries[index];
                                final isHighlight =
                                    highlight != null && e.path == highlight;
                                return Material(
                                  color: isHighlight
                                      ? colorScheme.primaryContainer
                                          .withOpacity(0.35)
                                      : null,
                                  child: ListTile(
                                    leading: Icon(
                                      TransferFileActions.iconForPath(e.path,
                                          isDirectory: e.isDirectory),
                                      color: e.isDirectory
                                          ? colorScheme.primary
                                          : colorScheme.onSurfaceVariant,
                                    ),
                                    title: Text(e.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                    subtitle: e.isDirectory
                                        ? const Text('文件夹')
                                        : Text(
                                            [
                                              if (e.size != null)
                                                TransferFileActions.formatSize(
                                                    e.size!),
                                              if (e.modified != null)
                                                '${e.modified!.month}/${e.modified!.day} ${e.modified!.hour}:${e.modified!.minute.toString().padLeft(2, '0')}',
                                            ].join(' · '),
                                          ),
                                    trailing: PopupMenuButton<String>(
                                      onSelected: (value) async {
                                        if (value == 'open') {
                                          if (e.isDirectory) {
                                            await _loadDirectory(e.path);
                                          } else if (mounted) {
                                            await TransferFileActions.openFile(
                                                context, e.path);
                                          }
                                        } else if (value == 'locate') {
                                          if (!e.isDirectory && mounted) {
                                            await TransferFileActions
                                                .openSaveLocation(
                                              context,
                                              highlightFile: e.path,
                                              directoryPath: _currentDir,
                                            );
                                          }
                                        } else if (value == 'rename') {
                                          await _renameEntry(e);
                                        } else if (value == 'details') {
                                          await _showDetails(e);
                                        } else if (value == 'delete') {
                                          await _deleteEntry(e);
                                        }
                                      },
                                      itemBuilder: (ctx) => [
                                        PopupMenuItem(
                                          value: 'open',
                                          child: Text(
                                              e.isDirectory ? '打开文件夹' : '打开文件'),
                                        ),
                                        if (!e.isDirectory)
                                          const PopupMenuItem(
                                              value: 'locate',
                                              child: Text('在目录中定位')),
                                        const PopupMenuItem(
                                            value: 'rename',
                                            child: Text('重命名')),
                                        const PopupMenuItem(
                                            value: 'details',
                                            child: Text('详情')),
                                        const PopupMenuItem(
                                            value: 'delete', child: Text('删除')),
                                      ],
                                    ),
                                    onTap: () => _onTapEntry(e),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
    );
  }
}
