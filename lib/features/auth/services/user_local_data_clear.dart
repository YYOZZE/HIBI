import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../schedule/schedule_event_store.dart';
import 'user_sync_scheduler.dart';

/// **已弃用**：多账号离线副本改由 [AccountStoragePaths] 按 `hibi_accounts/<userId>/` 隔离；
/// 退出登录不再清空磁盘，仅切换活动目录。若需「彻底卸载某账号本机数据」，可改为删除对应子目录。
/// 保留此类仅供必要时手动调用（例如隐私模式一键清空）。
class UserLocalDataClear {
  /// 在已成功 push 当前账户之后调用；会取消未完成的防抖 push，再清空文件与内存
  static Future<void> clearAll() async {
    UserSyncScheduler.cancelPendingPush();
    final dir = await getApplicationDocumentsDirectory();
    final mindFile = File('${dir.path}/hibi_mind_nodes.json');
    await mindFile.writeAsString(jsonEncode([]));

    final scheduleFile = File('${dir.path}/hibi_schedule_events.json');
    await scheduleFile.writeAsString(jsonEncode([]));
    ScheduleEventStore.instance.resetToEmpty();

    final assistantDir = Directory('${dir.path}/hibi_assistant');
    if (await assistantDir.exists()) {
      await for (final ent in assistantDir.list()) {
        try {
          if (ent is File) await ent.delete();
        } catch (_) {}
      }
    }

    // 通知思维/助理页从盘里重载（已是空）
    UserSyncScheduler.syncEpoch.value++;
  }
}
