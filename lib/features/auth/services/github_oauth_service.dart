import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../../config/github_oauth_config.dart';

/// Device Flow 第一步返回的设备码信息。
class GitHubDeviceCode {
  const GitHubDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int expiresIn;
  final int interval;
}

/// GitHub 用户资料（/user）。
class GitHubUserProfile {
  const GitHubUserProfile({
    required this.id,
    required this.login,
    this.name,
    this.avatarUrl,
  });

  final String id;
  final String login;
  final String? name;
  final String? avatarUrl;
}

/// 无后端 GitHub OAuth Device Flow + Star 校验。
class GitHubOAuthService {
  GitHubOAuthService({
    http.Client? httpClient,
    FlutterSecureStorage? secureStorage,
  })  : _http = httpClient ?? http.Client(),
        _secure = secureStorage ?? const FlutterSecureStorage();

  static final GitHubOAuthService instance = GitHubOAuthService();

  static const String _secureTokenKey = 'hibi_github_oauth_token';

  final http.Client _http;
  final FlutterSecureStorage _secure;

  /// 请求设备码；失败时抛出异常（含未配置 client_id）。
  Future<GitHubDeviceCode> requestDeviceCode() async {
    final id = GitHubOAuthConfig.clientId.trim();
    if (id.isEmpty) {
      throw StateError(
        '未配置 GitHub OAuth client_id。请设置 --dart-define=GITHUB_CLIENT_ID=... '
        '或填写 lib/config/github_oauth_config.dart 的 defaultClientId。',
      );
    }
    final resp = await _http.post(
      Uri.parse('https://github.com/login/device/code'),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {
        'client_id': id,
        'scope': GitHubOAuthConfig.scopes,
      },
    ).timeout(const Duration(seconds: 20));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError('获取设备码失败 (${resp.statusCode}): ${resp.body}');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final deviceCode = map['device_code']?.toString() ?? '';
    final userCode = map['user_code']?.toString() ?? '';
    final uri = map['verification_uri']?.toString() ??
        'https://github.com/login/device';
    if (deviceCode.isEmpty || userCode.isEmpty) {
      throw StateError('设备码响应无效: ${resp.body}');
    }
    return GitHubDeviceCode(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUri: uri,
      expiresIn: (map['expires_in'] as num?)?.toInt() ?? 900,
      interval: (map['interval'] as num?)?.toInt() ?? 5,
    );
  }

  /// 打开浏览器前往验证页。
  Future<bool> openVerificationPage(String verificationUri) async {
    final uri = Uri.tryParse(verificationUri);
    if (uri == null) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// 轮询直到拿到 access_token，或超时/拒绝。
  /// [shouldCancel] 返回 true 时中止。
  Future<String> pollAccessToken(
    GitHubDeviceCode code, {
    bool Function()? shouldCancel,
  }) async {
    final id = GitHubOAuthConfig.clientId.trim();
    var interval = Duration(seconds: code.interval.clamp(5, 30));
    final deadline = DateTime.now().add(Duration(seconds: code.expiresIn));

    while (DateTime.now().isBefore(deadline)) {
      if (shouldCancel?.call() == true) {
        throw StateError('已取消登录');
      }
      await Future<void>.delayed(interval);
      if (shouldCancel?.call() == true) {
        throw StateError('已取消登录');
      }

      final resp = await _http.post(
        Uri.parse('https://github.com/login/oauth/access_token'),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: {
          'client_id': id,
          'device_code': code.deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        },
      ).timeout(const Duration(seconds: 20));

      Map<String, dynamic> map;
      try {
        map = jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }

      final err = map['error']?.toString();
      if (err == null || err.isEmpty) {
        final token = map['access_token']?.toString() ?? '';
        if (token.isEmpty) {
          throw StateError('未返回 access_token');
        }
        return token;
      }
      if (err == 'authorization_pending') {
        continue;
      }
      if (err == 'slow_down') {
        interval += const Duration(seconds: 5);
        continue;
      }
      if (err == 'expired_token') {
        throw StateError('设备码已过期，请重新登录');
      }
      if (err == 'access_denied') {
        throw StateError('你已拒绝授权');
      }
      throw StateError('授权失败: $err');
    }
    throw StateError('登录超时，请重试');
  }

  Future<GitHubUserProfile> fetchUser(String accessToken) async {
    final resp = await _http.get(
      Uri.parse('https://api.github.com/user'),
      headers: _apiHeaders(accessToken),
    ).timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw StateError('获取 GitHub 用户失败 (${resp.statusCode})');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final login = map['login']?.toString() ?? '';
    final id = map['id']?.toString() ?? login;
    if (login.isEmpty) throw StateError('GitHub 用户名为空');
    return GitHubUserProfile(
      id: id,
      login: login,
      name: map['name']?.toString(),
      avatarUrl: map['avatar_url']?.toString(),
    );
  }

  /// `true` = 已 Star；`false` = 未 Star。网络错误抛异常。
  Future<bool> hasStarredRepo(String accessToken) async {
    final uri = Uri.parse(
      'https://api.github.com/user/starred/'
      '${GitHubOAuthConfig.owner}/${GitHubOAuthConfig.repo}',
    );
    final resp = await _http.get(
      uri,
      headers: {
        ..._apiHeaders(accessToken),
        'Accept': 'application/vnd.github+json',
      },
    ).timeout(const Duration(seconds: 20));
    if (resp.statusCode == 204) return true;
    if (resp.statusCode == 404) return false;
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw StateError('GitHub 令牌无效或权限不足 (${resp.statusCode})');
    }
    throw StateError('检查 Star 状态失败 (${resp.statusCode})');
  }

  Future<bool> openRepoForStar() {
    return openVerificationPage(GitHubOAuthConfig.starUrl);
  }

  Future<void> saveTokenSecurely(String token) async {
    try {
      await _secure.write(key: _secureTokenKey, value: token);
    } catch (e) {
      debugPrint('secure_storage write failed: $e');
    }
  }

  Future<String?> readTokenSecurely() async {
    try {
      return await _secure.read(key: _secureTokenKey);
    } catch (e) {
      debugPrint('secure_storage read failed: $e');
      return null;
    }
  }

  Future<void> clearTokenSecurely() async {
    try {
      await _secure.delete(key: _secureTokenKey);
    } catch (_) {}
  }

  Map<String, String> _apiHeaders(String token) => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'HIBI-Flutter-App',
      };
}
