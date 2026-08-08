import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
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
    this.verificationUriComplete,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUri;
  /// GitHub 可能返回的「已带 user_code」完整链接，优先用于内嵌 WebView。
  final String? verificationUriComplete;
  final int expiresIn;
  final int interval;

  /// 打开验证页时优先用完整链接，否则退回 verification_uri。
  String get bestVerificationUri =>
      (verificationUriComplete != null && verificationUriComplete!.isNotEmpty)
          ? verificationUriComplete!
          : verificationUri;
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

/// 面向用户的友好错误（UI 直接展示 [message]，勿再 toString 裸抛）。
class GitHubOAuthException implements Exception {
  const GitHubOAuthException(this.message, {this.canRetry = true});

  final String message;
  final bool canRetry;

  @override
  String toString() => message;
}

/// 无后端 GitHub OAuth Device Flow + Star 校验。
class GitHubOAuthService {
  GitHubOAuthService({
    http.Client? httpClient,
    FlutterSecureStorage? secureStorage,
  })  : _http = httpClient ?? _createHttpClient(),
        _ownsClient = httpClient == null,
        _secure = secureStorage ?? const FlutterSecureStorage();

  static final GitHubOAuthService instance = GitHubOAuthService();

  static const String _secureTokenKey = 'hibi_github_oauth_token';

  /// 连接超时（国内到 github.com 常偏慢）。
  static const Duration connectTimeout = Duration(seconds: 25);

  /// 单次请求总超时（连接 + 读响应）。
  static const Duration requestTimeout = Duration(seconds: 55);

  final http.Client _http;
  final bool _ownsClient;
  final FlutterSecureStorage _secure;

  static http.Client _createHttpClient() {
    final inner = HttpClient()
      ..connectionTimeout = connectTimeout
      ..idleTimeout = const Duration(seconds: 60)
      ..userAgent = 'HIBI-Flutter-App';
    return IOClient(inner);
  }

  void dispose() {
    if (_ownsClient) _http.close();
  }

  /// 请求设备码；失败时抛出 [GitHubOAuthException]。
  Future<GitHubDeviceCode> requestDeviceCode() async {
    final id = GitHubOAuthConfig.clientId.trim();
    if (id.isEmpty) {
      throw const GitHubOAuthException(
        '未配置 GitHub OAuth Client ID。请确认 OAuth App 已创建并启用 Device Flow。',
        canRetry: false,
      );
    }
    final resp = await _postForm(
      Uri.parse('https://github.com/login/device/code'),
      {
        'client_id': id,
        'scope': GitHubOAuthConfig.scopes,
      },
      stepLabel: '申请设备码',
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw GitHubOAuthException(
        _httpStatusHint(resp.statusCode, '申请设备码失败', resp.body),
      );
    }
    final map = _decodeJsonMap(resp.body, stepLabel: '申请设备码');
    final deviceCode = map['device_code']?.toString() ?? '';
    final userCode = map['user_code']?.toString() ?? '';
    final uri = map['verification_uri']?.toString() ??
        'https://github.com/login/device';
    final uriComplete = map['verification_uri_complete']?.toString();
    if (deviceCode.isEmpty || userCode.isEmpty) {
      throw const GitHubOAuthException('设备码响应无效，请重试或检查 OAuth App 是否启用 Device Flow。');
    }
    return GitHubDeviceCode(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUri: uri,
      verificationUriComplete:
          (uriComplete != null && uriComplete.isNotEmpty) ? uriComplete : null,
      expiresIn: (map['expires_in'] as num?)?.toInt() ?? 900,
      interval: (map['interval'] as num?)?.toInt() ?? 5,
    );
  }

  /// 打开系统浏览器前往验证页（内嵌 WebView 失败时的兜底）。
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
        throw const GitHubOAuthException('已取消登录', canRetry: true);
      }
      await Future<void>.delayed(interval);
      if (shouldCancel?.call() == true) {
        throw const GitHubOAuthException('已取消登录', canRetry: true);
      }

      http.Response resp;
      try {
        resp = await _postForm(
          Uri.parse('https://github.com/login/oauth/access_token'),
          {
            'client_id': id,
            'device_code': code.deviceCode,
            'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          },
          stepLabel: '等待授权',
        );
      } on GitHubOAuthException {
        // 轮询期间偶发超时：跳过本轮继续等，避免整段登录失败。
        continue;
      }

      Map<String, dynamic> map;
      try {
        map = _decodeJsonMap(resp.body, stepLabel: '等待授权');
      } catch (_) {
        continue;
      }

      final err = map['error']?.toString();
      if (err == null || err.isEmpty) {
        final token = map['access_token']?.toString() ?? '';
        if (token.isEmpty) {
          throw const GitHubOAuthException('未返回 access_token，请重试。');
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
        throw const GitHubOAuthException('设备码已过期，请重新登录。');
      }
      if (err == 'access_denied') {
        throw const GitHubOAuthException('你已在 GitHub 网页上拒绝授权。');
      }
      throw GitHubOAuthException('授权失败：$err');
    }
    throw const GitHubOAuthException('登录等待超时，请重新开始并在时限内完成网页授权。');
  }

  Future<GitHubUserProfile> fetchUser(String accessToken) async {
    final resp = await _getJson(
      Uri.parse('https://api.github.com/user'),
      headers: _apiHeaders(accessToken),
      stepLabel: '获取用户信息',
    );
    if (resp.statusCode != 200) {
      throw GitHubOAuthException(
        _httpStatusHint(resp.statusCode, '获取 GitHub 用户失败', resp.body),
      );
    }
    final map = _decodeJsonMap(resp.body, stepLabel: '获取用户信息');
    final login = map['login']?.toString() ?? '';
    final id = map['id']?.toString() ?? login;
    if (login.isEmpty) {
      throw const GitHubOAuthException('GitHub 用户名为空，请重试。');
    }
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
    final resp = await _getJson(
      uri,
      headers: {
        ..._apiHeaders(accessToken),
        'Accept': 'application/vnd.github+json',
      },
      stepLabel: '检查 Star',
    );
    if (resp.statusCode == 204) return true;
    if (resp.statusCode == 404) return false;
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw GitHubOAuthException(
        'GitHub 令牌无效或权限不足（${resp.statusCode}），请重新登录。',
      );
    }
    throw GitHubOAuthException(
      _httpStatusHint(resp.statusCode, '检查 Star 状态失败', resp.body),
    );
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

  Future<http.Response> _postForm(
    Uri uri,
    Map<String, String> body, {
    required String stepLabel,
  }) async {
    try {
      return await _http
          .post(
            uri,
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/x-www-form-urlencoded',
              'User-Agent': 'HIBI-Flutter-App',
            },
            body: body,
          )
          .timeout(requestTimeout);
    } catch (e) {
      throw _mapNetworkError(e, stepLabel);
    }
  }

  Future<http.Response> _getJson(
    Uri uri, {
    required Map<String, String> headers,
    required String stepLabel,
  }) async {
    try {
      return await _http.get(uri, headers: headers).timeout(requestTimeout);
    } catch (e) {
      throw _mapNetworkError(e, stepLabel);
    }
  }

  Map<String, dynamic> _decodeJsonMap(String body, {required String stepLabel}) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw const FormatException('not a map');
    } catch (_) {
      throw GitHubOAuthException('$stepLabel 响应无法解析，请检查网络后重试。');
    }
  }

  GitHubOAuthException _mapNetworkError(Object e, String stepLabel) {
    if (e is GitHubOAuthException) return e;
    if (e is TimeoutException) {
      return GitHubOAuthException(
        '$stepLabel 超时：当前网络访问 GitHub 较慢或被阻断。\n'
        '请确认能打开 github.com（必要时开启可访问 GitHub 的网络），然后点「重试」。',
      );
    }
    if (e is SocketException) {
      final msg = e.message;
      return GitHubOAuthException(
        '$stepLabel 失败：无法连接 GitHub（$msg）。\n'
        '本应用需直连 github.com / api.github.com，请检查网络后重试。',
      );
    }
    if (e is HandshakeException) {
      return GitHubOAuthException(
        '$stepLabel 失败：与 GitHub 的安全连接异常。请检查系统时间与网络环境后重试。',
      );
    }
    if (e is http.ClientException) {
      return GitHubOAuthException(
        '$stepLabel 失败：${e.message}\n请确认可访问 GitHub 后重试。',
      );
    }
    return GitHubOAuthException('$stepLabel 失败：$e');
  }

  String _httpStatusHint(int status, String title, String body) {
    if (status == 401 || status == 403) {
      return '$title（$status）。请确认 OAuth App 的 Client ID 正确且已启用 Device Flow。';
    }
    if (status == 404) {
      return '$title（404）。请确认已启用 Device Flow。';
    }
    if (status == 429) {
      return '$title：请求过于频繁，请稍后再试。';
    }
    final snippet = body.length > 160 ? '${body.substring(0, 160)}…' : body;
    return '$title（$status）${snippet.isEmpty ? '' : '：$snippet'}';
  }

  /// 将任意异常转为用户可读中文。
  static String friendlyError(Object e) {
    if (e is GitHubOAuthException) return e.message;
    final s = e.toString();
    if (s.contains('TimeoutException')) {
      return '连接 GitHub 超时。请确认网络可访问 github.com 后重试。';
    }
    return s
        .replaceFirst('Bad state: ', '')
        .replaceFirst('Exception: ', '')
        .replaceFirst('GitHubOAuthException: ', '');
  }
}
