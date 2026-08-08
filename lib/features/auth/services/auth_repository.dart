import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../config/api_config.dart';
import '../../../config/auth_gate_config.dart';
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
/// 本机稳定 local id（重装前不变；用于局域网握手）。
const String _keyLocalAccountId = 'hibi_local_account_id';

/// 会话快照（不含密码；token 与 prefs/secure 双写，升级后可恢复）。
const String _keySessionJson = 'hibi_github_session_v1';

/// App 访问状态机。
///
/// - [notLoggedIn]：无会话
/// - [local]：本地账号 → 可进主壳，助理关闭，不要求 Star
/// - [githubNeedStar]：GitHub 已授权未 Star → 不进主壳，引导 Star
/// - [githubOk]：GitHub + Star 204 → 可进主壳，助理开放
enum AppAccessState {
  notLoggedIn,
  local,
  githubNeedStar,
  githubOk,
}

/// 账户状态与持久化：单例，应用内唯一。
/// 支持本地账号与 GitHub（+ Star）两条路径。
///
/// **持久化策略（绝不存 GitHub 密码）**：
/// - GitHub `access_token` → `flutter_secure_storage` + SharedPreferences 备份
/// - 本地会话 → SharedPreferences（`local_<稳定id>`）
/// - 用户资料 / Star 缓存 → SharedPreferences（含 JSON 快照）
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

  /// GitHub Star 是否通过（仅 GitHub 路径有意义；本地账号恒为 false）。
  final ValueNotifier<bool> githubAccessGrantedNotifier = ValueNotifier<bool>(false);

  AuthUser? get currentUser => currentUserNotifier.value;

  /// 是否可进主壳（本地 或 GitHub+Star）。
  /// V4.0.1：[AuthGateConfig.bypassGitHubLoginGate] 为 true 时恒为可进（需已有会话）。
  bool get canEnterShell {
    if (AuthGateConfig.bypassGitHubLoginGate) {
      final u = currentUser;
      return u != null && u.token.isNotEmpty;
    }
    return accessState == AppAccessState.local ||
        accessState == AppAccessState.githubOk;
  }

  /// 是否可使用助理（门禁开启时仅 GitHub + Star）。
  /// V4.0.1：绕过开关打开时助理保持开放。
  bool get canUseAssistant {
    if (AuthGateConfig.bypassGitHubLoginGate) {
      return canEnterShell;
    }
    return accessState == AppAccessState.githubOk;
  }

  /// 兼容旧调用：曾表示「GitHub 会话可进 App」；现等同 [canUseAssistant]。
  bool get canEnterApp => canUseAssistant;

  /// 门禁状态机。
  AppAccessState get accessState {
    final u = currentUser;
    if (u == null || u.token.isEmpty) return AppAccessState.notLoggedIn;
    if (u.isLocal) return AppAccessState.local;
    if (!u.isGitHub) return AppAccessState.notLoggedIn;
    if (githubAccessGrantedNotifier.value) return AppAccessState.githubOk;
    return AppAccessState.githubNeedStar;
  }

  AuthApi? _api;
  AuthApi? get authApi => _api;
  set authApi(AuthApi? value) => _api = value;

  Future<void> _loadFuture = Future<void>.value();

  Future<void> ensureLoaded() async {
    await _loadFuture;
    // V4.0.1：绕过 GitHub 门禁时，无会话则自动本地账号，打开即进。
    if (AuthGateConfig.bypassGitHubLoginGate) {
      final u = currentUser;
      if (u == null || u.token.isEmpty) {
        await loginAsLocal();
      }
    }
  }

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
      final snapProvider = snap['authProvider']?.toString();
      if (provider == 'legacy' &&
          (snapProvider == 'github' || snapProvider == 'local')) {
        provider = snapProvider!;
      }
    }

    // —— 本地账号路径：进主壳，不要求 Star ——
    if (provider == 'local' ||
        token.startsWith('local_') ||
        phoneOrEmail.startsWith('local:')) {
      final localId = (userId.isNotEmpty
              ? userId
              : await _ensureStableLocalId(prefs))
          .trim();
      final user = AuthUser(
        userId: localId,
        phoneOrEmail: 'local:$localId',
        nickname: (nickname == null || nickname.isEmpty) ? '本地账号' : nickname,
        avatarUrl: avatarUrl,
        token: token.startsWith('local_') ? token : 'local_$localId',
        authProvider: 'local',
      );
      githubAccessGrantedNotifier.value = false;
      currentUserNotifier.value = user;
      AccountStoragePaths.setActiveUser(user);
      await prefs.setString(_keyToken, user.token);
      await prefs.setString(_keyUserId, user.userId);
      await prefs.setString(_keyAuthProvider, 'local');
      await _writeSessionSnapshot(user, starred: false);
      await reloadStoresAfterAccountSwitch();
      return;
    }

    // 双侧补齐（仅 GitHub token）
    if (prefsToken != token) {
      await prefs.setString(_keyToken, token);
    }
    if (secureToken != token) {
      await GitHubOAuthService.instance.saveTokenSecurely(token);
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
        // 旧版非 GitHub / 非本地登录不再放行
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

    // 3) Star：默认不放行；API 确认 204 才可进 App。
    // 弱网复检失败时才回退本地缓存（升级离线不白屏卡死）。
    final cachedStar = prefs.getBool(_keyStarred) ??
        (snap?['starred'] == true);
    githubAccessGrantedNotifier.value = false;

    var starred = false;
    try {
      starred = await GitHubOAuthService.instance.hasStarredRepo(token);
      await prefs.setBool(_keyStarred, starred);
      await _writeSessionSnapshot(user, starred: starred);
      // 未 Star：保留 token，门禁页引导 Star，绝不进主壳
    } on GitHubUnauthorizedException {
      await _invalidateLocalSession();
      return;
    } catch (e) {
      debugPrint('启动 Star 复检失败（沿用缓存 $cachedStar）: $e');
      starred = cachedStar;
    }

    // local → 当前 GitHub 的可选导入由主壳弹窗处理，此处不静默全合并
    await reloadStoresAfterAccountSwitch();
    githubAccessGrantedNotifier.value = starred;
  }

  Future<String> _ensureStableLocalId(SharedPreferences prefs) async {
    var id = prefs.getString(_keyLocalAccountId)?.trim();
    if (id != null && id.isNotEmpty) return id;
    id =
        'local_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    await prefs.setString(_keyLocalAccountId, id);
    return id;
  }

  /// 本机账号进入：可用思维/日程/传输；助理不可用；不要求 Star。
  Future<AuthUser> loginAsLocal({String? nickname}) async {
    final prefs = await SharedPreferences.getInstance();
    final localId = await _ensureStableLocalId(prefs);
    final user = AuthUser(
      userId: localId,
      phoneOrEmail: 'local:$localId',
      nickname: (nickname == null || nickname.trim().isEmpty)
          ? '本地账号'
          : nickname.trim(),
      token: 'local_$localId',
      authProvider: 'local',
    );
    githubAccessGrantedNotifier.value = false;
    await prefs.setBool(_keyStarred, false);
    await prefs.remove(_keyGithubLogin);
    await _saveToPrefs(user);
    // 本地 token 勿写入 GitHub secure 槽
    await GitHubOAuthService.instance.clearTokenSecurely();
    currentUserNotifier.value = user;
    AccountStoragePaths.setActiveUser(user);
    await reloadStoresAfterAccountSwitch();
    return user;
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
    } else if (user.isLocal) {
      await _writeSessionSnapshot(user, starred: false);
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

  /// 写入 GitHub 会话。`starred == true` 才算登录成功、可进主壳；
  /// `starred == false` 仅保留 token（已授权未 Star），不放行。
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
    // 先关放行，再写会话，避免短暂闪进主壳
    githubAccessGrantedNotifier.value = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyStarred, starred);
    await _saveToPrefs(user);
    currentUserNotifier.value = user;
    AccountStoragePaths.setActiveUser(user);
    await reloadStoresAfterAccountSwitch();
    githubAccessGrantedNotifier.value = starred;
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
    final wasGranted = githubAccessGrantedNotifier.value;
    try {
      final starred =
          await GitHubOAuthService.instance.hasStarredRepo(u.token);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyStarred, starred);
      await _writeSessionSnapshot(u, starred: starred);
      if (!wasGranted && starred) {
        AccountStoragePaths.setActiveUser(u);
        await reloadStoresAfterAccountSwitch();
      }
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
    final user = currentUser;
    final token = user?.token;
    // 本地 / GitHub 会话不走自建 auth API；先清会话，保证门禁立刻回到登录页。
    final mayRemoteLogout = user != null &&
        !user.isLocal &&
        !user.isGitHub &&
        token != null &&
        !token.startsWith('mock_');

    UserSyncScheduler.cancelPendingPush();
    await _invalidateLocalSession();
    try {
      await reloadStoresAfterAccountSwitch();
    } catch (_) {}

    if (!mayRemoteLogout) return;
    if (ApiConfig.isAuthApiConfigured) {
      try {
        await UserSyncService(baseUrl: ApiConfig.authApiBaseUrl).push(token);
      } catch (_) {}
    }
    if (_api != null) {
      try {
        await _api!.logout(token);
      } catch (_) {}
    }
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
