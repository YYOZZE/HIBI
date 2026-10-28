import 'dart:convert';
import 'dart:io';

import '../../auth/services/account_storage_paths.dart';
import '../../mind/models/mind_node.dart';
import '../../mind/services/mind_repository.dart';
import '../models/assistant_project.dart';
import '../models/work_log_entry.dart';

/// 助理项目与工作日志。存在账号目录，换 API 不会清掉。
class AssistantProjectStore {
  AssistantProjectStore._() {
    _loadFuture = _load();
  }

  static final AssistantProjectStore instance = AssistantProjectStore._();

  late final Future<void> _loadFuture;
  final List<AssistantProject> _projects = [];
  final Map<String, List<WorkLogEntry>> _logs = {};

  Future<void> ensureLoaded() => _loadFuture;

  List<AssistantProject> get projects => List.unmodifiable(_projects);

  List<WorkLogEntry> logsOf(String projectId) =>
      List.unmodifiable(_logs[projectId] ?? const []);

  Future<void> _load() async {
    try {
      final file = await _projectsFile();
      if (await file.exists()) {
        final list = jsonDecode(await file.readAsString()) as List<dynamic>;
        _projects
          ..clear()
          ..addAll(list.map((e) => AssistantProject.fromJson(e as Map<String, dynamic>)));
        if (_isAutoSeededList()) {
          await _replaceWithExample();
        }
      } else {
        await _seedExample();
        await _saveProjects();
      }
      for (final p in _projects) {
        await _readLog(p.id);
      }
    } catch (_) {}
  }

  /// 上次打开时按思维项目整表生成的列表，换成一个未绑定的示例项目。
  bool _isAutoSeededList() {
    if (_projects.length <= 1) return false;
    return _projects.every((p) => p.id.startsWith('apr_node_'));
  }

  Future<void> _replaceWithExample() async {
    for (final p in _projects) {
      try {
        final file = await _logFile(p.id);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    _projects.clear();
    _logs.clear();
    await _seedExample();
    await _saveProjects();
  }

  Future<void> _seedExample() async {
    final p = AssistantProject(id: 'apr_example', title: '示例项目');
    _projects.add(p);
    _logs[p.id] = [
      WorkLogEntry(
        id: 'wl_example',
        at: DateTime.now(),
        kind: 'system',
        title: '示例项目',
        body: '尚未绑定思维导图。长按项目可以绑定。',
      ),
    ];
    await _writeLog(p.id);
  }

  Future<File> _projectsFile() async {
    final dir = await AccountStoragePaths.assistantDir();
    return File('${dir.path}${Platform.pathSeparator}assistant_projects.json');
  }

  Future<File> _logFile(String projectId) async {
    final dir = await AccountStoragePaths.assistantDir();
    final safe = projectId.replaceAll(RegExp(r'[^\w\-]+'), '_');
    return File('${dir.path}${Platform.pathSeparator}worklog_$safe.json');
  }

  Future<void> _readLog(String projectId) async {
    try {
      final file = await _logFile(projectId);
      if (!await file.exists()) {
        _logs[projectId] = [];
        return;
      }
      final list = jsonDecode(await file.readAsString()) as List<dynamic>;
      _logs[projectId] = list
          .map((e) => WorkLogEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      _logs[projectId] = [];
    }
  }

  Future<void> _writeLog(String projectId) async {
    final file = await _logFile(projectId);
    final list = _logs[projectId] ?? [];
    await file.writeAsString(jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  Future<void> _saveProjects() async {
    final file = await _projectsFile();
    await file.writeAsString(
      jsonEncode(_projects.map((e) => e.toJson()).toList()),
    );
  }

  Future<AssistantProject> addProject(String title) async {
    await ensureLoaded();
    final name = title.trim().isEmpty ? '未命名项目' : title.trim();
    final p = AssistantProject(
      id: 'apr_${DateTime.now().millisecondsSinceEpoch}',
      title: name,
    );
    _projects.insert(0, p);
    _logs[p.id] = [
      WorkLogEntry(
        id: 'wl_${DateTime.now().microsecondsSinceEpoch}',
        at: DateTime.now(),
        kind: 'system',
        title: '建立项目',
        body: name,
      ),
    ];
    await _saveProjects();
    await _writeLog(p.id);
    return p;
  }

  Future<void> rename(String id, String title) async {
    await ensureLoaded();
    final i = _projects.indexWhere((p) => p.id == id);
    if (i < 0) return;
    final name = title.trim().isEmpty ? '未命名项目' : title.trim();
    _projects[i].title = name;
    _projects[i].updatedAt = DateTime.now();
    await _saveProjects();
    await append(
      id,
      kind: 'system',
      title: '重命名项目',
      body: name,
    );
  }

  Future<void> bindMind(String id, String? mindNodeId, {required String note}) async {
    await ensureLoaded();
    final i = _projects.indexWhere((p) => p.id == id);
    if (i < 0) return;
    final raw = mindNodeId?.trim();
    _projects[i].mindNodeId = (raw == null || raw.isEmpty) ? null : raw;
    _projects[i].updatedAt = DateTime.now();
    await _saveProjects();
    await append(id, kind: 'system', title: note, body: _projects[i].title);
  }

  Future<void> deleteProject(String id) async {
    await ensureLoaded();
    _projects.removeWhere((p) => p.id == id);
    _logs.remove(id);
    await _saveProjects();
    try {
      final file = await _logFile(id);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> append(
    String projectId, {
    required String kind,
    required String title,
    String body = '',
    String? agentId,
    String? agentName,
  }) async {
    await ensureLoaded();
    if (!_projects.any((p) => p.id == projectId)) return;
    final list = _logs.putIfAbsent(projectId, () => []);
    list.add(
      WorkLogEntry(
        id: 'wl_${DateTime.now().microsecondsSinceEpoch}',
        at: DateTime.now(),
        kind: kind,
        title: title,
        body: body,
        agentId: agentId,
        agentName: agentName,
      ),
    );
    await _writeLog(projectId);
  }

  MindNode? mindNodeOf(AssistantProject project) {
    final id = project.mindNodeId;
    if (id == null || id.isEmpty) return null;
    for (final n in MindRepository.instance.nodes) {
      if (n.id == id) return n;
    }
    return null;
  }
}
