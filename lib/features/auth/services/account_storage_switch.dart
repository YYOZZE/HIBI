import '../../assistant/services/assistant_repository.dart';
import '../../mind/services/mind_repository.dart';
import '../../schedule/schedule_event_store.dart';
import 'account_storage_paths.dart';
import 'user_sync_scheduler.dart';

/// 切换活动账号目录后，统一重载思维/日程/助理并 bump syncEpoch。
Future<void> reloadStoresAfterAccountSwitch() async {
  if (AccountStoragePaths.activeKey == AccountStoragePaths.localKey) {
    await AccountStoragePaths.migrateLegacyIntoLocalIfNeeded();
  }
  try {
    await MindRepository.instance.reloadFromDisk();
  } catch (_) {}
  await ScheduleEventStore.instance.reloadFromDisk();
  await AssistantRepository().reloadFromDisk();
  UserSyncScheduler.syncEpoch.value++;
}
