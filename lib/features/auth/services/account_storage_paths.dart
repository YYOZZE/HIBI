import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/auth_user.dart';

/// 多账号离线副本：每个账号使用独立子目录，切换账号只换 activeKey 并 reload，不删其他账号数据。
/// 目录结构：Documents/hibi_accounts/<key>/hibi_mind_nodes.json、hibi_schedule_events.json、hibi_assistant/...
/// key = `local`（未登录）或 sanitize(userId)（已登录）。
class AccountStoragePaths {
  AccountStoragePaths._();

  static const String localKey = 'local';

  /// 当前读写使用的账号键；未登录为 local
  static String _activeKey = localKey;
  static String get activeKey => _activeKey;

  /// 供 AuthRepository 在恢复/登录/登出后调用，切换活动目录
  static void setActiveUser(AuthUser? user) {
    if (user == null || user.userId.isEmpty) {
      _activeKey = localKey;
      return;
    }
    _activeKey = _sanitize(user.userId);
  }

  static String _sanitize(String id) {
    final s = id.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').trim();
    if (s.isEmpty) return localKey;
    // 避免路径过长
    return s.length > 80 ? s.substring(0, 80) : s;
  }

  static Future<Directory> _accountsRoot() async {
    final dir = await getApplicationDocumentsDirectory();
    final root = Directory('${dir.path}/hibi_accounts');
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }

  /// 当前账号的数据根目录（已 ensure 存在）
  static Future<Directory> currentAccountDir() async {
    final root = await _accountsRoot();
    final sub = Directory('${root.path}/$_activeKey');
    if (!await sub.exists()) await sub.create(recursive: true);
    return sub;
  }

  static Future<File> mindNodesFile() async {
    final dir = await currentAccountDir();
    return File('${dir.path}/hibi_mind_nodes.json');
  }

  static Future<File> scheduleEventsFile() async {
    final dir = await currentAccountDir();
    return File('${dir.path}/hibi_schedule_events.json');
  }

  static Future<Directory> assistantDir() async {
    final dir = await currentAccountDir();
    final sub = Directory('${dir.path}/hibi_assistant');
    if (!await sub.exists()) await sub.create(recursive: true);
    return sub;
  }

  /// 将旧版根目录下的文件迁移到 local，仅当 local 下对应文件不存在时执行一次
  static Future<void> migrateLegacyIntoLocalIfNeeded() async {
    if (_activeKey != localKey) return;
    final dir = await getApplicationDocumentsDirectory();
    final rootMind = File('${dir.path}/hibi_mind_nodes.json');
    final rootSchedule = File('${dir.path}/hibi_schedule_events.json');
    final rootAssistant = Directory('${dir.path}/hibi_assistant');
    final localDir = await currentAccountDir();

    Future<void> copyIfMissing(File src, File dst) async {
      if (!await src.exists() || await dst.exists()) return;
      try {
        await dst.writeAsString(await src.readAsString());
      } catch (_) {}
    }

    await copyIfMissing(rootMind, File('${localDir.path}/hibi_mind_nodes.json'));
    await copyIfMissing(rootSchedule, File('${localDir.path}/hibi_schedule_events.json'));

    if (await rootAssistant.exists()) {
      final dstAssist = Directory('${localDir.path}/hibi_assistant');
      if (!await dstAssist.exists()) await dstAssist.create(recursive: true);
      final agentsDst = File('${dstAssist.path}/assistant_agents.json');
      final agentsSrc = File('${rootAssistant.path}/assistant_agents.json');
      if (await agentsSrc.exists() && !await agentsDst.exists()) {
        try {
          await agentsDst.writeAsString(await agentsSrc.readAsString());
        } catch (_) {}
      }
      await for (final ent in rootAssistant.list()) {
        if (ent is File && ent.path.contains('messages_') && ent.path.endsWith('.json')) {
          final name = ent.uri.pathSegments.last;
          final dstFile = File('${dstAssist.path}/$name');
          if (!await dstFile.exists()) {
            try {
              await dstFile.writeAsString(await ent.readAsString());
            } catch (_) {}
          }
        }
      }
    }
  }
}
