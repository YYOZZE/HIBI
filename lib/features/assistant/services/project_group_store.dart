import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../auth/services/account_storage_paths.dart';
import '../models/colleague_roster.dart';
import '../models/project_group.dart';

/// 项目群聊。每个人的私聊文件不动，这里只存共享讨论。
class ProjectGroupStore {
  ProjectGroupStore._() {
    _loadFuture = _load();
  }

  static final ProjectGroupStore instance = ProjectGroupStore._();

  /// 左侧当前选中的助理项目。管家建群时用它，不新建人员。
  static String? focusedProjectId;

  /// 群聊里正在发言的助手 id。指示灯读这个值。
  static final speakingId = ValueNotifier<String?>(null);

  final revision = ValueNotifier<int>(0);

  late final Future<void> _loadFuture;
  final List<ProjectGroup> _groups = [];
  final Map<String, List<GroupMessage>> _messages = {};

  Future<void> ensureLoaded() => _loadFuture;

  List<ProjectGroup> groupsFor(String projectId) {
    final list = _groups.where((g) => g.projectId == projectId).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  ProjectGroup? find(String id) {
    for (final g in _groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  List<GroupMessage> messagesOf(String groupId) =>
      List.unmodifiable(_messages[groupId] ?? const []);

  Future<void> _load() async {
    try {
      final file = await _indexFile();
      if (!await file.exists()) return;
      final list = jsonDecode(await file.readAsString()) as List<dynamic>;
      _groups
        ..clear()
        ..addAll(list.map((e) => ProjectGroup.fromJson(e as Map<String, dynamic>)));
      for (final g in _groups) {
        await _readMessages(g.id);
      }
    } catch (_) {}
  }

  Future<File> _indexFile() async {
    final dir = await AccountStoragePaths.assistantDir();
    return File('${dir.path}${Platform.pathSeparator}project_groups.json');
  }

  Future<File> _messageFile(String groupId) async {
    final dir = await AccountStoragePaths.assistantDir();
    final safe = groupId.replaceAll(RegExp(r'[^\w\-]+'), '_');
    return File('${dir.path}${Platform.pathSeparator}groupmsg_$safe.json');
  }

  Future<void> _readMessages(String groupId) async {
    try {
      final file = await _messageFile(groupId);
      if (!await file.exists()) {
        _messages[groupId] = [];
        return;
      }
      final list = jsonDecode(await file.readAsString()) as List<dynamic>;
      _messages[groupId] =
          list.map((e) => GroupMessage.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      _messages[groupId] = [];
    }
  }

  Future<void> _writeMessages(String groupId) async {
    final file = await _messageFile(groupId);
    final list = _messages[groupId] ?? [];
    await file.writeAsString(jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  Future<void> _saveIndex() async {
    final file = await _indexFile();
    await file.writeAsString(jsonEncode(_groups.map((e) => e.toJson()).toList()));
    revision.value++;
  }

  /// 管家建群。管家本人始终在成员里，其余名字必须对上固定编制。
  Future<ProjectGroup> create({
    required String projectId,
    required String title,
    required String purpose,
    required List<String> memberTokens,
  }) async {
    await ensureLoaded();
    final members = _resolveMembers(memberTokens);
    if (members.length < 2) {
      throw StateError('至少再点名一位现有的秘书或女仆');
    }
    final group = ProjectGroup(
      id: 'grp_${DateTime.now().millisecondsSinceEpoch}',
      projectId: projectId,
      title: title.trim().isEmpty ? '未命名群聊' : title.trim(),
      purpose: purpose.trim(),
      memberIds: members.map((s) => s.id).toList(),
    );
    _groups.insert(0, group);
    final names = members.map((s) => s.name).join('、');
    _messages[group.id] = [
      GroupMessage(
        id: 'gm_${DateTime.now().microsecondsSinceEpoch}',
        at: DateTime.now(),
        speakerId: ColleagueRoster.butlerId,
        speakerName: ColleagueRoster.butler.name,
        content: purpose.trim().isEmpty
            ? '我按这个项目开了群聊，在场的有 $names。'
            : '我按这个项目开了群聊：${purpose.trim()}。在场的有 $names。',
      ),
    ];
    await _writeMessages(group.id);
    await _saveIndex();
    return group;
  }

  List<StaffSpec> _resolveMembers(List<String> tokens) {
    final picked = <StaffSpec>[ColleagueRoster.butler];
    final seen = <String>{ColleagueRoster.butlerId};
    for (final raw in tokens) {
      final spec = _matchStaff(raw);
      if (spec == null || !seen.add(spec.id)) continue;
      picked.add(spec);
    }
    return picked;
  }

  StaffSpec? _matchStaff(String raw) {
    final t = raw.trim().toLowerCase();
    if (t.isEmpty) return null;
    for (final s in ColleagueRoster.all) {
      final name = s.name.toLowerCase();
      if (s.id == raw.trim() || name == t || name.endsWith(t) || t.endsWith(name)) {
        return s;
      }
    }
    return null;
  }

  Future<void> append(
    String groupId, {
    required String speakerId,
    required String speakerName,
    required String content,
  }) async {
    await ensureLoaded();
    if (find(groupId) == null) return;
    final text = content.trim();
    if (text.isEmpty) return;
    final list = _messages.putIfAbsent(groupId, () => []);
    list.add(
      GroupMessage(
        id: 'gm_${DateTime.now().microsecondsSinceEpoch}',
        at: DateTime.now(),
        speakerId: speakerId,
        speakerName: speakerName,
        content: text,
      ),
    );
    await _writeMessages(groupId);
    revision.value++;
  }
}
