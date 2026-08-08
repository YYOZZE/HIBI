import 'dart:convert';

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

/// 会话快照（不含密码；token 与 prefs/secure 双写，升级后可恢复）。
const String _keySessionJson = 'hibi_github_session_v1';

/// 账户状态与持久化：单例，应用内唯一。
/// 3.3.8+ 门禁以 GitHub OAuth + Star 为准；旧版手机号/Mock 不再视为有效登录。
///
/// **持久化策略（绝不存 GitHub 密码）**：
/// - `access_token` → `flutter_secure_storage` + SharedPreferences 备份
/// - 用户资料 / Star 缓存 → SharedPreferences（含 JSON 快照）
/// - 冷启动：有有效 token 且 Star 缓存/复检通过 → 直接进主界面
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

    // 1) 合并 token：secure 优先，prefs 兜底；单边缺失则补写另一边。
    final prefsToken = prefs.getString(_keyToken);
    final secureToken = await GitHubOAuthService.instance.readTokenSecurely();
    var token = (secureToken != null && secureToken.isNotEmpty)
        ? secureToken
        : prefsToken;

    if (token == null || token.isEmpty) {
      // 尝试从会话快照恢复 token（极少数 secure/prefs 键异常时）
      token = _tokenFromSessionJson(prefs.getString(_keySessionJson));
    }

    if (token == null || token.isEmpty) {
      currentUserNotifier.value = null;
      githubAccessGrantedNotifier.value = false;
      AccountStoragePaths.setActiveUser(null);
      return;
    }

    // 双侧补齐，降低「升级后只丢一边」导致的重登。
    if (prefsToken != token) {
      await prefs.setString(_keyToken, token);
    }
    if (secureToken != token) {
      await GitHubOAuthService.instance.saveTokenSecurely(token);
    }

    var userId = prefs.getString(_keyUserId) ?? '';
    var phoneOrEmail = prefs.getString(_keyPhoneOrEmail) ?? '';
    var nickname = prefs.getString(_keyNickname);
    var avatarUrl = prefs.getString(_keyAvatarUrl);
    var githubLogin = prefs.getString(_keyGithubLogin);
    var provider = prefs.getString(_keyAuthProvider) ?? 'legacy';

    // 会话快照补全（prefs 单项被清、升级迁移时）
    final snap = _decodeSession(prefs.getString(_keySessionJson));
    if (snap != null) {
      if (userId.isEmpty) userId = snap['userId']?.toString() ?? '';
      if (phoneOrEmail.isEmpty) {
        phoneOrEmail = snap['phoneOrEmail']?.toString() ?? '';
      }
      nickname = (nickname == null || nickname.isEmpty)
          ? snap['nickname']?.toString()
          : nickname;
      avatarUrl = (avatarUrl == null || avatarUrl.isEmpty)
          ? snap['avatarUrl']?.toString()
          : avatarUrl;
      if (githubLogin == null || githubLogin.isEmpty) {
        githubLogin = snap['githubLogin']?.toString();
      }
      if (provider == 'legacy' && snap['authProvider']?.toString() == 'github') {
        provider = 'github';
      }
    }

    if ((githubLogin != null && githubLogin.isNotEmpty) ||
        GitHubOAuthService.looksLikeGitHubToken(token) ||
        phoneOrEmail.startsWith('github:')) {
      provider = 'github';
    }

    var user = AuthUser(
      userId: userId,
      phoneOrEmail: phoneOrEmail,
      nickname: nickname,
      avatarUrl: avatarUrl,
      token: token,
      githubLogin: githubLogin,
      authProvider: provider,
    );

    // 2) 资料残缺时用 token 向 GitHub 恢复，禁止误清会话逼用户重输密码。
    if (!user.isGitHub ||
        (user.githubLogin == null || user.githubLogin!.isEmpty) ||
        user.userId.isEmpty) {
      if (GitHubOAuthService.looksLikeGitHubToken(token) ||
          provider == 'github' ||
          phoneOrEmail.startsWith('github:')) {
        try {
          final profile =
              await GitHubOAuthService.instance.fetchUser(token);
          user = AuthUser(
            userId: 'gh_${profile.id}',
            phoneOrEmail: 'github:${profile.login}',
            nickname: profile.name?.trim().isNotEmpty == true
                ? profile.name
                : profile.login,
            avatarUrl: profile.avatarUrl,
            token: token,
            githubLogin: profile.login,
            authProvider: 'github',
          );
          await _saveToPrefs(user);
        } on GitHubUnauthorizedException {
          await _invalidateLocalSession();
          return;
        } catch (e) {
          debugPrint('恢复 GitHub 资料失败（保留本地会话）: $e');
          // 离线且本地几乎无资料：若完全不像 GitHub，才放弃
          if (!user.isGitHub &&
              !GitHubOAuthService.looksLikeGitHubToken(token)) {
            await _invalidateLocalSession();
            return;
          }
          // 标记为 github，避免旧逻辑误清
          user = user.copyWith(
            authProvider: 'github',
            githubLogin: user.githubLogin ??
                (phoneOrEmail.startsWith('github:')
                    ? phoneOrEmail.substring('github:'.length)
                    : user.githubLogin),
          );
        }
      } else {
        // 旧版非 GitHub 登录不再放行
        await _invalidateLocalSession();
        return;
      }
    }

    if (!user.isGitHub) {
      await _invalidateLocalSession();
      return;
    }

    currentUserNotifier.value = user;
    AccountStoragePaths.setActiveUser(user);
    await reloadStoresAfterAccountSwitch();

    // 3) Star：先用本地缓存放行（升级/弱网不挡），再后台复检
    final cachedStar = prefs.getBool(_keyStarred) ??
        (snap?['starred'] == true);
    githubAccessGrantedNotifier.value = cachedStar;

    try {
      final starred =
          await GitHubOAuthService.instance.hasStarredRepo(token);
      githubAccessGrantedNotifier.value = starred;
      await prefs.setBool(_keyStarred, starred);
      await _writeSessionSnapshot(user, starred: starred);
      // 未 Star：保留登录态，门禁页只引导 Star，不要求重新输密码
    } on GitHubUnauthorizedException {
      await _invalidateLocalSession();
    } catch (e) {
      debugPrint('启动 Star 复检失败（沿用缓存 $cachedStar）: $e');
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
      final starred = prefs.getBool(_keyStarred) ??
          githubAccessGrantedNotifier.value;
      await _writeSessionSnapshot(user, starred: starred);
    }
  }

  Future<void> _writeSessionSnapshot(
    AuthUser user, {
    required bool starred,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, dynamic>{
      'userId': user.userId,
      'phoneOrEmail': user.phoneOrEmail,
      'nickname': user.nickname,
      'avatarUrl': user.avatarUrl,
      'githubLogin': user.githubLogin,
      'authProvider': user.authProvider,
      'starred': starred,
      // token 再备份一份到快照，仅作 prefs 损坏时的最后手段（仍非密码）
      'accessToken': user.token,
      'savedAt': DateTime.now().toIso8601String(),
    };
    await prefs.setString(_keySessionJson, jsonEncode(map));
  }

  Map<String, dynamic>? _decodeSession(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  String? _tokenFromSessionJson(String? raw) {
    final map = _decodeSession(raw);
    final t = map?['accessToken']?.toString();
    if (t == null || t.isEmpty) return null;
    return t;
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
    await prefs.remove(_keySessionJson);
  }

  Future<void> _invalidateLocalSession() async {
    await _clearPrefs();
    await GitHubOAuthService.instance.clearTokenSecurely();
    currentUserNotifier.value = null;
    githubAccessGrantedNotifier.value = false;
    AccountStoragePaths.setActiveUser(null);
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyStarred, starred);
    await _saveToPrefs(user);
    currentUserNotifier.value = user;
    githubAccessGrantedNotifier.value = starred;
    AccountStoragePaths.setActiveUser(user);
    await reloadStoresAfterAccountSwitch();
    return user;
  }

  /// 重新检查 Star；返回是否已 Star。
  /// token 失效时清除本地会话；网络错误保留缓存、不强迫重登。
  Future<bool> refreshGitHubStarStatus() async {
    final u = currentUser;
    if (u == null || !u.isGitHub) {
      githubAccessGrantedNotifier.value = false;
      return false;
    }
    try {
      final starred =
          await GitHubOAuthService.instance.hasStarredRepo(u.token);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyStarred, starred);
      await _writeSessionSnapshot(u, starred: starred);
      githubAccessGrantedNotifier.value = starred;
      return starred;
    } on GitHubUnauthorizedException {
      await _invalidateLocalSession();
      return false;
    } catch (e) {
      debugPrint('refreshGitHubStarStatus 网络失败，保留缓存: $e');
      return githubAccessGrantedNotifier.value;
    }
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
    await _invalidateLocalSession();
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
