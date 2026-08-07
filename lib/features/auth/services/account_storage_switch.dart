import '../../assistant/services/assistant_repository.dart';
import '../../schedule/schedule_event_store.dart';
import 'account_storage_paths.dart';
import 'user_sync_scheduler.dart';

/// 切换活动账号目录后，统一重载日程/助理并 bump syncEpoch，思维列表页监听 epoch 后会 reloadFromDisk
Future<void> reloadStoresAfterAccountSwitch() async {
  if (AccountStoragePaths.activeKey == AccountStoragePaths.localKey) {
    await AccountStoragePaths.migrateLegacyIntoLocalIfNeeded();
  }
  await ScheduleEventStore.instance.reloadFromDisk();
  await AssistantRepository().reloadFromDisk();
  UserSyncScheduler.syncEpoch.value++;
}
