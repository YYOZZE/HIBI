import 'dart:convert';
import 'dart:io';


import '../../auth/services/account_storage_paths.dart';
import '../../auth/services/user_sync_scheduler.dart';
import '../models/agent.dart';
import '../models/chat_message.dart';

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

  /// 确保已从磁盘加载完成（启动时列表为空时调用）
  Future<void> ensureLoaded() => _loadFuture;

  List<Agent> get agents => List.unmodifiable(_agents);

  List<ChatMessage> getMessages(String agentId) {
    return List.unmodifiable(_messages[agentId] ?? []);
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
    final agent = Agent(
      id: 'agent_${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim().isEmpty ? '未命名智能体' : name.trim(),
      role: role.trim(),
    );
    _agents.insert(0, agent);
    await _saveAgents();
    return agent;
  }

  /// 按项目（思维节点）查找或创建「项目名（自动创建）」的助理；用于白板「助理」入口。
  Future<Agent> findOrCreateAgentForMindNode(String projectTitle, String projectId) async {
    await ensureLoaded();
    final name = '${projectTitle.trim().isEmpty ? "未命名项目" : projectTitle.trim()}（自动创建）';
    for (final a in _agents) {
      if (a.isAutoCreated && ((a.mindNodeId ?? '') == projectId || a.name == name)) return a;
    }
    final agent = Agent(
      id: 'agent_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      role: '',
      isAutoCreated: true,
      mindNodeId: projectId,
    );
    _agents.insert(0, agent);
    await _saveAgents();
    return agent;
  }

  Future<void> updateAgentName(String id, String name) async {
    final i = _agents.indexWhere((a) => a.id == id);
    if (i >= 0) {
      _agents[i].name = name.trim().isEmpty ? '未命名智能体' : name.trim();
      await _saveAgents();
    }
  }

  Future<void> updateAgentRole(String id, String role) async {
    final i = _agents.indexWhere((a) => a.id == id);
    if (i >= 0) {
      _agents[i].role = role.trim();
      await _saveAgents();
    }
  }

  Future<void> deleteAgent(String id) async {
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

  void addMessage(String agentId, ChatMessage message) {
    _messages.putIfAbsent(agentId, () => []).add(message);
    _saveMessages(agentId);
  }

  /// 按消息 id 删除单条（不存在则忽略）
  void removeMessageById(String agentId, String messageId) {
    final list = _messages[agentId];
    if (list == null) return;
    list.removeWhere((m) => m.id == messageId);
    _saveMessages(agentId);
  }

  /// 批量按 id 删除；删完后持久化一次
  void removeMessagesByIds(String agentId, Set<String> messageIds) {
    if (messageIds.isEmpty) return;
    final list = _messages[agentId];
    if (list == null) return;
    list.removeWhere((m) => messageIds.contains(m.id));
    _saveMessages(agentId);
  }

  Future<void> _saveMessages(String agentId) async {
    try {
      final list = _messages[agentId] ?? [];
      final dir = await _dataDir();
      final file = File('${dir.path}/messages_$agentId.json');
      await file.writeAsString(jsonEncode(list.map((m) => m.toJson()).toList()));
      UserSyncScheduler.requestPush();
    } catch (_) {}
  }

  /// 登录后从服务端写回 assistant 目录后调用：清空内存并重新加载
  Future<void> reloadFromDisk() async {
    try {
      _messages.clear();
      final dir = await _dataDir();
      final agentsFile = File('${dir.path}/assistant_agents.json');
      // 若 agents 文件缺失/损坏，不能直接把内存消息清空后不再加载，否则聊天页会表现为“只剩一条/看不到历史”。
      // 策略：优先用磁盘 agents 覆盖；若磁盘不可用，则保留当前内存 _agents，并仍然尝试加载 messages_<agentId>.json。
      if (await agentsFile.exists()) {
        final list = jsonDecode(await agentsFile.readAsString()) as List<dynamic>;
        _agents.clear();
        for (final e in list) {
          _agents.add(Agent.fromJson(e as Map<String, dynamic>));
        }
      }
      for (final agent in _agents) {
        await loadMessages(agent.id);
      }
    } catch (_) {}
  }

  Future<void> loadMessages(String agentId) async {
    if (_messages.containsKey(agentId)) return;
    try {
      final dir = await _dataDir();
      final file = File('${dir.path}/messages_$agentId.json');
      if (await file.exists()) {
        final list = jsonDecode(await file.readAsString()) as List<dynamic>;
        _messages[agentId] = list.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>)).toList();
      } else {
        _messages[agentId] = [];
      }
    } catch (_) {
      _messages[agentId] = [];
    }
  }
}
