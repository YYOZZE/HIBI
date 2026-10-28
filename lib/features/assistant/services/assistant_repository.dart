import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../../auth/services/account_storage_paths.dart';
import '../../auth/services/user_sync_scheduler.dart';
import '../models/agent.dart';
import '../models/chat_message.dart';
import '../models/colleague_roster.dart';
import '../models/hibi_assistant.dart';

/// 智能体与对话本地持久化（后续可改为从后端同步）
class AssistantRepository {
  AssistantRepository._internal() {
    _loadFuture = _loadAgents();
  }

  static final AssistantRepository instance = AssistantRepository._internal();

  factory AssistantRepository() => instance;

  late final Future<void> _loadFuture;
  final List<Agent> _agents = [];
  final Map<String, List<ChatMessage>> _messages = {};

  static const String _demoClearedPrefsKey = 'hibi_assistant_demo_cleared_v2';

  /// 确保已从磁盘加载完成（启动时列表为空时调用）
  Future<void> ensureLoaded() => _loadFuture;

  List<Agent> get agents => List.unmodifiable(_agents);

  List<ChatMessage> getMessages(String agentId, {String? projectId}) {
    return List.unmodifiable(_messages[_scopeKey(agentId, projectId)] ?? []);
  }

  /// 有项目时按「人 + 项目」分开存。不带项目的旧对话仍走原来的文件。
  static String _scopeKey(String agentId, String? projectId) {
    final project = projectId?.trim() ?? '';
    if (project.isEmpty) return agentId;
    return '${agentId}__$project';
  }

  Future<void> _loadAgents() async {
    try {
      if (AccountStoragePaths.activeKey == AccountStoragePaths.localKey) {
        await AccountStoragePaths.migrateLegacyIntoLocalIfNeeded();
      }
      final dir = await _dataDir();
      final file = File('${dir.path}/assistant_agents.json');
      if (await file.exists()) {
        final list = jsonDecode(await file.readAsString()) as List<dynamic>;
        _agents.clear();
        for (final e in list) {
          _agents.add(Agent.fromJson(e as Map<String, dynamic>));
        }
      }
    } catch (_) {}
    await _ensureBuiltinAndCleanupDemos();
  }

  /// 保证管家、秘书、女仆都在，名称与职能以代码为准；对话文件按 id 保留。
  Future<void> _ensureBuiltinAndCleanupDemos() async {
    final prefs = await SharedPreferences.getInstance();
    final cleared = prefs.getBool(_demoClearedPrefsKey) == true;

    if (!cleared) {
      // 一次性：去掉啊肥/肥呆/自动创建等，仅保留内置
      final keep = _agents.where((a) => a.isBuiltIn || ColleagueRoster.isStaffId(a.id)).toList();
      _agents
        ..clear()
        ..addAll(keep);
      await prefs.setBool(_demoClearedPrefsKey, true);
    }

    for (final spec in ColleagueRoster.all) {
      final idx = _agents.indexWhere((a) => a.id == spec.id);
      if (idx < 0) {
        _agents.add(spec.toAgent());
      } else {
        final old = _agents[idx];
        _agents[idx] = spec.toAgent(createdAt: old.createdAt);
      }
    }
    _sortAgents();
    await _saveAgents();
  }

  void _sortAgents() {
    _agents.sort((a, b) {
      final rank = ColleagueRoster.rankOf(a.id).compareTo(ColleagueRoster.rankOf(b.id));
      if (rank != 0) return rank;
      return b.createdAt.compareTo(a.createdAt);
    });
  }

  Future<void> _saveAgents() async {
    try {
      final dir = await _dataDir();
      final file = File('${dir.path}/assistant_agents.json');
      await file.writeAsString(jsonEncode(_agents.map((a) => a.toJson()).toList()));
      UserSyncScheduler.requestPush();
    } catch (_) {}
  }

  Future<Directory> _dataDir() async => AccountStoragePaths.assistantDir();

  Future<Agent> addAgent(String name, [String role = '']) async {
    await ensureLoaded();
    final agent = Agent(
      id: 'agent_${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim().isEmpty ? '未命名智能体' : name.trim(),
      role: role.trim(),
    );
    _agents.insert(0, agent);
    _sortAgents();
    await _saveAgents();
    return agent;
  }

  /// 白板「助理」入口：统一打开内置希比助手（不再为每个项目建 demo 助理）
  Future<Agent> findOrCreateAgentForMindNode(
    String projectTitle,
    String projectId,
  ) async {
    await ensureLoaded();
    await _ensureBuiltinAndCleanupDemos();
    return _agents.firstWhere((a) => a.id == HibiAssistant.id);
  }

  Future<void> updateAgentName(String id, String name) async {
    if (ColleagueRoster.isStaffId(id)) return;
    final i = _agents.indexWhere((a) => a.id == id);
    if (i >= 0) {
      _agents[i].name = name.trim().isEmpty ? '未命名智能体' : name.trim();
      await _saveAgents();
    }
  }

  Future<void> updateAgentRole(String id, String role) async {
    if (ColleagueRoster.isStaffId(id)) return;
    final i = _agents.indexWhere((a) => a.id == id);
    if (i >= 0) {
      _agents[i].role = role.trim();
      await _saveAgents();
    }
  }

  Future<void> deleteAgent(String id) async {
    if (ColleagueRoster.isStaffId(id)) return;
    _agents.removeWhere((a) => a.id == id);
    _messages.remove(id);
    await _saveAgents();
    await _deleteMessagesFile(id);
  }

  Future<void> _deleteMessagesFile(String agentId) async {
    try {
      final dir = await _dataDir();
      final file = File('${dir.path}/messages_$agentId.json');
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 按 agent 串行落盘，避免并发 _saveMessages 互相覆盖。
  final Map<String, Future<void>> _saveLocks = {};

  Future<void> addMessage(String agentId, ChatMessage message, {String? projectId}) async {
    final key = _scopeKey(agentId, projectId);
    _messages.putIfAbsent(key, () => []).add(message);
    await _saveMessages(key);
  }

  /// 用服务端消息列表替换本地缓存（按 id 去重）
  Future<void> replaceMessages(
    String agentId,
    List<ChatMessage> messages, {
    String? projectId,
  }) async {
    final key = _scopeKey(agentId, projectId);
    _messages[key] = List<ChatMessage>.from(messages);
    await _saveMessages(key);
  }

  /// 按消息 id 删除单条（不存在则忽略）
  Future<void> removeMessageById(String agentId, String messageId, {String? projectId}) async {
    final key = _scopeKey(agentId, projectId);
    final list = _messages[key];
    if (list == null) return;
    list.removeWhere((m) => m.id == messageId);
    await _saveMessages(key);
  }

  /// 批量按 id 删除；删完后持久化一次
  Future<void> removeMessagesByIds(
    String agentId,
    Set<String> messageIds, {
    String? projectId,
  }) async {
    if (messageIds.isEmpty) return;
    final key = _scopeKey(agentId, projectId);
    final list = _messages[key];
    if (list == null) return;
    list.removeWhere((m) => messageIds.contains(m.id));
    await _saveMessages(key);
  }

  Future<void> _saveMessages(String scopeKey) async {
    final prev = _saveLocks[scopeKey] ?? Future<void>.value();
    final done = Completer<void>();
    _saveLocks[scopeKey] = done.future;
    await prev;
    try {
      final list = List<ChatMessage>.from(_messages[scopeKey] ?? const []);
      final dir = await _dataDir();
      final file = File('${dir.path}/messages_$scopeKey.json');
      await file.writeAsString(jsonEncode(list.map((m) => m.toJson()).toList()));
      UserSyncScheduler.requestPush();
    } catch (_) {
    } finally {
      done.complete();
      if (identical(_saveLocks[scopeKey], done.future)) {
        _saveLocks.remove(scopeKey);
      }
    }
  }

  /// 登录后从服务端写回 assistant 目录后调用：清空内存并重新加载
  Future<void> reloadFromDisk() async {
    try {
      _messages.clear();
      final dir = await _dataDir();
      final agentsFile = File('${dir.path}/assistant_agents.json');
      if (await agentsFile.exists()) {
        final list = jsonDecode(await agentsFile.readAsString()) as List<dynamic>;
        _agents.clear();
        for (final e in list) {
          _agents.add(Agent.fromJson(e as Map<String, dynamic>));
        }
      }
      await _ensureBuiltinAndCleanupDemos();
      for (final agent in _agents) {
        await loadMessages(agent.id, force: true);
      }
    } catch (_) {}
  }

  /// [force] 为 true 时强制从磁盘重读（覆盖内存）
  Future<void> loadMessages(String agentId, {bool force = false, String? projectId}) async {
    final key = _scopeKey(agentId, projectId);
    if (!force && _messages.containsKey(key)) return;
    try {
      final dir = await _dataDir();
      final file = File('${dir.path}/messages_$key.json');
      if (await file.exists()) {
        final list = jsonDecode(await file.readAsString()) as List<dynamic>;
        _messages[key] =
            list.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>)).toList();
      } else {
        _messages[key] = [];
      }
    } catch (_) {
      _messages[key] = [];
    }
  }
}
