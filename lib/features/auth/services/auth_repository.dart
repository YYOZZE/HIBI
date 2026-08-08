import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../config/api_config.dart';
import '../models/auth_user.dart';
import 'auth_api.dart';
import 'account_storage_paths.dart';
import 'account_storage_switch.dart';
import 'github_oauth_service.dart';
import 'user_sync_scheduler.dart';
import 'user_sync_service.dart';

const String _keyToken = 'hibi_auth_token';
const String _keyUserId = 'hibi_auth_user_id';
const String _keyPhoneOrEmail = 'hibi_auth_phone_or_email';
const String _keyNickname = 'hibi_auth_nickname';
const String _keyAvatarUrl = 'hibi_auth_avatar_url';
const String _keyGithubLogin = 'hibi_auth_github_login';
const String _keyAuthProvider = 'hibi_auth_provider';
const String _keyStarred = 'hibi_github_starred';

/// 账户状态与持久化：单例，应用内唯一。
/// 3.3.8+ 门禁以 GitHub OAuth + Star 为准；旧版手机号/Mock 不再视为有效登录。
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

  /// 已通过 GitHub Star 校验时可进入主壳。
  final ValueNotifier<bool> githubAccessGrantedNotifier = ValueNotifier<bool>(false);

  AuthUser? get currentUser => currentUserNotifier.value;

  bool get canEnterApp {
    final u = currentUser;
    return u != null && u.isGitHub && githubAccessGrantedNotifier.value;
  }

  AuthApi? _api;
  AuthApi? get authApi => _api;
  set authApi(AuthApi? value) => _api = value;

  Future<void> _loadFuture = Future<void>.value();
  Future<void> ensureLoaded() => _loadFuture;

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    var token = prefs.getString(_keyToken);
    final secure = await GitHubOAuthService.instance.readTokenSecurely();
    if (secure != null && secure.isNotEmpty) {
      token = secure;
    }
    if (token == null || token.isEmpty) {
      currentUserNotifier.value = null;
      githubAccessGrantedNotifier.value = false;
      AccountStoragePaths.setActiveUser(null);
      return;
    }
    final userId = prefs.getString(_keyUserId) ?? '';
    final phoneOrEmail = prefs.getString(_keyPhoneOrEmail) ?? '';
    final nickname = prefs.getString(_keyNickname);
    final avatarUrl = prefs.getString(_keyAvatarUrl);
    final githubLogin = prefs.getString(_keyGithubLogin);
    var provider = prefs.getString(_keyAuthProvider) ?? 'legacy';
    if ((githubLogin != null && githubLogin.isNotEmpty) ||
        token.startsWith('gho_') ||
        token.startsWith('ghu_') ||
        token.startsWith('github_pat_')) {
      provider = 'github';
    }
    final user = AuthUser(
      userId: userId,
      phoneOrEmail: phoneOrEmail,
      nickname: nickname,
      avatarUrl: avatarUrl,
      token: token,
      githubLogin: githubLogin,
      authProvider: provider,
    );

    // 旧版非 GitHub 登录不再放行门禁
    if (!user.isGitHub) {
      await _clearPrefs();
      await GitHubOAuthService.instance.clearTokenSecurely();
      currentUserNotifier.value = null;
      githubAccessGrantedNotifier.value = false;
      AccountStoragePaths.setActiveUser(null);
      return;
    }

    currentUserNotifier.value = user;
    AccountStoragePaths.setActiveUser(user);
    await reloadStoresAfterAccountSwitch();

    // 启动时复检 Star；失败时先用本地缓存，进入后仍可被门禁拦住
    final cachedStar = prefs.getBool(_keyStarred) ?? false;
    githubAccessGrantedNotifier.value = cachedStar;
    try {
      final starred = await GitHubOAuthService.instance.hasStarredRepo(token);
      githubAccessGrantedNotifier.value = starred;
      await prefs.setBool(_keyStarred, starred);
      if (!starred) {
        // 保留用户信息便于引导 Star，但不放行
      }
    } catch (_) {
      // 离线：沿用缓存；无缓存则不放行
      if (!cachedStar) {
        githubAccessGrantedNotifier.value = false;
      }
    }
  }

  Future<void> _saveToPrefs(AuthUser user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyToken, user.token);
    await prefs.setString(_keyUserId, user.userId);
    await prefs.setString(_keyPhoneOrEmail, user.phoneOrEmail);
    await prefs.setString(_keyNickname, user.nickname ?? '');
    await prefs.setString(_keyAvatarUrl, user.avatarUrl ?? '');
    await prefs.setString(_keyGithubLogin, user.githubLogin ?? '');
    await prefs.setString(_keyAuthProvider, user.authProvider);
    if (user.isGitHub) {
      await GitHubOAuthService.instance.saveTokenSecurely(user.token);
    }
  }

  Future<void> _clearPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyToken);
    await prefs.remove(_keyUserId);
    await prefs.remove(_keyPhoneOrEmail);
    await prefs.remove(_keyNickname);
    await prefs.remove(_keyAvatarUrl);
    await prefs.remove(_keyGithubLogin);
    await prefs.remove(_keyAuthProvider);
    await prefs.remove(_keyStarred);
  }

  /// GitHub Device Flow 成功且已 Star 后写入本地。
  Future<AuthUser> loginWithGitHub({
    required String accessToken,
    required GitHubUserProfile profile,
    required bool starred,
  }) async {
    final user = AuthUser(
      userId: 'gh_${profile.id}',
      phoneOrEmail: 'github:${profile.login}',
      nickname: profile.name?.trim().isNotEmpty == true
          ? profile.name
          : profile.login,
      avatarUrl: profile.avatarUrl,
      token: accessToken,
      githubLogin: profile.login,
      authProvider: 'github',
    );
    await _saveToPrefs(user);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyStarred, starred);
    currentUserNotifier.value = user;
    githubAccessGrantedNotifier.value = starred;
    AccountStoragePaths.setActiveUser(user);
    await reloadStoresAfterAccountSwitch();
    return user;
  }

  /// 重新检查 Star；返回是否已 Star。
  Future<bool> refreshGitHubStarStatus() async {
    final u = currentUser;
    if (u == null || !u.isGitHub) {
      githubAccessGrantedNotifier.value = false;
      return false;
    }
    final starred = await GitHubOAuthService.instance.hasStarredRepo(u.token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyStarred, starred);
    githubAccessGrantedNotifier.value = starred;
    return starred;
  }

  /// 兼容旧登录页：若仍调用则提示改走 GitHub（保留 Mock 仅供测试）。
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
    throw UnsupportedError('请使用 GitHub 账号登录（应用内已改为 GitHub + Star 门禁）');
  }

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
    throw UnsupportedError('请使用 GitHub 账号登录（已取消自建注册）');
  }

  Future<void> logout() async {
    final token = currentUser?.token;
    if (ApiConfig.isAuthApiConfigured &&
        token != null &&
        !token.startsWith('mock_') &&
        currentUser?.isGitHub != true) {
      try {
        await UserSyncService(baseUrl: ApiConfig.authApiBaseUrl).push(token);
      } catch (_) {}
    }
    if (_api != null && token != null && currentUser?.isGitHub != true) {
      try {
        await _api!.logout(token);
      } catch (_) {}
    }
    UserSyncScheduler.cancelPendingPush();
    AccountStoragePaths.setActiveUser(null);
    try {
      await reloadStoresAfterAccountSwitch();
    } catch (_) {}
    await _clearPrefs();
    await GitHubOAuthService.instance.clearTokenSecurely();
    currentUserNotifier.value = null;
    githubAccessGrantedNotifier.value = false;
  }

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
    if (_api != null &&
        !current.token.startsWith('mock_') &&
        !current.isGitHub) {
      try {
        final remote = await _api!.updateProfile(
          current.token,
          nickname: nickname,
          avatarUrl: (avatarUrl != null && avatarUrl.startsWith('http'))
              ? avatarUrl
              : null,
        );
        if (remote != null) {
          next = next.copyWith(
            nickname: remote.nickname,
            avatarUrl:
                (avatarUrl ?? '').isNotEmpty ? avatarUrl : remote.avatarUrl,
          );
        }
      } catch (_) {}
    }
    await _saveToPrefs(next);
    currentUserNotifier.value = next;
    return next;
  }
}
