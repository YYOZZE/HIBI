import 'dart:convert';

/// 登录后拉取云端数据时，与当前本地数据合并，避免未登录阶段产生的数据被整文件覆盖掉。
class SyncMerge {
  /// 思维节点列表：按 id 合并，同一 id 保留 updatedAt 较新的一条（ISO 字符串可比较）。
  static List<dynamic> mergeMindLists(List<dynamic>? local, List<dynamic>? server) {
    final map = <String, Map<String, dynamic>>{};
    void put(Map<String, dynamic> e) {
      final id = e['id']?.toString();
      if (id == null || id.isEmpty) return;
      final existing = map[id];
      if (existing == null) {
        map[id] = Map<String, dynamic>.from(e);
        return;
      }
      final lu = existing['updatedAt']?.toString() ?? '';
      final su = e['updatedAt']?.toString() ?? '';
      if (su.compareTo(lu) >= 0) {
        map[id] = Map<String, dynamic>.from(e);
      }
    }

    if (local != null) {
      for (final e in local) {
        if (e is Map<String, dynamic>) put(e);
      }
    }
    if (server != null) {
      for (final e in server) {
        if (e is Map<String, dynamic>) put(e);
      }
    }
    return map.values.toList();
  }

  /// 日程列表：按 id 合并；同一 id 优先保留本地（未登录时改的日程不被云端旧数据覆盖），
  /// 仅存在于云端的 id 会加入。
  static List<dynamic> mergeScheduleLists(List<dynamic>? local, List<dynamic>? server) {
    final map = <String, Map<String, dynamic>>{};
    void putFrom(dynamic raw) {
      if (raw is! Map) return;
      final e = Map<String, dynamic>.from(raw);
      final id = e['id']?.toString();
      if (id == null || id.isEmpty) return;
      map[id] = e;
    }

    if (server != null) {
      for (final e in server) {
        putFrom(e);
      }
    }
    if (local != null) {
      for (final e in local) {
        putFrom(e);
      }
    }
    return map.values.toList();
  }

  /// 助理：agents 按 id 合并（同 mind，无 updatedAt 时后写覆盖先写，故先 server 后 local 保留本地同 id）。
  static Map<String, dynamic> mergeAssistant(
    Map<String, dynamic>? localBundle,
    Map<String, dynamic>? serverBundle,
  ) {
    final agents = <String, Map<String, dynamic>>{};
    final messages = <String, List<dynamic>>{};

    void mergeAgents(List<dynamic>? list, bool localWins) {
      if (list == null) return;
      for (final e in list) {
        if (e is! Map<String, dynamic>) continue;
        final id = e['id']?.toString();
        if (id == null || id.isEmpty) continue;
        if (localWins || !agents.containsKey(id)) {
          agents[id] = Map<String, dynamic>.from(e);
        }
      }
    }

    void mergeMessages(Map<String, dynamic>? m, bool fromServerFirst) {
      if (m == null) return;
      for (final e in m.entries) {
        final key = e.key;
        final list = e.value;
        if (list is! List) continue;
        final existing = messages[key] ?? <dynamic>[];
        if (fromServerFirst) {
          messages[key] = _dedupeMessages([...existing, ...list]);
        } else {
          messages[key] = _dedupeMessages([...list, ...existing]);
        }
      }
    }

    // 先合并 server 再合并 local，agents 同 id 以 local 为准；messages 拼接去重
    if (serverBundle != null) {
      mergeAgents(serverBundle['agents'] as List<dynamic>?, false);
      mergeMessages(serverBundle['messages'] as Map<String, dynamic>?, true);
    }
    if (localBundle != null) {
      mergeAgents(localBundle['agents'] as List<dynamic>?, true);
      mergeMessages(localBundle['messages'] as Map<String, dynamic>?, false);
    }

    return {
      'agents': agents.values.toList(),
      'messages': messages.map((k, v) => MapEntry(k, v)),
    };
  }

  /// 按时间戳+role+content 简单去重，避免重复条数爆炸
  static List<dynamic> _dedupeMessages(List<dynamic> list) {
    final seen = <String>{};
    final out = <dynamic>[];
    for (final e in list) {
      if (e is! Map) continue;
      final role = e['role']?.toString() ?? '';
      final content = e['content']?.toString() ?? '';
      final ts = e['timestamp']?.toString() ?? '';
      final key = '$role|$ts|$content';
      if (seen.add(key)) out.add(e);
    }
    return out;
  }
}
