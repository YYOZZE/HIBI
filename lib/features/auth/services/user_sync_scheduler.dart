import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../config/api_config.dart';
import '../../assistant/services/assistant_repository.dart';
import '../../mind/services/mind_repository.dart';
import '../../schedule/schedule_event_store.dart';
import 'auth_repository.dart';
import 'user_sync_service.dart';

/// 多设备「准实时」同步：本地保存后防抖上传到服务端；回到前台或画布页定时拉取合并并刷新。
/// 白板场景：桌面端操作约 1 秒内推送到云端，手机端画布页每 2 秒拉取并刷新显示。
class UserSyncScheduler {
  UserSyncScheduler._();
  static Timer? _pushTimer;
  static bool _pushInFlight = false;
  static bool _pullCanvasInFlight = false;
  static const Duration _pushDebounce = Duration(milliseconds: 300);
  static const Duration _pullCanvasInterval = Duration(milliseconds: 500);

  /// 有登录态且非 Mock 时才同步
  static bool get _canSync {
    final u = AuthRepository.instance.currentUser;
    if (u == null) return false;
    if (u.token.startsWith('mock_')) return false;
    return ApiConfig.isAuthApiConfigured;
  }

  /// 任意思维/日程/助理写盘后调用，约 300ms 后把当前整包推送到服务器（白板近实时同步）
  /// 登出前调用，避免清空后又把空数据 push 覆盖服务器
  static void cancelPendingPush() {
    _pushTimer?.cancel();
    _pushTimer = null;
  }

  static void requestPush() {
    if (!_canSync) return;
    _pushTimer?.cancel();
    _pushTimer = Timer(_pushDebounce, _doPush);
  }

  static Future<void> _doPush() async {
    if (!_canSync || _pushInFlight) return;
    _pushInFlight = true;
    try {
      final u = AuthRepository.instance.currentUser!;
      await UserSyncService(baseUrl: ApiConfig.authApiBaseUrl).push(u.token);
    } catch (_) {}
    _pushInFlight = false;
  }

  /// 应用回到前台时调用：先取消未决 push，再拉取云端合并写盘并刷新各仓库；思维/助理通过 syncEpoch 通知页面 reload
  /// 采用「先拉后推」：避免手机端本地旧数据先 push 覆盖电脑端新数据（云端优先、合并以 updatedAt 为准）
  static final ValueNotifier<int> syncEpoch = ValueNotifier(0);

  static DateTime? _lastPull;
  static Future<void> pullAndNotify() async {
    if (!_canSync) return;
    cancelPendingPush();
    final now = DateTime.now();
    if (_lastPull != null && now.difference(_lastPull!) < const Duration(seconds: 5)) {
      return;
    }
    _lastPull = now;
    try {
      final u = AuthRepository.instance.currentUser!;
      await UserSyncService(baseUrl: ApiConfig.authApiBaseUrl).pull(u.token);
      await MindRepository.instance.reloadFromDisk();
      await ScheduleEventStore.instance.reloadFromDisk();
      await AssistantRepository().reloadFromDisk();
      syncEpoch.value++;
    } catch (_) {}
  }

  /// 画布页专用：按给定最小间隔拉取云端并刷新各仓库，供白板近实时显示其他端变更。
  /// - 不传时默认 500ms；
  /// - 可在页面侧按交互状态传更大间隔（例如空闲 2s），减少无谓网络与抖动风险。
  static DateTime? _lastPullCanvas;
  static Future<void> pullForCanvasAndNotify({Duration? minInterval}) async {
    if (!_canSync || _pullCanvasInFlight) return;
    cancelPendingPush();
    final now = DateTime.now();
    final interval = minInterval ?? _pullCanvasInterval;
    if (_lastPullCanvas != null && now.difference(_lastPullCanvas!) < interval) {
      return;
    }
    _lastPullCanvas = now;
    _pullCanvasInFlight = true;
    try {
      final u = AuthRepository.instance.currentUser!;
      await UserSyncService(baseUrl: ApiConfig.authApiBaseUrl).pull(u.token);
      await MindRepository.instance.reloadFromDisk();
      await ScheduleEventStore.instance.reloadFromDisk();
      await AssistantRepository().reloadFromDisk();
      syncEpoch.value++;
    } catch (_) {
    } finally {
      _pullCanvasInFlight = false;
    }
  }

  /// 立即推送一次（用于「保存」按钮后同步到云端）；失败抛出，便于提示网络错误
  static Future<void> pushNow() async {
    if (!_canSync) return;
    if (_pushInFlight) return;
    _pushInFlight = true;
    try {
      final u = AuthRepository.instance.currentUser!;
      await UserSyncService(baseUrl: ApiConfig.authApiBaseUrl).push(u.token);
    } finally {
      _pushInFlight = false;
    }
  }

  /// 助理对话走 `/api/chat` 工具后，服务端已更新 `user_data`；此处拉取合并到本地日程/思维/助理文件，并 bump [syncEpoch]。
  /// 使用 [UserSyncService.pull] 的 `bypassSubscriptionCheck`：仅订助理未订「数据服务」时也必须能 pull，否则会话里创建的日程在日历页不可见。
  static Future<void> pullAfterAssistantToolUse() async {
    if (!_canSync) return;
    cancelPendingPush();
    try {
      final u = AuthRepository.instance.currentUser!;
      await UserSyncService(baseUrl: ApiConfig.authApiBaseUrl).pull(
        u.token,
        bypassSubscriptionCheck: true,
      );
      await MindRepository.instance.reloadFromDisk();
      await ScheduleEventStore.instance.reloadFromDisk();
      await AssistantRepository().reloadFromDisk();
      syncEpoch.value++;
    } catch (e, st) {
      debugPrint('pullAfterAssistantToolUse 失败: $e\n$st');
    }
  }
}
