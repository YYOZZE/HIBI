import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../assistant/services/assistant_repository.dart';
import '../../profile/subscription_access_service.dart';
import '../../schedule/schedule_event_store.dart';
import 'account_storage_paths.dart';
import 'sync_merge.dart';

/// 登录后从服务端拉取思维/日程/助理并写当前账号目录；退出前推送当前账号目录。
/// 与本地合并策略不变；读写均在 hibi_accounts/<activeKey>/ 下，多账号互不串。
class UserSyncService {
  UserSyncService({required this.baseUrl});
  final String baseUrl;

  String get _pullUrl => '$baseUrl/api/sync/pull';
  String get _pushUrl => '$baseUrl/api/sync/push';

  Future<void> _postPush(String token, Map<String, dynamic> body) async {
    await http
        .post(
          Uri.parse(_pushUrl),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 60));
  }

  /// 推送本地变更到服务端。
  /// - **日程**：只要已登录即可上传（多设备日历一致，不依赖「数据服务」）。
  /// - **思维 / 助理等**：需订阅「数据服务」后才随整包推送。
  Future<void> push(String token) async {
    final hasData = await SubscriptionAccessService.hasDataSyncAccess();
    final body = <String, dynamic>{};
    // 主题仅本地存储（SharedPreferences），不同步到云端；settings 可保留空对象供后续扩展
    body['settings'] = <String, dynamic>{};
    final scheduleFile = await AccountStoragePaths.scheduleEventsFile();
    if (await scheduleFile.exists()) {
      body['schedule'] = jsonDecode(await scheduleFile.readAsString());
    }

    if (!hasData) {
      // 未购数据服务：只同步日程，避免整包被拦截后「电脑建了日程、手机永远拉不到」
      if (!body.containsKey('schedule')) return;
      await _postPush(token, body);
      return;
    }

    final mindFile = await AccountStoragePaths.mindNodesFile();
    if (await mindFile.exists()) {
      body['mind'] = jsonDecode(await mindFile.readAsString());
    }
    final assistantDir = await AccountStoragePaths.assistantDir();
    if (await assistantDir.exists()) {
      final agentsFile = File('${assistantDir.path}/assistant_agents.json');
      if (await agentsFile.exists()) {
        final agents = jsonDecode(await agentsFile.readAsString());
        final messages = <String, dynamic>{};
        await for (final ent in assistantDir.list()) {
          if (ent is File && ent.path.contains('messages_') && ent.path.endsWith('.json')) {
            final name = ent.uri.pathSegments.last.replaceFirst('messages_', '').replaceFirst('.json', '');
            try {
              messages[name] = jsonDecode(await ent.readAsString());
            } catch (_) {}
          }
        }
        body['assistant'] = {'agents': agents, 'messages': messages};
      }
    }
    if (body.isEmpty) return;
    await _postPush(token, body);
  }

  /// [bypassSubscriptionCheck] 为 true 时跳过「数据服务」套餐校验（用于助理通过工具改写云端后必须拉取合并，否则仅订助理未订数据服务的用户永远看不到工具写入的日程）。
  Future<void> pull(String token, {bool bypassSubscriptionCheck = false}) async {
    final hasData = bypassSubscriptionCheck || await SubscriptionAccessService.hasDataSyncAccess();

    final res = await http
        .get(
          Uri.parse(_pullUrl),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) return;
    final data = jsonDecode(res.body) as Map<String, dynamic>?;
    if (data == null) return;

    // 未购数据服务：只合并服务端日程（与 push 对称），不覆盖本地思维/助理文件
    if (!hasData) {
      final scheduleFile = await AccountStoragePaths.scheduleEventsFile();
      List<dynamic>? localSchedule;
      if (await scheduleFile.exists()) {
        try {
          localSchedule = jsonDecode(await scheduleFile.readAsString()) as List<dynamic>?;
        } catch (_) {}
      }
      final serverSchedule = data['schedule'];
      if (serverSchedule != null && serverSchedule is List) {
        final merged = SyncMerge.mergeScheduleLists(localSchedule, serverSchedule);
        await scheduleFile.writeAsString(jsonEncode(merged));
      }
      await ScheduleEventStore.instance.reloadFromDisk();
      return;
    }

    // 1. 账号级设置：主题不参与同步，仅本地存储；此处可扩展其他需同步的 settings
    // （原 themeId 已移除，主题由 ThemeNotifier + SharedPreferences 持久化，默认暗色）

    // 2. 思维节点
    final mindFile = await AccountStoragePaths.mindNodesFile();
    List<dynamic>? localMind;
    if (await mindFile.exists()) {
      try {
        localMind = jsonDecode(await mindFile.readAsString()) as List<dynamic>?;
      } catch (_) {}
    }
    final serverMind = data['mind'];
    if (serverMind != null && serverMind is List) {
      final merged = SyncMerge.mergeMindLists(localMind, serverMind);
      await mindFile.writeAsString(jsonEncode(merged));
    }

    final scheduleFile = await AccountStoragePaths.scheduleEventsFile();
    List<dynamic>? localSchedule;
    if (await scheduleFile.exists()) {
      try {
        localSchedule = jsonDecode(await scheduleFile.readAsString()) as List<dynamic>?;
      } catch (_) {}
    }
    final serverSchedule = data['schedule'];
    if (serverSchedule != null && serverSchedule is List) {
      final merged = SyncMerge.mergeScheduleLists(localSchedule, serverSchedule);
      await scheduleFile.writeAsString(jsonEncode(merged));
    }

    final sub = await AccountStoragePaths.assistantDir();
    Map<String, dynamic>? localBundle;
    if (await sub.exists()) {
      final agentsFile = File('${sub.path}/assistant_agents.json');
      // 重要：即使 agents 文件缺失（例如旧版本/首次迁移异常），仍应读取 messages_*.json，
      // 否则 pull 时 serverAssistant 会覆盖本地消息，表现为「对话历史突然消失」。
      try {
        List<dynamic> agents = const [];
        if (await agentsFile.exists()) {
          try {
            agents = jsonDecode(await agentsFile.readAsString()) as List<dynamic>;
          } catch (_) {
            agents = const [];
          }
        }
        final messages = <String, dynamic>{};
        await for (final ent in sub.list()) {
          if (ent is File && ent.path.contains('messages_') && ent.path.endsWith('.json')) {
            final name = ent.uri.pathSegments.last.replaceFirst('messages_', '').replaceFirst('.json', '');
            try {
              messages[name] = jsonDecode(await ent.readAsString());
            } catch (_) {}
          }
        }
        // 仅当存在任一内容时才视为可合并的本地 bundle
        if (agents.isNotEmpty || messages.isNotEmpty) {
          localBundle = {'agents': agents, 'messages': messages};
        }
      } catch (_) {}
    }
    final serverAssistant = data['assistant'];
    if (serverAssistant is Map<String, dynamic> ||
        (serverAssistant != null && serverAssistant is Map)) {
      final serverMap = Map<String, dynamic>.from(serverAssistant as Map);
      final merged = SyncMerge.mergeAssistant(localBundle, serverMap);
      if (!await sub.exists()) await sub.create(recursive: true);
      await File('${sub.path}/assistant_agents.json')
          .writeAsString(jsonEncode(merged['agents']));
      final msgMap = merged['messages'];
      if (msgMap is Map) {
        for (final e in msgMap.entries) {
          await File('${sub.path}/messages_${e.key}.json')
              .writeAsString(jsonEncode(e.value));
        }
      }
    }

    await ScheduleEventStore.instance.reloadFromDisk();
    await AssistantRepository().reloadFromDisk();
  }
}
