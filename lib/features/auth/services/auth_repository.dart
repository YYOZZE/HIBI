import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../config/api_config.dart';
import '../models/auth_user.dart';
import 'auth_api.dart';
import 'account_storage_paths.dart';
import 'account_storage_switch.dart';
import 'user_sync_scheduler.dart';
import 'user_sync_service.dart';

const String _keyToken = 'hibi_auth_token';
const String _keyUserId = 'hibi_auth_user_id';
const String _keyPhoneOrEmail = 'hibi_auth_phone_or_email';
const String _keyNickname = 'hibi_auth_nickname';
const String _keyAvatarUrl = 'hibi_auth_avatar_url';

/// 账户状态与持久化：单例，应用内唯一
/// 启动时从 SharedPreferences 恢复；登录/注册成功后写入并通知；退出/更换账户时清除并通知
class AuthRepository {
  AuthRepository._() {
    _loadFuture = _loadFromPrefs();
  }

  static AuthRepository? _instance;
  static AuthRepository get instance {
    _instance ??= AuthRepository._();
    return _instance!;
  }

  final ValueNotifier<AuthUser?> currentUserNotifier = ValueNotifier<AuthUser?>(null);

  AuthUser? get currentUser => currentUserNotifier.value;

  AuthApi? _api;
  AuthApi? get authApi => _api;
  set authApi(AuthApi? value) => _api = value;

  Future<void> _loadFuture = Future<void>.value();
  /// 启动时等待此 Future，确保已从本地恢复登录状态后再决定显示登录页或主壳
  Future<void> ensureLoaded() => _loadFuture;

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_keyToken);
    if (token == null || token.isEmpty) {
      currentUserNotifier.value = null;
      AccountStoragePaths.setActiveUser(null);
      return;
    }
    final userId = prefs.getString(_keyUserId) ?? '';
    final phoneOrEmail = prefs.getString(_keyPhoneOrEmail) ?? '';
    final nickname = prefs.getString(_keyNickname);
    final avatarUrl = prefs.getString(_keyAvatarUrl);
    final user = AuthUser(
      userId: userId,
      phoneOrEmail: phoneOrEmail,
      nickname: nickname,
      avatarUrl: avatarUrl,
      token: token,
    );
    currentUserNotifier.value = user;
    AccountStoragePaths.setActiveUser(user);
    await reloadStoresAfterAccountSwitch();
  }

  Future<void> _saveToPrefs(AuthUser user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyToken, user.token);
    await prefs.setString(_keyUserId, user.userId);
    await prefs.setString(_keyPhoneOrEmail, user.phoneOrEmail);
    await prefs.setString(_keyNickname, user.nickname ?? '');
    await prefs.setString(_keyAvatarUrl, user.avatarUrl ?? '');
  }

  Future<void> _clearPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyToken);
    await prefs.remove(_keyUserId);
    await prefs.remove(_keyPhoneOrEmail);
    await prefs.remove(_keyNickname);
    await prefs.remove(_keyAvatarUrl);
  }

  /// 登录：调用 API 后写入本地并通知
  Future<AuthUser> login(
    String phoneOrEmail,
    String password, {
    String? captchaPlatform,
    String? captchaChallengeId,
    String? lotNumber,
    String? captchaOutput,
    String? passToken,
    String? genTime,
  }) async {
    if (_api != null) {
      final user = await _api!.login(
        phoneOrEmail,
        password,
        captchaPlatform: captchaPlatform,
        captchaChallengeId: captchaChallengeId,
        lotNumber: lotNumber,
        captchaOutput: captchaOutput,
        passToken: passToken,
        genTime: genTime,
      );
      if (user == null) throw Exception('登录失败，请检查账号或密码');
      await _saveToPrefs(user);
      currentUserNotifier.value = user;
      AccountStoragePaths.setActiveUser(user);
      if (ApiConfig.isAuthApiConfigured) {
        try {
          final sync = UserSyncService(baseUrl: ApiConfig.authApiBaseUrl);
          await sync.pull(user.token);
          // 合并后的数据推回服务端，避免云端仍为空、下次换设备丢失本地阶段数据
          await sync.push(user.token);
        } catch (_) {}
      }
      await reloadStoresAfterAccountSwitch();
      return user;
    }
    // 未配置后端时使用本地 Mock，便于前端联调
    final user = AuthUser(
      userId: 'local_${DateTime.now().millisecondsSinceEpoch}',
      phoneOrEmail: phoneOrEmail,
      nickname: null,
        avatarUrl: null,
      token: 'mock_token_${phoneOrEmail.hashCode}',
    );
    await _saveToPrefs(user);
    currentUserNotifier.value = user;
    AccountStoragePaths.setActiveUser(user);
    await reloadStoresAfterAccountSwitch();
    return user;
  }

  /// 注册：调用 API 后写入本地并通知（后端要求邀请码时须传入 inviteCode）
  Future<AuthUser> register({
    required String phoneOrEmail,
    required String password,
    String? nickname,
    String? inviteCode,
    String? captchaPlatform,
    String? captchaChallengeId,
    String? lotNumber,
    String? captchaOutput,
    String? passToken,
    String? genTime,
  }) async {
    if (_api != null) {
      final user = await _api!.register(
        phoneOrEmail: phoneOrEmail,
        password: password,
        nickname: nickname,
        inviteCode: inviteCode,
        captchaPlatform: captchaPlatform,
        captchaChallengeId: captchaChallengeId,
        lotNumber: lotNumber,
        captchaOutput: captchaOutput,
        passToken: passToken,
        genTime: genTime,
      );
      if (user == null) throw Exception('注册失败');
      await _saveToPrefs(user);
      currentUserNotifier.value = user;
      AccountStoragePaths.setActiveUser(user);
      if (ApiConfig.isAuthApiConfigured) {
        try {
          final sync = UserSyncService(baseUrl: ApiConfig.authApiBaseUrl);
          await sync.pull(user.token);
          await sync.push(user.token);
        } catch (_) {}
      }
      await reloadStoresAfterAccountSwitch();
      return user;
    }
    final user = AuthUser(
      userId: 'local_${DateTime.now().millisecondsSinceEpoch}',
      phoneOrEmail: phoneOrEmail,
      nickname: nickname,
      avatarUrl: null,
      token: 'mock_token_${phoneOrEmail.hashCode}',
    );
    await _saveToPrefs(user);
    currentUserNotifier.value = user;
    AccountStoragePaths.setActiveUser(user);
    await reloadStoresAfterAccountSwitch();
    return user;
  }

  /// 退出登录 / 更换账户：先推送本地数据到服务端，再注销 token、清除本地
  Future<void> logout() async {
    final token = currentUser?.token;
    if (ApiConfig.isAuthApiConfigured && token != null && !token.startsWith('mock_')) {
      try {
        await UserSyncService(baseUrl: ApiConfig.authApiBaseUrl).push(token);
      } catch (_) {}
    }
    if (_api != null && token != null) {
      try {
        await _api!.logout(token);
      } catch (_) {}
    }
    // 多账号离线副本：不删其他账号目录；只取消未决 push、切回 local 并重载，避免串数据
    UserSyncScheduler.cancelPendingPush();
    AccountStoragePaths.setActiveUser(null);
    try {
      await reloadStoresAfterAccountSwitch();
    } catch (_) {}
    await _clearPrefs();
    currentUserNotifier.value = null;
  }

  /// 更新本地资料，并在已登录且后端可用时同步昵称（可选头像 URL）
  Future<AuthUser?> updateProfile({
    String? nickname,
    String? avatarUrl,
  }) async {
    final current = currentUser;
    if (current == null) return null;
    var next = current.copyWith(
      nickname: nickname ?? current.nickname,
      avatarUrl: avatarUrl ?? current.avatarUrl,
    );
    if (_api != null && !current.token.startsWith('mock_')) {
      try {
        final remote = await _api!.updateProfile(
          current.token,
          nickname: nickname,
          avatarUrl: (avatarUrl != null && avatarUrl.startsWith('http')) ? avatarUrl : null,
        );
        if (remote != null) {
          next = next.copyWith(
            nickname: remote.nickname,
            avatarUrl: (avatarUrl ?? '').isNotEmpty ? avatarUrl : remote.avatarUrl,
          );
        }
      } catch (_) {}
    }
    await _saveToPrefs(next);
    currentUserNotifier.value = next;
    return next;
  }
}
