import 'dart:convert';
import 'dart:io';


import '../../auth/services/account_storage_paths.dart';
import '../../auth/services/user_sync_scheduler.dart';
import '../models/mind_node.dart';

/// 思维节点本地持久化（单例，便于 pull 后统一 reload，避免多端同步时本地旧内存覆盖云端）
class MindRepository {
  MindRepository._() {
    _loadFuture = _load();
  }

  static final MindRepository instance = MindRepository._();

  factory MindRepository() => instance;

  late final Future<void> _loadFuture;
  final List<MindNode> _nodes = [];
  List<MindNode> get nodes => List.unmodifiable(_nodes);

  /// 确保已从磁盘加载完成（启动时列表为空时调用）
  Future<void> ensureLoaded() => _loadFuture;

  Future<File> _file() async => AccountStoragePaths.mindNodesFile();

  /// 登录后从服务端写回本地文件后调用，重新载入内存
  Future<void> reloadFromDisk() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final list = jsonDecode(await file.readAsString()) as List<dynamic>;
      _nodes.clear();
      for (final e in list) {
        _nodes.add(MindNode.fromJson(e as Map<String, dynamic>));
      }
      _nodes.sort(_compareNodes);
    } catch (_) {}
  }

  static int _compareNodes(MindNode a, MindNode b) {
    if (a.isStarred != b.isStarred) return a.isStarred ? -1 : 1;
    final c = b.updatedAt.compareTo(a.updatedAt);
    if (c != 0) return c;
    return a.id.compareTo(b.id);
  }

  Future<void> _load() async {
    try {
      if (AccountStoragePaths.activeKey == AccountStoragePaths.localKey) {
        await AccountStoragePaths.migrateLegacyIntoLocalIfNeeded();
      }
      final file = await _file();
      if (await file.exists()) {
        final list = jsonDecode(await file.readAsString()) as List<dynamic>;
        _nodes.clear();
        for (final e in list) {
          _nodes.add(MindNode.fromJson(e as Map<String, dynamic>));
        }
        _nodes.sort(_compareNodes);
      }
    } catch (_) {}
  }

  /// 写盘并请求同步；失败时抛出，便于调用方提示用户
  Future<void> _save() async {
    final file = await _file();
    await file.writeAsString(
      jsonEncode(_nodes.map((n) => n.toJson()).toList()),
    );
    UserSyncScheduler.requestPush();
  }

  Future<MindNode> add(String title, [String essence = '']) async {
    final node = MindNode(
      id: 'node_${DateTime.now().millisecondsSinceEpoch}',
      title: title.trim().isEmpty ? '未命名' : title.trim(),
      essence: essence,
    );
    _nodes.insert(0, node);
    await _save();
    return node;
  }

  /// 插入已经过格式校验和 ID 重建的导入节点。
  Future<void> addImported(MindNode node) async {
    if (_nodes.any((existing) => existing.id == node.id)) {
      throw StateError('导入节点 ID 与现有数据冲突');
    }
    _nodes.insert(0, node);
    _nodes.sort(_compareNodes);
    await _save();
  }

  Future<void> update(MindNode node) async {
    node.updatedAt = DateTime.now();
    final idx = _nodes.indexWhere((n) => n.id == node.id);
    if (idx >= 0) {
      _nodes[idx] = node;
    } else {
      _nodes.insert(0, node);
    }
    _nodes.sort(_compareNodes);
    await _save();
  }

  Future<void> delete(String id) async {
    _nodes.removeWhere((n) => n.id == id);
    await _save();
  }
}
